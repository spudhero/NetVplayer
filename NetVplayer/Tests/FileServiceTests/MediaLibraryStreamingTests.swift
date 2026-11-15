import Foundation
import Testing
import Models
import Storage
import FileServiceEngine
@testable import MediaLibraryEngine

@Suite("BMH-02 durable streaming matching", .serialized, .timeLimit(.minutes(2)))
struct MediaLibraryStreamingTests {
    @Test func onlinePosterPrecedesSlowDirectoryCompletionAndAllBatchesDrain() async throws {
        let f = try StreamingEnvironment(); defer { f.clean() }
        let provider = StreamingProvider(), directoryGate = StreamingGate()
        let (scanner, matcher) = f.pipeline(provider)
        let scan = Task { await scanner.scan(f.library, client: StreamingFiles(count: 1, slowDirectory: directoryGate)) }
        try await eventually { await directoryGate.entered }
        try await eventually { try await f.index.records(libraryID: f.library.id).first?.onlineMetadata.poster != nil }
        #expect(await scanner.currentProgress(libraryID: f.library.id)?.isRunning == true)
        #expect(await matcher.currentProgress(libraryID: f.library.id)?.isRunning == true)
        await directoryGate.release(); await scan.value; await matcher.waitForMatching(libraryID: f.library.id)
        let metrics = try #require(await matcher.currentProgress(libraryID: f.library.id)?.metrics)
        #expect(try #require(metrics.firstOnlinePosterAddressSeconds) < #require(metrics.scanFinishedSeconds))
        #expect(try #require(metrics.scanFinishedSeconds) <= #require(metrics.matchFinishedSeconds))
        #expect(metrics.processed == 4 && metrics.matched == 4 && metrics.matchOutcome == .completed)
        #expect(try await f.index.pendingMatchCount(libraryID: f.library.id) == 0)
        #expect(try await f.index.records(libraryID: f.library.id).allSatisfy { $0.onlineMetadata.poster != nil })
        try saveEvidence("streaming-metrics.json", metrics)
    }

    @Test func fullQueueBackpressuresScannerWithoutCancellingEarlierBatches() async throws {
        let f = try StreamingEnvironment(); defer { f.clean() }
        let gate = StreamingGate(), provider = StreamingProvider()
        await provider.setGate(gate)
        let (scanner, matcher) = f.pipeline(provider, capacity: 2)
        let scan = Task { await scanner.scan(f.library, client: StreamingFiles(count: 12)) }
        try await eventually { await gate.entered }
        try await eventually { try await f.index.pendingMatchCount(libraryID: f.library.id) == 2 }
        try await Task.sleep(for: .milliseconds(40))
        #expect(try await f.index.records(libraryID: f.library.id).count == 2)
        await gate.release(); await scan.value; await matcher.waitForMatching(libraryID: f.library.id)
        let metrics = try #require(await matcher.currentProgress(libraryID: f.library.id)?.metrics)
        #expect(metrics.matchQueuePeak == 2 && (metrics.matchBackpressureWaits ?? 0) > 0)
        #expect(metrics.processed == 12 && metrics.matched == 12 && metrics.matchOutcome == .completed)
        #expect(await provider.searches == 12)
        try saveEvidence("backpressure-metrics.json", metrics)
    }

