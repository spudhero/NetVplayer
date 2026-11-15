import Foundation
import CryptoKit
import CSQLite
import Testing
import Models
@testable import Storage
import FileServiceEngine
import MediaLibraryEngine

@Suite("BMH-05 scan I/O invariants", .serialized, .timeLimit(.minutes(2)))
struct MediaScanIOTests {
    @Test func configurationDigestCompatibilityAndExternalEdits() throws {
        let f = try ScanIOEnvironment(); defer { f.clean() }
        let original = try MediaLibraryScanner.configurationRevision(f.library, store: f.store)
        // Byte-for-byte compatibility with persisted pre-BMH-05 checkpoints.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var material = try encoder.encode(f.library); material.append(try encoder.encode(f.service))
        material.append(Data(try f.store.scanAuthorizationRevision(for: f.service.id).utf8))
        #expect(original == SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined())
        #expect(try MediaLibraryScanner.configurationRevision(f.library, store: f.store) == original)
        let url = f.state.appendingPathComponent("file-services.json")
        let bytes = try Data(contentsOf: url)
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let changed = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "fixture.invalid", with: "changed.invalid").utf8)
        try #require(changed.count == bytes.count && changed != bytes)
        try changed.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let replaced = try MediaLibraryScanner.configurationRevision(f.library, store: f.store)
        #expect(replaced != original)
        // In-place edit and restored mtime still change ctime; don't trust size/mtime alone.
        let file = try FileHandle(forWritingTo: url)
        try file.write(contentsOf: bytes); try file.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        #expect(try MediaLibraryScanner.configurationRevision(f.library, store: f.store) == original)
        let other = FileServiceStore(storage: StorageManager(storageDirectory: f.state), preferences: f.preferences)
        try other.saveBookmark(Data("new-scope".utf8), for: f.service.id)
        let authorized = try MediaLibraryScanner.configurationRevision(f.library, store: f.store)
        #expect(authorized != original)
        let authURL = f.state.appendingPathComponent("file-scan-revisions.json")
        let authorization = try Data(contentsOf: authURL)
        try Data("invalid-json".utf8).write(to: authURL, options: .atomic)
        #expect(throws: (any Error).self) { try MediaLibraryScanner.configurationRevision(f.library, store: f.store) }
        try authorization.write(to: authURL, options: .atomic)
        #expect(try MediaLibraryScanner.configurationRevision(f.library, store: f.store) == authorized)
        try FileManager.default.removeItem(at: url)
        #expect(throws: MediaScanRecoveryError.self) { try MediaLibraryScanner.configurationRevision(f.library, store: f.store) }
        try bytes.write(to: url, options: .atomic)
        #expect(try MediaLibraryScanner.configurationRevision(f.library, store: f.store) == authorized)
    }

    @Test func sharedSidecarsRetryFailuresAndRespectFileAndManualPriority() async throws {
        let f = try ScanIOEnvironment(); defer { f.clean() }
        let client = ScanIOFiles()
        let scanner = MediaLibraryScanner(index: f.index, store: f.store)
        await scanner.scan(f.library, client: client)
        #expect(await client.reads("/First/a.nfo") == 1)
        #expect(await client.reads("/First/movie.nfo") == 2) // b fails once; c retries successfully.
        #expect(await client.reads("/Second/movie.nfo") == 1) // b/c share one successful parse.
        let first = try f.reference("/First/a.mkv"), second = try f.reference("/Second/b.mkv")
        #expect(try await f.index.record(reference: first)?.metadata.title == "File-specific")
        #expect(try await f.index.record(reference: second)?.metadata.title == "Second 1")
        try await f.index.applyCorrection(.init(reference: second, fields: .init(title: "Pinned")))
        await client.change()
        await scanner.scan(f.library, client: client)
        #expect(try await f.index.record(reference: first)?.metadata.title == "File-specific")
        #expect(try await f.index.record(reference: second)?.metadata.title == "Pinned")
        #expect(try await f.index.record(reference: second)?.localMetadata.title == "Second 2")
        let reopened = MediaIndex(url: f.indexURL)
        #expect(try await reopened.record(reference: second)?.metadata.title == "Pinned")
        let after = await client.reads("/Second/movie.nfo")
        await scanner.scan(f.library, client: client)
        #expect(await client.reads("/Second/movie.nfo") == after) // unchanged incremental scan.
    }

    @Test(arguments: ["cancel", "configuration", "authorization"])
    func suspendedSidecarCannotWriteAfterInvalidation(change: String) async throws {
        let f = try ScanIOEnvironment(); defer { f.clean() }
        let client = ScanIOFiles(hold: true)
        let scanner = MediaLibraryScanner(index: f.index, store: f.store)
        let task = Task { await scanner.scan(f.library, client: client) }
        let entered = await client.waitForRead()
        if !entered { await client.release(); await scanner.cancelAllAndWait() }
        try #require(entered)
        switch change {
        case "cancel": await scanner.cancel(libraryID: f.library.id)
        case "configuration":
            var catalog = f.store.load(); catalog.services[0].address = "https://other.invalid"
            try f.store.save(catalog)
        default: try f.store.saveBookmark(Data("replaced-scope".utf8), for: f.service.id)
        }
        await client.release(); await task.value
        #expect(try await f.index.records(libraryID: f.library.id).isEmpty)
        let status = try #require(await scanner.currentProgress(libraryID: f.library.id))
        if change == "cancel" { #expect(status.isCancelled) }
        else { #expect(status.recoveryError == .configurationChanged) }
    }

    @Test func atomicBrowseUpdatesRecoverAfterRollbackSchemaChangeAndReopen() async throws {
        let f = try ScanIOEnvironment(); defer { f.clean() }
        let run = UUID()
        _ = try await f.index.beginScanCheckpoint(library: f.library, revision: "fixture", request: .rescan, runID: run)
        func record(_ name: String) throws -> MediaRecord {
            let ref = try f.reference("/" + name + ".mkv")
            return .init(reference: ref, entry: .init(path: ref.path, name: name + ".mkv", isDirectory: false), groupKey: name,
                         filenameMetadata: .init(title: name, year: name == "Before" ? 2000 : 2020))
        }
        try await f.index.upsertScanned(record("Before"), runID: run)
        let before = try record("Before")
        _ = try await f.index.record(reference: before.reference)
        try f.executeSQL("CREATE TRIGGER reject_fixture BEFORE INSERT ON media WHEN NEW.path='/Reject.mkv' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        await #expect(throws: MediaIndexError.self) { try await f.index.upsertScanned(record("Reject"), runID: run) }
        try f.executeSQL("DROP TRIGGER reject_fixture")
        try await f.index.upsertScanned(record("After"), runID: run)
        let records = try await f.index.records(libraryID: f.library.id)
        #expect(Set(records.map { $0.metadata.title }) == ["Before", "After"])
        #expect(try await f.index.record(reference: before.reference)?.metadata.year == 2000)
        let reopened = MediaIndex(url: f.indexURL)
        #expect(try await reopened.records(libraryID: f.library.id).count == 2)
        var updated = try #require(try await f.index.record(reference: before.reference))
        updated.localMetadata = try NFOMetadataParser.parse(Data("<movie><title>Updated</title><actor><name>New Actor</name></actor></movie>".utf8))
        try await f.index.upsertScanned(updated, runID: run)
        #expect(try await f.index.facets(libraryID: f.library.id).actors.map(\.name) == ["New Actor"])
        updated.localMetadata.title = "Another title" // same facets must survive a scalar-only update.
        try await f.index.upsertScanned(updated, runID: run)
        #expect(try await f.index.facets(libraryID: f.library.id).actors.map(\.name) == ["New Actor"])
        updated.localMetadata.cast = []
        try await f.index.upsertScanned(updated, runID: run)
        #expect(try await f.index.facets(libraryID: f.library.id).actors.isEmpty)
    }
}

private struct ScanIOEnvironment {
    let root: URL, state: URL, indexURL: URL, index: MediaIndex, store: FileServiceStore, preferences: UserPreferences
    let service: FileServiceConfiguration, library: MediaLibraryConfiguration
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bmh05-" + UUID().uuidString)
        state = root.appendingPathComponent("state"); indexURL = root.appendingPathComponent("media.sqlite")
        index = MediaIndex(url: indexURL)
        preferences = UserPreferences(defaults: UserDefaults(suiteName: "bmh05." + UUID().uuidString)!, credentialStore: MemoryCredentialStore())
        store = FileServiceStore(storage: StorageManager(storageDirectory: state), preferences: preferences)
        service = .init(name: "Fixture", kind: .webDAV, address: "https://fixture.invalid/a")
        library = .init(serviceID: service.id, name: "Fixture", metadataSource: .local)
        try store.save(.init(services: [service], libraries: [library]))
    }
    func reference(_ path: String) throws -> FileResourceReference { try .init(serviceID: service.id, libraryID: library.id, path: path) }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func executeSQL(_ sql: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(indexURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}

private actor ScanIOFiles: FileServiceClient {
    private var version = 1, counts: [String: Int] = [:]
    private var hold: Bool, entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(hold: Bool = false) { self.hold = hold }
    func connect() async throws {}
    func change() { version += 1 }
    func reads(_ path: String) -> Int { counts[path, default: 0] }
    func list(path: String, cursor: String?) async throws -> FileEntryPage {
        if path == "/" {
            return .init(entries: ["First", "Second"].map { .init(path: "/" + $0, name: $0, isDirectory: true) })
        }
        return .init(entries: ["a.mkv", "b.mkv", "c.mkv", "a.nfo", "movie.nfo"].map { name in
            .init(path: path + "/" + name, name: name, isDirectory: false, size: 200, version: "\(version)")
        })
    }
    func read(path: String, range: Range<Int64>) async throws -> Data {
        counts[path, default: 0] += 1
        if hold {
            entered = true
            await withCheckedContinuation { continuation = $0 } // deliberately completes after cancellation.
        }
        if path == "/First/movie.nfo", counts[path] == 1 { throw FileServiceError.protocolFailure("fixture read failed") }
        let title = path.hasSuffix("a.nfo") ? "File-specific" : (path.contains("First") ? "First" : "Second") + " \(version)"
        return Data("<movie><title>\(title)</title><year>2020</year></movie>".utf8)
    }
    func waitForRead() async -> Bool {
        for _ in 0..<2000 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
    func release() { hold = false; continuation?.resume(); continuation = nil }
    func stat(path: String) async throws -> FileEntry { throw FileServiceError.protocolFailure("Unused fixture operation") }
    func resolve(path: String) async throws -> ResolvedFileResource { throw FileServiceError.protocolFailure("Unused fixture operation") }
}
