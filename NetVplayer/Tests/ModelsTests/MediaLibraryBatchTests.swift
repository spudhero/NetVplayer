import Foundation
import Testing
@testable import Models

@Suite("Multiple library folders")
struct MediaLibraryBatchTests {
    @Test func pathsAreNormalizedAndSeparateFoldersKeepTheirIdentities() throws {
        let service = UUID()
        let movies = MediaLibraryConfiguration(serviceID: service, name: " 电影 ", path: "电影//./", kind: .movies)
        let tv = MediaLibraryConfiguration(serviceID: service, name: "剧集", path: "/剧集", kind: .television)
        let result = try MediaLibraryBatch.validated([movies, tv], serviceID: service, existing: [])
        #expect(result.map(\.id) == [movies.id, tv.id])
        #expect(result.map(\.path) == ["/电影", "/剧集"])
        #expect(result.map(\.name) == ["电影", "剧集"])
        #expect(result.map(\.kind) == [.movies, .television])
    }

    @Test func duplicateAndParentChildFoldersCannotCreateDuplicateScans() {
        let service = UUID()
        let existing = MediaLibraryConfiguration(serviceID: service, name: "Movies", path: "/Movies")
        for path in ["/Movies", "/Movies/Action", "/"] {
            let draft = MediaLibraryConfiguration(serviceID: service, name: "New", path: path)
            #expect(throws: FileServiceError.self) { try MediaLibraryBatch.validated([draft], serviceID: service, existing: [existing]) }
            #expect(throws: FileServiceError.self) { try MediaLibraryBatch.validated([existing, draft], serviceID: service, existing: []) }
        }
        #expect(!MediaLibraryBatch.overlaps("/Movies", "/Movies2"))
        #expect(MediaLibraryBatch.overlaps("/Movies//", "/Movies/Action"))
    }

    @Test func invalidOrForeignDraftsDoNotPassValidation() {
        let service = UUID()
        for draft in [
            MediaLibraryConfiguration(serviceID: service, name: "", path: "/Movies"),
            MediaLibraryConfiguration(serviceID: service, name: "Escape", path: "/../Movies"),
            MediaLibraryConfiguration(serviceID: UUID(), name: "Foreign", path: "/Movies")
        ] {
            #expect(throws: FileServiceError.self) { try MediaLibraryBatch.validated([draft], serviceID: service, existing: []) }
        }
        #expect(throws: FileServiceError.self) { try MediaLibraryBatch.validated([], serviceID: service, existing: []) }
    }
}
