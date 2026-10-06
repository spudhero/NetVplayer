import Foundation
import Testing
import Models
import Storage
import MediaLibraryEngine

@Suite("Metadata providers", .serialized)
struct MetadataProviderTests {
    @Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_ONLINE_METADATA_ACCEPTANCE"] != "1"), arguments: [false, true])
    func realOnlineMetadataResponse(_ screenshotMovie: Bool) async throws {
        let title = screenshotMovie ? "2 Fast 2 Furious" : "肖申克的救赎"
        let subjectID = screenshotMovie ? "1307442" : "1292052"
        let year = screenshotMovie ? 2003 : 1994
        let provider = DoubanMetadataProvider()
        do {
            let candidates = try await provider.search(title: title, year: year, kind: .movies)
            #expect(candidates.contains { $0.metadata.doubanID == subjectID })
            print("[ONLINE_DOUBAN] \(title): public search returned \(candidates.count) candidates")
            do {
                let metadata = try await provider.details(id: subjectID, kind: .movies)
                #expect(metadata.title?.contains(screenshotMovie ? "速度与激情2" : "肖申克") == true)
                #expect(metadata.doubanRating != nil); #expect(metadata.poster != nil)
                print("[ONLINE_DOUBAN] \(title): public detail, rating and poster parsed without a verification sheet")
            } catch MetadataProviderError.verification {
                print("[ONLINE_DOUBAN] Detail requires human verification; challenge detected, detail acceptance pending")
            }
        } catch MetadataProviderError.verification {
            print("[ONLINE_DOUBAN] Search requires human verification; challenge detected, online acceptance pending")
        }
        if let credential = try MetadataCredentials.resolve() {
            let candidates = try await TMDBMetadataProvider(credential: credential).search(title: title, year: year, kind: .movies)
            #expect(!candidates.isEmpty); print("[ONLINE_TMDB] Authenticated Chinese search verified")
        } else { print("[ONLINE_TMDB] Not run: publisher credential absent") }
    }
    @Test func publisherCredentialPersonalOverrideAndMissingKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        let url = directory.appendingPathComponent("TMDB.json")
        #expect(try MetadataCredentials.resolve(preferences: preferences, bundleURL: nil) == nil)
        try Data(#"{"kind":"apiKey","value":"publisher-fixture-key"}"#.utf8).write(to: url)
        #expect(try MetadataCredentials.resolve(preferences: preferences, bundleURL: url)?.value == "publisher-fixture-key")
        try MetadataCredentials.savePersonal(.init(kind: .readAccessToken, value: "personal-fixture-token"), preferences: preferences)
        #expect(try MetadataCredentials.resolve(preferences: preferences, bundleURL: url)?.kind == .readAccessToken)
        #expect(try MetadataCredentials.resolve(preferences: preferences, bundleURL: url)?.value == "personal-fixture-token")
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains("personal-fixture-token"))
        try MetadataCredentials.savePersonal(nil, preferences: preferences)
        #expect(try MetadataCredentials.resolve(preferences: preferences, bundleURL: url)?.kind == .apiKey)
        #expect(throws: MetadataProviderError.self) { try MetadataCredentials.savePersonal(.init(kind: .apiKey, value: "a\nb"), preferences: preferences) }
        #expect(!String(describing: UserPreferenceSnapshot(preferences: preferences)).contains("publisher-fixture-key"))
    }
    @Test func tmdbAuthenticationChineseSearchAndSeparateRatings() async throws {
        let requests = RecordedMetadataRequests()
        let request: MetadataRequest = { url, headers in
            await requests.record(url, headers)
            let body = #"{"id":12,"title":"示例电影","release_date":"2024-03-01","overview":"简介","poster_path":"/poster.jpg","vote_average":8.4}"#
            let data = url.path.contains("search") ? Data(("{\"results\":[" + body + "]}").utf8) : Data(body.utf8)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let api = TMDBMetadataProvider(credential: .init(kind: .apiKey, value: "fixture-api-key"), request: request)
        let results = try await api.search(title: "示例电影", year: 2024, kind: .movies)
        #expect(results.count == 1); #expect(results.first?.metadata.tmdbRating == 8.4); #expect(results.first?.metadata.doubanRating == nil)
        let token = TMDBMetadataProvider(credential: .init(kind: .readAccessToken, value: "fixture-token"), request: request)
        let details = try await token.details(id: "12", kind: .movies)
        #expect(details.poster == "https://image.tmdb.org/t/p/w500/poster.jpg")
        let records = await requests.values
        let query = URLComponents(url: records[0].0, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(.init(name: "language", value: "zh-CN")))
        #expect(query.contains(.init(name: "year", value: "2024")))
        #expect(query.contains(.init(name: "api_key", value: "fixture-api-key")))
        #expect(records[0].1["Authorization"] == nil)
        #expect(records[1].1["Authorization"] == "Bearer fixture-token")
        #expect(!records[1].0.absoluteString.contains("fixture-token"))
    }
    @Test func doubanPublicSearchDetailsAndVerificationDetection() async throws {
        let html = #"<html><script type="application/ld+json">{"@type":"Movie","name":"示例电影","datePublished":"2024-03-01","description":"豆瓣简介","image":"https://img1.doubanio.com/view/photo/s_ratio_poster/public/p1.webp","aggregateRating":{"ratingValue":"9.2"}}</script></html>"#
        let provider = DoubanMetadataProvider(request: { url, _ in
            let data = url.path.contains("subject_suggest") ? Data(#"[{"id":"123","title":"示例电影","sub_title":"Example Movie","year":"2024","img":"https://img1.doubanio.com/p1.jpg","episode":""}]"#.utf8) : Data(html.utf8)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await provider.search(title: "示例电影", year: 2024, kind: .movies).first?.metadata.doubanID == "123")
        let english = try await provider.search(title: "Example Movie", year: 2024, kind: .movies)
        #expect(MetadataMatcher.uniqueMatch(candidates: english, title: "Example Movie", year: 2024, kind: .movies)?.metadata.doubanID == "123")
        let metadata = try await provider.details(id: "https://movie.douban.com/subject/123/", kind: .movies)
        #expect(metadata.title == "示例电影"); #expect(metadata.year == 2024); #expect(metadata.doubanRating == 9.2); #expect(metadata.tmdbRating == nil)
        #expect(DoubanMetadataProvider.subjectID("https://example.org/subject/123/") == nil)
        let redirected = HTTPURLResponse(url: URL(string: "https://sec.douban.com/b")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        #expect(DoubanMetadataProvider.verificationURL(response: redirected, data: Data())?.host == "sec.douban.com")
        let ordinary = HTTPURLResponse(url: URL(string: "https://movie.douban.com/subject/123/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        #expect(DoubanMetadataProvider.verificationURL(response: ordinary, data: Data("<title>豆瓣 - 验证</title>".utf8)) != nil)
        #expect(DoubanMetadataProvider.verificationURL(response: ordinary, data: Data(html.utf8)) == nil)
    }
    @Test(arguments: [MediaLibraryKind.movies, .television])
    func englishFilenamesMatchOriginalTitlesWithChinesePresentation(_ kind: MediaLibraryKind) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "中英文匹配", metadataSource: .tmdb)
        let movie = kind == .movies
        let title = movie ? "Alien Romulus" : "Breaking Bad"
        let localized = movie ? "异形：夺命舰" : "绝命毒师"
        let year = movie ? 2024 : 2008
        let provider = TMDBMetadataProvider(credential: .init(kind: .readAccessToken, value: "fixture-token"), request: { url, _ in
            let fields: [String: Any] = movie
                ? ["id": 945961, "title": localized, "original_title": "Alien: Romulus", "release_date": "2024-08-14", "poster_path": "/movie.jpg"]
                : ["id": 1396, "name": localized, "original_name": title, "first_air_date": "2008-01-20", "poster_path": "/tv.jpg"]
            let object: [String: Any] = url.path.contains("search") ? ["results": [fields]] : fields
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/\(title) (\(year)).mkv")
        try await index.upsert(.init(reference: ref, entry: .init(path: ref.path, name: "\(title).mkv", isDirectory: false),
            groupKey: title, filenameMetadata: .init(title: title, year: year, kind: kind)), scanID: UUID())
        let matcher = MetadataMatcher(index: index, providers: [provider])
        await matcher.enqueue(library: library, references: [ref])
        await matcher.waitForMatching(libraryID: library.id)
        let record = try #require(try await index.record(reference: ref))
        #expect(record.onlineMetadata.title == localized)
        #expect(record.onlineMetadata.poster?.hasPrefix("https://image.tmdb.org/") == true)
        #expect(record.candidates.isEmpty)
        #expect(MediaLibraryPresentation.vod(record: record, site: .init()).vodName == localized)
    }
    @Test func yearlessMatchesKeepRemakesPendingAndReportActualOutcomes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "匹配结果", metadataSource: .tmdb)
        let provider = TMDBMetadataProvider(credential: .init(kind: .readAccessToken, value: "fixture-token"), request: { url, _ in
            let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
            let fields: [String: Any] = ["id": 21519, "title": "A计划", "original_title": "A計劃", "release_date": "1983-12-22", "poster_path": "/poster.jpg"]
            var object = fields
            if url.path.contains("search") {
                let results: [[String: Any]]
                if title == "A计划" { results = [fields] }
                else if title == "The Thing" {
                    results = [
                        ["id": 1, "title": "怪形", "original_title": "The Thing", "release_date": "1982-01-01"],
                        ["id": 2, "title": "怪形前传", "original_title": "The Thing", "release_date": "2011-01-01"]
                    ]
                } else { results = [] }
                object = ["results": results]
            }
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        var references: [FileResourceReference] = []
        for title in ["A计划", "The Thing", "Unknown Movie"] {
            let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/\(title).mkv")
            references.append(ref)
            try await index.upsert(.init(reference: ref, entry: .init(path: ref.path, name: "\(title).mkv", isDirectory: false),
                groupKey: title, filenameMetadata: .init(title: title, kind: .movies)), scanID: UUID())
        }
        let matcher = MetadataMatcher(index: index, providers: [provider])
        await matcher.enqueue(library: library, references: references)
        await matcher.waitForMatching(libraryID: library.id)
        #expect(try await index.record(reference: references[0])?.onlineMetadata.poster != nil)
        #expect(try await index.record(reference: references[1])?.onlineMetadata.title == nil)
        #expect(try await index.record(reference: references[1])?.candidates.count == 2)
        let progress = try #require(await matcher.currentProgress(libraryID: library.id))
        #expect(progress.completed == 3)
        #expect(progress.matched == 1); #expect(progress.needsConfirmation == 1); #expect(progress.unmatched == 1)
        #expect(progress.message == "影视信息处理完成：已匹配 1，待确认 1，未找到 1")
        // Reusing already matched records still contributes to the outcome summary.
        await matcher.enqueue(library: library, references: references)
        await matcher.waitForMatching(libraryID: library.id)
        #expect(await matcher.currentProgress(libraryID: library.id)?.matched == 1)
    }
    @Test(arguments: [FallbackFixture.Outcome.empty, .ambiguous, .failure])
    fileprivate func automaticTriesDoubanWhenTMDBCannotMatch(_ outcome: FallbackFixture.Outcome) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "自动兜底", metadataSource: .automatic)
        let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/Example Movie (2024).mkv")
        try await index.upsert(.init(reference: ref, entry: .init(path: ref.path, name: "Example Movie.mkv", isDirectory: false),
            groupKey: "movie", filenameMetadata: .init(title: "Example Movie", year: 2024, kind: .movies)), scanID: UUID())
        let tmdb = FallbackFixture(source: .tmdb, outcome: outcome)
        let douban = FallbackFixture(source: .douban, outcome: .success)
        let matcher = MetadataMatcher(index: index, providers: [tmdb, douban])
        await matcher.enqueue(library: library, references: [ref])
        await matcher.waitForMatching(libraryID: library.id)
        let record = try #require(try await index.record(reference: ref))
        #expect(record.onlineMetadata.doubanID == "123")
        #expect(record.onlineMetadata.poster == "https://example.org/douban.jpg")
        #expect(record.onlineMetadata.doubanRating == 9.2)
        #expect(record.candidates.isEmpty); #expect(record.metadataError == nil)
        #expect(await tmdb.searchCount == 1); #expect(await tmdb.detailsCount == 0)
        #expect(await douban.searchCount == 1); #expect(await douban.detailsCount == 1)
        #expect(await matcher.currentProgress(libraryID: library.id)?.matched == 1)
    }
    @Test(arguments: [FallbackFixture.Outcome.empty, .success])
    fileprivate func automaticOnlyReportsMissingAfterBothSourcesAndStopsAfterTMDBSuccess(_ outcome: FallbackFixture.Outcome) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "来源顺序", metadataSource: .automatic)
        let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/Example Movie.mkv")
        try await index.upsert(.init(reference: ref, entry: .init(path: ref.path, name: "Example Movie.mkv", isDirectory: false),
            groupKey: "movie", filenameMetadata: .init(title: "Example Movie", year: 2024, kind: .movies)), scanID: UUID())
        let tmdb = FallbackFixture(source: .tmdb, outcome: outcome)
        let douban = FallbackFixture(source: .douban, outcome: .empty)
        let matcher = MetadataMatcher(index: index, providers: [tmdb, douban])
        await matcher.enqueue(library: library, references: [ref])
        await matcher.waitForMatching(libraryID: library.id)
        #expect(await tmdb.searchCount == 1)
        #expect(await douban.searchCount == (outcome == .success ? 0 : 1))
        #expect(await matcher.currentProgress(libraryID: library.id)?.unmatched == (outcome == .success ? 0 : 1))
        #expect(await matcher.currentProgress(libraryID: library.id)?.completed == 1)
    }
    @Test func matcherPauseResumeSourceSwitchLocksAndFailurePreservesCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        var library = MediaLibraryConfiguration(serviceID: UUID(), name: "测试", metadataSource: .douban)
        let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/示例电影 (2024).mkv")
        let record = MediaRecord(reference: ref, entry: .init(path: ref.path, name: "示例电影 (2024).mkv", isDirectory: false), groupKey: "movie",
            filenameMetadata: .init(title: "示例电影", year: 2024, kind: .movies), localMetadata: .init(plot: "本地简介"), onlineMetadata: .init(tmdbRating: 8.4))
        try await index.upsert(record, scanID: UUID())
        let provider = MatchingFixture()
        await provider.setMode(.verification)
        let matcher = MetadataMatcher(index: index, providers: [provider])
        await matcher.enqueue(library: library, references: [ref])
        await matcher.waitForMatching(libraryID: library.id)
        #expect(await matcher.verificationURL()?.host == "sec.douban.com")
        #expect(await matcher.currentProgress(libraryID: library.id)?.isRunning == false)
        #expect(try await index.record(reference: ref)?.onlineMetadata.tmdbRating == 8.4)
        await provider.setMode(.normal)
        await matcher.resumeAfterVerification(); await matcher.waitForMatching(libraryID: library.id)
        #expect(try await index.record(reference: ref)?.metadata.doubanRating == 9.2)
        #expect(try await index.record(reference: ref)?.metadata.plot == "本地简介")
        try await index.applyCorrection(.init(reference: ref, fields: .init(title: "手动锁定")))
        await provider.setMode(.rateLimited)
        try await matcher.rematch(library); await matcher.waitForMatching(libraryID: library.id)
        #expect(try await index.record(reference: ref)?.metadata.title == "手动锁定")
        #expect(try await index.record(reference: ref)?.metadata.doubanRating == 9.2)
        library.metadataSource = .local
        try await matcher.rematch(library); await matcher.waitForMatching(libraryID: library.id)
        #expect(try await index.record(reference: ref)?.metadata.tmdbRating == nil)
        #expect(try await index.record(reference: ref)?.metadata.title == "手动锁定")
    }
    @Test func rateLimitStopsWholeBatchAndAutomaticFallsBackWithoutTMDBKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "测试", metadataSource: .automatic)
        var refs: [FileResourceReference] = []
        for i in 0..<100 {
            let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/电影\(i).mkv"); refs.append(ref)
            try await index.upsert(.init(reference: ref, entry: .init(path: ref.path, name: "电影\(i).mkv", isDirectory: false), groupKey: "movie",
                filenameMetadata: .init(title: "示例电影", year: 2024, kind: .movies)), scanID: UUID())
        }
        let provider = MatchingFixture(); await provider.setMode(.rateLimited)
        let matcher = MetadataMatcher(index: index, providers: [provider])
        await matcher.enqueue(library: library, references: refs); await matcher.waitForMatching(libraryID: library.id)
        #expect(await provider.searchCount == 1)
        #expect(try await index.records(libraryID: library.id).count == 100)
        await provider.setMode(.normal)
        try await matcher.rematch(library); await matcher.waitForMatching(libraryID: library.id)
        #expect(try await index.record(reference: refs[0])?.metadata.doubanRating == 9.2)
        #expect(try await index.record(reference: refs[0])?.metadata.tmdbRating == nil)
    }
}

