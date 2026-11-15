import Foundation
import Testing
import Models
import Storage
import FileServiceEngine
import MediaLibraryEngine
import CSQLite

@Suite("Explicit scan checkpoints", .serialized, .timeLimit(.minutes(2)))
struct MediaScanCheckpointTests {
    @Test func largeInterruptedScanRechecksCompletedDirectoriesAndDiscoversMoves() async throws {
        let f = try ScanTestEnvironment(); defer { f.clean() }
        let client = CheckpointProtocolFixture()
        await client.set("/", files: (0..<1200).map { "Movie\($0).mkv" }, folders: ["Pending", "Done"])
        await client.set("/Done", files: ["Keep.mkv", "Moved.mkv"])
        await client.set("/Pending", files: ["Later.mkv"])
        await client.hold("/Pending")
        let scanner = f.scanner()
        let abandoned = Task { await scanner.scan(f.library, client: client) }
        await client.waitForHold("/Pending")
        let checkpoint = try #require(try await f.index.scanCheckpoint(libraryID: f.library.id))
        #expect(checkpoint.completedDirectories == 2 && checkpoint.pendingDirectories == 1)
        #expect(checkpoint.directories.first { $0.path == "/Pending" }?.state == .pending)
        let keep = try f.reference("/Done/Keep.mkv")
        try await f.index.applyCorrection(.init(reference: keep, fields: .init(title: "Manual title")))

        // Synthetic process loss: revoke the previous writer without running its cleanup.
        let reopened = MediaIndex(url: f.indexURL)
        try await reopened.interruptScanCheckpoint(libraryID: f.library.id, phase: .interrupted)
        await client.release("/Pending"); await abandoned.value
        #expect(try await reopened.lastSuccessfulScan(libraryID: f.library.id) == nil)
        await client.set("/Done", files: ["Keep.mkv", "Added.mkv"])
        await client.set("/Pending", files: ["Later.mkv", "Moved.mkv"])
        await client.resetCalls()
        let resumed = f.scanner(index: reopened)
        await resumed.scan(f.library, client: client, request: .resume)
        let paths = Set(try await reopened.records(libraryID: f.library.id).map(\.reference.path))
        #expect(paths.count == 1204)
        #expect(paths.contains("/Done/Added.mkv") && paths.contains("/Pending/Moved.mkv"))
        #expect(!paths.contains("/Done/Moved.mkv"))
        #expect(try await reopened.record(reference: keep)?.metadata.title == "Manual title")
        #expect(try await reopened.record(reference: keep)?.id == keep.locator)
        #expect(await client.listedPaths == ["/", "/Done", "/Pending"])
        #expect(try await reopened.scanCheckpoint(libraryID: f.library.id)?.phase == .completed)
        #expect(try await reopened.lastSuccessfulScan(libraryID: f.library.id) != nil)
    }

    @Test func partialFailureKeepsOldIndexAndRetryOnlyFinalizesSelectedSubtree() async throws {
        let f = try ScanTestEnvironment(); defer { f.clean() }
        let client = CheckpointProtocolFixture()
        await client.set("/", files: ["Gone.mkv"], folders: ["Online", "Off", "Offish", "Other"])
        await client.set("/Online", files: ["Online.mkv"])
        await client.set("/Off", files: ["Old.mkv", "Keep.mkv"], folders: ["GoneChild"])
        await client.set("/Off/GoneChild", files: ["Nested.mkv"])
        await client.set("/Offish", files: ["Boundary.mkv"])
        await client.set("/Other", files: ["Other.mkv"])
        let scanner = f.scanner()
        await scanner.scan(f.library, client: client)
        let success = try await f.index.lastSuccessfulScan(libraryID: f.library.id)
        let oldCount = try await f.index.records(libraryID: f.library.id).count
        let keep = try f.reference("/Off/Keep.mkv")
        try await f.index.applyCorrection(.init(reference: keep, fields: .init(title: "Keep correction")))
        await client.set("/", files: [], folders: ["Online", "Off", "Offish", "Other"])
        await client.fail("/Off"); await client.fail("/Other")
        await scanner.scan(f.library, client: client)
        #expect(try await f.index.records(libraryID: f.library.id).count == oldCount)
        #expect(try await f.index.scanCheckpoint(libraryID: f.library.id)?.failedDirectories == ["/Off", "/Other"])

        await client.recover("/Off")
        await client.set("/Off", files: ["New.mkv", "Keep.mkv"])
        await client.resetCalls()
        await scanner.scan(f.library, client: client, request: .retryFailed(paths: ["/Off"]))
        #expect(await client.listedPaths == ["/", "/Off"])
        let paths = Set(try await f.index.records(libraryID: f.library.id).map(\.reference.path))
        #expect(paths.contains("/Gone.mkv") && paths.contains("/Other/Other.mkv") && paths.contains("/Offish/Boundary.mkv"))
        #expect(paths.contains("/Off/New.mkv") && !paths.contains("/Off/Old.mkv") && !paths.contains("/Off/GoneChild/Nested.mkv"))
        #expect(try await f.index.record(reference: keep)?.metadata.title == "Keep correction")
        #expect(try await f.index.lastSuccessfulScan(libraryID: f.library.id) == success)
        #expect(try await f.index.scanCheckpoint(libraryID: f.library.id)?.failedDirectories == ["/Other"])
        await client.recover("/Other")
        await scanner.scan(f.library, client: client, request: .retryFailed(paths: ["/Other"]))
        #expect(try await f.index.scanCheckpoint(libraryID: f.library.id)?.phase == .completed)
        #expect(try await f.index.lastSuccessfulScan(libraryID: f.library.id) == success)
        #expect(try await f.index.records(libraryID: f.library.id).contains { $0.reference.path == "/Gone.mkv" })
    }

