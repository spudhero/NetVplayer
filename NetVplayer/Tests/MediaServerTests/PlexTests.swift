import Foundation
import Testing
import Models
import Storage
import Networking
import ProxyServer
import SpiderEngine
@testable import MediaServerEngine

@Suite("Plex native integration", .serialized)
struct PlexTests {
    @Test func tokenAuthenticationPaginationDetailsAndPrivateArtwork() async throws {
        let fixture = PlexFixture()
        let transport = MediaServerTransport(handler: { try await fixture.handle($0, limit: $1) })
        let login = try MediaServerClient(account: .init(kind: .plex, server: "https://plex.invalid"), transport: transport)
        let (account, token) = try await login.authenticate(username: "", password: "plex-fixture-token")
        #expect(account.name == "Plex" && account.serverID == "plex-server")
        let client = try MediaServerClient(account: account, token: token, transport: transport)
        try await client.validateSession()
        let views = try await client.views()
        #expect(views.first?.Id == "section-1")
        let secondPage = try await client.items(parent: "section-1", page: 2)
        #expect(secondPage.Items?.count == 3 && secondPage.TotalRecordCount == 53)
        #expect(await fixture.pageStart == "50")
        let item = try await client.item("1")
        #expect(item.Name == "城市漫游" && item.Type == "Movie" && item.ProductionYear == 2026)
        #expect(item.MediaSources?.count == 2 && item.MediaSources?.first?.Size == 1024)
        #expect(item.MediaSources?.first?.MediaStreams?.last?.DeliveryUrl == "/library/streams/9")
        #expect(item.UserData?.PlaybackPositionTicks == 12_500_0000)
        let artwork = try MediaServerArtworkReference(item: .init(accountID: account.id, itemID: "1"), tag: "123")
        #expect(try await client.artwork(artwork) == PlexFixture.image)
        #expect(!artwork.locator.contains(token))
        let (changed, _) = try await client.authenticate(username: "", password: "another-fixture-token")
        #expect(changed.id != account.id && changed.userID != account.userID)
        await #expect(throws: MediaServerError.authentication) { try await login.authenticate(username: "", password: "wrong") }
    }
    @Test func rangePlaybackSubtitlesProgressAndRelease() async throws {
        let fixture = PlexFixture()
        let transport = MediaServerTransport(handler: { try await fixture.handle($0, limit: $1) })
        let login = try MediaServerClient(account: .init(kind: .plex, server: "https://plex.invalid"), transport: transport)
        let (account, token) = try await login.authenticate(username: "", password: "plex-fixture-token")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MediaServerStore(storage: StorageManager(storageDirectory: folder), preferences:
            UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore()))
        try store.save([account]); try store.saveToken(token, for: account)
        let runtime = MediaServerRuntime(store: store, transport: transport)
        let provider = MediaServerNativeProvider(accountID: account.id, runtime: runtime)
        let reference = try MediaServerReference(accountID: account.id, itemID: "1", sourceID: "22")
        let detail = try await provider.detailContent(site: account.site(), id: reference.itemLocator)
        #expect(detail.vod?.mediaServerDetail?.files.count == 2)
        #expect(detail.vod?.vodPic.hasPrefix("netvplayer-artwork:") == true)
        try ProxyServer.shared.start(); defer { ProxyServer.shared.stop() }
        let result = try await runtime.resolve(reference)
        let playback = try #require(result.mediaServer)
        #expect(result.url.contains("127.0.0.1") && !result.url.contains(token) && result.header.isEmpty)
        #expect(result.subs.count == 1 && playback.chapters.map(\.seconds) == [0, 30])
        var request = URLRequest(url: try #require(URL(string: result.url)))
        request.setValue("bytes=500-599", forHTTPHeaderField: "Range")
        let bytes = try await URLSession.shared.data(for: request)
        #expect(bytes.0 == PlexFixture.bytes.subdata(in: 500..<600))
        #expect(await fixture.partIDs.contains("22"))
        await runtime.report(playback.leaseID, snapshot: .init(seconds: 24), started: true)
        await runtime.release(playback.leaseID, snapshot: .init(seconds: 34))
        for _ in 0..<100 {
            if await fixture.states.last == "stopped" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.states == ["playing", "stopped"])
        #expect(await fixture.lastTime == "34000")
        #expect(await fixture.lastDuration == "90000")
        #expect((try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode == 404)
    }
    @Test func resourceURLsAndRedirectsNeverForwardTokenOffServer() throws {
        let client = try MediaServerClient(account: .init(kind: .plex, server: "https://plex.invalid"), token: "plex-fixture-token")
        for path in ["https://other.invalid/library/parts/1/file", "//other.invalid/library/parts/1/file", "/library/parts/../1/file", "/library/parts/%2e%2e/1/file", "/library/parts/1/file?X-Plex-Token=secret"] {
            #expect(client.plexResourceRequest(path, prefixes: ["/library/parts/"]) == nil)
        }
        let request = try #require(client.plexResourceRequest("/library/parts/1/file.mkv", prefixes: ["/library/parts/"]))
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "plex-fixture-token")
        let nested = try MediaServerClient(account: .init(kind: .plex, server: "https://plex.invalid/nested"), token: "plex-fixture-token")
        #expect(nested.plexResourceRequest("/library/parts/1/file.mkv", prefixes: ["/library/parts/"])?.url?.path == "/nested/library/parts/1/file.mkv")
        var proposed = request; proposed.url = URL(string: "https://other.invalid/video")
        let redirected = try #require(HTTPRedirectPolicy.redirected(request, proposed: proposed, status: 302, hop: 1))
        #expect(redirected.value(forHTTPHeaderField: "X-Plex-Token") == nil)
    }
}

