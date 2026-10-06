import Foundation
import Testing
import ConfigEngine
import Models
import Networking
import Storage
@testable import NetVplayerApp

@Suite("Live source configuration and selection", .serialized)
struct LiveSourceConfigurationTests {
    private let configURL = "https://live-selection.example.test/config.json"
    private let firstURL = "https://live-selection.example.test/first.m3u"
    private let secondURL = "https://live-selection.example.test/second.m3u"
    private let config = """
        {"lives":[
          {"name":"First","url":"./first.m3u","boot":true},
          {"name":"Second","url":"./second.m3u","ua":"FixturePlayer/1.0",
           "referer":"https://live-selection.example.test/","header":{"X-Fixture":"live"},"timeout":7}
        ]}
        """
    private let playlist = """
        #EXTM3U
        #EXTINF:-1 group-title="News",Fixture channel
        https://media.example.test/channel.m3u8
        """

    @MainActor
    @Test func restoresSecondSourceAndPassesItsHeadersToThePlaylistRequest() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.preferences.currentLiveName = "Second"
        LiveSourceURLProtocol.register(configURL, body: config)
        LiveSourceURLProtocol.register(secondURL, body: playlist)
        let state = fixture.makeState()

        #expect(await state.loadLiveConfiguration(url: configURL))
        #expect(state.lives.map(\.name) == ["First", "Second"])
        #expect(state.activeLive?.url == secondURL)
        #expect(state.selectedChannel?.name == "Fixture channel")
        #expect(fixture.preferences.currentLiveConfigUrl == configURL)
        #expect(LiveSourceURLProtocol.requests(firstURL).isEmpty)
        let request = try #require(LiveSourceURLProtocol.requests(secondURL).first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "FixturePlayer/1.0")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://live-selection.example.test/")
        #expect(request.value(forHTTPHeaderField: "X-Fixture") == "live")
        #expect(request.timeoutInterval == 7)
        #expect(state.selectedChannel?.requestHeaders["User-Agent"] == "FixturePlayer/1.0")
    }

    @MainActor
    @Test func failedFirstSourceLeavesOtherSourcesSelectableAndRemembersTheSwitch() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        LiveSourceURLProtocol.register(configURL, body: config)
        LiveSourceURLProtocol.register(firstURL, body: "unavailable", status: 503)
        LiveSourceURLProtocol.register(secondURL, body: playlist)
        let state = fixture.makeState()

        #expect(await state.loadLiveConfiguration(url: configURL))
        #expect(state.lives.count == 2)
        #expect(state.channelGroups.isEmpty)
        #expect(state.liveError != nil)
        #expect(state.liveConfigurationError == nil)
        await state.changeLive(try #require(state.lives.last))
        #expect(state.liveError == nil)
        #expect(state.selectedChannel?.name == "Fixture channel")
        #expect(fixture.preferences.currentLiveName == "Second")

        let reopened = fixture.makeState()
        #expect(await reopened.loadLiveConfiguration(url: fixture.preferences.currentLiveConfigUrl))
        #expect(reopened.activeLive?.name == "Second")
        #expect(LiveSourceURLProtocol.requests(firstURL).count == 1)
    }

    @MainActor
    @Test func directPlaylistUsesItsFirstResponseAndRefreshesWithoutOldSourceMetadata() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        LiveSourceURLProtocol.register(firstURL, body: playlist)
        let state = fixture.makeState()
        state.activeLive = Live(name: "Old", url: secondURL, ua: "OldAgent", referer: "https://old.example.test/")

        #expect(await state.loadLiveConfiguration(url: firstURL))
        #expect(state.lives.count == 1)
        #expect(state.activeLive?.url == firstURL)
        #expect(state.activeLive?.ua == "")
        #expect(state.activeLive?.groups.isEmpty == true)
        #expect(state.channelGroups.first?.channels.first?.referer == "")
        #expect(LiveSourceURLProtocol.requests(firstURL).count == 1)

        LiveSourceURLProtocol.register(firstURL, body: playlist.replacingOccurrences(of: "Fixture channel", with: "Updated channel"))
        #expect(await state.loadLiveContent())
        #expect(state.selectedChannel?.name == "Updated channel")
        #expect(LiveSourceURLProtocol.requests(firstURL).count == 2)
    }

    @MainActor
    @Test func invalidConfigurationPreservesTheWorkingSourceAndSavedAddress() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        LiveSourceURLProtocol.register(firstURL, body: playlist)
        LiveSourceURLProtocol.register(configURL, body: "<html>Not a configuration</html>")
        let state = fixture.makeState()
        #expect(await state.loadLiveConfiguration(url: firstURL))

        #expect(await state.loadLiveConfiguration(url: configURL) == false)
        #expect(state.liveConfigurationError != nil)
        #expect(state.activeLive?.url == firstURL)
        #expect(state.selectedChannel?.name == "Fixture channel")
        #expect(fixture.preferences.currentLiveConfigUrl == firstURL)
    }

    @MainActor
    @Test func inlineSourceNeedsNoPlaylistURL() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let state = fixture.makeState()
        let live = Live(name: "Inline", ua: "InlineAgent", groups: [
            ChannelGroup(name: "News", channels: [Channel(name: "Inline channel", urls: ["https://media.example.test/live.m3u8"])])
        ])
        await state.changeLive(live)
        #expect(state.selectedChannel?.name == "Inline channel")
        #expect(state.selectedChannel?.requestHeaders["User-Agent"] == "InlineAgent")
        #expect(state.liveError == nil)
    }

    @MainActor
    @Test(arguments: [200, 503])
    func lateOldSourceCannotOverwriteChannelsOrClearTheNewLoadingState(oldStatus: Int) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        LiveSourceURLProtocol.register(firstURL, body: playlist.replacingOccurrences(of: "Fixture channel", with: "Old channel"), status: oldStatus, held: true)
        LiveSourceURLProtocol.register(secondURL, body: playlist, held: true)
        let state = fixture.makeState()
        let oldTask = Task { await state.changeLive(Live(name: "First", url: firstURL)) }
        await LiveSourceURLProtocol.waitForRequest(firstURL)
        let newTask = Task { await state.changeLive(Live(name: "Second", url: secondURL)) }
        await LiveSourceURLProtocol.waitForRequest(secondURL)

        LiveSourceURLProtocol.release(firstURL)
        await oldTask.value
        #expect(state.activeLive?.name == "Second")
        #expect(state.isLoadingLive)
        #expect(state.channelGroups.isEmpty)
        #expect(state.liveError == nil)

        LiveSourceURLProtocol.release(secondURL)
        await newTask.value
        #expect(state.selectedChannel?.name == "Fixture channel")
        #expect(!state.isLoadingLive)
        #expect(state.liveError == nil)
    }

    @MainActor
    @Test func vodReloadKeepsTheSeparateLiveConfigurationAndSelection() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.preferences.currentLiveConfigUrl = configURL
        fixture.preferences.currentLiveName = "Second"
        LiveSourceURLProtocol.register(configURL, body: config)
        LiveSourceURLProtocol.register(secondURL, body: playlist)
        let vodURL = "https://live-selection.example.test/vod.json"
        LiveSourceURLProtocol.register(vodURL, body: #"{"sites":[],"lives":[{"name":"VOD Live","url":"https://unused.example.test/live.m3u"}]}"#)
        let state = fixture.makeState()

        await state.loadConfig(url: vodURL, waitForProviderRuntime: false)
        #expect(state.configError == nil)
        #expect(state.lives.map(\.name) == ["First", "Second"])
        #expect(state.activeLive?.name == "Second")
        #expect(state.activeLive?.url == secondURL)
        #expect(fixture.preferences.currentLiveConfigUrl == configURL)
        #expect(LiveSourceURLProtocol.requests(secondURL).count == 1)
    }

    @Test func missingSavedSourceFallsBackToBootThenFirst() throws {
        let sources = [Live(name: "First"), Live(name: "Boot", boot: true), Live(name: "Saved")]
        let input = LiveConfigurationInput(sources: sources, initialGroups: nil)
        #expect(input.selectedSource(preferredName: "Saved")?.name == "Saved")
        #expect(input.selectedSource(preferredName: "Removed")?.name == "Boot")
        #expect(LiveConfigurationInput(sources: [sources[0]], initialGroups: nil)
            .selectedSource(preferredName: "Removed")?.name == "First")
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_REAL_LIVE_CONFIG"] != nil))
    func realUserConfiguredSourceLoadsAndProducesAPlayableSpec() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(environment["NETVPLAYER_REAL_LIVE_CONFIG"])
        let name = try #require(environment["NETVPLAYER_REAL_LIVE_NAME"])
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.preferences.currentLiveName = name
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: fixture.directory),
            userPreferences: fixture.preferences, providerRuntimeBootstrap: nil,
            providerRuntimeRegistrationOverride: { false })
        var spec: PlaySpec?
        state.playSpecHandler = { spec = $0 }
        state.presentLivePlayer()
        defer { state.dismissLivePlayer() }

        #expect(await state.loadLiveConfiguration(url: url))
        #expect(state.activeLive?.name == name)
        #expect(!state.channelGroups.isEmpty)
        #expect(state.liveError == nil)
        let playable = try #require(spec)
        #expect(playable.metadata["playback.kind"] == "live")
        #expect(playable.url.hasPrefix("http"))
        print("[REAL_LIVE] sources=\(state.lives.count) groups=\(state.channelGroups.count) channels=\(state.channelGroups.reduce(0) { $0 + $1.channels.count }) format=\(playable.format)")
    }

    @MainActor
    private struct Fixture {
        let suite = "LiveSourceTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences: UserPreferences
        let client: HTTPClient

        init() {
            preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LiveSourceURLProtocol.self]
            client = HTTPClient(session: URLSession(configuration: configuration))
            LiveSourceURLProtocol.reset()
        }

        func makeState() -> AppState {
            AppState(loadDefaultConfig: false, startProxyServer: false,
                liveHTTPClient: client,
                configResolver: ConfigResolver(httpClient: client, preferences: preferences, allowsProxyFallback: false),
                storageManager: StorageManager(storageDirectory: directory),
                userPreferences: preferences, providerRuntimeBootstrap: nil,
                providerRuntimeRegistrationOverride: { false })
        }

        func close() {
            LiveSourceURLProtocol.reset()
            LiveConfig.shared.clear()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private final class LiveSourceURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Response {
        let body: String
        let status: Int
        let held: Bool
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private static var capturedRequests: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var pending: [String: (LiveSourceURLProtocol, Response)] = [:]
    nonisolated(unsafe) private static var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!.absoluteString
        Self.lock.lock()
        Self.capturedRequests[url, default: []].append(request)
        let response = Self.responses[url] ?? Response(body: "", status: 404, held: false)
        if response.held { Self.pending[url] = (self, response) }
        let waiters = Self.waiters.removeValue(forKey: url) ?? []
        Self.lock.unlock()
        waiters.forEach { $0.resume() }
        if !response.held { complete(response) }
    }

    private func complete(_ response: Response) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func register(_ url: String, body: String, status: Int = 200, held: Bool = false) {
        lock.withLock { responses[url] = Response(body: body, status: status, held: held) }
    }
    static func requests(_ url: String) -> [URLRequest] { lock.withLock { capturedRequests[url] ?? [] } }
    static func waitForRequest(_ url: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if capturedRequests[url]?.isEmpty == false {
                lock.unlock()
                continuation.resume()
            } else {
                waiters[url, default: []].append(continuation)
                lock.unlock()
            }
        }
    }
    static func release(_ url: String) {
        let result = lock.withLock { pending.removeValue(forKey: url) }
        if let (instance, response) = result { instance.complete(response) }
    }
    static func reset() {
        lock.withLock {
            responses = [:]
            capturedRequests = [:]
            pending = [:]
            waiters = [:]
        }
    }
}