    @Test func cancelWakesBlockedProducerAndFreshRescanRejectsLateOldResults() async throws {
        let f = try StreamingEnvironment(); defer { f.clean() }
        let gate = StreamingGate(), oldProvider = StreamingProvider(prefix: "old-")
        await oldProvider.setGate(gate)
        let (scanner, matcher) = f.pipeline(oldProvider, capacity: 2)
        let scan = Task { await scanner.scan(f.library, client: StreamingFiles(count: 6)) }
        try await eventually { try await f.index.pendingMatchCount(libraryID: f.library.id) == 2 }
        await scanner.cancel(libraryID: f.library.id); await scan.value
        #expect(await scanner.currentProgress(libraryID: f.library.id)?.isCancelled == true)
        #expect(try await f.index.pendingMatchCount(libraryID: f.library.id) == 2)
        let restartedIndex = MediaIndex(url: f.indexURL)
        let newMatcher = MetadataMatcher(index: restartedIndex, providers: [StreamingProvider(prefix: "new-")], store: f.store)
        let newScanner = MediaLibraryScanner(index: restartedIndex, store: f.store, matcher: newMatcher)
        await newScanner.scan(f.library, client: StreamingFiles(count: 6), request: .resume)
        #expect(await newScanner.currentProgress(libraryID: f.library.id)?.recoveryError == .cancelled)
        await newScanner.scan(f.library, client: StreamingFiles(count: 6))
        await newMatcher.waitForMatching(libraryID: f.library.id)
        await gate.release(); await matcher.waitForMatching(libraryID: f.library.id)
        let records = try await restartedIndex.records(libraryID: f.library.id)
        #expect(records.count == 6 && records.allSatisfy { $0.onlineMetadata.title?.hasPrefix("new-") == true })
        #expect(await matcher.currentProgress(libraryID: f.library.id)?.metrics?.matchOutcome == .cancelled)
    }

