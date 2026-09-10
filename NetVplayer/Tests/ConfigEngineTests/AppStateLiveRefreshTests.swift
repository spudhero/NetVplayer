import Foundation
import Testing
import Models
import Networking
import PlayerEngine
@testable import NetVplayerApp

@Suite("AppState live content refresh", .serialized)
struct AppStateLiveRefreshTests {
    @MainActor
    @Test func emptyContentResponseRetriesAndResumesAnOpenLivePlayerExactlyOnce() async throws {
        let sourceURL = "https://live-resume.example.test/channels.txt"
        let streamURL = "https://live-resume.example.test/cctv2.m3u8"
        LiveRefreshURLProtocol.reset()
        defer { LiveRefreshURLProtocol.reset() }
        LiveRefreshURLProtocol.register(
            url: sourceURL,
            responses: [
                .init(body: "", statusCode: 200, contentType: "text/plain"),
                .init(
                    body: "央视,#genre#\nCCTV2超清,\(streamURL)\n",
                    statusCode: 200,
                    contentType: "text/plain"
                ),
            ]
        )
        LiveRefreshURLProtocol.register(
            url: streamURL,
            responses: [
                .init(
                    body: "#EXTM3U\n#EXT-X-VERSION:3\n",
                    statusCode: 200,
                    contentType: "application/vnd.apple.mpegurl"
                ),
            ]
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveRefreshURLProtocol.self]
        let appState = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            liveHTTPClient: HTTPClient(session: URLSession(configuration: configuration))
        )
        appState.activeLive = Live(name: "resume-source", url: sourceURL)
        appState.presentLivePlayer()
        defer { appState.dismissLivePlayer() }

        var capturedSpecs: [PlaySpec] = []
        appState.playSpecHandler = { capturedSpecs.append($0) }

