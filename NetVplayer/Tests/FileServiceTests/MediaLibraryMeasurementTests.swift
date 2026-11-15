import Foundation
import Testing
import Models
import Storage
import FileServiceEngine
@testable import MediaLibraryEngine

@Suite("BMH-01 filename truth and pipeline measurements", .serialized)
struct MediaLibraryMeasurementTests {
    struct Truth: Sendable {
        let path: String; let kind: MediaLibraryKind; let title: String; let original: String?
        let year: Int?; let season: Int?; let episode: Int?
    }
    // The first 20 are the archived research inputs. Additional cases protect against over-matching.
    static let truth: [Truth] = [
        .init(path: "/Movies/Arrival.2016.1080p.BluRay.mkv", kind: .movies, title: "Arrival", original: nil, year: 2016, season: nil, episode: nil),
        .init(path: "/Movies/1917.2019.2160p.BluRay.mkv", kind: .movies, title: "1917", original: nil, year: 2019, season: nil, episode: nil),
        .init(path: "/Movies/2001.A.Space.Odyssey.1968.1080p.mkv", kind: .movies, title: "2001 A Space Odyssey", original: nil, year: 1968, season: nil, episode: nil),
        .init(path: "/Movies/12.Monkeys.1995.1080p.mkv", kind: .movies, title: "12 Monkeys", original: nil, year: 1995, season: nil, episode: nil),
        .init(path: "/Movies/[哈利·波特与死亡圣器(下)]Harry.Potter.and.the.Deathly.Hallows.Part.2.2011.2160p.mkv", kind: .movies, title: "哈利·波特与死亡圣器(下)", original: "Harry Potter and the Deathly Hallows Part 2", year: 2011, season: nil, episode: nil),
        .init(path: "/Movies/[BOBO]Spirited.Away.2001.1080p.mkv", kind: .movies, title: "Spirited Away", original: nil, year: 2001, season: nil, episode: nil),
        .init(path: "/Movies/流浪地球2.2023.2160p.mkv", kind: .movies, title: "流浪地球2", original: nil, year: 2023, season: nil, episode: nil),
        .init(path: "/Movies/Movie.Title.WEBRip.1080p.mkv", kind: .movies, title: "Movie Title", original: nil, year: nil, season: nil, episode: nil),
        .init(path: "/Movies/Movie.Title.2160p.WEB-DL.DV.mkv", kind: .movies, title: "Movie Title", original: nil, year: nil, season: nil, episode: nil),
        .init(path: "/Movies/Se7en.1995.REMASTERED.1080p.mkv", kind: .movies, title: "Se7en", original: nil, year: 1995, season: nil, episode: nil),
        .init(path: "/TV/Breaking.Bad.S02E03.1080p.mkv", kind: .television, title: "Breaking Bad", original: nil, year: nil, season: 2, episode: 3),
        .init(path: "/TV/Show/Season 2/01.mkv", kind: .television, title: "Show", original: nil, year: nil, season: 2, episode: 1),
        .init(path: "/TV/Show/Season 1/1x01.mkv", kind: .television, title: "Show", original: nil, year: nil, season: 1, episode: 1),
        .init(path: "/TV/Show.E01.1080p.mkv", kind: .television, title: "Show", original: nil, year: nil, season: 1, episode: 1),
        .init(path: "/TV/Show - 01.mkv", kind: .television, title: "Show", original: nil, year: nil, season: 1, episode: 1),
        .init(path: "/TV/The.100.S01E01.mkv", kind: .television, title: "The 100", original: nil, year: nil, season: 1, episode: 1),
        .init(path: "/TV/庆余年.第2季.第03集.1080p.mkv", kind: .television, title: "庆余年", original: nil, year: nil, season: 2, episode: 3),
        .init(path: "/Movies/Wall-E.2008.1080p.mkv", kind: .movies, title: "Wall-E", original: nil, year: 2008, season: nil, episode: nil),
        .init(path: "/Movies/Avatar (2009) {tmdb-19995}.mkv", kind: .movies, title: "Avatar", original: nil, year: 2009, season: nil, episode: nil),
        .init(path: "/Movies/(流浪地球2) The.Wandering.Earth.II.2023.2160p.mkv", kind: .movies, title: "流浪地球2", original: "The Wandering Earth II", year: 2023, season: nil, episode: nil),
        .init(path: "/Movies/1917.mkv", kind: .movies, title: "1917", original: nil, year: nil, season: nil, episode: nil),
        .init(path: "/Movies/2001.A.Space.Odyssey.mkv", kind: .movies, title: "2001 A Space Odyssey", original: nil, year: nil, season: nil, episode: nil),
        .init(path: "/Movies/Blade.Runner.2049.2017.1080p.mkv", kind: .movies, title: "Blade Runner 2049", original: nil, year: 2017, season: nil, episode: nil),
        .init(path: "/Movies/Wonder.Woman.1984.2020.WEBRip.mkv", kind: .movies, title: "Wonder Woman 1984", original: nil, year: 2020, season: nil, episode: nil),
        .init(path: "/Movies/Summer.of.1999.Is.Here.mkv", kind: .movies, title: "Summer of 1999 Is Here", original: nil, year: nil, season: nil, episode: nil),
        .init(path: "/Movies/[REC].2007.1080p.mkv", kind: .movies, title: "REC", original: nil, year: 2007, season: nil, episode: nil),
        .init(path: "/Movies/Movie - 01.mkv", kind: .movies, title: "Movie - 01", original: nil, year: nil, season: nil, episode: nil),
        .init(path: "/Movies/Movie.E01.1080p.mkv", kind: .mixed, title: "Movie E01", original: nil, year: nil, season: nil, episode: nil),
        .init(path: "/TV/1899.mkv", kind: .television, title: "1899", original: nil, year: nil, season: 1, episode: nil),
        .init(path: "/TV/Show/Season 2/Show.E01.mkv", kind: .television, title: "Show", original: nil, year: nil, season: 2, episode: 1),
        .init(path: "/TV/Show/Season 2/Show.S03E04.mkv", kind: .television, title: "Show", original: nil, year: nil, season: 3, episode: 4),
        .init(path: "/TV/Show/Season 0/02.mkv", kind: .mixed, title: "Show", original: nil, year: nil, season: 0, episode: 2),
        .init(path: "/TV/Show/Season 2/1001.mkv", kind: .television, title: "1001", original: nil, year: nil, season: 2, episode: nil),
        .init(path: "/Movies/WEBRipley.2020.mkv", kind: .movies, title: "WEBRipley", original: nil, year: 2020, season: nil, episode: nil),
        .init(path: "/Movies/Title.HDReam.mkv", kind: .movies, title: "Title HDReam", original: nil, year: nil, season: nil, episode: nil),
        .init(path: "/Movies/中文.😀.2020.WEBRip.mkv", kind: .movies, title: "中文 😀", original: nil, year: 2020, season: nil, episode: nil),
    ]
    @Test func manuallyLabelledFilenameCorpus() throws {
        var rows: [[String: Any]] = []
        for item in Self.truth {
            let actual = MediaFilenameParser.parse(path: item.path, libraryKind: item.kind)
            #expect(actual.title == item.title, "\(item.path)")
            #expect(actual.originalTitle == item.original, "\(item.path)")
            #expect(actual.year == item.year, "\(item.path)")
            #expect(actual.season == item.season, "\(item.path)")
            #expect(actual.episode == item.episode, "\(item.path)")
            #expect(actual.kind == (item.season == nil ? .movies : .television), "\(item.path)")
            rows.append(["path": item.path, "actual": String(decoding: try JSONEncoder().encode(actual), as: UTF8.self),
                         "matchesExpectedFields": actual.title == item.title && actual.originalTitle == item.original && actual.year == item.year && actual.season == item.season && actual.episode == item.episode])
        }
        try save("filename-truth.json", data: JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]))
    }
    @Test func scanningMatchingAndSafeExportUseSameMonotonicRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = TaskDiagnosticStore(storage: StorageManager(storageDirectory: root))
        let index = MediaIndex(url: root.appendingPathComponent("media.sqlite"))
        let matcher = MetadataMatcher(index: index, providers: [TruthProvider()], diagnostics: diagnostics)
        let scanner = MediaLibraryScanner(index: index, diagnostics: diagnostics, matcher: matcher)
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "private-library", metadataSource: .tmdb)
        let names = ["1917.2019.1080p.mkv", "1917.2019.2160p.mkv", "Duplicate.2020.mkv", "Unknown.2020.mkv"]
        await scanner.scan(library, client: MetricsFiles(names: names))
        await matcher.waitForMatching(libraryID: library.id)
        let scan = try #require(await scanner.currentProgress(libraryID: library.id)?.metrics)
        let progress = try #require(await matcher.currentProgress(libraryID: library.id))
        let match = try #require(progress.metrics)
        #expect(match.runID == scan.runID)
        let times = try [#require(match.firstFileSeconds), #require(match.scanFinishedSeconds), #require(match.matchStartedSeconds),
                         #require(match.firstOnlineMetadataSeconds), #require(match.firstOnlinePosterAddressSeconds), #require(match.matchFinishedSeconds)]
        #expect(times.allSatisfy { $0 >= 0 })
        #expect(times[0] <= times[1] && times[0] <= times[2])
        #expect(times[2] <= times[3] && times[3] <= times[4] && times[4] <= times[5])
        #expect(times[1] <= times[5]) // Matching drains only after the producer closes.
        #expect(match.providerSearchCalls == 3 && match.providerDetailCalls == 1)
        #expect(match.cacheHits == 2) // The duplicate file reuses both the search and detail responses.
        #expect(match.matchOutcome == .completed && match.processed == 4)
        #expect(match.matched == 2 && match.needsConfirmation == 1 && match.unmatched == 1)
        let records = try await index.records(libraryID: library.id)
        #expect(records.filter { $0.onlineMetadata.tmdbID == "1917-truth" }.count == 2)
        #expect(records.filter { $0.candidates.count == 2 }.count == 1)
        let bytes = try diagnostics.exportData()
        let text = String(decoding: bytes, as: UTF8.self)
        for secret in names + ["private-library", "private.invalid", library.id.uuidString] { #expect(!text.contains(secret)) }
        #expect(text.contains("firstOnlinePosterAddressSeconds") && text.contains("metadataMatch"))
        #expect(try diagnostics.records().count == 2)
        try save("pipeline-diagnostics.json", data: bytes)
        let verdict: [String: Any] = ["files": 4, "expectedAutoMatches": 2, "actualCorrectAutoMatches": records.filter { $0.onlineMetadata.tmdbID == "1917-truth" }.count,
            "wrongAutoMatches": records.filter { $0.onlineMetadata.tmdbID != nil && $0.onlineMetadata.tmdbID != "1917-truth" }.count,
            "needsConfirmation": match.needsConfirmation, "unmatched": match.unmatched, "scope": "controlled fixture, not representative library accuracy"]
        try save("matching-truth.json", data: JSONSerialization.data(withJSONObject: verdict, options: [.prettyPrinted, .sortedKeys]))
    }
    @Test func cancelledMatcherDoesNotClaimPosterOrCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = TaskDiagnosticStore(storage: StorageManager(storageDirectory: root))
        let index = MediaIndex(url: root.appendingPathComponent("media.sqlite"))
        let provider = GatedProvider()
        let matcher = MetadataMatcher(index: index, providers: [provider], diagnostics: diagnostics)
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "cancel", metadataSource: .tmdb)
        let reference = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/Cancel.2020.mkv")
        try await index.upsert(.init(reference: reference, entry: .init(path: reference.path, name: "Cancel.2020.mkv", isDirectory: false), groupKey: "cancel", filenameMetadata: .init(title: "Cancel", year: 2020, kind: .movies)), scanID: UUID())
        _ = try #require(try await index.record(reference: reference))
        await matcher.enqueue(library: library, references: [reference])
        try #require(await provider.waitForSearch())
        await matcher.cancel(libraryID: library.id)
        await provider.release()
        await matcher.waitForMatching(libraryID: library.id)
        let metrics = try #require(await matcher.currentProgress(libraryID: library.id)?.metrics)
        #expect(metrics.matchOutcome == .cancelled && metrics.firstOnlinePosterAddressSeconds == nil)
        #expect(metrics.processed == 0)
        #expect(try await index.record(reference: reference)?.onlineMetadata.title == nil)
        #expect(try diagnostics.records().first?.latest.state == .cancelled)
    }
    @Test func rematchClearsOldFilenameGuessesAndKeepsManualFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = MediaIndex(url: root.appendingPathComponent("media.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "numeric-title", metadataSource: .local)
        let reference = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/1917.mkv")
        var record = MediaRecord(reference: reference, entry: .init(path: reference.path, name: "1917.mkv", isDirectory: false), groupKey: "old", filenameMetadata: .init(title: "1917", year: 1917))
        record.correction = .init(reference: reference, fields: .init(title: "Pinned", year: 2019))
        try await index.upsert(record, scanID: UUID())
        let matcher = MetadataMatcher(index: index)
        try await matcher.rematch(library); await matcher.waitForMatching(libraryID: library.id)
        let updated = try #require(try await index.record(reference: reference))
        #expect(updated.filenameMetadata.title == "1917" && updated.filenameMetadata.year == nil)
        #expect(updated.metadata.title == "Pinned" && updated.metadata.year == 2019)
    }
    @Test func matchDiagnosticsDoNotReplaceScanRetryHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = TaskDiagnosticStore(storage: StorageManager(storageDirectory: root))
        let index = MediaIndex(url: root.appendingPathComponent("media.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "retry", metadataSource: .local)
        let scanID = UUID()
        try diagnostics.record(.init(id: scanID, kind: .mediaScan, localSubjectID: library.id,
            event: .init(time: Date().addingTimeInterval(-10), stage: .finished, state: .needsAttention, retryCount: 3)))
        try diagnostics.record(.init(id: UUID(), kind: .metadataMatch, localSubjectID: library.id,
            event: .init(stage: .finished, state: .completed, retryCount: 99)))
        let scanner = MediaLibraryScanner(index: index, diagnostics: diagnostics)
        await scanner.scan(library, client: MetricsFiles(names: []), request: .resume)
        let resumed = try #require(try diagnostics.records().first { $0.kind == .mediaScan && $0.id != scanID })
        #expect(resumed.latest.retryCount == 4)
    }
    @Test func oldDiagnosticsDecodeAndNumericProjectionIsBounded() throws {
        let old = try JSONDecoder().decode(TaskDiagnosticEvent.self, from: Data(#"{"time":0,"stage":"finished","state":"completed","retryCount":0}"#.utf8))
        #expect(old.mediaMetrics == nil)
        var metrics = MediaLibraryMetrics(); metrics.firstFileSeconds = -.infinity; metrics.elapsedSeconds = .nan
        metrics.providerSearchCalls = -3; metrics.candidates = Int.max
        let safe = TaskDiagnosticEvent(stage: .finished, state: .completed, mediaMetrics: metrics)
        #expect(safe.mediaMetrics?.firstFileSeconds == nil && safe.mediaMetrics?.elapsedSeconds == 0)
        #expect(safe.mediaMetrics?.providerSearchCalls == 0 && safe.mediaMetrics?.candidates == 10_000_000)
        _ = try JSONEncoder().encode(safe)
    }
    private func save(_ name: String, data: Data) throws {
        guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_BMH01_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name), options: .atomic)
    }
}

private struct MetricsFiles: FileServiceClient {
    let names: [String]
    func connect() async throws {}
    func list(path: String, cursor: String?) async throws -> FileEntryPage {
        .init(entries: names.map { .init(path: "/" + $0, name: $0, isDirectory: false, size: 1) })
    }
    func stat(path: String) async throws -> FileEntry { throw FileServiceError.path(path) }
    func read(path: String, range: Range<Int64>) async throws -> Data { Data() }
    func resolve(path: String) async throws -> ResolvedFileResource { throw FileServiceError.path(path) }
}
private struct TruthProvider: MetadataProvider {
    let source: MetadataSource = .tmdb
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        if title == "1917" { return [.init(source: .tmdb, metadata: .init(title: title, year: 2019, kind: .movies, tmdbID: "1917-truth"))] }
        if title == "Duplicate" { return ["remake-a", "remake-b"].map { .init(source: .tmdb, metadata: .init(title: title, year: 2020, kind: .movies, tmdbID: $0)) } }
        return []
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        .init(title: "1917", year: 2019, kind: .movies, poster: "https://private.invalid/poster.jpg", tmdbID: id)
    }
}
private actor GatedProvider: MetadataProvider {
    nonisolated let source: MetadataSource = .tmdb
    private var started = false
    private var gate: CheckedContinuation<Void, Never>?
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        started = true
        await withCheckedContinuation { gate = $0 }
        return [.init(source: .tmdb, metadata: .init(title: title, year: year, kind: kind, tmdbID: "cancel"))]
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        .init(title: "Cancel", poster: "https://private.invalid/cancel.jpg")
    }
    func waitForSearch() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !started && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return started
    }
    func release() { gate?.resume(); gate = nil }
}