    @Test func resumedUnchangedDirectoryDoesNotReviveRowsRetainedFromAnOlderScan() async throws {
        let f = try ScanTestEnvironment(); defer { f.clean() }
        let client = CheckpointProtocolFixture()
        await client.set("/", files: ["Kept.mkv", "Removed.mkv"], folders: ["Off"])
        await client.set("/Off", files: ["Offline.mkv"])
        let scanner = f.scanner(); await scanner.scan(f.library, client: client)
        await client.set("/", files: ["Kept.mkv"], folders: ["Off"])
        await client.fail("/Off")
        await scanner.scan(f.library, client: client)
        #expect(try await f.index.records(libraryID: f.library.id).count == 3)
        await client.recover("/Off")
        await f.scanner(index: MediaIndex(url: f.indexURL)).scan(f.library, client: client, request: .resume)
        let paths = Set(try await f.index.records(libraryID: f.library.id).map(\.reference.path))
        #expect(paths == ["/Kept.mkv", "/Off/Offline.mkv"])
    }

    @Test func repeatedContinueCoalescesAndCancelRejectsLatePages() async throws {
        let f = try ScanTestEnvironment(); defer { f.clean() }
        let client = CheckpointProtocolFixture()
        await client.set("/", files: ["Original.mkv"], folders: ["Off"])
        await client.fail("/Off")
        let scanner = f.scanner(); await scanner.scan(f.library, client: client)
        await client.recover("/Off"); await client.set("/Off", files: ["Late.mkv"])
        await client.hold("/"); await client.resetCalls()
        let continuing = Task { await scanner.scan(f.library, client: client, request: .resume) }
        await client.waitForHold("/")
        await scanner.start(f.library, request: .resume)
        await scanner.start(f.library, request: .retryFailed(paths: ["/Off"]))
        #expect(await client.listedPaths == ["/"])
        await scanner.cancel(libraryID: f.library.id)
        await client.release("/"); await continuing.value
        #expect(try await f.index.scanCheckpoint(libraryID: f.library.id)?.phase == .cancelled)
        #expect(try await f.index.records(libraryID: f.library.id).map(\.reference.path) == ["/Original.mkv"])
        await client.resetCalls()
        await scanner.scan(f.library, client: client, request: .resume)
        await scanner.scan(f.library, client: client, request: .retryFailed(paths: ["/Off"]))
        #expect(await client.listedPaths.isEmpty)
        #expect(await scanner.currentProgress(libraryID: f.library.id)?.recoveryError == .cancelled)
        await scanner.scan(f.library, client: client) // An explicit rescan is a new task.
        #expect(try await f.index.records(libraryID: f.library.id).count == 2)
    }

