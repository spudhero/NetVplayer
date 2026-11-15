import Foundation
import Models
import ProxyServer
import SpiderEngine
import Storage
import Testing
import MediaServerEngine

@Suite("Media server file version selection", .serialized)
struct MediaServerVersionTests {
    @Test func opaqueVersionLocatorRoundTripsAndRejectsUnrecognizedQueries() throws {
        let base = try MediaServerReference(accountID: UUID(), itemID: "film")
        let version = try MediaServerReference(accountID: base.accountID, itemID: base.itemID, sourceID: "source-b")
        #expect(MediaServerReference(locator: version.locator) == version)
        #expect(base.matchesItem(version.locator) && base.locator == version.itemLocator)
        #expect(HistoryPersistencePolicy.sanitizedEpisodeLocator(version.locator) == version.locator)
        #expect(HistoryPersistencePolicy.episodeKey(siteKey: "site", vodId: "film", vodFlag: "original", episodeURL: version.locator)
            != HistoryPersistencePolicy.episodeKey(siteKey: "site", vodId: "film", vodFlag: "original", episodeURL: base.locator))
        for suffix in ["?", "?source=", "?source=a&source=b", "?source=a&token=secret", "?token=x", "?source=../bad", "?source=a#fragment"] {
            #expect(MediaServerReference(locator: base.locator + suffix) == nil)
        }
        #expect(throws: MediaServerError.response) { try MediaServerReference(accountID: base.accountID, itemID: "film", sourceID: "bad/id") }
    }

    @Test(arguments: [MediaServerKind.emby, .jellyfin])
    func selectedVersionControlsNegotiationBytesSubtitlesChaptersAndReports(_ kind: MediaServerKind) async throws {
        try ProxyServer.shared.start()
        defer { ProxyServer.shared.stop() }
        let context = try VersionTestContext(kind: kind)
        defer { context.cleanup() }
        let fixture = VersionFixture()
        let runtime = context.runtime(fixture)
        let reference = try MediaServerReference(accountID: context.account.id, itemID: "film", sourceID: "source-b")
        let provider = MediaServerNativeProvider(accountID: context.account.id, runtime: runtime)
        let detail = try #require(try await provider.detailContent(site: context.account.site(), id: reference.itemLocator).vod)
        #expect(detail.mediaServerDetail?.files.map(\.sourceID) == ["source-a", "source-b"])
        #expect(detail.mediaServerDetail?.files.last?.playbackLocator == reference.locator)
        let result = try await provider.playerContent(site: context.account.site(), flag: "Original", id: reference.locator)
        let owner = try #require(result.mediaServer)
        #expect(await fixture.requestedSource == "source-b")
        #expect(owner.identity == context.account.identity(itemID: "film", sourceID: "source-b"))
        #expect(owner.identity != context.account.identity(itemID: "film", sourceID: "source-a"))
        #expect(owner.resumeSeconds == 0) // Item-wide server progress cannot identify the selected cut.
        #expect(owner.chapters.map(\.seconds) == [5])
        #expect(result.subs.first?.name == "Subtitles source-b")
        #expect(await fixture.subtitlePaths.allSatisfy { $0.contains("/source-b/") })
        var request = URLRequest(url: try #require(URL(string: result.url)))
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let (bytes, _) = try await URLSession.shared.data(for: request)
        #expect(bytes == Data(repeating: 66, count: 4))
        #expect(await fixture.streamSources == ["source-b"])
        await runtime.report(owner.leaseID, snapshot: .init(seconds: 5), started: true)
        await runtime.release(owner.leaseID)
        let deadline = ContinuousClock.now + .seconds(2)
        while await fixture.reportSources.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.reportSources == ["source-b", "source-b"])
        #expect(await runtime.activeLeaseCount == 0)
    }

    @Test(arguments: ["missing", "unsupported"])
    func unavailableChoiceDoesNotFallBackToAnotherVersion(_ mode: String) async throws {
        let context = try VersionTestContext(kind: .jellyfin)
        defer { context.cleanup() }
        let fixture = VersionFixture(mode: mode)
        let runtime = context.runtime(fixture)
        await #expect(throws: MediaServerError.selectedSourceUnavailable) {
            try await runtime.resolve(.init(accountID: context.account.id, itemID: "film", sourceID: "source-b"))
        }
        #expect(await fixture.streamSources.isEmpty)
        #expect(await fixture.subtitlePaths.isEmpty)
        #expect(await runtime.activeLeaseCount == 0)
    }
}

