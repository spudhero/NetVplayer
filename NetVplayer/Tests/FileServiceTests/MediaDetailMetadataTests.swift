import Foundation
import Testing
import Models
import Storage
import MediaLibraryEngine

@Suite("NAS detail metadata", .serialized)
struct MediaDetailMetadataTests {
    @Test func tmdbDetailsIncludeCreditsAndOptionalMovieAndTVFields() async throws {
        let provider = TMDBMetadataProvider(credential: .init(kind: .readAccessToken, value: "fixture")) { url, _ in
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "append_to_response", value: "credits")) == true)
            let body = #"{"id":21521,"title":"A计划续集","name":"剧集","runtime":106,"episode_run_time":[45],"release_date":"1987-08-19","genres":[{"name":"动作"}],"production_countries":[{"name":"Hong Kong"}],"spoken_languages":[{"name":"广州话"}],"production_companies":[{"name":"Golden Harvest"}],"tagline":"继续冒险","backdrop_path":"/back.jpg","credits":{"cast":[{"name":"成龙","character":"马如龙","profile_path":"/actor.jpg"},{"character":"无姓名"}],"crew":[{"name":"成龙","job":"Director"},{"name":"成龙","job":"Screenplay"},{"name":"成龙","job":"Story"}]}}"#
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let movie = try await provider.details(id: "21521", kind: .movies)
        #expect(movie.runtimeMinutes == 106 && movie.genres == ["动作"])
        #expect(movie.releaseDate == "1987-08-19" && movie.languages == ["广州话"])
        #expect(movie.directors == ["成龙"] && movie.writers == ["成龙"])
        #expect(movie.cast == [.init(name: "成龙", role: "马如龙", portrait: "https://image.tmdb.org/t/p/w185/actor.jpg")])
        #expect(movie.fanart == "https://image.tmdb.org/t/p/w1280/back.jpg" && movie.detailVersion == 2)
        let tv = TMDBMetadataProvider(credential: .init(kind: .apiKey, value: "fixture")) { url, _ in
            (Data(#"{"id":1,"name":"剧集","episode_run_time":[45],"first_air_date":"2020-01-01","credits":{"cast":[]}}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let show = try await tv.details(id: "1", kind: .television)
        #expect(show.runtimeMinutes == 45 && show.showTitle == "剧集" && show.directors == nil)
        #expect(show.detailVersion == 2 && show.cast == [])
    }

    @Test func localAndDoubanDetailsPreserveArtScopeAndPrecedence() throws {
        let xml = """
        <movie><title>本地片名</title><originaltitle>Original</originaltitle><runtime>106</runtime><genre>动作</genre><genre>喜剧</genre>
        <director>导演</director><credits>编剧</credits><country>中国香港</country><studio>公司</studio><premiered>1987-08-19</premiered>
        <actor><name>演员</name><role>角色</role><thumb>https://example.test/actor.jpg</thumb></actor><thumb>https://example.test/poster.jpg</thumb></movie>
        """
        let local = try NFOMetadataParser.parse(Data(xml.utf8))
        #expect(local.poster == "https://example.test/poster.jpg")
        #expect(local.cast?.first?.portrait == "https://example.test/actor.jpg")
        #expect(local.genres == ["动作", "喜剧"] && local.directors == ["导演"])
        let html = #"<script type="application/ld+json">{"@type":"Movie","name":"在线片名","genre":["喜剧"],"duration":"PT1H46M","actor":[{"name":"在线演员","image":"https://example.test/a.jpg"}],"director":[{"name":"在线导演"}],"datePublished":"1987-08-19"}</script>"#
        let online = try DoubanMetadataProvider.parseSubject(Data(html.utf8), id: "1", fallbackKind: .movies)
        #expect(online.runtimeMinutes == 106 && online.cast?.first?.name == "在线演员")
        let invalidDuration = html.replacingOccurrences(of: "PT1H46M", with: "PT9223372036854775807H46M")
        #expect(try DoubanMetadataProvider.parseSubject(Data(invalidDuration.utf8), id: "1", fallbackKind: .movies).runtimeMinutes == nil)
        let merged = local.fillingMissing(from: online)
        #expect(merged.directors == ["导演"] && merged.cast?.first?.name == "演员")
        #expect(try JSONDecoder().decode(MediaMetadata.self, from: JSONEncoder().encode(merged)) == merged)
        let legacy = try JSONDecoder().decode(MediaMetadata.self, from: Data(#"{"title":"旧缓存"}"#.utf8))
        #expect(legacy.cast == nil && legacy.detailVersion == nil && legacy.runtimeMinutes == nil)
    }

    @Test func enrichesKnownIdentityOnceAndKeepsLocalOnlyAndUnmatchedOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let provider = DetailFixtureProvider()
        let matcher = MetadataMatcher(index: index, providers: [provider])
        let record = try fixtureRecord()
        try await index.upsert(record, scanID: UUID())
        let enriched = try await matcher.enrichDetails(reference: record.reference, source: .tmdb)
        #expect(enriched?.metadata.title == "本地优先")
        #expect(enriched?.metadata.runtimeMinutes == 106 && enriched?.metadata.cast?.count == 1)
        _ = try await matcher.enrichDetails(reference: record.reference, source: .tmdb)
        #expect(await provider.calls == 1)
        var oldDetails = record; oldDetails.onlineMetadata.detailVersion = 1
        try await index.upsert(oldDetails)
        #expect(try await matcher.enrichDetails(reference: record.reference, source: .tmdb)?.onlineMetadata.detailVersion == 2)
        #expect(await provider.calls == 1) // Same known identity reuses the upgraded response.
        var legacyCorrection = record; legacyCorrection.metadataSource = nil
        legacyCorrection.correction = .init(reference: record.reference, fields: .init(tmdbID: "12"))
        try await index.upsert(legacyCorrection)
        #expect(try await matcher.enrichDetails(reference: record.reference, source: .tmdb)?.onlineMetadata.detailVersion == 2)
        #expect(await provider.calls == 1)
        var local = record; local.metadataSource = .local
        try await index.upsert(local)
        _ = try await matcher.enrichDetails(reference: record.reference, source: .local)
        #expect(await provider.calls == 1)
        var unknown = record; unknown.onlineMetadata = .init()
        try await index.upsert(unknown)
        _ = try await matcher.enrichDetails(reference: record.reference, source: .tmdb)
        #expect(await provider.calls == 1)
    }

    @Test func slowResponseCannotOverwriteCorrectionSourceChangeOrRemovedLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let record = try fixtureRecord()
        try await index.upsert(record, scanID: UUID())
        let snapshot = try #require(try await index.record(reference: record.reference))
        let details = MediaMetadata(title: "新资料", tmdbID: "12", runtimeMinutes: 106, detailVersion: 1)
        try await index.applyCorrection(.init(reference: record.reference, fields: .init(title: "用户修正")))
        #expect(try await index.enrichDetails(details, snapshot: snapshot)?.metadata.title == "用户修正")
        #expect(try await index.record(reference: record.reference)?.onlineMetadata.runtimeMinutes == nil)
        var local = record; local.metadataSource = .local
        try await index.upsert(local)
        #expect(try await index.enrichDetails(details, snapshot: snapshot)?.metadataSource == .local)
        try await index.removeLibrary(try #require(record.reference.libraryID))
        #expect(try await index.enrichDetails(details, snapshot: snapshot) == nil)
    }

    private func fixtureRecord() throws -> MediaRecord {
        let ref = try FileResourceReference(serviceID: UUID(), libraryID: UUID(), path: "/Movie.mkv")
        return .init(reference: ref, entry: .init(path: ref.path, name: "Movie.mkv", isDirectory: false), groupKey: "movie",
                     filenameMetadata: .init(title: "Movie", kind: .movies), localMetadata: .init(title: "本地优先"),
                     onlineMetadata: .init(title: "线上旧资料", tmdbID: "12"), metadataSource: .tmdb)
    }
}

private actor DetailFixtureProvider: MetadataProvider {
    nonisolated let source = MetadataSource.tmdb
    var calls = 0
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        Issue.record("Opening details must not rematch titles")
        return []
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        calls += 1
        return .init(title: "影片", tmdbID: id, runtimeMinutes: 106, cast: [.init(name: "演员")], detailVersion: 2)
    }
}