    @Test func cancellingAQueuedScanDoesNotWaitForOtherLibrariesOrVisitItsRoot() async throws {
        let f = try ScanTestEnvironment(); defer { f.clean() }
        let scanner = f.scanner(), first = CheckpointProtocolFixture(), second = CheckpointProtocolFixture()
        let other = MediaLibraryConfiguration(serviceID: f.service.id, name: "Second", metadataSource: .local)
        let queued = MediaLibraryConfiguration(serviceID: f.service.id, name: "Queued", metadataSource: .local)
        await first.hold("/"); await second.hold("/")
        let task1 = Task { await scanner.scan(f.library, client: first) }
        await first.waitForHold("/")
        let task2 = Task { await scanner.scan(other, client: second) }
        await second.waitForHold("/")
        await scanner.start(queued)
        await scanner.cancel(libraryID: queued.id)
        await scanner.waitForScan(libraryID: queued.id)
        #expect(await scanner.currentProgress(libraryID: queued.id)?.isRunning == false)
        #expect(try await f.index.scanCheckpoint(libraryID: queued.id) == nil)
        #expect(await scanner.currentProgress(libraryID: f.library.id)?.isRunning == true)
        #expect(await scanner.currentProgress(libraryID: other.id)?.isRunning == true)
        await first.release("/"); await second.release("/")
        await task1.value; await task2.value
    }

