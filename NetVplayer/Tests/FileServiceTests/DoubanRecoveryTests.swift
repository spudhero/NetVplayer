import Foundation
import Testing
import Models
import Storage
import MediaLibraryEngine

@Suite("Douban public page recovery", .serialized)
struct DoubanRecoveryTests {
    private static let url = URL(string: "https://movie.douban.com/subject/1307442/")!
    private static let html = #"<html><head><title>速度与激情2 (豆瓣)</title><script src="https://sec.douban.com/site-script.js"></script><script type="application/ld+json">{"@type":"Movie","name":"速度与激情2","datePublished":"2003-06-03","image":"https://img1.doubanio.com/view/photo/s_ratio_poster/public/p1.webp","aggregateRating":{"ratingValue":"7.5"}}</script></head><body><h1><span property="v:itemreviewed">速度与激情2 2 Fast 2 Furious</span></h1></body></html>"#

    @Test func normalMoviePagesDoNotBecomeVerificationBecauseOfScriptsOrStatusAlone() {
        let response = HTTPURLResponse(url: Self.url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        #expect(DoubanMetadataProvider.verificationURL(response: response, data: Data(Self.html.utf8)) == nil)
        let denied = HTTPURLResponse(url: Self.url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        #expect(DoubanMetadataProvider.verificationURL(response: denied, data: Data("Forbidden".utf8)) == nil)
        let captcha = Data(#"<html><title>豆瓣 - 验证</title><form><input id='captcha-answer'></form></html>"#.utf8)
        #expect(DoubanMetadataProvider.verificationURL(response: response, data: captcha) == Self.url)
    }

    @Test func blockedHTTPDetailsUseNormalBrowserPageBeforePausing() async throws {
        let calls = RecoveryRequests()
        let provider = DoubanMetadataProvider(request: { _, _ in
            await calls.recordHTTP()
            return (Data("<title>豆瓣</title>".utf8), HTTPURLResponse(url: URL(string: "https://sec.douban.com/c")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, publicPageRequest: { url, _ in
            await calls.recordBrowser()
            return (Data(Self.html.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let movie = try await provider.details(id: "1307442", kind: .movies)
        #expect(movie.title == "速度与激情2"); #expect(movie.year == 2003)
        #expect(movie.poster != nil); #expect(movie.doubanRating == 7.5)
        #expect(await calls.http == 1); #expect(await calls.browser == 1)
    }

    @Test func genuineBrowserChallengeStillRequiresUserAndIsNotRetriedInALoop() async throws {
        let calls = RecoveryRequests()
        let challenge = URL(string: "https://sec.douban.com/b")!
        let provider = DoubanMetadataProvider(request: { _, _ in
            await calls.recordHTTP()
            return (Data(), HTTPURLResponse(url: challenge, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, publicPageRequest: { _, _ in
            await calls.recordBrowser()
            throw MetadataProviderError.verification(challenge)
        })
        do {
            _ = try await provider.details(id: "1307442", kind: .movies)
            Issue.record("A real browser challenge must not be treated as movie metadata")
        } catch MetadataProviderError.verification(let url) { #expect(url == challenge) }
        #expect(await calls.http == 1); #expect(await calls.browser == 1)
    }

    @Test func visibleNormalPageCanResumeWithoutRepeatingBlockedRequest() async throws {
        let calls = RecoveryRequests()
        let provider = DoubanMetadataProvider(request: { _, _ in
            await calls.recordHTTP()
            throw MetadataProviderError.invalidResponse
        })
        #expect(await provider.acceptPublicPage(html: Self.html, text: "", at: Self.url))
        let movie = try await provider.details(id: "1307442", kind: .movies)
        #expect(movie.title == "速度与激情2"); #expect(movie.doubanRating == 7.5)
        #expect(await calls.http == 0)
        #expect(await provider.acceptPublicPage(html: Self.html, text: "", at: URL(string: "https://example.org/subject/1307442/")!) == false)
        #expect(await provider.acceptPublicPage(html: "<title>验证</title>", text: "", at: Self.url) == false)
    }

    @Test func browserSearchJSONKeepsOriginalTitlesAndRejectsOtherMoviePages() async throws {
        let provider = DoubanMetadataProvider(request: { _, _ in throw MetadataProviderError.invalidResponse })
        let url = URL(string: "https://movie.douban.com/j/subject_suggest?q=2%20Fast%202%20Furious")!
        let json = #"[{"id":"1307442","title":"速度与激情2","sub_title":"2 Fast 2 Furious","year":"2003","episode":""}]"#
        #expect(await provider.acceptPublicPage(html: "<html><body><pre>JSON</pre></body></html>", text: json, at: url))
        let candidates = try await provider.search(title: "2 Fast 2 Furious", year: nil, kind: .movies)
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "2 Fast 2 Furious", year: nil, kind: .movies)?.metadata.doubanID == "1307442")
        #expect(await provider.acceptPublicPage(html: Self.html, text: "", at: URL(string: "https://movie.douban.com/")!) == false)
        #expect(await provider.acceptPublicPage(html: Self.html, text: "", at: URL(string: "https://movie.douban.com/subject/1307442/photos/")!) == false)
    }

    @Test func ordinaryBrowserTimeoutKeepsLaterTMDBMoviesRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = MediaIndex(url: directory.appendingPathComponent("index.sqlite"))
        let library = MediaLibraryConfiguration(serviceID: UUID(), name: "加载超时", metadataSource: .automatic)
        var references: [FileResourceReference] = []
        for title in ["Needs Douban", "Known Movie"] {
            let ref = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: "/\(title).mkv")
            references.append(ref)
            try await index.upsert(.init(reference: ref, entry: .init(path: ref.path, name: "\(title).mkv", isDirectory: false),
                groupKey: title, filenameMetadata: .init(title: title, kind: .movies)), scanID: UUID())
        }
        let tmdb = TMDBMetadataProvider(credential: .init(kind: .apiKey, value: "fixture-key"), request: { url, _ in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
            let movie: [String: Any] = ["id": 12, "title": "已知电影", "original_title": "Known Movie", "release_date": "2024-01-01", "poster_path": "/known.jpg"]
            let body = url.path.contains("search") ? ["results": query == "Known Movie" ? [movie] : []] : movie
            return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let douban = DoubanMetadataProvider(request: { _, _ in
            (Data("<title>豆瓣</title><body>载入中 ...</body>".utf8), HTTPURLResponse(url: URL(string: "https://sec.douban.com/c")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, publicPageRequest: { _, _ in throw MetadataProviderError.unavailable("豆瓣网页载入超时") })
        let matcher = MetadataMatcher(index: index, providers: [tmdb, douban])
        await matcher.enqueue(library: library, references: references)
        await matcher.waitForMatching(libraryID: library.id)
        #expect(await matcher.verificationURL() == nil)
        #expect(await matcher.currentProgress(libraryID: library.id)?.completed == 2)
        #expect(await matcher.currentProgress(libraryID: library.id)?.matched == 1)
        #expect(try await index.record(reference: references[0])?.metadataError == "豆瓣网页载入超时")
        #expect(try await index.record(reference: references[1])?.onlineMetadata.poster == "https://image.tmdb.org/t/p/w500/known.jpg")
    }
}

private actor RecoveryRequests {
    var http = 0
    var browser = 0
    func recordHTTP() { http += 1 }
    func recordBrowser() { browser += 1 }
}