private struct VersionTestContext {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("server-version-" + UUID().uuidString)
    let domain = "ServerVersions." + UUID().uuidString
    let defaults: UserDefaults
    let store: MediaServerStore
    let account: MediaServerConfiguration
    init(kind: MediaServerKind) throws {
        defaults = UserDefaults(suiteName: domain)!
        store = .init(storage: .init(storageDirectory: directory), preferences: .init(defaults: defaults, credentialStore: MemoryCredentialStore()))
        account = .init(name: "Demo", kind: kind, server: "https://versions.invalid", serverID: "server", userID: "user")
        try store.save([account]); try store.saveToken("version-fixture-token", for: account)
    }
    func runtime(_ fixture: VersionFixture) -> MediaServerRuntime {
        .init(store: store, transport: .init(handler: { request, _ in try await fixture.respond(request) }))
    }
    func cleanup() { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
}

private actor VersionFixture {
    let mode: String
    var requestedSource: String?
    var streamSources: [String] = []
    var subtitlePaths: [String] = []
    var reportSources: [String] = []
    init(mode: String = "normal") { self.mode = mode }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!, path = url.path
        func response(_ value: Any) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        if path.hasSuffix("/System/Info/Public") { return try response(["Id": "server"]) }
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "version-fixture-token")
        #expect(!url.absoluteString.contains("version-fixture-token"))
        if path.hasSuffix("/Users/Me") || path.hasSuffix("/Users/user") { return try response(["Id": "user"]) }
        let sources: [[String: Any]] = ["source-a", "source-b"].filter { mode != "missing" || $0 != "source-b" }.map { source in
            ["Id": source, "Name": source == "source-a" ? "1080p" : "2160p HDR", "Size": 4096, "Protocol": "File", "Container": "mkv",
             "SupportsDirectPlay": !(mode == "unsupported" && source == "source-b"),
             "Chapters": [["Name": "Selected chapter", "StartPositionTicks": source == "source-b" ? 50_000_000 : 0]],
             "MediaStreams": [["Index": 3, "Type": "Subtitle", "Codec": "srt", "DisplayTitle": "Subtitles " + source, "IsExternal": true]]]
        }
        if path.hasSuffix("/Items/film") {
            return try response(["Id": "film", "Name": "Demo Movie", "Type": "Movie", "MediaType": "Video", "RunTimeTicks": 100_000_000,
                "UserData": ["PlaybackPositionTicks": 70_000_000], "MediaSources": sources])
        }
        if path.hasSuffix("/PlaybackInfo") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            requestedSource = body["MediaSourceId"] as? String
            #expect(body["EnableTranscoding"] as? Bool == false)
            // Return every version in the old order even when the server ignores the requested filter.
            return try response(["PlaySessionId": "session", "MediaSources": sources])
        }
        if path.contains("/Subtitles/") {
            subtitlePaths.append(path)
            return (Data("1\n00:00:00,000 --> 00:00:01,000\nDemo\n".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if path.hasSuffix("/stream") {
            let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "MediaSourceId" }?.value ?? ""
            streamSources.append(source)
            let parts = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-3").dropFirst(6).split(separator: "-")
            let low = Int(parts[0])!, high = Int(parts[1])!
            return (Data(repeating: source == "source-b" ? 66 : 65, count: high - low + 1),
                HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes \(low)-\(high)/4096"])!)
        }
        if path.contains("/Sessions/Playing") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            reportSources.append(body["MediaSourceId"] as? String ?? "")
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        throw MediaServerError.response
    }
}