    @Test func newRunRejectsWritesAndCompletionFromSupersededScanner() async throws {
        let f = try ScanTestEnvironment(); defer { f.clean() }
        let oldRun = UUID(), newRun = UUID()
        _ = try await f.index.beginScanCheckpoint(library: f.library, revision: "fixture", request: .rescan, runID: oldRun)
        let second = MediaIndex(url: f.indexURL)
        _ = try await second.beginScanCheckpoint(library: f.library, revision: "fixture", request: .resume, runID: newRun)
        let ref = try f.reference("/Stale.mkv")
        await #expect(throws: MediaScanRecoveryError.superseded) {
            try await f.index.upsertScanned(.init(reference: ref, entry: .init(path: ref.path, name: "Stale.mkv", isDirectory: false), groupKey: "stale", filenameMetadata: .init()), runID: oldRun)
        }
        await #expect(throws: MediaScanRecoveryError.superseded) {
            try await f.index.completeScanCheckpoint(libraryID: f.library.id, runID: oldRun, fullSuccess: true)
        }
        #expect(try await second.records(libraryID: f.library.id).isEmpty)
        #expect(try await second.lastSuccessfulScan(libraryID: f.library.id) == nil)
    }

    @Test(arguments: ["root", "endpoint", "library", "account", "bookmark", "removed"])
    func configurationAndAuthorizationEditsRejectResumeBeforeReading(change: String) async throws {
        let f = try ScanTestEnvironment(configured: true); defer { f.clean() }
        let client = CheckpointProtocolFixture()
        await client.set("/", files: ["Original.mkv"], folders: ["Off"]); await client.fail("/Off")
        let scanner = f.scanner(); await scanner.scan(f.library, client: client)
        let before = try #require(try await f.index.scanCheckpoint(libraryID: f.library.id))
        var catalog = f.store.load(), library = f.library
        switch change {
        case "root": catalog.services[0].rootPath = "/new-root"
        case "endpoint": catalog.services[0].address = "https://other.invalid"
        case "library": catalog.libraries[0].path = "/other"; library = catalog.libraries[0]
        case "account": try f.store.saveCredentials(.init(username: "other", password: "fixture-secret"), for: catalog.services[0])
        case "bookmark": try f.store.saveBookmark(Data("different-scope".utf8), for: f.service.id)
        default: catalog.services = []
        }
        try f.store.save(catalog)
        await client.resetCalls()
        await scanner.scan(library, client: client, request: .resume)
        #expect(await client.listedPaths.isEmpty)
        #expect(try await f.index.scanCheckpoint(libraryID: f.library.id)?.id == before.id)
        #expect(try await f.index.records(libraryID: f.library.id).count == 1)
    }

    @Test func accountChangeDuringNonCooperativeReadCannotPublishOldFiles() async throws {
        let f = try ScanTestEnvironment(configured: true); defer { f.clean() }
        let client = CheckpointProtocolFixture(); await client.set("/", files: ["OldAccount.mkv"]); await client.hold("/")
        let scanner = f.scanner()
        let task = Task { await scanner.scan(f.library, client: client) }
        await client.waitForHold("/")
        try f.store.saveCredentials(.init(username: "new", password: "fixture-secret"), for: f.service)
        await client.release("/"); await task.value
        #expect(try await f.index.records(libraryID: f.library.id).isEmpty)
        #expect(try await f.index.scanCheckpoint(libraryID: f.library.id)?.phase == .invalidated)
    }

    @Test func expirationAndCancelledSummaryAreLocalOnlyAndDoNotExtendRetention() async throws {
        let f = try ScanTestEnvironment(configured: true); defer { f.clean() }
        let runID = UUID(), revision = try MediaLibraryScanner.configurationRevision(f.library, store: f.store)
        _ = try await f.index.beginScanCheckpoint(library: f.library, revision: revision, request: .rescan, runID: runID,
            now: Date().addingTimeInterval(-MediaScanCheckpoint.retention - 60))
        let scanner = f.scanner(), client = CheckpointProtocolFixture()
        let checkpoint = try #require(try await scanner.checkpoint(libraryID: f.library.id))
        #expect(checkpoint.isExpired() && !checkpoint.canContinue(revision: revision))
        let saved = try await f.index.scanCheckpoint(libraryID: f.library.id)
        _ = try await scanner.checkpoint(libraryID: f.library.id)
        #expect(try await f.index.scanCheckpoint(libraryID: f.library.id) == saved)
        #expect(await scanner.currentProgress(libraryID: f.library.id) == nil)
        await scanner.scan(f.library, client: client, request: .resume)
        #expect(await client.listedPaths.isEmpty)
        #expect(await scanner.currentProgress(libraryID: f.library.id)?.recoveryError == .expired)
        #expect(try await f.index.scanCheckpoint(libraryID: f.library.id) == saved)
    }

    @Test func incompletePagingAndOutOfScopeEntriesNeverSupplyCompletionEvidence() async throws {
        let f = try ScanTestEnvironment(); defer { f.clean() }
        let client = CheckpointProtocolFixture()
        await client.set("/", files: ["Keep.mkv"])
        let scanner = f.scanner(); await scanner.scan(f.library, client: client)
        await client.setInvalidPaging(true)
        await scanner.scan(f.library, client: client)
        #expect(try await f.index.scanCheckpoint(libraryID: f.library.id)?.failedDirectories == ["/"])
        #expect(try await f.index.records(libraryID: f.library.id).count == 1)
        await client.setInvalidPaging(false)
        await client.setEntries("/", [.init(path: "/elsewhere/Injected.mkv", name: "Injected.mkv", isDirectory: false)])
        await scanner.scan(f.library, client: client)
        #expect(try await f.index.scanCheckpoint(libraryID: f.library.id)?.failedDirectories == ["/"])
        #expect(try await f.index.records(libraryID: f.library.id).count == 1)
    }

    @Test func scopeUsesExactUnicodePathBoundariesAndFutureCheckpointFailsClosed() async throws {
        let f = try ScanTestEnvironment(); defer { f.clean() }
        let name = "Re\u{301}🎞️_%", path = "/" + name
        let client = CheckpointProtocolFixture(); await client.set("/", files: [], folders: [name, name + "2"])
        await client.set(path, files: ["Remove.mkv"]); await client.set(path + "2", files: ["Keep.mkv"])
        let scanner = f.scanner(); await scanner.scan(f.library, client: client)
        await client.fail(path); await scanner.scan(f.library, client: client)
        await client.recover(path); await client.set(path, files: [])
        await scanner.scan(f.library, client: client, request: .retryFailed(paths: [path]))
        #expect(try await f.index.records(libraryID: f.library.id).map(\.reference.path) == [path + "2/Keep.mkv"])
        try f.executeSQL("UPDATE scan_checkpoint SET payload=replace(CAST(payload AS TEXT),'\"version\":1','\"version\":99')")
        await #expect(throws: MediaScanRecoveryError.unavailable) { try await f.index.scanCheckpoint(libraryID: f.library.id) }
    }

    @Test func incompleteEvidenceCannotFinishAnEntireLibraryAndBadStorageDoesNotReadTheService() async throws {
        let f = try ScanTestEnvironment(); defer { f.clean() }
        let runID = UUID()
        _ = try await f.index.beginScanCheckpoint(library: f.library, revision: "fixture", request: .rescan, runID: runID)
        await #expect(throws: MediaScanRecoveryError.unavailable) {
            try await f.index.completeScanCheckpoint(libraryID: f.library.id, runID: runID, fullSuccess: true)
        }
        try await f.index.visitScanDirectory(.init(path: "/", state: .completed, scanID: runID), libraryID: f.library.id, runID: runID, children: ["/Pending"])
        await #expect(throws: MediaScanRecoveryError.unavailable) {
            try await f.index.completeScanCheckpoint(libraryID: f.library.id, runID: runID, fullSuccess: true)
        }
        #expect(try await f.index.lastSuccessfulScan(libraryID: f.library.id) == nil)
        let blocking = f.root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocking)
        let brokenIndex = MediaIndex(url: blocking.appendingPathComponent("index.sqlite"))
        let scanner = f.scanner(index: brokenIndex), client = CheckpointProtocolFixture()
        await scanner.scan(f.library, client: client)
        #expect(await client.listedPaths.isEmpty)
        #expect(await scanner.currentProgress(libraryID: f.library.id)?.isRunning == false)
    }

    @Test func checkpointPayloadContainsNoAuthorizationOrProtocolErrorBody() async throws {
        let f = try ScanTestEnvironment(configured: true); defer { f.clean() }
        try f.store.saveCredentials(.init(username: "synthetic-account", password: "fixture-secret-token", directoryPasswords: ["/": "fixture-directory-secret"]), for: f.service)
        let client = CheckpointProtocolFixture(); await client.fail("/")
        await f.scanner().scan(f.library, client: client)
        let saved = try #require(try await f.index.scanCheckpoint(libraryID: f.library.id))
        let text = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!text.contains("fixture-secret-token") && !text.contains("fixture-directory-secret") && !text.contains("synthetic-account"))
        #expect(!text.contains("fixture.invalid") && !text.contains("not-for-records") && !text.contains("https:"))
        #expect(saved.failedDirectories == ["/"])
    }

    @Test func openListAdapterPaginatesAndRetriesOnlyTheFailedVirtualDirectory() async throws {
        let f = try ScanTestEnvironment(); defer { f.clean() }
        let protocolFixture = ScanOpenListHTTPFixture()
        let client = try AListClient(configuration: .init(id: f.service.id, name: "OpenList fixture", kind: .openList,
            address: "https://fixture.invalid", rootPath: "/user-root"),
            requestHandler: { url, method, _, body in try await protocolFixture.request(url: url, method: method, body: body) })
        let scanner = f.scanner(); await scanner.scan(f.library, client: client)
        #expect(try await f.index.records(libraryID: f.library.id).count == 226)
        await protocolFixture.setPhase(1)
        await scanner.scan(f.library, client: client)
        #expect(try await f.index.scanCheckpoint(libraryID: f.library.id)?.failedDirectories == ["/Off"])
        #expect(try await f.index.records(libraryID: f.library.id).count == 226)
        await protocolFixture.setPhase(2)
        await scanner.scan(f.library, client: client, request: .retryFailed(paths: ["/Off"]))
        #expect(await protocolFixture.paths == ["/user-root", "/user-root", "/user-root/Off"])
        let records = try await f.index.records(libraryID: f.library.id)
        #expect(records.count == 226 && records.contains { $0.reference.path == "/Off/New.mkv" })
        #expect(!records.contains { $0.reference.path == "/Off/Old.mkv" })
        #expect(await protocolFixture.onlyReadEndpoints)
    }

    @Test func checkpointCapacityRollsBackDirectoryCompletionAtomically() async throws {
        let f = try ScanTestEnvironment(); defer { f.clean() }
        let runID = UUID()
        _ = try await f.index.beginScanCheckpoint(library: f.library, revision: "fixture", request: .rescan, runID: runID)
        await #expect(throws: MediaScanRecoveryError.capacity) {
            try await f.index.visitScanDirectory(.init(path: "/", state: .completed), libraryID: f.library.id, runID: runID,
                children: (0..<MediaScanCheckpoint.maximumDirectories).map { "/d\($0)" })
        }
        let checkpoint = try #require(try await f.index.scanCheckpoint(libraryID: f.library.id))
        #expect(checkpoint.directories == [.init(path: "/")])
        #expect(try await f.index.lastSuccessfulScan(libraryID: f.library.id) == nil)
    }
}

