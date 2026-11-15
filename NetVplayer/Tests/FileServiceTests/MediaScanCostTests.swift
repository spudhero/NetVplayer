import Foundation
import Testing
import Models
import Storage
import FileServiceEngine
@testable import MediaLibraryEngine

@Suite("BMH-05 measured scan costs", .serialized)
struct MediaScanCostTests {
    /// Opt-in: fixed synthetic inputs, real SQLite and configured scan guards. No online provider.
    /// Keep timings out of assertions; correctness and I/O counts are checked separately.
    @Test func measuredConfiguredScan() async throws {
        guard let output = ProcessInfo.processInfo.environment["NETVPLAYER_BMH05_BENCHMARK_DIR"] else { return }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        for round in 0..<3 {
            let work = root.appendingPathComponent("round-\(round)")
            let storage = StorageManager(storageDirectory: work.appendingPathComponent("state"))
            let preferences = UserPreferences(defaults: UserDefaults(suiteName: "bmh05." + UUID().uuidString)!, credentialStore: MemoryCredentialStore())
            let store = FileServiceStore(storage: storage, preferences: preferences)
            let service = FileServiceConfiguration(name: "Cost fixture", kind: .webDAV, address: "https://fixture.invalid")
            let library = MediaLibraryConfiguration(serviceID: service.id, name: "Cost fixture", metadataSource: .local)
            let others = (0..<31).map { FileServiceConfiguration(name: "Unused \($0)", kind: .webDAV, address: "https://unused.invalid/\($0)") }
            try store.save(.init(services: [service] + others, libraries: [library]))
            try store.saveBookmark(Data("synthetic-scope".utf8), for: service.id)
            let files = ScanCostFiles(count: 1000)
            let index = MediaIndex(url: work.appendingPathComponent("media.sqlite"))
            let scanner = MediaLibraryScanner(index: index, store: store)
            var row: [String: Any] = ["round": round, "files": 1000, "configuredServices": 32]
            for phase in ["first", "incremental", "sidecarChanged"] {
                if phase == "sidecarChanged" { await files.changeSidecar() }
                await files.resetCounts()
                let start = ContinuousClock.now
                await scanner.scan(library, client: files)
                let seconds = Self.seconds(start.duration(to: .now))
                let progress = try #require(await scanner.currentProgress(libraryID: library.id))
                #expect(!progress.isCancelled && progress.recoveryError == nil && progress.files == 1000)
                let records = try await index.records(libraryID: library.id)
                #expect(records.count == 1000)
                #expect(records.allSatisfy { $0.localMetadata.title == (phase == "sidecarChanged" ? "Changed local title" : "Local title") })
                let counts = await files.counts()
                row[phase] = ["wallSeconds": seconds, "nfoReads": counts.0, "nfoReadWaitSeconds": counts.1,
                              "listCalls": counts.2, "metrics": String(decoding: try JSONEncoder().encode(progress.metrics), as: UTF8.self)]
            }
            // Independent operation probes; these are not additive whole-pipeline CPU percentages.
            var start = ContinuousClock.now
            for _ in 0..<4000 { _ = try MediaLibraryScanner.configurationRevision(library, store: store) }
            row["configuration4000Seconds"] = Self.seconds(start.duration(to: .now))
            let sqlIndex = MediaIndex(url: work.appendingPathComponent("sql.sqlite")), run = UUID()
            _ = try await sqlIndex.beginScanCheckpoint(library: library, revision: "cost-fixture", request: .rescan, runID: run)
            let metadata = try NFOMetadataParser.parse(ScanCostFiles.nfo("Local title"))
            start = .now
            for n in 0..<2000 {
                let ref = try FileResourceReference(serviceID: service.id, libraryID: library.id, path: "/SQL.\(n).mkv")
                try await sqlIndex.upsertScanned(.init(reference: ref, entry: .init(path: ref.path, name: "SQL.\(n).mkv", isDirectory: false),
                    groupKey: "cost", filenameMetadata: .init(title: "SQL", year: 2020), localMetadata: metadata), runID: run)
            }
            row["sqlite2000AtomicWritesSeconds"] = Self.seconds(start.duration(to: .now))
            #expect(try await sqlIndex.records(libraryID: library.id).count == 2000)
            results.append(row)
        }
        let report: [String: Any] = ["stage": "BMH-05", "clock": "ContinuousClock, wall seconds", "rounds": results,
            "conditions": "debug SwiftPM; 1000 synthetic versions, one shared movie.nfo, 1ms cancellable wait per read, real WAL SQLite, 32 configured services; no HTTP or artwork",
            "scope": "operation probes are independent; provider calls and actual HTTP requests are zero; first poster is not measured"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("scan-costs.json"), options: .atomic)
    }

