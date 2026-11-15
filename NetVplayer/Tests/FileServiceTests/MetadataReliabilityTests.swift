import Foundation
import Testing
import Models
import Storage
@testable import MediaLibraryEngine

@Suite("BMH-03 matching reliability", .serialized, .timeLimit(.minutes(5)))
struct MetadataReliabilityTests {
    @Test(arguments: ["search", "detail"])
    func onlineDetailSharesNASRequestsAndCancellation(phase: String) async throws {
        let f = try ReliabilityEnvironment(); defer { f.clean() }
        let record = try f.record("Movie")
        try await f.index.upsert(record, scanID: UUID())
        let gate = ReliabilityGate(), provider = ReliabilityProvider(gate: gate, phase: phase)
        let matcher = MetadataMatcher(index: f.index, providers: [provider])
        await matcher.enqueue(library: f.library, references: [record.reference])
        try await eventually { await gate.entered }
        let online = Task {
            if phase == "search" {
                _ = try await matcher.searchOnline(title: "Movie", year: nil, kind: .movies)
            } else {
                _ = try await matcher.onlineDetails(candidate: .init(source: .tmdb,
                    metadata: .init(title: "Movie", kind: .movies, tmdbID: "12")))
            }
        }
        try await eventually {
            let stats = await matcher.cacheStatistics()
            return phase == "search" ? stats.search.waiters == 2 : stats.detail.waiters == 2
        }
        online.cancel()
        await #expect(throws: CancellationError.self) { try await online.value }
        await gate.release(); await matcher.waitForMatching(libraryID: f.library.id)
        #expect(await provider.searches == 1)
        #expect(await provider.detailCalls == 1)
        #expect(try await f.index.record(reference: record.reference)?.onlineMetadata.title == "Movie")
        let stats = await matcher.cacheStatistics()
        #expect(stats.search.flights == 0 && stats.detail.flights == 0)
    }

    @Test(arguments: ["search", "detail"])
    func librariesShareInflightAndCancelOnlyOneWaiter(phase: String) async throws {
        let f = try ReliabilityEnvironment(); defer { f.clean() }
        let other = MediaLibraryConfiguration(serviceID: f.library.serviceID, name: "Other", metadataSource: .tmdb)
        let a = try f.record("Movie"), b = try f.record("Movie", library: other)
        try await f.index.upsert(a, scanID: UUID()); try await f.index.upsert(b, scanID: UUID())
        let gate = ReliabilityGate(), provider = ReliabilityProvider(gate: gate, phase: phase)
        let matcher = MetadataMatcher(index: f.index, providers: [provider])
        await matcher.enqueue(library: f.library, references: [a.reference])
        try await eventually { await gate.entered }
        await matcher.enqueue(library: other, references: [b.reference])
        try await eventually {
            let stats = await matcher.cacheStatistics()
            return phase == "search" ? stats.search.waiters == 2 : stats.detail.waiters == 2
        }
        await matcher.cancel(libraryID: f.library.id)
        // A cancelled consumer returns while the other library still owns the request.
        await matcher.waitForMatching(libraryID: f.library.id)
        #expect(await matcher.currentProgress(libraryID: other.id)?.isRunning == true)
        await gate.release(); await matcher.waitForMatching(libraryID: other.id)
        #expect(await provider.searches == 1); #expect(await provider.detailCalls == 1)
        #expect(try await f.index.record(reference: a.reference)?.onlineMetadata.title == nil)
        #expect(try await f.index.record(reference: b.reference)?.onlineMetadata.title == "Movie")
        let stats = await matcher.cacheStatistics()
        #expect(stats.search.flights == 0 && stats.detail.flights == 0)
        try saveEvidence("inflight-\(phase).json", ["libraries": 2, "searchCalls": await provider.searches,
            "detailCalls": await provider.detailCalls, "cancelledLibraryUnchanged": true,
            "otherLibraryCompleted": true, "flightsAfterCompletion": stats.search.flights + stats.detail.flights])
    }