    @Test func restartClaimsPersistedWorkOnlyOnExplicitResume() async throws {
        let f = try StreamingEnvironment(); defer { f.clean() }
        let run = UUID(), revision = try MediaLibraryScanner.configurationRevision(f.library, store: f.store)
        _ = try await f.index.beginScanCheckpoint(library: f.library, revision: revision, request: .rescan, runID: run)
        try await f.index.beginMatching(libraryID: f.library.id, revision: revision, runID: run)
        let record = try f.record(0)
        try await f.index.upsertScanned(record, runID: run, queueForMatching: true)
        let oldWork = try #require(try await f.index.nextMatch(libraryID: f.library.id, runID: run))
        let reopened = MediaIndex(url: f.indexURL), provider = StreamingProvider()
        let matcher = MetadataMatcher(index: reopened, providers: [provider], store: f.store)
        let scanner = MediaLibraryScanner(index: reopened, store: f.store, matcher: matcher)
        #expect(try await scanner.checkpoint(libraryID: f.library.id)?.phase == .interrupted)
        #expect(await provider.searches == 0)
        #expect(try await reopened.pendingMatchCount(libraryID: f.library.id) == 1)
        await scanner.scan(f.library, client: StreamingFiles(count: 1), request: .resume)
        await matcher.waitForMatching(libraryID: f.library.id)
        var stale = oldWork.record; stale.onlineMetadata = .init(title: "stale")
        await #expect(throws: MediaScanRecoveryError.superseded) {
            try await f.index.commitMatch(stale, snapshot: oldWork.record, work: oldWork, runID: run)
        }
        #expect(try await reopened.record(reference: record.reference)?.onlineMetadata.poster != nil)
        #expect(try await reopened.pendingMatchCount(libraryID: f.library.id) == 0)
    }

    @Test(arguments: ["source", "account", "endpoint", "delete"])
    func changedConfigurationAndDeletionRejectLateProviderResult(change: String) async throws {
        let f = try StreamingEnvironment(); defer { f.clean() }
        let gate = StreamingGate(), provider = StreamingProvider()
        await provider.setGate(gate)
        let (scanner, matcher) = f.pipeline(provider, capacity: 1)
        let scan = Task { await scanner.scan(f.library, client: StreamingFiles(count: 3)) }
        try await eventually { await gate.entered }
        var catalog = f.store.load()
        switch change {
        case "source": catalog.libraries[0].metadataSource = .local; try f.store.save(catalog)
        case "account": try f.store.saveCredentials(.init(username: "new-account", password: "fixture-only"), for: f.service)
        case "endpoint": catalog.services[0].address = "https://new.invalid"; try f.store.save(catalog)
        default: try await f.index.removeLibrary(f.library.id)
        }
        await gate.release(); await scan.value; await matcher.waitForMatching(libraryID: f.library.id)
        #expect(try await f.index.records(libraryID: f.library.id).allSatisfy { $0.onlineMetadata.title == nil })
        #expect(await matcher.currentProgress(libraryID: f.library.id)?.metrics?.firstOnlinePosterAddressSeconds == nil)
        #expect(await matcher.currentProgress(libraryID: f.library.id)?.metrics?.matchOutcome != .completed)
        if change == "delete" { #expect(try await f.index.pendingMatchCount(libraryID: f.library.id) == 0) }
    }

    @Test func snapshotCASPreservesCorrectionsAndNewScanPayload() async throws {
        let f = try StreamingEnvironment(); defer { f.clean() }
        let run = UUID(), revision = try MediaLibraryScanner.configurationRevision(f.library, store: f.store)
        _ = try await f.index.beginScanCheckpoint(library: f.library, revision: revision, request: .rescan, runID: run)
        try await f.index.beginMatching(libraryID: f.library.id, revision: revision, runID: run)
        let original = try f.record(0)
        try await f.index.upsertScanned(original, runID: run, queueForMatching: true)
        let work = try #require(try await f.index.nextMatch(libraryID: f.library.id, runID: run))
        try await f.index.applyCorrection(.init(reference: original.reference, fields: .init(title: "Manual")))
        var stale = work.record; stale.onlineMetadata = .init(title: "Stale", poster: "https://example.invalid/stale.jpg")
        #expect(try await !f.index.commitMatch(stale, snapshot: work.record, work: work, runID: run))
        #expect(try await f.index.pendingMatchCount(libraryID: f.library.id) == 1)
        var changed = original; changed.localMetadata = .init(title: "New NFO"); changed.entry.size = 900
        try await f.index.upsertScanned(changed, runID: run, queueForMatching: true)
        #expect(try await !f.index.commitMatch(stale, snapshot: work.record, work: work, runID: run))
        let current = try #require(try await f.index.record(reference: original.reference))
        #expect(current.metadata.title == "Manual" && current.localMetadata.title == "New NFO" && current.entry.size == 900)
        #expect(current.onlineMetadata.title == nil)
    }

    @Test func durableCapacityRollsBackFileAndQueueTogetherAndRevisionDropsOldWork() async throws {
        let f = try StreamingEnvironment(); defer { f.clean() }
        let run = UUID()
        _ = try await f.index.beginScanCheckpoint(library: f.library, revision: "one", request: .rescan, runID: run)
        try await f.index.beginMatching(libraryID: f.library.id, revision: "one", runID: run)
        for i in 0..<MediaIndex.maximumPendingMatches {
            try await f.index.upsertScanned(f.record(i), runID: run, queueForMatching: true)
        }
        await #expect(throws: MediaScanRecoveryError.capacity) {
            try await f.index.upsertScanned(f.record(999), runID: run, queueForMatching: true)
        }
        #expect(try await f.index.record(reference: f.record(999).reference) == nil)
        #expect(try await f.index.pendingMatchCount(libraryID: f.library.id) == 128)
        try await f.index.beginMatching(libraryID: f.library.id, revision: "changed-account", runID: UUID())
        #expect(try await f.index.pendingMatchCount(libraryID: f.library.id) == 0)
    }

    @Test func providerPauseRetainsWorkAndVerificationResumeDrainsIt() async throws {
        let f = try StreamingEnvironment(source: .douban); defer { f.clean() }
        let provider = StreamingProvider(source: .douban)
        await provider.setVerification(true)
        let (scanner, matcher) = f.pipeline(provider, capacity: 1)
        await scanner.scan(f.library, client: StreamingFiles(count: 3))
        await matcher.waitForMatching(libraryID: f.library.id)
        #expect(try await f.index.pendingMatchCount(libraryID: f.library.id) == 1)
        #expect(await matcher.verificationURL()?.host == "sec.douban.com")
        await provider.setVerification(false)
        await matcher.resumeAfterVerification(); await matcher.waitForMatching(libraryID: f.library.id)
        #expect(try await f.index.pendingMatchCount(libraryID: f.library.id) == 0)
        #expect(try await f.index.records(libraryID: f.library.id).first?.onlineMetadata.title != nil)
        // Resume discovery explicitly; verification only resumes already accepted files.
        await scanner.scan(f.library, client: StreamingFiles(count: 3), request: .resume)
        await matcher.waitForMatching(libraryID: f.library.id)
        #expect(try await f.index.records(libraryID: f.library.id).filter { $0.onlineMetadata.title != nil }.count == 3)
    }

    private func eventually(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !predicate() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for fixture event")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func saveEvidence<T: Encodable>(_ name: String, _ value: T) throws {
        guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_BMH02_EVIDENCE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name))
    }
}