private struct ScanTestEnvironment {
    let root: URL, indexURL: URL, index: MediaIndex, store: FileServiceStore
    let service: FileServiceConfiguration, library: MediaLibraryConfiguration
    init(configured: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("msc05-" + UUID().uuidString)
        indexURL = root.appendingPathComponent("index.sqlite"); index = MediaIndex(url: indexURL)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: "msc05." + UUID().uuidString)!, credentialStore: MemoryCredentialStore())
        store = FileServiceStore(storage: StorageManager(storageDirectory: root.appendingPathComponent("state")), preferences: preferences)
        service = .init(name: "Protocol fixture", kind: .webDAV, address: "https://fixture.invalid")
        library = .init(serviceID: service.id, name: "Checkpoint fixture", metadataSource: .local)
        if configured { try store.save(.init(services: [service], libraries: [library])) }
    }
    func scanner(index: MediaIndex? = nil) -> MediaLibraryScanner { .init(index: index ?? self.index, store: store) }
    func reference(_ path: String) throws -> FileResourceReference { try .init(serviceID: service.id, libraryID: library.id, path: path) }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func executeSQL(_ sql: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(indexURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}

private actor CheckpointProtocolFixture: FileServiceClient {
    private var directories: [String: [FileEntry]] = [:], failures = Set<String>()
    private var heldPaths = Set<String>(), enteredHolds = Set<String>()
    private var releases: [String: CheckedContinuation<Void, Never>] = [:]
    private var holdWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var invalidPaging = false
    private(set) var listedPaths: [String] = []
    func set(_ path: String, files: [String], folders: [String] = []) {
        directories[path] = files.map { .init(path: (path == "/" ? "/" + $0 : path + "/" + $0), name: $0, isDirectory: false, size: 100, modifiedAt: Date(timeIntervalSince1970: 1)) }
            + folders.map { .init(path: (path == "/" ? "/" + $0 : path + "/" + $0), name: $0, isDirectory: true) }
    }
    func setEntries(_ path: String, _ entries: [FileEntry]) { directories[path] = entries }
    func fail(_ path: String) { failures.insert(path) }
    func recover(_ path: String) { failures.remove(path) }
    func resetCalls() { listedPaths = [] }
    func setInvalidPaging(_ value: Bool) { invalidPaging = value }
    func hold(_ path: String) { heldPaths.insert(path); enteredHolds.remove(path) }
    func waitForHold(_ path: String) async {
        if enteredHolds.contains(path) { return }
        await withCheckedContinuation { holdWaiters[path, default: []].append($0) }
    }
    func release(_ path: String) { heldPaths.remove(path); releases.removeValue(forKey: path)?.resume() }
    func connect() async throws {}
    func list(path: String, cursor: String?) async throws -> FileEntryPage {
        listedPaths.append(path)
        let snapshot = directories[path] ?? []
        if heldPaths.contains(path) {
            enteredHolds.insert(path)
            for waiter in holdWaiters.removeValue(forKey: path) ?? [] { waiter.resume() }
            await withCheckedContinuation { releases[path] = $0 }
        }
        if failures.contains(path) { throw FileServiceError.network("offline fixture, secret=https://fixture.invalid/?token=not-for-records") }
        return .init(entries: snapshot, nextCursor: invalidPaging ? "same-cursor" : nil)
    }
    func stat(path: String) async throws -> FileEntry { throw FileServiceError.path(path) }
    func read(path: String, range: Range<Int64>) async throws -> Data { Data() }
    func resolve(path: String) async throws -> ResolvedFileResource { throw FileServiceError.path(path) }
}

private actor ScanOpenListHTTPFixture {
    private var phase = 0
    private(set) var paths: [String] = []
    private(set) var onlyReadEndpoints = true
    func setPhase(_ value: Int) { phase = value; paths = [] }
    func request(url: URL, method: String, body: Data?) throws -> (Data, HTTPURLResponse) {
        onlyReadEndpoints = onlyReadEndpoints && method == "POST" && url.path == "/api/fs/list"
        let request = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        let path = request?["path"] as? String ?? "", page = request?["page"] as? Int ?? 1
        paths.append(path)
        let content: [[String: Any]]
        let code: Int
        if path == "/user-root" {
            let all = (0..<225).map { ["name": "Movie\($0).mkv", "is_dir": false, "size": 100] as [String: Any] }
                + [["name": "Off", "is_dir": true]]
            content = Array(all.dropFirst((page - 1) * 200).prefix(200)); code = 200
        } else if path == "/user-root/Off" {
            content = [["name": phase == 2 ? "New.mkv" : "Old.mkv", "is_dir": false, "size": 100]]
            code = phase == 1 ? 403 : 200
        } else { content = []; code = 404 }
        let total = path == "/user-root" ? 226 : content.count
        let result: [String: Any] = ["code": code, "message": "synthetic-service-error", "data": ["content": content, "total": total]]
        return (try JSONSerialization.data(withJSONObject: result), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
