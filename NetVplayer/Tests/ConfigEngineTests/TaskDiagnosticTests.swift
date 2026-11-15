import Foundation
import Testing
import Models
import Storage
import Networking
import FileServiceEngine
import MediaLibraryEngine
@testable import DriveEngine
@testable import NetVplayerApp

@Suite("Local task results and safe diagnostic projection", .serialized, .timeLimit(.minutes(2)))
struct TaskDiagnosticTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("msc06-" + UUID().uuidString) }
    private func scope() -> DriveTransferTaskScope {
        .init(provider: .quark, cacheKey: "private/cache", sourceKey: "private/source", accountReference: "sensitive-account",
              configurationIdentity: "private-config", target: "/private-folder?token=secret", shareID: "private-share",
              sourceFileID: "private-file", name: "private-title.mkv", size: 1, collectionName: "private-collection")
    }
    private func sample(id: UUID = UUID(), time: Date = Date(), state: TaskResultState = .processing) -> TaskDiagnosticRecord {
        .init(id: id, kind: .driveTransfer, provider: .quark, event: .init(time: time, stage: .confirming, state: state))
    }

    @Test func capacityRetentionAndEventBoundsNeverTouchRecoveryEvidence() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageDirectory: root), now = Date()
        let recovery = DriveTransferTaskStore(storage: storage, maximumRecords: 1)
        var task = DriveTransferTask(scope: scope(), now: now.addingTimeInterval(-40 * 86400))
        task.phase = .outcomeUnknown; task.submitted = true; task.cancelled = true; task.remainingReadRetries = 0
        task.remoteTaskID = "https://private.invalid/file?signature=must-not-export"
        try recovery.insert(task)
        let recoveryURL = root.appendingPathComponent(DriveTransferTaskStore.filename)
        let evidence = try Data(contentsOf: recoveryURL)
        let history = TaskDiagnosticStore(storage: storage, maximumRecords: 3)
        for offset in 0..<10 { try history.record(sample(time: now.addingTimeInterval(Double(offset))), now: now) }
        #expect(try history.records(now: now).count == 3)
        let id = UUID()
        for offset in 0..<30 { try history.record(sample(id: id, time: now.addingTimeInterval(Double(offset))), now: now) }
        #expect(try history.records(now: now).first { $0.id == id }?.events.count == 12)
        #expect(try Data(contentsOf: recoveryURL) == evidence)
        #expect(try recovery.records() == [task])
        let historyURL = root.appendingPathComponent(TaskDiagnosticStore.filename)
        let before = try Data(contentsOf: historyURL)
        #expect(try history.records(now: now.addingTimeInterval(15 * 86400)).isEmpty)
        _ = try history.exportData(now: now.addingTimeInterval(15 * 86400))
        #expect(try Data(contentsOf: historyURL) == before)
        #expect(try Data(contentsOf: recoveryURL) == evidence)
        #expect(try recovery.records().first?.remainingReadRetries == 0)
        try history.record(sample(time: now.addingTimeInterval(15 * 86400)), now: now.addingTimeInterval(15 * 86400))
        #expect(try history.records(now: now.addingTimeInterval(15 * 86400)).count == 1)
        #expect(try recovery.records() == [task])
    }

    @Test func explicitProjectionRejectsSensitiveCodesAndExtraPersistedFields() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageDirectory: root), history = TaskDiagnosticStore(storage: storage)
        let record = sample()
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        var events = raw["events"] as! [[String: Any]]
        events[0]["serviceCode"] = "Cookie=secret; token=https://private.invalid/path?sig=secret"
        events[0]["httpStatus"] = 900; events[0]["retryCount"] = 10000
        raw["events"] = events
        raw["configuration"] = ["Authorization": "Bearer secret", "Cookie": "secret"]
        raw["account"] = "sensitive-account"; raw["resourceURL"] = "https://private.invalid/path?signature=secret"
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "records": [raw]])
        try bytes.write(to: root.appendingPathComponent(TaskDiagnosticStore.filename))
        let data = try history.exportData()
        let text = String(decoding: data, as: UTF8.self)
        for privateValue in ["secret", "Cookie", "Authorization", "signature", "private.invalid", "sensitive-account", "configuration", "resourceURL", "localSubjectID"] {
            #expect(!text.contains(privateValue))
        }
        let report = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(report.keys) == ["schemaVersion", "generatedAt", "tasks"])
        let row = (report["tasks"] as! [[String: Any]])[0]
        #expect(Set(row.keys) == ["correlationID", "kind", "provider", "events"])
        let event = (row["events"] as! [[String: Any]])[0]
        #expect(event["retryCount"] as? Int == 99)
        #expect(event["serviceCode"] == nil && event["httpStatus"] == nil)
        #expect(event["state"] as? String == "waitingConfirmation")
        #expect(try Data(contentsOf: root.appendingPathComponent(TaskDiagnosticStore.filename)) == bytes)
        #expect(TaskDiagnosticPrivacy.serviceCode("QuotaExhausted") == "QuotaExhausted")
        #expect(TaskDiagnosticPrivacy.serviceCode("-6") == "-6")
        for secret in ["token=abc", "request-1234", "https://x.invalid/?sig=x", "/private/path", "12345678", "001", "\n401"] {
            #expect(TaskDiagnosticPrivacy.serviceCode(secret) == nil)
        }
    }

    @Test func corruptHistoryAndFutureVersionsPreserveOriginalAndDoNotBlockRecovery() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageDirectory: root), history = TaskDiagnosticStore(storage: storage)
        let url = root.appendingPathComponent(TaskDiagnosticStore.filename)
        for bytes in [Data("broken".utf8), Data(#"{"version":99,"records":[]}"#.utf8)] {
            try bytes.write(to: url)
            #expect(throws: (any Error).self) { try history.records() }
            #expect(throws: (any Error).self) { try history.record(sample()) }
            #expect(try Data(contentsOf: url) == bytes)
            let recovery = DriveTransferTaskStore(storage: storage)
            var task = DriveTransferTask(scope: scope()); task.completed = true
            try recovery.insert(task)
            #expect(try recovery.records().contains(task))
        }
    }

    @Test func reopenedConcurrentWritersKeepAllRowsAndCancellationWins() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let records = (0..<24).map { _ in sample() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask { try TaskDiagnosticStore(storage: StorageManager(storageDirectory: root)).record(record) }
            }
            try await group.waitForAll()
        }
        let store = TaskDiagnosticStore(storage: StorageManager(storageDirectory: root))
        #expect(Set(try store.records().map(\.id)) == Set(records.map(\.id)))
        let id = records[0].id
        try store.record(sample(id: id, state: .cancelled))
        try TaskDiagnosticStore(storage: StorageManager(storageDirectory: root)).record(sample(id: id, state: .needsLogin))
        #expect(try store.records().first { $0.id == id }?.latest.state == .cancelled)
    }

    @Test func productionTransferClassificationRetainsStageRetryAndServiceCode() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageDirectory: root), taskStore = DriveTransferTaskStore(storage: storage)
        let coordinator = DriveTransferCoordinator(store: taskStore), fixture = TaskHTTPResponses()
        do {
            _ = try await coordinator.confirmedTransfer(cacheKey: "private/cache", scope: scope()) { attempt in
                _ = try await attempt.submit(previousIDs: []) { throw URLError(.networkConnectionLost) }
                _ = try await DriveHTTPClient(HTTPClient(), provider: .quark).perform(
                    url: "https://fixture.invalid/1/clouddrive/file/sort?token=secret", headers: ["Cookie": "sensitive-cookie"], timeout: 2
                ) { _ in await fixture.response() }
                throw DriveEngineError.transferConfirmationPending()
            }
        } catch DriveEngineError.transferConfirmationPending { }
        let record = try #require(taskStore.diagnostics.records().first)
        #expect(record.kind == .driveTransfer && record.latest.stage == .confirming)
        #expect(record.latest.state == .needsLogin && record.latest.reason == .credentialExpired)
        #expect(record.latest.retryCount == 1 && record.latest.httpStatus == 401 && record.latest.serviceCode == "31001")
        #expect(await fixture.requests == 2)
        let durable = try #require(taskStore.records().first)
        #expect(durable.protectsUncertainWrite && durable.remainingReadRetries == 1)
        let exported = String(decoding: try taskStore.diagnostics.exportData(), as: UTF8.self)
        for secret in ["private/cache", "private-folder", "private-title", "sensitive-account", "secret", "sensitive-cookie", "fixture.invalid"] { #expect(!exported.contains(secret)) }
        #expect(try DriveTransferTaskStore(storage: StorageManager(storageDirectory: root)).diagnostics.records() == [record])
    }

    @Test func nestedErrorsAndCancellationCannotBecomeFailuresOrLeak() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageDirectory: root), store = DriveTransferTaskStore(storage: storage)
        let secret = NSError(domain: "https://secret.invalid/path?token=x", code: 42,
                             userInfo: [NSLocalizedDescriptionKey: "Cookie=secret", NSUnderlyingErrorKey: URLError(.badURL)])
        #expect(TaskDiagnosticIssue.local(secret).reason == .unavailable)
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [NSUnderlyingErrorKey: secret])
        do {
            _ = try await DriveTransferCoordinator(store: store).confirmedTransfer(cacheKey: "private/cache", scope: scope()) { _ in throw cancelled }
        } catch { #expect(TaskDiagnosticIssue.isCancellation(error)) }
        #expect(try store.records().first?.cancelled == true)
        #expect(try store.diagnostics.records().first?.latest.state == .cancelled)
        #expect(!String(decoding: try store.diagnostics.exportData(), as: UTF8.self).contains("secret"))
    }

    @MainActor @Test func reasonsActionsAndCancellationAreConsistentAcrossEntrances() throws {
        for reason in AppFailureReason.allTaskReasons {
            let failure = DriveServiceFailure(provider: .quark, reason: reason, operation: .listing)
            let issue = DriveTaskDiagnosticIssue.issue(failure)
            let event = TaskDiagnosticEvent(stage: .confirming, state: reason == .credentialExpired ? .needsLogin : .needsAttention, issue: issue)
            #expect(UserFacingErrorPresenter.taskMessage(event) == UserFacingErrorPresenter.message(for: failure, context: .playback))
            let action = UserFacingErrorPresenter.playbackTaskAction(for: failure)
            if reason == .credentialExpired { #expect(action == .login) }
            if [.rateLimited, .temporaryNetwork, .signedURLExpired].contains(reason) { #expect(action == .retryLater) }
            if [.quotaExceeded, .permissionDenied].contains(reason) { #expect(action == .settings) }
            if reason == .outcomeUnknown { #expect(action == .reviewTasks) }
        }
        for cancellation in [CancellationError() as Error, URLError(.cancelled), MediaScanRecoveryError.cancelled, DriveTaskRecoveryError.cancelled] {
            let presentation = UserFacingErrorPresenter.presentation(for: cancellation, context: .storage(operation: "扫描"))
            #expect(presentation.recoverySuggestion.isEmpty)
            #expect(UserFacingErrorPresenter.playbackTaskAction(for: cancellation) == nil)
            #expect(!presentation.combinedMessage.contains("失败"))
        }
        let event = TaskDiagnosticEvent(stage: .preparingPlayback, state: .completed, issue: .init(.playbackAddressPending))
        #expect(UserFacingErrorPresenter.taskState(event) == "已完成")
        #expect(UserFacingErrorPresenter.taskMessage(event).contains("准备播放"))
        #expect(!UserFacingErrorPresenter.taskMessage(event).contains("播放成功"))
    }

    @Test func realScannerEventsReopenWithoutIOAndExplicitRetryAndCancelKeepTheirResults() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageDirectory: root), diagnostics = TaskDiagnosticStore(storage: storage)
        let index = MediaIndex(url: root.appendingPathComponent("index.sqlite"))
        let defaults = UserDefaults(suiteName: "msc06.scan." + UUID().uuidString)!
        let store = FileServiceStore(storage: storage, preferences: UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore()))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "private-library", metadataSource: .local)
        let fixture = TaskScanFixture()
        let scanner = MediaLibraryScanner(index: index, store: store, diagnostics: diagnostics)
        await scanner.scan(library, client: fixture)
        let first = try #require(diagnostics.records().first)
        #expect(first.kind == .mediaScan && first.latest.state == .needsLogin && first.latest.reason == .credentialExpired)
        #expect(first.localSubjectID == library.id)
        let calls = await fixture.calls
        let checkpoint = try #require(try await scanner.checkpoint(libraryID: library.id))
        let reopened = MediaLibraryScanner(index: MediaIndex(url: root.appendingPathComponent("index.sqlite")), store: store, diagnostics: diagnostics)
        #expect(await reopened.diagnosticIssue(libraryID: library.id)?.reason == .credentialExpired)
        #expect(try await reopened.checkpoint(libraryID: library.id) == checkpoint)
        _ = try diagnostics.exportData()
        #expect(await fixture.calls == calls)
        await fixture.recover()
        await reopened.scan(library, client: fixture, request: .resume)
        let retried = try #require(diagnostics.records().first)
        #expect(retried.latest.state == .completed && retried.latest.retryCount == 1)
        await fixture.hold()
        let operation = Task { await reopened.scan(library, client: fixture) }
        await fixture.waitForEntry()
        await reopened.cancel(libraryID: library.id)
        await fixture.release()
        await operation.value
        let cancelled = try #require(diagnostics.records().first)
        #expect(cancelled.latest.state == .cancelled)
        #expect(try await reopened.checkpoint(libraryID: library.id)?.phase == .cancelled)
        let text = String(decoding: try diagnostics.exportData(), as: UTF8.self)
        for secret in ["private-library", "secret", "private.invalid", "Cookie", library.id.uuidString] { #expect(!text.contains(secret)) }
    }

    @MainActor @Test func appRestartAndExportOnlyReadLocalStateAndLoginActionDoesNotResume() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageDirectory: root), recovery = DriveTransferTaskStore(storage: storage)
        var task = DriveTransferTask(scope: scope()); task.phase = .outcomeUnknown; task.submitted = true; task.remainingReadRetries = 0
        try recovery.insert(task)
        let suite = "msc06." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        let original = try Data(contentsOf: root.appendingPathComponent(DriveTransferTaskStore.filename))
        for _ in 0..<2 {
            let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
                                 storageManager: storage, userPreferences: preferences, providerRuntimeBootstrap: nil)
            #expect(state.driveTaskSummaries == [task] && state.recentTaskDiagnostics.count == 1)
            state.refreshTaskDiagnostics()
            try state.exportTaskDiagnostics(to: root.appendingPathComponent("export.json"))
            #expect(state.driveRecoveryOperations.isEmpty && state.driveRecoveryBusy.isEmpty)
            #expect(try Data(contentsOf: root.appendingPathComponent(DriveTransferTaskStore.filename)) == original)
            state.continueDriveTask(task)
            #expect(state.recentTaskDiagnostics.first?.latest.state == .needsLogin)
            #expect(state.driveRecoveryOperations.isEmpty)
            state.pendingTaskLogin = .quark
            state.finishTaskSheetDismissal()
            #expect(state.cloudAuthRequest?.provider == .quark && state.cloudAuthRequest?.resume == nil)
            #expect(state.driveRecoveryOperations.isEmpty)
            state.cancelCloudAuthorization()
        }
        #expect(try recovery.records().first?.remainingReadRetries == 0)
    }
}

