import Foundation
import Testing
import Models
import Storage
@testable import MediaLibraryEngine

@Suite("BMH-03 scale and Douban pacing", .serialized, .timeLimit(.minutes(5)))
struct MetadataScaleAndPacingTests {
    @Test func rematchVisitsMoreThanFiftyThousandWhileGroupingChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "Large", metadataSource: .tmdb)
        let count = 50_017, scan = UUID()
        let start = ContinuousClock.now
        for i in 0..<count {
            let path = String(format: "/%06d.mkv", i)
            let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: path)
            // NFO query stays identical; online identity changes all grouping keys
            // on the first page, which makes offset/group-order pagination unsafe.
            let record = MediaRecord(reference: ref, entry: .init(path: path, name: path, isDirectory: false), groupKey: "unused",
                filenameMetadata: .init(title: "Old \(count - i)", kind: .movies), localMetadata: .init(title: "Movie", kind: .movies))
            try await index.upsert(record, scanID: scan)
        }
        let provider = ScaleProvider(), matcher = MetadataMatcher(index: index, providers: [provider])
        let matchStart = ContinuousClock.now
        try await matcher.rematch(library); await matcher.waitForMatching(libraryID: library.id)
        let status = try #require(await matcher.currentProgress(libraryID: library.id))
        #expect(status.total == count && status.completed == count && status.matched == count)
        #expect(await provider.searches == 1); #expect(await provider.detailsCount == 1)
        let verifyRun = UUID()
        #expect(try await index.beginRematch(libraryID: library.id, runID: verifyRun) == count)
        var cursor = "", visited = 0, pages = 0
        while true {
            let ids = try await index.rematchPage(libraryID: library.id, runID: verifyRun, after: cursor)
            if ids.isEmpty { break }
            #expect(ids.count <= 256)
            for id in ids {
                let record = try #require(try await index.rematchRecord(id: id, libraryID: library.id))
                #expect(record.onlineMetadata.tmdbID == "12" && record.metadataError == nil)
            }
            cursor = try #require(ids.last); visited += ids.count; pages += 1
        }
        try await index.endRematch(runID: verifyRun)
        #expect(visited == count && pages == 196)
        let stats = await matcher.cacheStatistics()
        #expect(stats.search.positive == 1 && stats.detail.positive == 1)
        try saveEvidence("large-rematch.json", ["records": count, "visited": visited, "pages": pages, "pageLimit": 256,
            "searchCalls": await provider.searches, "detailCalls": await provider.detailsCount,
            "searchCacheEntries": stats.search.positive, "detailCacheEntries": stats.detail.positive,
            "totalSeconds": seconds(start.duration(to: .now)), "matchAndVerificationSeconds": seconds(matchStart.duration(to: .now))])
    }

    @Test func identitySnapshotExcludesNewFilesAndSurvivesUpdatesDeletionAndReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "Snapshot")
        func record(_ i: Int) throws -> MediaRecord {
            let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/\(i).mkv")
            return .init(reference: ref, entry: .init(path: ref.path, name: "\(i).mkv", isDirectory: false), groupKey: "group",
                         filenameMetadata: .init(title: "\(600-i)", kind: .movies))
        }
        for i in 0..<600 { try await index.upsert(record(i), scanID: UUID()) }
        let run = UUID(); #expect(try await index.beginRematch(libraryID: library.id, runID: run) == 600)
        var visited = Set<String>(), cursor = "", pageNumber = 0
        while true {
            let ids = try await index.rematchPage(libraryID: library.id, runID: run, after: cursor, limit: 97)
            if ids.isEmpty { break }
            for id in ids {
                #expect(visited.insert(id).inserted)
                var current = try #require(try await index.rematchRecord(id: id, libraryID: library.id))
                current.onlineMetadata = .init(title: "000 New order", tmdbID: "1"); try await index.upsert(current)
            }
            if pageNumber == 0 { try await index.upsert(record(999), scanID: UUID()) }
            cursor = try #require(ids.last); pageNumber += 1
        }
        #expect(visited.count == 600)
        #expect(!visited.contains(try record(999).id))
        let replacement = UUID(); #expect(try await index.beginRematch(libraryID: library.id, runID: replacement) == 601)
        try await index.endRematch(runID: run)
        #expect(try await !index.rematchPage(libraryID: library.id, runID: replacement).isEmpty)
        try await index.removeLibrary(library.id)
        #expect(try await index.rematchPage(libraryID: library.id, runID: replacement).isEmpty)
    }

    @Test func multipleLibrariesAndProvidersStrictlySpaceDoubanIncludingBrowserFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite")), starts = PacingStarts()
        func provider(_ fallback: Bool) -> DoubanMetadataProvider {
            DoubanMetadataProvider(request: { url, _ in
                await starts.record("http")
                if fallback {
                    return (Data(), HTTPURLResponse(url: URL(string: "https://sec.douban.com/b")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                return (Data("[]".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, publicPageRequest: { url, _ in
                await starts.record("browser")
                return (Data("[]".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        }
        let sharedProvider = provider(true), separateProvider = provider(false)
        let a = MetadataMatcher(index: index, providers: [sharedProvider]), b = MetadataMatcher(index: index, providers: [separateProvider])
        var libraries: [MediaLibraryConfiguration] = []
        for i in 0..<3 {
            let library = MediaLibraryConfiguration(serviceID: UUID(), name: "Library \(i)", metadataSource: .douban)
            libraries.append(library)
            let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/Query \(i).mkv")
            let record = MediaRecord(reference: ref, entry: .init(path: ref.path, name: ref.path, isDirectory: false), groupKey: "q",
                                     filenameMetadata: .init(title: "Query \(i)", kind: .movies))
            try await index.upsert(record, scanID: UUID())
            await (i == 2 ? b : a).enqueue(library: library, references: [ref])
        }
        for (i, library) in libraries.enumerated() { await (i == 2 ? b : a).waitForMatching(libraryID: library.id) }
        let values = await starts.values
        #expect(values.count == 5)
        let intervals = zip(values, values.dropFirst()).map { seconds($0.0.0.duration(to: $0.1.0)) }
        #expect(intervals.allSatisfy { $0 >= 1.0 })
        try saveEvidence("douban-pacing.json", ["intervalsSeconds": intervals, "minimumSeconds": intervals.min() ?? 0,
            "httpStarts": values.filter { $0.1 == "http" }.count, "browserStarts": values.filter { $0.1 == "browser" }.count,
            "libraries": 3, "providerInstances": 2, "configuredMinimumSeconds": 1])
    }

    @Test func cancelledPacingWaiterReleasesLaneAndNeverStartsRequest() async throws {
        let limiter = DoubanRequestLimiter(interval: .milliseconds(25)), starts = PacingStarts(), gate = PacingGate()
        let url = URL(string: "https://movie.douban.com/")!
        let first = Task { try await limiter.perform {
            await starts.record("first"); await gate.wait()
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        } }
        while await starts.values.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        let cancelled = Task { try await limiter.perform {
            await starts.record("cancelled")
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        } }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await gate.release(); _ = try await first.value
        _ = try await limiter.perform {
            await starts.record("last")
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await starts.values.map(\.1) == ["first", "last"])
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
    private func saveEvidence(_ name: String, _ value: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_BMH03_EVIDENCE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(name))
    }
}
private actor ScaleProvider: MetadataProvider {
    nonisolated let source = MetadataSource.tmdb
    var searches = 0, detailsCount = 0
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        searches += 1
        return [.init(source: .tmdb, metadata: .init(title: title, kind: kind, tmdbID: "12"))]
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        detailsCount += 1; return .init(title: "Movie", kind: kind, tmdbID: id)
    }
}
private actor PacingStarts {
    var values: [(ContinuousClock.Instant, String)] = []
    func record(_ label: String) { values.append((.now, label)) }
}
private actor PacingGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
