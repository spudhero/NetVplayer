import Foundation
import Models
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

@Test func proxyRequestCancellationDoesNotReportPlaybackExitAsAServerFailure() throws {
    let error = URLError(.networkConnectionLost)
    #expect(ProxyHTTPHandler.requestFailureDiagnosticMeasurements(
        for: error, taskIsCancelled: true, channelIsActive: true
    ) == nil)
    #expect(ProxyHTTPHandler.requestFailureDiagnosticMeasurements(
        for: error, taskIsCancelled: false, channelIsActive: false
    ) == nil)
    let measurements = try #require(ProxyHTTPHandler.requestFailureDiagnosticMeasurements(
        for: error, taskIsCancelled: false, channelIsActive: true
    ))
    #expect(measurements == ["errorKind": 4, "code": -1005])
    let fields = measurements.keys.sorted().map { "\($0)=\(measurements[$0]!)" }.joined(separator: " ")
    let record = try #require(RemoteDiagnosticRecord(localMessage:
        "[PROXY_SERVER_ERROR] \(fields) url=https://private.invalid/token"
    ))
    #expect(record.isError)
    #expect(record.measurements == measurements)
    #expect(record.fingerprint == ["netvplayer", "PROXY_SERVER_ERROR", "errorKind:4", "code:-1005"])
}

@Test func unknownProxyErrorsRetainNumericCodesWithoutPrivateDetails() {
    let error = NSError(domain: "private-sentinel", code: 310, userInfo: [
        NSLocalizedDescriptionKey: "private URL and credentials",
    ])
    #expect(ProxyHTTPHandler.remoteDiagnosticMeasurements(for: error) == ["errorKind": 0, "errorCode": 310])
}
