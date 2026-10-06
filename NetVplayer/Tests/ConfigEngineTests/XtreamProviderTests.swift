import XCTest
import Foundation
import Models
import Networking
import Storage
@testable import SpiderEngine

final class XtreamProviderTests: XCTestCase {
    private func provider(expired: Bool = false) throws -> (XtreamSiteProvider, Site) {
        let configuration = try XtreamConfiguration(name: "Fixture", server: "https://xtream.invalid/base")
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [XtreamFixtureProtocol.self]
        let site = try configuration.site()
        return (try XtreamSiteProvider(configuration: configuration,
            client: HTTPClient(session: URLSession(configuration: sessionConfig)),
            credentials: { XtreamCredentials(username: expired ? "expired" : "user", password: "fixture-pass") }), site)
    }

    func testAccountStatusAndOriginValidation() async throws {
        let (provider, _) = try provider(expired: true)
        do { try await provider.authenticate(); XCTFail("expired Active must be rejected") }
        catch { XCTAssertEqual(error as? XtreamError, .inactiveAccount) }
        XCTAssertThrowsError(try XtreamConfiguration(name: "bad", server: "https://user:pass@example.com"))
        XCTAssertThrowsError(try XtreamConfiguration(name: "bad", server: "http://example.com"))
        XCTAssertNoThrow(try XtreamConfiguration(name: "local", server: "http://example.com", allowsHTTP: true))
    }

    func testMovieMetadataFallbackSearchAndCredentialFreeIdentity() async throws {
        let (provider, site) = try provider()
        let home = try await provider.homeContent(site: site)
        XCTAssertEqual(home.types.count, 2)
        let search = try await provider.searchContent(site: site, keyword: "Fixture", quick: false, page: "1")
        XCTAssertEqual(search.list.count, 2)
        let detail = try await provider.detailContent(site: site, id: "movie:11")
        let vod = try XCTUnwrap(detail.list.first)
        XCTAssertEqual(vod.vodName, "Fixture Movie")
        let episode = try XCTUnwrap(vod.parseFlags().first?.episodes.first)
        XCTAssertFalse(episode.url.contains("fixture-pass"))
        XCTAssertEqual(HistoryPersistencePolicy.sanitizedEpisodeLocator(episode.url), episode.url)
        let player = try await provider.playerContent(site: site, flag: "Xtream", id: episode.url)
        XCTAssertEqual(player.url, "https://xtream.invalid/base/movie/user/fixture-pass/11.mp4")
        let other = try XtreamResource(accountID: UUID(), kind: "movie", streamID: "11", format: "mp4")
        do { _ = try await provider.playerContent(site: site, flag: "", id: other.encoded); XCTFail("foreign account") }
        catch { XCTAssertEqual(error as? XtreamError, .invalidReference) }
    }

