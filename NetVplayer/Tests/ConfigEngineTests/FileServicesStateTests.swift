import Foundation
import Testing
import Models
import Storage
import FileServiceEngine
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