private struct StreamingEnvironment {
    let root: URL, indexURL: URL, index: MediaIndex, store: FileServiceStore
    let service: FileServiceConfiguration, library: MediaLibraryConfiguration
    init(source: MetadataSource = .tmdb) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bmh02-" + UUID().uuidString)
        indexURL = root.appendingPathComponent("index.sqlite"); index = MediaIndex(url: indexURL)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore())
        store = FileServiceStore(storage: StorageManager(storageDirectory: root.appendingPathComponent("state")), preferences: preferences)
        service = .init(name: "Fixture", kind: .webDAV, address: "https://fixture.invalid")
        library = .init(serviceID: service.id, name: "Fixture", metadataSource: source)
        try store.save(.init(services: [service], libraries: [library]))
    }
    func pipeline(_ provider: some MetadataProvider, capacity: Int = 128) -> (MediaLibraryScanner, MetadataMatcher) {
        let matcher = MetadataMatcher(index: index, providers: [provider], store: store)
        return (.init(index: index, store: store, matcher: matcher, matchQueueCapacity: capacity), matcher)
    }
    func record(_ i: Int) throws -> MediaRecord {
        let name = "Movie\(i).2020.mkv", path = "/" + name
        return .init(reference: try .init(serviceID: service.id, libraryID: library.id, path: path),
                     entry: .init(path: path, name: name, isDirectory: false, size: 1), groupKey: "",
                     filenameMetadata: MediaFilenameParser.parse(path: path, libraryKind: .movies))
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
private actor StreamingGate {
    private(set) var entered = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered = true; if !released { await withCheckedContinuation { continuations.append($0) } } }
    func release() { released = true; let pending = continuations; continuations.removeAll(); for item in pending { item.resume() } }
}
private actor StreamingProvider: MetadataProvider {
    nonisolated let source: MetadataSource
    private let prefix: String
    private var gate: StreamingGate?
    private var verification = false
    private(set) var searches = 0
    init(prefix: String = "", source: MetadataSource = .tmdb) { self.prefix = prefix; self.source = source }
    func setGate(_ gate: StreamingGate) { self.gate = gate }
    func setVerification(_ value: Bool) { verification = value }
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        searches += 1
        if verification { throw MetadataProviderError.verification(URL(string: "https://sec.douban.com/fixture")!) }
        if let gate { await gate.wait() } // Deliberately ignores cancellation to exercise late callbacks.
        return [.init(source: source, metadata: .init(title: title, year: year, kind: kind, tmdbID: source == .tmdb ? title : nil,
                                                      doubanID: source == .douban ? title : nil))]
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        .init(title: prefix + id, year: 2020, kind: kind, poster: "https://fixture.invalid/poster.jpg", tmdbID: source == .tmdb ? id : nil,
              doubanID: source == .douban ? id : nil)
    }
}
private struct StreamingFiles: FileServiceClient {
    let count: Int
    var slowDirectory: StreamingGate?
    func connect() async throws {}
    func list(path: String, cursor: String?) async throws -> FileEntryPage {
        if path != "/", let slowDirectory { await slowDirectory.wait() }
        var entries: [FileEntry] = (0..<(path == "/" ? count : 3)).map { i in
            let name = "\(path == "/" ? "Movie" : "Late")\(i).2020.mkv"
            return .init(path: (path == "/" ? "" : path) + "/" + name, name: name, isDirectory: false, size: 1)
        }
        if path == "/", slowDirectory != nil { entries.append(.init(path: "/Slow", name: "Slow", isDirectory: true)) }
        return .init(entries: entries)
    }
    func stat(path: String) async throws -> FileEntry { throw FileServiceError.path(path) }
    func read(path: String, range: Range<Int64>) async throws -> Data { Data() }
    func resolve(path: String) async throws -> ResolvedFileResource { throw FileServiceError.path(path) }
}
