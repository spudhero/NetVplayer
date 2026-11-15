import Foundation
import Testing
import Models
import Storage
import ProxyServer
import SpiderEngine
import MediaServerEngine

@Suite("Real Plex server acceptance", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_PLEX_TEST_CONFIG"] != nil))
struct PlexLiveAcceptanceTests {
    struct Fixture: Decodable { var server: String; var token: String; var name: String }
    @Test func libraryArtworkOriginalPlaybackAndProgress() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_PLEX_TEST_CONFIG"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(URL(string: fixture.server)?.host == "127.0.0.1", "Only explicitly configured local fixtures may run this acceptance test")
        let login = try MediaServerClient(account: .init(name: fixture.name, kind: .plex, server: fixture.server, allowsHTTP: true))
        let (account, token) = try await login.authenticate(username: "", password: fixture.token)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plex-acceptance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaServerStore(storage: StorageManager(storageDirectory: directory), preferences:
            UserPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentialStore: MemoryCredentialStore()))
        try store.save([account]); try store.saveToken(token, for: account)
        let runtime = MediaServerRuntime(store: store), provider = MediaServerNativeProvider(accountID: account.id, runtime: runtime)
        let home = try await provider.homeContent(site: account.site())
        let category = try #require(home.types.first)
        let page = try await provider.categoryContent(site: account.site(), tid: category.typeId, page: "1", filter: false, extend: [:])
        try #require(page.list.count == 3)
        for movie in page.list {
            let artwork = try #require(MediaServerArtworkReference(locator: movie.vodPic))
            #expect(try await runtime.artwork(artwork).count > 1000)
        }
        let movie = try #require(page.list.first { $0.vodName == "城市漫游" })
        let detail = try await provider.detailContent(site: account.site(), id: movie.vodId)
        #expect(detail.vod?.mediaServerDetail?.files.first?.videoCodec == "h264")
        #expect(detail.vod?.vodContent.contains("实测样片") == true)
        let reference = try #require(MediaServerReference(locator: movie.vodId))
        try ProxyServer.shared.start(); defer { ProxyServer.shared.stop() }
        let result = try await runtime.resolve(reference)
        let playback = try #require(result.mediaServer)
        #expect(result.subs.count == 1)
        var request = URLRequest(url: try #require(URL(string: result.url)))
        request.setValue("bytes=1000000-1000031", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.data(for: request)
        #expect(bytes.count == 32 && (response as? HTTPURLResponse)?.statusCode == 206)
        let subtitle = try #require(result.subs.first)
        let subtitleData = try await URLSession.shared.data(from: #require(URL(string: subtitle.url))).0
        #expect(String(decoding: subtitleData, as: UTF8.self).contains("文件服务实测字幕"))
        let movieURL = result.url, subtitleURL = subtitle.url
        let code = try await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mpv")
            process.arguments = ["--no-config", "--vo=null", "--ao=null", "--start=3", "--length=2", "--really-quiet", "--sub-file=" + subtitleURL, movieURL]
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }.value
        #expect(code == 0)
        await runtime.report(playback.leaseID, snapshot: .init(seconds: 63), started: true)
        await runtime.release(playback.leaseID, snapshot: .init(seconds: 65))
        let client = try await runtime.client(for: account.id)
        var offset: Int64?
        for _ in 0..<30 {
            offset = try await client.item(reference.itemID).UserData?.PlaybackPositionTicks
            if offset == 650_000_000 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(offset == 650_000_000)
        #expect((try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode == 404)
        print("[REAL_PLEX] 3 posters; detail and h264 file; range read; Chinese subtitle; mpv decode from 3s; server progress 65s; playback lease released")
    }
}