    static func seconds(_ duration: Duration) -> Double {
        let c = duration.components; return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    @Test func measuredSQLiteUpdates() async throws {
        guard let output = ProcessInfo.processInfo.environment["NETVPLAYER_BMH05_BENCHMARK_DIR"] else { return }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for round in 0..<3 {
            let index = MediaIndex(url: root.appendingPathComponent("updates-\(round).sqlite"))
            let library = MediaLibraryConfiguration(serviceID: UUID(), name: "SQL update fixture", metadataSource: .local)
            let run = UUID()
            _ = try await index.beginScanCheckpoint(library: library, revision: "fixture", request: .rescan, runID: run)
            _ = try await index.records(libraryID: library.id)
            let original = try NFOMetadataParser.parse(ScanCostFiles.nfo("Local title"))
            var row: [String: Any] = ["round": round]
            for phase in ["insert", "scalarUpdate"] {
                let start = ContinuousClock.now
                for n in 0..<2000 {
                    let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/SQL.\(n).mkv")
                    var metadata = original
                    if phase == "scalarUpdate" { metadata.plot = "Changed plot" }
                    try await index.upsertScanned(.init(reference: ref,
                        entry: .init(path: ref.path, name: "SQL.\(n).mkv", isDirectory: false, version: phase), groupKey: "cost",
                        filenameMetadata: .init(title: "SQL", year: 2020), localMetadata: metadata), runID: run)
                }
                row[phase + "Seconds"] = Self.seconds(start.duration(to: .now))
                let records = try await index.records(libraryID: library.id)
                #expect(records.count == 2000)
                #expect(records.allSatisfy { $0.entry.version == phase })
                if phase == "scalarUpdate" { #expect(records.allSatisfy { $0.localMetadata.plot == "Changed plot" }) }
                #expect(try await index.facets(libraryID: library.id).actors.count == 12)
            }
            rows.append(row)
        }
        try JSONSerialization.data(withJSONObject: ["clock": "ContinuousClock wall seconds", "rowsPerPhase": 2000,
            "scope": "real SQLite; atomic per-record insert/update, 12 actors and one director; scalar update changes entry version and plot; not HTTP", "rounds": rows],
            options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("sqlite-updates.json"), options: .atomic)
    }
}

actor ScanCostFiles: FileServiceClient {
    let count: Int
    private var changed = false, reads = 0, lists = 0, readWait: Double = 0
    init(count: Int) { self.count = count }
    nonisolated static func nfo(_ title: String) -> Data {
        let actors = (0..<12).map { "<actor><name>Actor \($0)</name><role>Role \($0)</role></actor>" }.joined()
        return Data(("<movie><title>" + title + "</title><year>2020</year><plot>" + String(repeating: "Synthetic plot. ", count: 80)
                     + "</plot><director>Fixture Director</director>" + actors + "</movie>").utf8)
    }
    func changeSidecar() { changed = true }
    func resetCounts() { reads = 0; lists = 0; readWait = 0 }
    func counts() -> (Int, Double, Int) { (reads, readWait, lists) }
    func connect() async throws {}
    func list(path: String, cursor: String?) async throws -> FileEntryPage {
        lists += 1
        let data = Self.nfo(changed ? "Changed local title" : "Local title")
        return FileEntryPage(entries: (0..<count).map { .init(path: "/Fixture.2020.\($0).mkv", name: "Fixture.2020.\($0).mkv", isDirectory: false, size: 1024, version: "1") }
            + [.init(path: "/movie.nfo", name: "movie.nfo", isDirectory: false, size: Int64(data.count), version: changed ? "2" : "1")])
    }
    func read(path: String, range: Range<Int64>) async throws -> Data {
        reads += 1; let start = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(1))
        readWait += MediaScanCostTests.seconds(start.duration(to: .now))
        return Self.nfo(changed ? "Changed local title" : "Local title")
    }
    func stat(path: String) async throws -> FileEntry { throw FileServiceError.protocolFailure("Unused fixture operation") }
    func resolve(path: String) async throws -> ResolvedFileResource { throw FileServiceError.protocolFailure("Unused fixture operation") }
}