private actor RecordedMetadataRequests {
    var values: [(URL, [String: String])] = []
    func record(_ url: URL, _ headers: [String: String]) { values.append((url, headers)) }
}
private actor FallbackFixture: MetadataProvider {
    enum Outcome: Sendable { case empty, ambiguous, failure, success }
    nonisolated let source: MetadataSource
    let outcome: Outcome
    var searchCount = 0
    var detailsCount = 0
    init(source: MetadataSource, outcome: Outcome) { self.source = source; self.outcome = outcome }
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        searchCount += 1
        if outcome == .failure { throw MetadataProviderError.rateLimited }
        if outcome == .empty { return [] }
        let candidate = MetadataCandidate(source: source, metadata: .init(title: "示例电影", originalTitle: title, year: year, kind: kind,
            tmdbID: source == .tmdb ? "12" : nil, doubanID: source == .douban ? "123" : nil))
        return outcome == .ambiguous ? [candidate, candidate] : [candidate]
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        detailsCount += 1
        return .init(title: "示例电影", year: 2024, kind: kind, poster: "https://example.org/\(source.rawValue).jpg",
            tmdbID: source == .tmdb ? id : nil, doubanID: source == .douban ? id : nil,
            tmdbRating: source == .tmdb ? 8.4 : nil, doubanRating: source == .douban ? 9.2 : nil)
    }
}
private actor MatchingFixture: MetadataProvider {
    nonisolated let source = MetadataSource.douban
    enum Mode { case normal, verification, rateLimited }
    var mode: Mode = .normal
    var searchCount = 0
    func setMode(_ mode: Mode) { self.mode = mode }
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        searchCount += 1
        switch mode {
        case .verification: throw MetadataProviderError.verification(URL(string: "https://sec.douban.com/b")!)
        case .rateLimited: throw MetadataProviderError.rateLimited
        case .normal: return [.init(source: .douban, metadata: .init(title: title, year: year, kind: kind, doubanID: "123"))]
        }
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata { .init(title: "示例电影", year: 2024, kind: kind, plot: "在线简介", doubanID: "123", doubanRating: 9.2) }
}
