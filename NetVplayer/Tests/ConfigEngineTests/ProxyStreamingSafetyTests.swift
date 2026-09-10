import Foundation
import Testing
@testable import PlayerEngine
@testable import ProxyServer

@Test func genericPlaybackRelayOptsIntoStreamingProxy() throws {
    let upstreamURL = "https://media.example.test/opaque-video-object"
    let relayURL = try #require(LiveHLSRelayPolicy.localRelayURL(
        for: upstreamURL,
        headers: ["Referer": "https://media.example.test/play"],
        proxyPort: 9978,
        streaming: true
    ))
    let components = try #require(URLComponents(string: relayURL))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
        ($0.name, $0.value ?? "")
    })

    #expect(components.path == "/proxy")
    #expect(query["stream"] == "1")
    #expect(query["u64"].flatMap(ProxyURLCodec.decode) == upstreamURL)
}

@Test func bufferedProxyResponseLimitStaysBelowNIOCapacity() {
    #expect(ProxyServer.canBufferResponse(byteCount: ProxyServer.maxBufferedResponseBytes))
    #expect(!ProxyServer.canBufferResponse(byteCount: ProxyServer.maxBufferedResponseBytes + 1))
    #expect(ProxyServer.maxBufferedResponseBytes < Int(UInt32.max))
}
