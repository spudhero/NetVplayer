import Foundation
import Testing
import Models
import Storage
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
}
