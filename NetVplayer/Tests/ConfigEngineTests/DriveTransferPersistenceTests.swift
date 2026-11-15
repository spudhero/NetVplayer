import Foundation
import Models
import Storage
import Testing
@testable import DriveEngine
@testable import NetVplayerApp

private actor PersistentTransferCounter {
    var writes = 0
    func write() { writes += 1 }
}

struct DriveTransferPersistenceTests {
    private func scope(_ key: String = "source") -> DriveTransferTaskScope {
        .init(provider: .quark, cacheKey: key, sourceKey: key, accountReference: "account-hash",
              configurationIdentity: "configuration-hash", target: "folder", shareID: "share",
              sourceFileID: "source", name: "sample.mp4", size: 100)
    }
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("msc04-" + UUID().uuidString) }

    @Test func writeAheadAndLostResponseSurviveReinstantiation() async throws {
        let root = location(), remote = PersistentTransferCounter()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DriveTransferTaskStore(storage: StorageManager(storageDirectory: root))
        let coordinator = DriveTransferCoordinator(store: store)
        do {
            _ = try await coordinator.confirmedTransfer(cacheKey: "source", scope: scope()) { attempt in
                _ = try await attempt.submit(previousIDs: ["older"]) {
                    let independent = DriveTransferTaskStore(storage: StorageManager(storageDirectory: root))
                    let disk = try #require(independent.records().first)
                    #expect(disk.submitted && disk.phase == .outcomeUnknown)
                    #expect(disk.previousIDs == ["older"])
                    await remote.write()
                    throw URLError(.networkConnectionLost)
                }
                throw DriveEngineError.transferConfirmationPending()
            }
        } catch DriveEngineError.transferConfirmationPending { }
        let reopened = DriveTransferCoordinator(store: DriveTransferTaskStore(storage: StorageManager(storageDirectory: root)))
        #expect(try await reopened.summaries().first?.submitted == true)
        await #expect(throws: DriveTaskRecoveryError.self) {
            _ = try await reopened.confirmedTransfer(cacheKey: "source", scope: scope()) { _ in
                await remote.write()
                throw DriveEngineError.transferConfirmationPending()
            }
        }
        #expect(await remote.writes == 1)
    }

    @Test(arguments: ["beforeSubmit", "receipt", "confirmed"])
    func boundaryRecordsReopenWithoutReplaying(boundary: String) async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageDirectory: root), task = DriveTransferTask(scope: scope())
        let store = DriveTransferTaskStore(storage: storage)
        try store.insert(task)
        let attempt = DriveTransferAttempt(record: task, store: store)
        if boundary != "beforeSubmit" {
            _ = try await attempt.submit(previousIDs: ["old"]) { .init(fileID: "destination", taskID: "remote-task") }
        }
        if boundary == "confirmed" { try await attempt.confirmed("destination", parent: "folder") }
        let disk = try #require(DriveTransferTaskStore(storage: StorageManager(storageDirectory: root)).records().first)
        #expect(disk.phase == (boundary == "beforeSubmit" ? .notSubmitted : boundary == "receipt" ? .submittedAwaitingConfirmation : .fileConfirmed))
        #expect(disk.submitted == (boundary != "beforeSubmit"))
        #expect(!disk.completed)
        if boundary != "beforeSubmit" { #expect(disk.remoteTaskID == "remote-task") }
        if boundary == "confirmed" { #expect(disk.lastVerifiedAt != nil) }
    }

    @Test func failedWriteAheadPreventsTransportAndReceiptWriteFailureKeepsUnknownEvidence() async throws {
        let root = location(), remote = PersistentTransferCounter()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = DriveTransferTaskStore(storage: StorageManager(storageDirectory: root))
        let task = DriveTransferTask(scope: scope())
        try store.insert(task)
        let attempt = DriveTransferAttempt(record: task, store: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        await #expect(throws: DriveTaskRecoveryError.self) {
            _ = try await attempt.submit(previousIDs: []) { await remote.write(); return .init(fileID: "new") }
        }
        #expect(await remote.writes == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        await #expect(throws: DriveTaskRecoveryError.self) {
            _ = try await attempt.submit(previousIDs: ["old"]) {
                await remote.write()
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
                return .init(fileID: "new")
            }
        }
        #expect(await remote.writes == 1)
        let disk = try #require(DriveTransferTaskStore(storage: StorageManager(storageDirectory: root)).records().first)
        #expect(disk.submitted && disk.phase == .outcomeUnknown && disk.fileID == nil)
    }

    @Test func cancelledUnknownEvidenceNeverExpiresOrAllowsLateCommit() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DriveTransferTaskStore(storage: StorageManager(storageDirectory: root), maximumRecords: 1)
        let record = DriveTransferTask(scope: scope(), now: .distantPast)
        try store.insert(record)
        let attempt = DriveTransferAttempt(record: record, store: store)
        _ = try await attempt.submit(previousIDs: []) { .init(fileID: "remote") }
        try store.cancel(record.id)
        await #expect(throws: DriveTaskRecoveryError.self) { try await attempt.confirmed("late") }
        #expect(throws: DriveTaskRecoveryError.self) { try store.insert(DriveTransferTask(scope: scope("another")), now: .distantFuture) }
        let disk = try #require(DriveTransferTaskStore(storage: StorageManager(storageDirectory: root)).records().first)
        #expect(disk.cancelled && disk.protectsUncertainWrite && disk.fileID == "remote")
    }

    @Test func migrationCorruptionFutureVersionAndBoundedRetention() throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = StorageManager(storageDirectory: root)
        let store = DriveTransferTaskStore(storage: actual, maximumRecords: 2)
        var completed = DriveTransferTask(scope: scope("old"), now: .distantPast)
        completed.completed = true
        try store.insert(completed)
        var protected = DriveTransferTask(scope: scope("unknown"), now: .distantPast)
        protected.submitted = true; protected.phase = .outcomeUnknown
        try store.insert(protected)
        try store.insert(DriveTransferTask(scope: scope("new")))
        #expect(try store.records().count == 2)
        #expect(try store.records().contains(where: { $0.id == protected.id }))
        let url = root.appendingPathComponent(DriveTransferTaskStore.filename)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["version"] = 1
        var rows = try #require(object["records"] as? [[String: Any]])
        rows[0].removeValue(forKey: "remainingReadRetries"); object["records"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        #expect(try store.records()[0].remainingReadRetries == 0)
        let migrated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(migrated["version"] as? Int == 2)
        object["version"] = 99
        let future = try JSONSerialization.data(withJSONObject: object)
        try future.write(to: url)
        #expect(throws: DriveTaskRecoveryError.self) { try store.records() }
        #expect(try Data(contentsOf: url) == future)
        try Data("broken".utf8).write(to: url)
        #expect(throws: DriveTaskRecoveryError.self) { try store.insert(DriveTransferTask(scope: scope())) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
    }

    @Test func independentlyOpenedStoresSerializeAtomicReadModifyWrite() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = StorageManager(storageDirectory: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let store = DriveTransferTaskStore(storage: StorageManager(storageDirectory: root))
                    try store.insert(DriveTransferTask(scope: scope("source-\(index)")))
                }
            }
            try await group.waitForAll()
        }
        #expect(try DriveTransferTaskStore(storage: StorageManager(storageDirectory: root)).records().count == 32)
    }

    @Test func independentlyOpenedCoordinatorsCannotReserveTheSameSourceTwice() async throws {
        let root = location(), remote = PersistentTransferCounter()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = StorageManager(storageDirectory: root)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let store = DriveTransferTaskStore(storage: StorageManager(storageDirectory: root))
                    do { try store.insert(DriveTransferTask(scope: scope())); await remote.write() }
                    catch { #expect(error is DriveTaskRecoveryError) }
                }
            }
            await group.waitForAll()
        }
        #expect(await remote.writes == 1)
        #expect(try DriveTransferTaskStore(storage: StorageManager(storageDirectory: root)).records().count == 1)
    }

    @Test func recoveryErrorsCannotFallBackToAnotherPlaybackRoute() {
        for error in [DriveTaskRecoveryError.storageUnavailable, .capacityReached, .requiresReview, .scopeChanged, .cancelled, .staleRecord] {
            #expect(DriveServiceFailure.stopsRecovery(error))
            #expect(!UserFacingErrorPresenter.message(for: error, context: .playback).isEmpty)
        }
    }

    @MainActor @Test func appRecreationRestoresOnlyLocalSummariesAndStableConfiguration() throws {
        let root = location(), suite = "msc04-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageDirectory: root), preferences = UserPreferences(defaults: defaults)
        preferences.currentVodConfigUrl = "https://configured.example/config"
        try storage.saveConfigs([.init(url: preferences.currentVodConfigUrl, json: "{\"sites\":[]}")])
        try DriveTransferTaskStore(storage: storage).insert(DriveTransferTask(scope: scope()))
        let first = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: storage, userPreferences: preferences, providerRuntimeBootstrap: nil)
        let second = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: root), userPreferences: UserPreferences(defaults: defaults), providerRuntimeBootstrap: nil)
        #expect(first.driveTaskSummaries == second.driveTaskSummaries)
        #expect(second.driveTaskSummaries.count == 1 && second.driveRecoveryOperations.isEmpty)
        #expect(first.driveRecoveryConfigurationIdentity == second.driveRecoveryConfigurationIdentity)
        let identity = second.driveRecoveryConfigurationIdentity
        try storage.saveConfigs([.init(url: preferences.currentVodConfigUrl, json: "{\"sites\":[{}]}")])
        #expect(identity != second.driveRecoveryConfigurationIdentity)
    }
}