private extension AppFailureReason {
    static var allTaskReasons: [Self] { [.credentialExpired, .permissionDenied, .quotaExceeded, .rateLimited, .temporaryNetwork,
                                        .fileMissing, .signedURLExpired, .outcomeUnknown, .mappingChanged, .mappingUnconfirmed] }
}
private actor TaskHTTPResponses {
    var requests = 0
    func response() -> HTTPResponse {
        requests += 1
        return .init(data: Data((requests == 1 ? #"{"code":429}"# : #"{"code":31001,"message":"Cookie=secret"}"#).utf8),
                     statusCode: requests == 1 ? 429 : 401, headers: [:])
    }
}

private actor TaskScanFixture: FileServiceClient {
    var calls = 0
    private var fails = true, holds = false, entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func recover() { fails = false }
    func hold() { holds = true; entered = false }
    func waitForEntry() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
    func release() { holds = false; continuation?.resume(); continuation = nil }
    func connect() async throws {}
    func list(path: String, cursor: String?) async throws -> FileEntryPage {
        calls += 1
        if holds {
            entered = true; waiter?.resume(); waiter = nil
            await withCheckedContinuation { continuation = $0 }
        }
        if fails { throw FileServiceError.authentication }
        return .init(entries: [], nextCursor: nil)
    }
    func stat(path: String) async throws -> FileEntry { throw FileServiceError.path(path) }
    func read(path: String, range: Range<Int64>) async throws -> Data { Data() }
    func resolve(path: String) async throws -> ResolvedFileResource { throw FileServiceError.network("Cookie=secret https://private.invalid/?token=x") }
}