    @Test func matchingAndDetailPageShareTheSameDetailRequest() async throws {
        let f = try ReliabilityEnvironment(); defer { f.clean() }
        let a = try f.record("Movie"), other = MediaLibraryConfiguration(serviceID: UUID(), name: "Known", metadataSource: .tmdb)
        var b = try f.record("Movie", library: other)
        b.onlineMetadata = .init(title: "Old", kind: .movies, tmdbID: "12"); b.metadataSource = .tmdb
        try await f.index.upsert(a, scanID: UUID()); try await f.index.upsert(b, scanID: UUID())
        let gate = ReliabilityGate(), provider = ReliabilityProvider(gate: gate, phase: "detail")
        let matcher = MetadataMatcher(index: f.index, providers: [provider])
        await matcher.enqueue(library: f.library, references: [a.reference])
        try await eventually { await gate.entered }
        let reference = b.reference
        let detail = Task { try await matcher.enrichDetails(reference: reference, source: .tmdb) }
        try await eventually { await matcher.cacheStatistics().detail.waiters == 2 }
        detail.cancel()
        await #expect(throws: CancellationError.self) { try await detail.value }
        await gate.release(); await matcher.waitForMatching(libraryID: f.library.id)
        #expect(await provider.detailCalls == 1)
        #expect(try await f.index.record(reference: a.reference)?.onlineMetadata.detailVersion == 2)
        #expect(try await f.index.record(reference: b.reference)?.onlineMetadata.title == "Old")
    }

    @Test func cancelledLastWaiterCannotPublishLateOrEraseANewerFlight() async throws {
        let pool = MetadataRequestPool<Int>(disposition: { _ in .positive }, cost: { _ in 8 })
        let oldGate = ReliabilityGate(), newGate = ReliabilityGate()
        let old = Task { try await pool.value(for: "same") { await oldGate.wait(); return 1 } }
        try await eventually { await oldGate.entered }
        old.cancel()
        await #expect(throws: CancellationError.self) { try await old.value }
        let fresh = Task { try await pool.value(for: "same") { await newGate.wait(); return 2 } }
        try await eventually { await newGate.entered }
        await oldGate.release()
        #expect(await pool.statistics().flights == 1)
        await newGate.release(); #expect(try await fresh.value.value == 2)
        let cached = try await pool.value(for: "same") { Issue.record("Fresh cache was lost"); return 3 }
        #expect(cached.value == 2 && cached.reused)
    }

