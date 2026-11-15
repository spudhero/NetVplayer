import Foundation
import Models
import Networking
import ProxyServer
import SpiderEngine
import Storage
import Testing
@testable import MediaServerEngine

@Suite("FnOS and Zspace synthetic HTTP integration", .serialized)
struct NASMediaTests {
    @Test func fnOSSignatureMatchesIndependentVectors() throws {
        let body = Data(#"{"app_name":"trimemedia-web","password":"p\u00e4ss","username":"fixture"}"#.utf8)
        #expect(MediaServerClient.fnOSAuthx(path: "/v/api/v1/login", body: body, query: [], nonce: "123456", timestamp: "1792584000123") ==
            "nonce=123456&timestamp=1792584000123&sign=1c1d287840b0078d57e3657a4ce0d329")
        #expect(MediaServerClient.fnOSAuthx(path: "/v/api/v1/search/list", body: nil,
            query: [.init(name: "x", value: "+%"), .init(name: "q", value: "中文 空格")], nonce: "123456", timestamp: "1792584000123") ==
            "nonce=123456&timestamp=1792584000123&sign=c95b5815da0ff76c997b47fd9477ab81")
        let configuration = try MediaServerConfiguration(kind: .fnos, server: "https://nas.invalid/v/").validated()
        #expect(configuration.server == "https://nas.invalid")
    }

    @Test(arguments: [MediaServerKind.fnos, .zspace])
    func authenticationPostersDetailsSearchAndEpisodes(_ kind: MediaServerKind) async throws {
        let fixture = try NASHTTPFixture(kind: kind)
        defer { fixture.close() }
        let (account, token) = try await fixture.login()
        #expect(account.kind == kind && account.username == "fixture")
        #expect(account.serverID == "mock-" + kind.rawValue)
        #expect(account.userID == (kind == .fnos ? "user1" : "101"))
        let client = try MediaServerClient(account: account, token: token)
        #expect(try await client.sessionUser().Name == "fixture")
        let library = try #require(try await client.views().first?.Id)
        let first = try await client.items(parent: library, page: 1)
        #expect(first.Items?.count == 3 && first.TotalRecordCount == 3)
        #expect(try await client.items(parent: library, page: 2).Items?.isEmpty == true)
        #expect(try await client.items(parent: nil, page: 1, search: "中文 空格+%").Items?.first?.Id == "film1")
        let item = try await client.item("film1")
        #expect(item.Overview?.contains("本地模拟服务") == true)
        #expect(item.ProductionYear == 2026 && item.CommunityRating == 8.5)
        #expect(item.MediaSources?.first?.MediaStreams?.first?.Width == 960)
        #expect(item.UserData?.PlaybackPositionTicks == 30_000_000)
        let reference = try MediaServerReference(accountID: account.id, itemID: "film1")
        for (kind, tag) in [(MediaServerArtworkReference.Kind.primary, item.ImageTags?["Primary"]), (.backdrop, item.BackdropImageTags?.first)] {
            let art = try MediaServerArtworkReference(item: reference, tag: #require(tag), kind: kind)
            #expect(try await client.artwork(art) == Data("synthetic-jpeg".utf8))
            #expect(!art.locator.contains(token))
        }
        let episodes = try await client.items(parent: nil, page: 1, series: "series1")
        #expect(episodes.Items?.map(\.Id) == ["episode1", "episode2"])
        await #expect(throws: MediaServerError.authentication) { try await fixture.login(password: "wrong") }
        try await client.logout()
        let summary = try fixture.summary()
        #expect(summary["signatureFailures"] as? Int == 0)
        #expect(summary["artworkReads"] as? Int == 2)
    }

    @Test(arguments: [MediaServerKind.fnos, .zspace])
    func originalRangeSubtitlesProgressResumeAndRelease(_ kind: MediaServerKind) async throws {
        let fixture = try NASHTTPFixture(kind: kind)
        defer { fixture.close() }
        let (account, token) = try await fixture.login()
        let store = try fixture.store(account: account, token: token)
        let runtime = MediaServerRuntime(store: store)
        let provider = MediaServerNativeProvider(accountID: account.id, runtime: runtime)
        let reference = try MediaServerReference(accountID: account.id, itemID: "film1")
        let detail = try await provider.detailContent(site: account.site(), id: reference.locator)
        #expect(detail.vod?.mediaServerDetail?.files.count == 1)
        let series = try await provider.detailContent(site: account.site(), id: MediaServerReference(accountID: account.id, itemID: "series1").locator)
        #expect(series.vod?.episodeDetails.count == 2)
        try ProxyServer.shared.start()
        defer { ProxyServer.shared.stop() }
        let result = try await runtime.resolve(reference)
        let owner = try #require(result.mediaServer)
        #expect(owner.resumeSeconds == 3 && result.subs.count == 1)
        #expect(result.url.contains("127.0.0.1") && !result.url.contains(token) && result.header.isEmpty)
        var request = URLRequest(url: try #require(URL(string: result.url)))
        request.setValue("bytes=500-999", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(bytes == fixture.bytes.subdata(in: 500..<1000))
        let subtitle = try await URLSession.shared.data(from: #require(URL(string: result.subs[0].url))).0
        #expect(String(decoding: subtitle, as: UTF8.self).contains("字幕读取通过"))
        await runtime.report(owner.leaseID, snapshot: .init(seconds: 12.75, audioIndex: 1, subtitleIndex: 3), started: true)
        await runtime.release(owner.leaseID, snapshot: .init(seconds: 24.75, paused: true, audioIndex: 1))
        for _ in 0..<100 {
            if (try fixture.summary()["lastSeconds"] as? Int) == 24 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await runtime.activeLeaseCount == 0)
        let restored = try await runtime.resolve(reference)
        #expect(restored.mediaServer?.resumeSeconds == 24)
        #expect(restored.mediaServer?.identity == owner.identity)
        await runtime.release(try #require(restored.mediaServer?.leaseID))
        #expect((try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode == 404)
        let summary = try fixture.summary()
        #expect(summary["signatureFailures"] as? Int == 0)
        #expect((summary["rangeReads"] as? Int ?? 0) > 0)
        let reports = try #require(summary["reports"] as? [[String: Any]])
        #expect(reports.last?["seconds"] as? Int == 24)
        #expect(reports.last?["media"] as? String == "source-film1")
    }

    @Test(arguments: [MediaServerKind.fnos, .zspace])
    func changedServerOrUserCannotReuseSession(_ kind: MediaServerKind) async throws {
        let fixture = try NASHTTPFixture(kind: kind)
        defer { fixture.close() }
        let (original, token) = try await fixture.login()
        var changed = original; changed.userID = "someone-else"
        await #expect(throws: MediaServerError.authentication) { try await MediaServerClient(account: changed, token: token).validateSession() }
        changed = original; changed.serverID = "replaced-server"
        await #expect(throws: MediaServerError.authentication) { try await MediaServerClient(account: changed, token: token).validateSession() }
        let fresh = try await MediaServerClient(account: changed).authenticate(username: "fixture", password: "fixture-password").0
        #expect(fresh.id != original.id)
    }

    @Test func fnOSExpiredByteReadSignatureIsRenewed() async throws {
        let fixture = try NASHTTPFixture(kind: .fnos)
        defer { fixture.close() }
        let (account, token) = try await fixture.login()
        let client = try MediaServerClient(account: account, token: token)
        var expired = client.originalRequest(item: "film1", source: "source-film1", audio: false)
        expired.setValue("bytes=0-499", forHTTPHeaderField: "Range")
        expired.setValue(MediaServerClient.fnOSAuthx(path: try #require(expired.url).path, body: nil, query: [],
            nonce: "123456", timestamp: "1"), forHTTPHeaderField: "Authx")
        await #expect(throws: MediaServerError.http(403)) {
            try await client.transport.request(expired, maximumBytes: 500)
        }
        let reader = MediaServerByteSource(client: client, fallback: expired, direct: nil, size: Int64(fixture.bytes.count))
        #expect(try await reader.read(0..<500) == fixture.bytes.prefix(500))
        await reader.close()
        #expect(try fixture.summary()["signatureFailures"] as? Int == 1)
        #expect(try fixture.summary()["rangeReads"] as? Int == 1)
    }

    @Test func fnOSUnavailableOriginalRejectsBothAutomaticAndExplicitVersion() async throws {
        let fixture = try NASHTTPFixture(kind: .fnos, unplayable: true)
        defer { fixture.close() }
        let (account, token) = try await fixture.login()
        let client = try MediaServerClient(account: account, token: token)
        await #expect(throws: MediaServerError.originalUnavailable) { try await client.playbackInfo("film1") }
        await #expect(throws: MediaServerError.selectedSourceUnavailable) { try await client.playbackInfo("film1", sourceID: "source-film1") }
        #expect(try fixture.summary()["rangeReads"] as? Int == 0)
    }
}

/// Starts the independent Python wire fixture on an OS-selected loopback port.
/// It intentionally does not use MediaServerClient's serializer or signing helpers.
final class NASHTTPFixture: @unchecked Sendable {
    let directory: URL
    let kind: MediaServerKind
    let process = Process()
    let bytes = Data((0..<16384).map { UInt8($0 % 251) })
    private var defaultsDomains: [String] = []
    private(set) var endpoint = ""
    var summaryURL: URL { directory.appendingPathComponent("summary.json") }

    init(kind: MediaServerKind, media: URL? = nil, artwork: URL? = nil, unplayable: Bool = false) throws {
        self.kind = kind
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nas-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = directory.appendingPathComponent("fixture.mp4")
        try bytes.write(to: local)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("script/serve_nas_media_fixture.py").path,
            "--kind", kind.rawValue, "--media", (media ?? local).path, "--summary", summaryURL.path]
        if let artwork { process.arguments! += ["--artwork", artwork.path] }
        if unplayable { process.arguments!.append("--unplayable") }
        let log = directory.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: log)
        process.standardError = process.standardOutput
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, process.isRunning {
                if let port = (try? summary()["port"]) as? Int { endpoint = "http://127.0.0.1:\(port)"; return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw MediaServerError.response
        } catch { close(); throw error }
    }
    func summary() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: summaryURL)) as? [String: Any] ?? [:] }
    func login(password: String = "fixture-password") async throws -> (MediaServerConfiguration, String) {
        try await MediaServerClient(account: .init(name: kind.title + "模拟服务", kind: kind, server: endpoint, allowsHTTP: true))
            .authenticate(username: "fixture", password: password)
    }
    func store(account: MediaServerConfiguration, token: String) throws -> MediaServerStore {
        let domain = "nas-test-" + account.id.uuidString
        defaultsDomains.append(domain)
        let defaults = UserDefaults(suiteName: domain)!
        let store = MediaServerStore(storage: StorageManager(storageDirectory: directory.appendingPathComponent("storage")),
            preferences: UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore()))
        try store.save([account]); try store.saveToken(token, for: account)
        return store
    }
    func close() {
        if process.isRunning {
            process.terminate()
            // waitUntilExit can remain in its run loop after this child has
            // exited. Bound fixture cleanup and report a real shutdown failure.
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        }
        #expect(!process.isRunning, "The NAS HTTP fixture must terminate within two seconds")
        for domain in defaultsDomains { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        if !process.isRunning { try? FileManager.default.removeItem(at: directory) }
    }
}