        #expect(await appState.loadLiveContentAndResumeIfNeeded())
        #expect(appState.selectedChannel?.name == "CCTV2超清")
        #expect(capturedSpecs.map(\.url) == [streamURL])
        #expect(LiveRefreshURLProtocol.requestCount(for: sourceURL) == 2)
        #expect(LiveRefreshURLProtocol.requestCount(for: streamURL) == 1)
    }

    @MainActor
    @Test func expiredSignedAddressRefreshesChannelListAndRetriesOnce() async throws {
        let sourceURL = "https://live-refresh.example.test/channels.txt"
        let staleURL = "https://live-refresh.example.test/cctv1.m3u8?token=stale"
        let refreshedURL = "https://live-refresh.example.test/cctv1.m3u8?token=fresh"
        let staleList = "央视,#genre#\nCCTV1综合,\(staleURL)\n"
        let refreshedList = "央视,#genre#\nCCTV1综合,\(refreshedURL)\n"

        LiveRefreshURLProtocol.reset()
        defer { LiveRefreshURLProtocol.reset() }
        LiveRefreshURLProtocol.register(
            url: sourceURL,
            responses: [
                .init(body: staleList, statusCode: 200, contentType: "text/plain"),
                .init(body: refreshedList, statusCode: 200, contentType: "text/plain"),
            ]
        )
        LiveRefreshURLProtocol.register(
            url: staleURL,
            responses: [.init(body: "", statusCode: 605, contentType: "text/plain")]
        )
        LiveRefreshURLProtocol.register(
            url: refreshedURL,
            responses: [
                .init(
                    body: "#EXTM3U\n#EXT-X-VERSION:3\n",
                    statusCode: 200,
                    contentType: "application/vnd.apple.mpegurl"
                ),
            ]
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveRefreshURLProtocol.self]
        let httpClient = HTTPClient(session: URLSession(configuration: configuration))
        let appState = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            liveHTTPClient: httpClient
        )
        appState.activeLive = Live(name: "signed-source", url: sourceURL)
        appState.presentLivePlayer()
        defer { appState.dismissLivePlayer() }

        #expect(await appState.loadLiveContent())
        let staleChannel = try #require(appState.channelGroups.first?.channels.first)
        appState.selectedGroup = appState.channelGroups.first

        var capturedSpec: PlaySpec?
        appState.playSpecHandler = { spec in
            capturedSpec = spec
        }
        await appState.playChannel(staleChannel)

        #expect(capturedSpec?.url == refreshedURL)
        #expect(appState.selectedChannel?.urls.first == refreshedURL)
        #expect(LiveRefreshURLProtocol.requestCount(for: sourceURL) == 2)
        #expect(LiveRefreshURLProtocol.requestCount(for: staleURL) == 1)
        #expect(LiveRefreshURLProtocol.requestCount(for: refreshedURL) == 1)
    }

    @MainActor
    @Test func directHLSEOFFallsBackToRelayBeforeRefreshingContent() async throws {
        let sourceURL = "https://live-relay.example.test/channels.txt"
        let streamURL = "https://live-relay.example.test/cctv1.m3u8"
        LiveRefreshURLProtocol.reset()
        defer { LiveRefreshURLProtocol.reset() }
        LiveRefreshURLProtocol.register(
            url: sourceURL,
            responses: [
                .init(
                    body: "央视,#genre#\nCCTV1综合,\(streamURL)\n",
                    statusCode: 200,
                    contentType: "text/plain"
                ),
            ]
        )
        LiveRefreshURLProtocol.register(
            url: streamURL,
            responses: [
                .init(
                    body: "#EXTM3U\n#EXT-X-VERSION:3\n",
                    statusCode: 200,
                    contentType: "application/vnd.apple.mpegurl"
                ),
            ]
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveRefreshURLProtocol.self]
        let appState = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            liveHTTPClient: HTTPClient(session: URLSession(configuration: configuration))
        )
        appState.activeLive = Live(name: "relay-source", url: sourceURL)
        appState.presentLivePlayer()
        defer { appState.dismissLivePlayer() }
        #expect(await appState.loadLiveContent())
        let channel = try #require(appState.channelGroups.first?.channels.first)
        appState.selectedGroup = appState.channelGroups.first

        var capturedSpecs: [PlaySpec] = []
        appState.playSpecHandler = { spec in
            capturedSpecs.append(spec)
        }
        await appState.playChannel(channel)
        let directSpec = try #require(capturedSpecs.first)
        #expect(directSpec.mpvOptions["stream-lavf-o"] == "icy=0")
        appState.livePlayerState.currentSpec = directSpec

        appState.handleMPVPlaybackFailure(
            spec: directSpec,
            message: "直播 HLS 直连加载失败：源站连接被中断，通常是网络路径、源站防护或签名失效导致。已允许本地 relay 兜底。"
        )
        try await Task.sleep(nanoseconds: 1_700_000_000)

        #expect(capturedSpecs.count == 2)
        #expect(capturedSpecs.last?.metadata[LiveHLSRelayPolicy.transportMetadataKey] == LiveHLSRelayPolicy.localRelayTransport)
        #expect(LiveRefreshURLProtocol.requestCount(for: sourceURL) == 1)
    }

    @MainActor
    @Test func liveMPVFailureIsValidatedAgainstLivePlayerState() async throws {
        let sourceURL = "https://live-state.example.test/channels.txt"
        let streamURL = "https://live-state.example.test/cctv1.m3u8"
        LiveRefreshURLProtocol.reset()
        defer { LiveRefreshURLProtocol.reset() }
        LiveRefreshURLProtocol.register(
            url: sourceURL,
            responses: [
                .init(
                    body: "央视,#genre#\nCCTV1综合,\(streamURL)\n",
                    statusCode: 200,
                    contentType: "text/plain"
                ),
            ]
        )
        LiveRefreshURLProtocol.register(
            url: streamURL,
            responses: [
                .init(
                    body: "#EXTM3U\n#EXT-X-VERSION:3\n",
                    statusCode: 200,
                    contentType: "application/vnd.apple.mpegurl"
                ),
            ]
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveRefreshURLProtocol.self]
        let appState = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            liveHTTPClient: HTTPClient(session: URLSession(configuration: configuration))
        )
        appState.activeLive = Live(name: "state-source", url: sourceURL)
        appState.presentLivePlayer()
        defer { appState.dismissLivePlayer() }
        #expect(await appState.loadLiveContent())
        let channel = try #require(appState.channelGroups.first?.channels.first)
        appState.selectedGroup = appState.channelGroups.first

        var capturedSpec: PlaySpec?
        appState.playSpecHandler = { spec in
            capturedSpec = spec
        }
        await appState.playChannel(channel)
        let spec = try #require(capturedSpec)
        appState.livePlayerState.currentSpec = spec

        appState.handleMPVPlaybackFailure(
            spec: spec,
            message: "mpv 播放结束但返回错误: unrecognized file format"
        )
        try await Task.sleep(nanoseconds: 1_700_000_000)

        #expect(appState.liveError?.contains("播放器加载失败") == true)
    }
}

private final class LiveRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let body: String
        let statusCode: Int
        let contentType: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: [Response]] = [:]
    nonisolated(unsafe) private static var requestCounts: [String: Int] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        guard let responseSpec = Self.nextResponse(for: url.absoluteString) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: responseSpec.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": responseSpec.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseSpec.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func register(url: String, responses newResponses: [Response]) {
        lock.lock()
        defer { lock.unlock() }
        responses[url] = newResponses
    }

    static func requestCount(for url: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[url, default: 0]
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses = [:]
        requestCounts = [:]
    }

    private static func nextResponse(for url: String) -> Response? {
        lock.lock()
        defer { lock.unlock() }
        requestCounts[url, default: 0] += 1
        guard var queued = responses[url], !queued.isEmpty else { return nil }
        let next = queued.removeFirst()
        responses[url] = queued
        return next
    }
}
