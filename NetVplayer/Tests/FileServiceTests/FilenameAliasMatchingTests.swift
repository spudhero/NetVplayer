import Foundation
import Testing
import Models
import Storage
import MediaLibraryEngine

@Suite("NAS filename and official alias matching", .serialized)
struct FilenameAliasMatchingTests {
    @Test func bilingualFilenamesPreserveBothTitlesAndReleaseGroupPrefixes() {
        let movie = MediaFilenameParser.parse(path: "/[哈利·波特与死亡圣器(下)]Harry.Potter.and.the.Deathly.Hallows.Part.2.2011.2160p.BluRay.mkv", libraryKind: .mixed)
        #expect(movie.title == "哈利·波特与死亡圣器(下)")
        #expect(movie.originalTitle == "Harry Potter and the Deathly Hallows Part 2")
        #expect(movie.year == 2011); #expect(movie.kind == .movies)
        let group = MediaFilenameParser.parse(path: "/[BOBO]Movie.Name.2024.1080p.mkv", libraryKind: .movies)
        #expect(group.title?.contains("Movie Name") == true); #expect(group.originalTitle == nil)
        #expect(MediaFilenameParser.normalizedTitle("Fast & Furious 6") == MediaFilenameParser.normalizedTitle("Fast and Furious 6"))
        #expect(MediaFilenameParser.normalizedTitle("Fast Furious 6") != MediaFilenameParser.normalizedTitle("Fast and Furious 6"))
    }

    @Test(arguments: [MediaLibraryKind.movies, .television])
    func officialAliasesMatchExactlyAndRemakesStayPending(_ kind: MediaLibraryKind) async throws {
        let provider = TMDBMetadataProvider(credential: .init(kind: .readAccessToken, value: "fixture-token"), request: { url, _ in
            let fields: [String: Any] = kind == .movies
                ? ["id": 36658, "title": "X战警2", "original_title": "X2", "release_date": "2003-01-01"]
                : ["id": 12, "name": "中文剧名", "original_name": "Original Show", "first_air_date": "2003-01-01"]
            let object: [String: Any]
            if url.path.hasSuffix("alternative_titles") {
                object = [kind == .movies ? "titles" : "results": [["title": "X-Men 2"]]]
            } else { object = ["results": [fields]] }
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let candidates = try await provider.search(title: "X-men 2", year: 2003, kind: kind)
        #expect(candidates.first?.metadata.alternativeTitles == ["X-Men 2"])
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "X-men 2", year: 2003, kind: kind) != nil)
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "X-men 3", year: 2003, kind: kind) == nil)
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "X-men 2", year: 2000, kind: kind) == nil)
        var remake = candidates[0]; remake.metadata.year = 2024; remake.metadata.tmdbID = "13"
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates + [remake], title: "X-men 2", year: nil, kind: kind) == nil)
    }

    @Test func partialAliasLookupCannotEstablishUniqueMatch() async throws {
        let provider = TMDBMetadataProvider(credential: .init(kind: .readAccessToken, value: "fixture-token"), request: { url, _ in
            if url.path.contains("/2/") { throw URLError(.timedOut) }
            let object: [String: Any] = url.path.hasSuffix("alternative_titles")
                ? ["titles": [["title": "Alias"]]]
                : ["results": [["id": 1, "title": "First", "release_date": "2003-01-01"], ["id": 2, "title": "Second", "release_date": "2003-01-01"]]]
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let candidates = try await provider.search(title: "Alias", year: 2003, kind: .movies)
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.metadata.alternativeTitles == nil })
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "Alias", year: 2003, kind: .movies) == nil)
    }

    @Test func rematchReparsesCachedBilingualNamesAndPreservesManualTitle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "旧索引", metadataSource: .tmdb)
        let path = "/[哈利·波特与死亡圣器(下)]Harry.Potter.and.the.Deathly.Hallows.Part.2.2011.2160p.mkv"
        let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: path)
        try await index.upsert(.init(reference: ref, entry: .init(path: path, name: (path as NSString).lastPathComponent, isDirectory: false),
            groupKey: "unchanged-identity", filenameMetadata: .init(title: "哈利·波特与死亡圣器(下)]Harry Potter and the Deathly Hallows Part 2", year: 2011, kind: .movies)), scanID: UUID())
        let provider = TMDBMetadataProvider(credential: .init(kind: .readAccessToken, value: "fixture-token"), request: { url, _ in
            let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
            let fields: [String: Any] = ["id": 12445, "title": "哈利·波特与死亡圣器2", "original_title": "Harry Potter and the Deathly Hallows: Part 2", "release_date": "2011-01-01", "poster_path": "/hp.jpg"]
            let object: [String: Any] = url.path.contains("search") ? ["results": title == "Harry Potter and the Deathly Hallows Part 2" ? [fields] : []] : fields
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let matcher = MetadataMatcher(index: index, providers: [provider])
        try await matcher.rematch(library); await matcher.waitForMatching(libraryID: library.id)
        let matched = try #require(try await index.record(reference: ref))
        #expect(matched.onlineMetadata.tmdbID == "12445")
        #expect(matched.onlineMetadata.poster == "https://image.tmdb.org/t/p/w500/hp.jpg")
        #expect(matched.filenameMetadata.originalTitle == "Harry Potter and the Deathly Hallows Part 2")
        #expect(matched.reference == ref); #expect(matched.id == ref.locator)
        try await index.applyCorrection(.init(reference: ref, fields: .init(title: "手动标题")))
        try await matcher.rematch(library); await matcher.waitForMatching(libraryID: library.id)
        #expect(try await index.record(reference: ref)?.metadata.title == "手动标题")
        #expect(try await index.record(reference: ref)?.onlineMetadata.poster == matched.onlineMetadata.poster)
    }
}
