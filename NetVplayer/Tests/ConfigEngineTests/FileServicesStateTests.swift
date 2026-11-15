import Foundation
import Testing
import Models
import Storage
import FileServiceEngine
import MediaLibraryEngine
import CSQLite
@testable import NetVplayerApp

@Suite("File services view state", .serialized)
@MainActor
struct FileServicesStateTests {
    @Test func selectingLibraryLoadsIndexWithoutStartingHiddenDirectoryRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let service = FileServiceConfiguration(name: "NAS", kind: .smb, address: "smb://nas.local", share: "Shared")
        let library = MediaLibraryConfiguration(serviceID: service.id, name: "Movies")
        let reference = try FileResourceReference(serviceID: service.id, libraryID: library.id, path: "/Movie.mkv")
        try await index.upsert(.init(reference: reference, entry: .init(path: reference.path, name: "Movie.mkv", isDirectory: false),
            groupKey: "movie", filenameMetadata: .init(title: "Movie", kind: .movies)), scanID: UUID())
        let state = FileServicesState(catalog: .init(services: [service], libraries: [library]), index: index)
        state.error = "Previous service error"; state.directoryError = "Previous directory error"
        state.selectService(service.id)
        #expect(state.mode == .library)
        #expect(state.busy == false)
        #expect(state.directoryError == nil); #expect(state.error == nil)
        for _ in 0..<200 where state.mediaLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(state.mediaRecords.count == 1)
        #expect(state.mediaLoading == false)
        #expect(state.directoryError == nil); #expect(state.error == nil)
    }

    @Test(arguments: [true, false])
    func reopenedIndexRemainsBrowsableUntilExplicitRefresh(hasSuccessfulScan: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data().write(to: media.appendingPathComponent("Original (2024).mkv"))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        let store = FileServiceStore(storage: StorageManager(storageDirectory: directory.appendingPathComponent("state")), preferences: preferences)
        let service = FileServiceConfiguration(name: "Offline-capable library", kind: .local)
        let library = MediaLibraryConfiguration(serviceID: service.id, name: "Movies", metadataSource: .local)
        try store.save(.init(services: [service], libraries: [library]))
        try store.saveBookmark(media.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), for: service.id)
        let runtime = FileServiceRuntime(store: store)
        let client = try await runtime.client(for: service.id)
        let url = directory.appendingPathComponent("index.sqlite")
        let initialIndex = MediaIndex(url: url)
        await MediaLibraryScanner(index: initialIndex).scan(library, client: client)
        let original = try #require(try await initialIndex.records(libraryID: library.id).first)
        try await initialIndex.applyCorrection(.init(reference: original.reference, fields: .init(title: "Saved title")))

        // A cold index may have an old successful scan, or only a partial/failed scan.
        // Neither state makes browsing permission to enumerate the source again.
        let oldDate = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        var database: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let dateValue = hasSuccessfulScan ? String(oldDate.timeIntervalSince1970) : "NULL"
        try #require(sqlite3_exec(database, "UPDATE scan_state SET last_success=\(dateValue)", nil, nil, nil) == SQLITE_OK)
        try Data().write(to: media.appendingPathComponent("Added while closed (2025).mkv"))

        let reopened = MediaIndex(url: url)
        let scanner = MediaLibraryScanner(index: reopened)
        let refreshed = LibraryScanRecorder()
        let state = FileServicesState(index: reopened, store: store, runtime: runtime,
            startLibraryScan: {
                await scanner.scan($0, client: client)
                await refreshed.append($0.id)
            })
        state.selectService(service.id); await state.waitForMediaLoad()
        #expect(state.mode == .library && !state.busy)
        #expect(state.mediaRecords.count == 1 && state.mediaRecords.first?.metadata.title == "Saved title")
        #expect(state.mediaError == nil && state.directoryError == nil)
        #expect(await refreshed.ids.isEmpty)
        #expect(await scanner.currentProgress(libraryID: library.id) == nil)
        let previousScan = try await reopened.lastSuccessfulScan(libraryID: library.id)
        if hasSuccessfulScan {
            #expect(try #require(previousScan).timeIntervalSince(oldDate).magnitude < 0.001)
        } else { #expect(previousScan == nil) }

        state.refreshCurrentView()
        for _ in 0..<400 {
            if await refreshed.ids == [library.id] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await refreshed.ids == [library.id])
        state.loadMedia(); await state.waitForMediaLoad()
        #expect(state.mediaRecords.count == 2)
        #expect(state.mediaRecords.contains { $0.metadata.title == "Saved title" })
        #expect(try await reopened.lastSuccessfulScan(libraryID: library.id)! > oldDate)
        await runtime.invalidate(serviceID: service.id)
    }
    @Test(arguments: ["interrupted", "expired", "cancelled", "changed"])
    func checkpointStartupAndOrdinarySwitchingNeverStartAScan(phase: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msc05-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileServiceStore(storage: StorageManager(storageDirectory: directory.appendingPathComponent("state")),
            preferences: UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore()))
        let service = FileServiceConfiguration(name: "Offline fixture", kind: .webDAV, address: "https://unreachable.invalid")
        let library = MediaLibraryConfiguration(serviceID: service.id, name: "Unfinished", metadataSource: .local)
        let otherService = FileServiceConfiguration(name: "Other offline fixture", kind: .smb, address: "smb://unreachable.invalid", share: "Share")
        let otherLibrary = MediaLibraryConfiguration(serviceID: otherService.id, name: "Other")
        var catalog = FileServiceCatalog(services: [service, otherService], libraries: [library, otherLibrary])
        try store.save(catalog)
        let url = directory.appendingPathComponent("index.sqlite"), index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let ref = try FileResourceReference(serviceID: service.id, libraryID: library.id, path: "/Saved.mkv")
        var record = MediaRecord(reference: ref, entry: .init(path: ref.path, name: "Saved.mkv", isDirectory: false), groupKey: "saved", filenameMetadata: .init(title: "Saved"))
        record.correction = .init(reference: ref, fields: .init(title: "Manual title"))
        try await index.upsert(record, scanID: UUID())
        let revision = try MediaLibraryScanner.configurationRevision(library, store: store)
        let date = phase == "expired" ? Date().addingTimeInterval(-MediaScanCheckpoint.retention - 10) : Date()
        _ = try await index.beginScanCheckpoint(library: library, revision: revision, request: .rescan, runID: UUID(), now: date)
        if phase == "cancelled" { try await index.interruptScanCheckpoint(libraryID: library.id, phase: .cancelled) }
        if phase == "changed" { catalog.services[0].rootPath = "/new"; try store.save(catalog) }
        let saved = try await index.scanCheckpoint(libraryID: library.id)
        let requests = LibraryScanRecorder()
        let reopened = MediaIndex(url: url), scanner = MediaLibraryScanner(index: reopened, store: store)
        let state = FileServicesState(index: reopened, store: store,
            startLibraryScan: { await requests.append($0.id) }, scanner: scanner)
        state.selectService(service.id); await state.waitForMediaLoad()
        #expect(state.mediaRecords.first?.metadata.title == "Manual title")
        #expect(state.selectedScanCheckpoint?.id == saved?.id)
        let checkpoint = try #require(state.selectedScanCheckpoint)
        #expect(state.canContinueScan(checkpoint) == (phase == "interrupted"))
        state.selectService(otherService.id); await state.waitForMediaLoad()
        state.selectService(service.id); await state.waitForMediaLoad()
        state.loadMedia(); await state.waitForMediaLoad()
        #expect(await requests.ids.isEmpty)
        #expect(await scanner.currentProgress(libraryID: library.id) == nil)
        #expect(await scanner.currentProgress(libraryID: otherLibrary.id) == nil)
        #expect(try await reopened.scanCheckpoint(libraryID: library.id) == saved)
        #expect(try await reopened.lastSuccessfulScan(libraryID: library.id) == nil)
        #expect(!state.busy && !state.isRefreshing)
    }

    @Test func automaticPagingCoalescesRequestsAndStopsAtExactEnd() async throws {
        let fixture = try await makeIndexFixture(count: 200)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = fixture.state
        state.selectService(fixture.service.id)
        await state.waitForMediaLoad()
        #expect(state.mediaRecords.count == 100)
        #expect(state.mediaHasMore)
        for _ in 0..<12 { state.loadNextMediaPage() }
        await state.waitForMediaLoad()
        #expect(state.mediaRecords.count == 200)
        #expect(Set(state.mediaRecords.map(\.id)).count == 200)
        #expect(!state.mediaHasMore)
        state.loadNextMediaPage()
        #expect(!state.mediaLoading)
        #expect(state.mediaRecords.count == 200)
    }

    @Test func switchingServiceDuringAppendCannotPublishOldLibrary() async throws {
        let fixture = try await makeIndexFixture(count: 250)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = fixture.state
        state.selectService(fixture.service.id)
        await state.waitForMediaLoad()
        state.loadNextMediaPage()
        let other = FileServiceConfiguration(name: "Other", kind: .smb, address: "smb://other.local", share: "Shared")
        let otherLibrary = MediaLibraryConfiguration(serviceID: other.id, name: "Empty")
        state.catalog.services.append(other); state.catalog.libraries.append(otherLibrary)
        state.selectService(other.id)
        #expect(state.mediaRecords.isEmpty)
        await state.waitForMediaLoad()
        #expect(state.selectedLibraryID == otherLibrary.id)
        #expect(state.mediaRecords.isEmpty)
        #expect(!state.mediaHasMore)
        #expect(!state.mediaLoading)
    }

    @Test func indexRefreshKeepsLoadedPagesAndShortFinalPage() async throws {
        let fixture = try await makeIndexFixture(count: 215)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = fixture.state
        state.selectService(fixture.service.id)
        await state.waitForMediaLoad()
        state.loadNextMediaPage(); await state.waitForMediaLoad()
        state.loadMedia(); await state.waitForMediaLoad()
        #expect(state.mediaRecords.count == 200)
        state.loadNextMediaPage(); await state.waitForMediaLoad()
        #expect(state.mediaRecords.count == 215)
        #expect(!state.mediaHasMore)
        state.selectedLibraryID = nil; state.loadMedia()
        #expect(state.mediaRecords.isEmpty)
        #expect(!state.mediaLoading)
    }

    @Test func failedIndexLoadDoesNotAutomaticallyRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FileServiceConfiguration(name: "NAS")
        let library = MediaLibraryConfiguration(serviceID: service.id, name: "Movies")
        let state = FileServicesState(catalog: .init(services: [service], libraries: [library]), index: MediaIndex(url: directory))
        state.selectService(service.id); await state.waitForMediaLoad()
        #expect(state.mediaError != nil)
        #expect(!state.mediaLoading)
        state.loadNextMediaPage()
        #expect(!state.mediaLoading)
        state.retryMediaPage(); await state.waitForMediaLoad()
        #expect(state.mediaError != nil)
    }

    @Test func filterChangesResetPagingAndIgnoreStaleAppendResults() async throws {
        let fixture = try await makeIndexFixture(count: 215)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = fixture.state
        state.selectService(fixture.service.id); await state.waitForMediaLoad()
        state.loadNextMediaPage()
        state.setMediaFilter(.init(collection: "name:missing"))
        await state.waitForMediaLoad()
        #expect(state.mediaRecords.isEmpty && !state.mediaHasMore)
        #expect(state.mediaFilter.collection == "name:missing")
        state.setMediaFilter(.init()); await state.waitForMediaLoad()
        #expect(state.mediaRecords.count == 100 && state.mediaHasMore)
        state.selectedLibraryID = nil; state.loadMedia()
        #expect(state.mediaRecords.isEmpty)
    }

    @Test func actorDetailAliasUsesTheCanonicalSelectionAndResults() async throws {
        let fixture = try await makeIndexFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = fixture.state
        let library = try #require(state.catalog.libraries.first)
        let index = MediaIndex(url: fixture.directory.appendingPathComponent("index.sqlite"))
        let files = try await index.records(libraryID: library.id)
        for (number, file) in files.enumerated() {
            var updated = file
            updated.filenameMetadata.cast = [number == 0 ? .init(name: "成龙", tmdbID: "6384") : .init(name: "成龙 Jackie Chan")]
            updated.filenameMetadata.directors = [number == 0 ? "陈木胜" : "宫崎骏"]
            try await index.upsert(updated, scanID: UUID())
        }
        state.selectService(fixture.service.id); await state.waitForMediaLoad()
        state.setMediaFilter(.init(actor: "name:成龙")); await state.waitForMediaLoad()
        #expect(state.mediaFilter.actor == "tmdb:6384")
        #expect(state.mediaRecords.count == 2)
        #expect(state.mediaFacets.actors.first?.id == state.mediaFilter.actor)
        let director = MediaLibraryIdentity.directorKey("宫崎骏")
        state.setMediaFilter(.init(actor: "name:成龙", director: director)); await state.waitForMediaLoad()
        #expect(state.mediaFilter.actor == "tmdb:6384" && state.mediaFilter.director == director)
        #expect(state.mediaRecords.count == 1 && state.mediaRecords.first?.metadata.directors == ["宫崎骏"])
        #expect(state.mediaFacets.directors.count == 2)
        let other = MediaLibraryConfiguration(serviceID: fixture.service.id, name: "Other")
        state.catalog.libraries.append(other)
        state.selectedLibraryID = other.id; state.loadMedia(); await state.waitForMediaLoad()
        #expect(state.mediaFilter.isEmpty && state.mediaRecords.isEmpty)
        // A detail opened from history can return to a different library with its actor selected.
        state.selectedLibraryID = library.id
        state.setMediaFilter(.init(director: director)); await state.waitForMediaLoad()
        #expect(state.mediaFilter.director == director && state.mediaRecords.count == 1)
    }

    @Test func failedCorrectionSaveRestoresPersistedCorrections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore())
        let store = FileServiceStore(storage: StorageManager(storageDirectory: directory), preferences: preferences)
        let ref = try FileResourceReference(serviceID: UUID(), libraryID: UUID(), path: "/missing.mkv")
        let previous = MediaManualCorrection(reference: ref, fields: .init(title: "Previous"))
        try store.saveCorrections([previous])
        let state = FileServicesState(index: MediaIndex(url: directory.appendingPathComponent("index.sqlite")), store: store)
        await #expect(throws: (any Error).self) { try await state.saveCorrection(.init(reference: ref, fields: .init(title: "New"))) }
        #expect(store.loadCorrections() == [previous])
    }

    @Test func batchSaveIsAtomicAndRetainsConnectionAndExistingLibraryIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Movies", "TV", "Existing"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore())
        let store = FileServiceStore(storage: StorageManager(storageDirectory: directory.appendingPathComponent("state")), preferences: preferences)
        let service = FileServiceConfiguration(name: "NAS fixture", kind: .local)
        let existing = MediaLibraryConfiguration(serviceID: service.id, name: "Existing", path: "/Existing")
        let original = FileServiceCatalog(services: [service], libraries: [existing])
        try store.save(original)
        try store.saveBookmark(directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), for: service.id)
        let runtime = FileServiceRuntime(store: store)
        let scanned = LibraryScanRecorder()
        let state = FileServicesState(index: MediaIndex(url: directory.appendingPathComponent("index.sqlite")), store: store, runtime: runtime,
            startLibraryScan: { await scanned.append($0.id) })
        let movies = MediaLibraryConfiguration(serviceID: service.id, name: "Movies", path: "/Movies", kind: .movies)
        let missing = MediaLibraryConfiguration(serviceID: service.id, name: "Missing", path: "/Missing")
        await #expect(throws: (any Error).self) { try await state.addLibraries([movies, missing], to: service.id) }
        #expect(store.load() == original)
        #expect(await scanned.ids.isEmpty)
        let television = MediaLibraryConfiguration(serviceID: service.id, name: "TV", path: "/TV", kind: .television)
        try await state.addLibraries([movies, television], to: service.id)
        #expect(store.load().services == [service])
        #expect(store.load().libraries == [existing, movies, television])
        #expect(await scanned.ids == [movies.id, television.id])
        await #expect(throws: FileServiceError.self) { try await state.addLibraries([movies], to: service.id) }
        #expect(store.load().libraries.count == 3)
        await runtime.invalidate(serviceID: service.id)
    }

    private func makeIndexFixture(count: Int) async throws -> (state: FileServicesState, service: FileServiceConfiguration, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let service = FileServiceConfiguration(name: "NAS", kind: .smb, address: "smb://nas.local", share: "Shared")
        let library = MediaLibraryConfiguration(serviceID: service.id, name: "Movies")
        let scan = UUID()
        for number in 0..<count {
            let title = String(format: "Movie %04d", number)
            let reference = try FileResourceReference(serviceID: service.id, libraryID: library.id, path: "/" + title + ".mkv")
            try await index.upsert(.init(reference: reference, entry: .init(path: reference.path, name: title, isDirectory: false),
                groupKey: title, filenameMetadata: .init(title: title, kind: .movies)), scanID: scan)
        }
        let state = FileServicesState(catalog: .init(services: [service], libraries: [library]), index: index)
        return (state, service, directory)
    }

}

private actor LibraryScanRecorder {
    var ids: [UUID] = []
    func append(_ id: UUID) { ids.append(id) }
}