    func testSeriesSeasonsAndSameChannelLiveCandidates() async throws {
        let (provider, site) = try provider()
        let detail = try await provider.detailContent(site: site, id: "series:22")
        XCTAssertEqual(detail.list.first?.parseFlags().first?.episodes.count, 2)
        let groups = try await provider.liveGroups()
        let channel = try XCTUnwrap(groups.first?.channels.first)
        XCTAssertEqual(groups.first?.channels.count, 1, "Malformed live rows must not discard valid channels")
        XCTAssertEqual(channel.urls.count, 2)
        let ts = try XtreamResource(channel.urls[0]), hls = try XtreamResource(channel.urls[1])
        XCTAssertEqual(ts.streamID, hls.streamID)
        XCTAssertEqual(ts.accountID, hls.accountID)
        XCTAssertEqual(ts.format, "ts"); XCTAssertEqual(hls.format, "m3u8")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(channel), as: UTF8.self).contains("fixture-pass"))
    }

    func testShortEpgDecodesTitlesAndUsesEpochBeforeServerTimeZone() async throws {
        let (provider, _) = try provider()
        let result = try await provider.shortEpg(streamID: "41")
        XCTAssertEqual(result.items.map(\.title), ["Morning News", "Next Show"])
        XCTAssertEqual(result.items[0].start.timeIntervalSince1970, 1_790_812_800)
        XCTAssertEqual(result.items[1].start.timeIntervalSince1970, 1_790_816_400)
        let data = Data("""
        [{"title":"Local time","start":"2026-10-01 08:00:00","end":"2026-10-01 09:00:00"},
         {"title":"Backwards","start_timestamp":"1790816400","stop_timestamp":"1790812800"}]
        """.utf8)
        let rows = try JSONDecoder().decode([JSONDynamicValue].self, from: data)
        let items = XtreamSiteProvider.epgItems(rows: rows, timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].start.timeIntervalSince1970, 1_790_812_800)
        do { _ = try await provider.shortEpg(streamID: "../bad"); XCTFail("invalid ID must be rejected") }
        catch { XCTAssertEqual(error as? XtreamError, .invalidReference) }
    }

    func testBackupRestoresAccountConfigurationWithoutPassword() throws {
        let name = "xtream-backup-\(UUID())", restoredName = "xtream-restored-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!, restoredDefaults = UserDefaults(suiteName: restoredName)!
        defer { defaults.removePersistentDomain(forName: name); restoredDefaults.removePersistentDomain(forName: restoredName) }
        let preferences = UserPreferences(defaults: defaults)
        let configuration = try XtreamConfiguration(name: "Fixture", server: "https://fixture.invalid")
        preferences.xtreamConfigurations = [configuration]
        try preferences.saveXtreamCredentials(XtreamCredentials(username: "user", password: "do-not-backup"), for: configuration.id)
        let bytes = try JSONEncoder().encode(UserPreferenceSnapshot(preferences: preferences))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("do-not-backup"))
        let restored = UserPreferences(defaults: restoredDefaults)
        try JSONDecoder().decode(UserPreferenceSnapshot.self, from: bytes).apply(to: restored)
        XCTAssertEqual(restored.xtreamConfigurations, [configuration])
        XCTAssertThrowsError(try restored.xtreamCredentials(for: configuration.id))
    }
}

private final class XtreamFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let action = query.first { $0.name == "action" }?.value ?? "auth"
        let expired = query.first { $0.name == "username" }?.value == "expired"
        let body: String
        switch action {
        case "get_short_epg": body = """
        {"epg_listings":[
          {"title":"TW9ybmluZyBOZXdz","start_timestamp":"1790812800","stop_timestamp":"1790816400","start":"2000-01-01 00:00:00"},
          {"title":"Next Show","start_timestamp":1790816400,"end_timestamp":1790820000},
          {"title":"Invalid","start_timestamp":"NaN","stop_timestamp":"Infinity"}]}
        """
        case "auth": body = "{\"user_info\":{\"auth\":1,\"status\":\"Active\",\"exp_date\":\"\(expired ? "1" : "0")\"}}"
        case "get_vod_categories", "get_series_categories", "get_live_categories": body = "[{\"category_id\":\"1\",\"category_name\":\"Fixture\"}]"
        case "get_vod_streams": body = "[{\"stream_id\":11,\"name\":\"Fixture Movie\"},null]"
        case "get_series": body = "[{\"series_id\":22,\"name\":\"Fixture Series\"}]"
        case "get_vod_info": body = "{\"info\":[],\"movie_data\":{\"container_extension\":\"mp4\"}}"
        case "get_series_info": body = "{\"info\":{},\"episodes\":{\"1\":[{\"id\":31,\"title\":\"First\",\"container_extension\":\"mp4\"},{\"title\":\"Malformed\"},{\"id\":32,\"title\":\"Second\",\"container_extension\":\"mp4\"}]}}"
        case "get_live_streams": body = "[{\"stream_id\":41,\"name\":\"Fixture Live\",\"category_id\":\"1\"},null,{\"stream_id\":\"bad\",\"name\":\"Malformed\",\"category_id\":\"1\"}]"
        default: body = "[]"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