private actor PlexFixture {
    static let bytes = Data((0..<1024).map { UInt8($0 % 256) })
    static let image = Data("synthetic-image".utf8)
    var pageStart: String?, lastTime: String?, lastDuration: String?
    var partIDs: [String] = [], states: [String] = []
    func handle(_ request: URLRequest, limit: Int) throws -> (Data, HTTPURLResponse) {
        let url = request.url!, path = url.path
        func reply(_ data: Data, _ status: Int = 200, _ headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
            (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        guard ["plex-fixture-token", "another-fixture-token"].contains(request.value(forHTTPHeaderField: "X-Plex-Token") ?? "") else { return reply(Data(), 401) }
        #expect(url.query?.contains("fixture-token") != true)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        let container: [String: Any]
        switch path {
        case "", "/": container = ["machineIdentifier": "plex-server"]
        case "/library/sections": container = ["Directory": [["key": "1", "title": "电影", "type": "movie"]]]
        case "/library/sections/1/all":
            pageStart = request.value(forHTTPHeaderField: "X-Plex-Container-Start")
            container = ["totalSize": 53, "Metadata": (51...53).map { ["ratingKey": String($0), "title": "Movie \($0)", "type": "movie"] }]
        case "/library/metadata/1":
            let streams: [[String: Any]] = [["id": 7, "index": 0, "streamType": 1, "codec": "h264", "width": 960, "height": 540],
                ["id": 8, "index": 1, "streamType": 2, "codec": "aac", "channels": 1],
                ["id": 9, "index": 2, "streamType": 3, "codec": "srt", "key": "/library/streams/9", "languageCode": "zho"]]
            container = ["Metadata": [["ratingKey": "1", "title": "城市漫游", "summary": "Plex 样片", "type": "movie", "year": 2026,
                "thumb": "/library/metadata/1/thumb/123", "updatedAt": 123, "duration": 90000, "viewOffset": 12500,
                "Genre": [["tag": "测试"]], "Director": [["tag": "QA"]],
                "Chapter": [["startTimeOffset": 0], ["startTimeOffset": 30000]],
                "Media": [11, 22].map { ["Part": [["id": $0, "key": "/library/parts/\($0)/file.mp4", "file": "/private/中文.mp4", "size": 1024, "container": "mp4", "Stream": streams]]] }]]]
        case "/library/metadata/1/thumb/123": return reply(Self.image, 200, ["Content-Type": "image/jpeg"])
        case "/library/streams/9": return reply(Data("1\n00:00:01,000 --> 00:00:03,000\n中文字幕\n".utf8))
        case let value where value.hasPrefix("/library/parts/"):
            partIDs.append(String(path.split(separator: "/")[2]))
            let bounds = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(separator: "-").map { Int($0)! }
            return reply(Self.bytes.subdata(in: bounds[0]..<(bounds[1] + 1)), 206,
                ["Content-Range": "bytes \(bounds[0])-\(bounds[1])/1024"])
        case "/:/timeline":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            func value(_ key: String) -> String { query.first { $0.name == key }?.value ?? "" }
            states.append(value("state")); lastTime = value("time"); lastDuration = value("duration"); return reply(Data())
        default: throw MediaServerError.response
        }
        return reply(try JSONSerialization.data(withJSONObject: ["MediaContainer": container]), 200, ["Content-Type": "application/json"])
    }
}