    @Test func negativeTTLPositiveTTLCountAndByteBoundsAndForceRefresh() async throws {
        let clock = ReliabilityClock()
        let policy = MetadataCachePolicy(positiveTTL: .seconds(10), negativeTTL: .seconds(2), positiveCapacity: 2, negativeCapacity: 2, maximumBytes: 96)
        let pool = MetadataRequestPool<Int>(policy: policy, disposition: { $0 == 0 ? .negative : .positive }, cost: { _ in 20 }, now: { clock.now })
        for key in ["n1", "n2", "n3"] { _ = try await pool.value(for: key) { 0 } }
        #expect(await pool.statistics().negative == 2)
        #expect(try await pool.value(for: "n2") { Issue.record("Negative entry missed before TTL"); return 1 }.value == 0)
        clock.advance(.seconds(3))
        #expect(try await pool.value(for: "n2") { 2 }.value == 2)
        for key in ["p1", "p2", "p3"] { _ = try await pool.value(for: key) { 1 } }
        let stats = await pool.statistics()
        #expect(stats.positive == 2 && stats.bytes <= 96)
        clock.advance(.seconds(11))
        #expect(await pool.statistics().positive == 0)
        let start = clock.now
        _ = try await pool.value(for: "fresh") { 1 }
        clock.advance(.seconds(1))
        #expect(try await pool.value(for: "fresh", cachedAfter: clock.now) { 2 }.value == 2)
        #expect(try await pool.value(for: "fresh", cachedAfter: start) { Issue.record("Per-run reuse failed"); return 3 }.value == 2)
        let oversized = MetadataRequestPool<Int>(policy: policy, disposition: { _ in .positive }, cost: { _ in 200 })
        _ = try await oversized.value(for: "large") { 1 }
        #expect(await oversized.statistics().positive == 0)
        // A failed forced refresh cannot reveal a previously cached empty result.
        _ = try await pool.value(for: "miss") { 0 }
        clock.advance(.seconds(1))
        await #expect(throws: MetadataProviderError.self) {
            try await pool.value(for: "miss", cachedAfter: clock.now) { throw MetadataProviderError.rateLimited }
        }
        #expect(try await pool.value(for: "miss") { 7 }.value == 7)
    }

    @Test func oneRunWithManyTitlesKeepsOnlyBoundedSharedCaches() async throws {
        let f = try ReliabilityEnvironment(); defer { f.clean() }
        let provider = ReliabilityProvider()
        let matcher = MetadataMatcher(index: f.index, providers: [provider],
            cachePolicy: .init(positiveCapacity: 3, negativeCapacity: 2, maximumBytes: 2048))
        var refs: [FileResourceReference] = []
        for i in 0..<40 {
            let record = try f.record("Title \(i)")
            try await f.index.upsert(record, scanID: UUID()); refs.append(record.reference)
        }
        await matcher.enqueue(library: f.library, references: refs); await matcher.waitForMatching(libraryID: f.library.id)
        let stats = await matcher.cacheStatistics()
        #expect(await provider.searches == 40)
        #expect(stats.search.positive <= 3 && stats.detail.positive <= 3)
        #expect(stats.search.bytes <= 2048 && stats.detail.bytes <= 2048)
        #expect(await matcher.currentProgress(libraryID: f.library.id)?.completed == 40)
        try saveEvidence("bounded-caches.json", ["titlesProcessed": 40, "positiveCapacityPerPool": 3,
            "bytesLimitPerPool": 2048, "searchEntries": stats.search.positive, "detailEntries": stats.detail.positive,
            "searchBytes": stats.search.bytes, "detailBytes": stats.detail.bytes, "perRunCacheCopies": 0])
    }

    @Test func emptySearchExpiresAndErrorsNeverBecomeCachedMisses() async throws {
        let f = try ReliabilityEnvironment(); defer { f.clean() }
        let record = try f.record("Movie"); try await f.index.upsert(record, scanID: UUID())
        let provider = ReliabilityProvider(); await provider.setMode(.empty)
        let matcher = MetadataMatcher(index: f.index, providers: [provider], cachePolicy: .init(negativeTTL: .milliseconds(30)))
        for _ in 0..<2 {
            await matcher.enqueue(library: f.library, references: [record.reference]); await matcher.waitForMatching(libraryID: f.library.id)
        }
        #expect(await provider.searches == 1)
        try await Task.sleep(for: .milliseconds(40))
        await provider.setMode(.normal)
        await matcher.enqueue(library: f.library, references: [record.reference]); await matcher.waitForMatching(libraryID: f.library.id)
        #expect(await provider.searches == 2)
        #expect(try await f.index.record(reference: record.reference)?.onlineMetadata.title == "Movie")
    }

    @Test(arguments: [ReliabilityProvider.Mode.authentication, .rateLimited, .service, .network])
    fileprivate func providerFailuresPauseButExplicitRetryDoesNotReuseFailure(mode: ReliabilityProvider.Mode) async throws {
        let f = try ReliabilityEnvironment(); defer { f.clean() }
        let a = try f.record("Movie"), b = try f.record("Later")
        try await f.index.upsert(a, scanID: UUID()); try await f.index.upsert(b, scanID: UUID())
        let provider = ReliabilityProvider(); await provider.setMode(mode)
        let matcher = MetadataMatcher(index: f.index, providers: [provider])
        await matcher.enqueue(library: f.library, references: [a.reference, b.reference]); await matcher.waitForMatching(libraryID: f.library.id)
        #expect(await provider.searches == 1)
        #expect(await matcher.currentProgress(libraryID: f.library.id)?.unmatched == 0)
        #expect(await matcher.currentProgress(libraryID: f.library.id)?.metrics?.matchOutcome == .paused)
        #expect(try await f.index.record(reference: a.reference)?.metadataError != nil)
        #expect(await matcher.cacheStatistics().search.negative == 0)
        await provider.setMode(.normal)
        await matcher.enqueue(library: f.library, references: [a.reference, b.reference]); await matcher.waitForMatching(libraryID: f.library.id)
        #expect(await provider.searches == 3)
        #expect(await matcher.currentProgress(libraryID: f.library.id)?.matched == 2)
    }

    @Test func individualMalformedSearchAndDetailDoNotDisableLaterItems() async throws {
        let f = try ReliabilityEnvironment(); defer { f.clean() }
        let provider = ReliabilityProvider(); await provider.setMode(.item)
        let matcher = MetadataMatcher(index: f.index, providers: [provider])
        let records = try ["Bad", "BadDetail", "Good", "Bad"].enumerated().map { try f.record($0.element, path: "/\($0.offset).mkv") }
        for record in records { try await f.index.upsert(record, scanID: UUID()) }
        await matcher.enqueue(library: f.library, references: records.map(\.reference)); await matcher.waitForMatching(libraryID: f.library.id)
        #expect(await provider.searches == 4); #expect(await provider.detailCalls == 2)
        let status = await matcher.currentProgress(libraryID: f.library.id)
        #expect(status?.completed == 4 && status?.matched == 1 && status?.unmatched == 0 && status?.failed == 3)
        #expect(try await f.index.record(reference: records[2].reference)?.onlineMetadata.title == "Good")
    }

    @Test(arguments: [false, true])
    func explicitDetailBatchIsPagedAndStopsOnlyForProviderFailures(pause: Bool) async throws {
        let f = try ReliabilityEnvironment(); defer { f.clean() }
        let provider = ReliabilityProvider(); await provider.setMode(pause ? .authentication : .item)
        for i in 0..<301 {
            var record = try f.record("Known \(i)")
            record.onlineMetadata = .init(title: "Known \(i)", kind: .movies, tmdbID: i == 0 ? "404" : String(1000+i))
            record.metadataSource = .tmdb
            try await f.index.upsert(record, scanID: UUID())
        }
        let matcher = MetadataMatcher(index: f.index, providers: [provider])
        await matcher.enrichLibraryDetails(f.library); await matcher.waitForMatching(libraryID: f.library.id)
        #expect(await provider.searches == 0)
        #expect(await provider.detailCalls == (pause ? 1 : 301))
        let progress = await matcher.currentProgress(libraryID: f.library.id)
        #expect(progress?.failed == 1 && progress?.unmatched == 0)
        #expect(progress?.matched == (pause ? 0 : 300))
    }

    @Test(arguments: [401, 403, 429, 503, 404, 422, 200])
    func httpErrorsKeepTheirScope(status: Int) async throws {
        let provider = TMDBMetadataProvider(credential: .init(kind: .apiKey, value: "fixture"), request: { url, _ in
            (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await provider.search(title: "Movie", year: nil, kind: .movies); Issue.record("Expected classified failure") }
        catch {
            let category = MetadataProviderError.category(of: error)
            switch status {
            case 401, 403: #expect(category == .authentication)
            case 429: #expect(category == .rateLimited)
            case 503: #expect(category == .service)
            default: #expect(category == .item)
            }
        }
    }

    @Test(arguments: [403, 429, 503])
    func doubanHTTPFailuresAreClassifiedBeforeParsing(status: Int) async throws {
        let provider = DoubanMetadataProvider(request: { url, _ in
            (Data("Forbidden".utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await provider.search(title: "Movie", year: nil, kind: .movies); Issue.record("Expected classified failure") }
        catch {
            #expect(MetadataProviderError.category(of: error) == (status == 403 ? .authentication : status == 429 ? .rateLimited : .service))
        }
    }

    @Test func incompleteAliasesAreSuggestionsAndNeverNegativeOrPositiveCache() async throws {
        let f = try ReliabilityEnvironment(); defer { f.clean() }
        let record = try f.record("Alias"); try await f.index.upsert(record, scanID: UUID())
        let requests = ReliabilityCounter()
        let provider = TMDBMetadataProvider(credential: .init(kind: .apiKey, value: "fixture"), request: { url, _ in
            await requests.increment()
            let search = url.path.contains("search")
            return (Data((search ? #"{"results":[{"id":12,"title":"Other"}]}"# : "{}").utf8),
                    HTTPURLResponse(url: url, statusCode: search ? 200 : 429, httpVersion: nil, headerFields: nil)!)
        })
        let matcher = MetadataMatcher(index: f.index, providers: [provider])
        for _ in 0..<2 {
            await matcher.enqueue(library: f.library, references: [record.reference]); await matcher.waitForMatching(libraryID: f.library.id)
        }
        #expect(await requests.value == 4)
        #expect(try await f.index.record(reference: record.reference)?.candidates.count == 1)
        #expect(try await f.index.record(reference: record.reference)?.onlineMetadata.title == nil)
        let stats = await matcher.cacheStatistics()
        #expect(stats.search.positive == 0 && stats.search.negative == 0)
    }

    private func eventually(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !predicate() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for fixture")
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func saveEvidence(_ name: String, _ value: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_BMH03_EVIDENCE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(name))
    }
}

private struct ReliabilityEnvironment {
    let directory: URL
    let index: MediaIndex
    let library = MediaLibraryConfiguration(serviceID: UUID(), name: "Reliability", metadataSource: .tmdb)
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
    }
    func record(_ title: String, library: MediaLibraryConfiguration? = nil, path: String? = nil) throws -> MediaRecord {
        let library = library ?? self.library
        let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: path ?? "/\(title).mkv")
        return .init(reference: ref, entry: .init(path: ref.path, name: "\(title).mkv", isDirectory: false), groupKey: title,
                     filenameMetadata: .init(title: title, kind: .movies))
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
}
private actor ReliabilityGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private actor ReliabilityProvider: MetadataProvider {
    enum Mode: Sendable { case normal, empty, authentication, rateLimited, service, network, item }
    nonisolated let source = MetadataSource.tmdb
    let gate: ReliabilityGate?
    let phase: String
    var mode = Mode.normal
    var searches = 0, detailCalls = 0
    init(gate: ReliabilityGate? = nil, phase: String = "") { self.gate = gate; self.phase = phase }
    func setMode(_ mode: Mode) { self.mode = mode }
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        searches += 1
        if phase == "search" { await gate?.wait() }
        switch mode {
        case .authentication: throw MetadataProviderError.authentication
        case .rateLimited: throw MetadataProviderError.rateLimited
        case .service: throw MetadataProviderError.serviceUnavailable
        case .network: throw URLError(.timedOut)
        case .empty: return []
        case .item where title == "Bad": throw MetadataProviderError.invalidResponse
        default: break
        }
        return [.init(source: .tmdb, metadata: .init(title: title, year: year, kind: kind, tmdbID: title == "BadDetail" ? "404" : title == "Good" ? "13" : title == "Later" ? "14" : "12"))]
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        detailCalls += 1
        if phase == "detail" { await gate?.wait() }
        if mode == .authentication { throw MetadataProviderError.authentication }
        if id == "404" { throw MetadataProviderError.notFound }
        return .init(title: id == "13" ? "Good" : id == "14" ? "Later" : "Movie", kind: kind, tmdbID: id, detailVersion: 2)
    }
}
private final class ReliabilityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { value } }
    func advance(_ duration: Duration) { lock.withLock { value = value.advanced(by: duration) } }
}
private actor ReliabilityCounter {
    var value = 0
    func increment() { value += 1 }
}
