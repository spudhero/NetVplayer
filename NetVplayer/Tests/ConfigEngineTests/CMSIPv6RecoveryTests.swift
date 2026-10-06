import Foundation
import Models
import Networking
import PlayerEngine
import Testing
@testable import ProxyServer

@Test func sourceResourceTransportOnlyAcceptsVerifiedPosterEndpoint() {
    #expect(SourceResourceTransport.supportsPoster(URL(string: "https://img1.wsyzy.org/upload/vod/202610/a.jpg")!))
    for value in ["http://img1.wsyzy.org/upload/vod/a.jpg", "https://img1.wsyzy.org:444/upload/vod/a.jpg", "https://img1.wsyzy.org.evil.test/upload/vod/a.jpg", "https://user@img1.wsyzy.org/upload/vod/a.jpg", "https://img1.wsyzy.org/other/a.jpg", "https://img1.wsyzy.org/upload/vod/../private/a.jpg"] {
        #expect(!SourceResourceTransport.supportsPoster(URL(string: value)!))
    }
}
private let cmsRecoveryURL = "https://api.wsyzy.net/api.php/provide/vod/?ac=detail&t=6&pg=2"

@Test func testGuangyingPlaybackUsesVerifiedHLSRelayOnly() {
    #expect(PlaybackProxyPolicy.shouldUseLocalHLSProxy(for: PlaySpec(url: "https://v15.wsyzym3u8.com/movie/index.m3u8")))
    #expect(PlaybackProxyPolicy.shouldUseLocalHLSProxy(for: PlaySpec(url: "https://v13.wsyzym3u8.com/movie/index.m3u8")))
    for value in [
        "https://v15.wsyzym3u8.com/movie/video.mp4",
        "https://v15.wsyzym3u8.com.evil.test/movie/index.m3u8",
        "https://v14.wsyzym3u8.com/movie/index.m3u8",
        "http://v15.wsyzym3u8.com/movie/index.m3u8",
        "https://v15.wsyzym3u8.com:8443/movie/index.m3u8",
        "https://user:pass@v15.wsyzym3u8.com/movie/index.m3u8"
    ] {
        #expect(!PlaybackProxyPolicy.shouldUseLocalHLSProxy(for: PlaySpec(url: value)))
    }
}

@Test func testCMSIPv6RecoveryOnlyTargetsVerifiedTLSFailure() throws {
    let url = try #require(URL(string: cmsRecoveryURL))
    #expect(CMSIPv6Recovery.shouldAttempt(url, after: URLError(.secureConnectionFailed)))
    #expect(CMSIPv6Recovery.shouldAttempt(url, after: URLError(.networkConnectionLost)))
    #expect(CMSIPv6Recovery.shouldAttempt(url, after: URLError(.timedOut)))
    for code in [URLError.Code.cancelled, .userAuthenticationRequired,
                 .serverCertificateUntrusted, .serverCertificateHasBadDate, .cannotParseResponse] {
        #expect(!CMSIPv6Recovery.shouldAttempt(url, after: URLError(code)))
    }
    for value in [
        "http://api.wsyzy.net/api.php/provide/vod/",
        "https://api.wsyzy.net.evil.test/api.php/provide/vod/",
        "https://api.wsyzy.net:8443/api.php/provide/vod/",
        "https://user:pass@api.wsyzy.net/api.php/provide/vod/",
        "https://api.wsyzy.net/other", "https://example.com/api.php/provide/vod/"
    ] {
        #expect(!CMSIPv6Recovery.shouldAttempt(try #require(URL(string: value)), after: URLError(.secureConnectionFailed)))
    }
}

@Test func testCMSIPv6RecoveryPreservesRequestAndTriesSecondPublicAddress() async throws {
    let response = try await CMSIPv6Recovery.recover(
        for: cmsRecoveryURL, after: URLError(.secureConnectionFailed),
        httpClient: cmsRecoveryClient(), timeout: 1
    ) { url, address in
        #expect(url.absoluteString == cmsRecoveryURL)
        #expect(["2606:4700:4700::1111", "2606:4700:4700::1001"].contains(address))
        if address == "2606:4700:4700::1111" { throw URLError(.cannotConnectToHost) }
        return HTTPResponse(data: Data(#"{"list":[{"vod_id":"fixture"}]}"#.utf8), statusCode: 200, finalURL: url)
    }
    #expect(response?.statusCode == 200)
    #expect(response?.text.contains("fixture") == true)
}

@Test(arguments: [301, 403, 503, 200])
func testCMSIPv6RecoveryRejectsFailedOrChangedDestinations(status: Int) async throws {
    let response = try await CMSIPv6Recovery.recover(
        for: cmsRecoveryURL, after: URLError(.secureConnectionFailed),
        httpClient: cmsRecoveryClient(), timeout: 1
    ) { url, _ in
        HTTPResponse(data: Data(), statusCode: status,
                     finalURL: status == 200 ? URL(string: "https://example.com/intercepted") : url)
    }
    #expect(response == nil)
}

@Test func testCMSIPv6RecoveryLeavesUnrelatedFailuresUntouched() async throws {
    let response = try await CMSIPv6Recovery.recover(
        for: cmsRecoveryURL, after: URLError(.serverCertificateUntrusted),
        httpClient: cmsRecoveryClient(), timeout: 1
    ) { _, _ in
        Issue.record("A certificate trust failure must not trigger the connection compatibility path")
        throw URLError(.unknown)
    }
    #expect(response == nil)
}

@Test func testCMSIPv6RecoveryPropagatesCancellation() async throws {
    do {
        _ = try await CMSIPv6Recovery.recover(
            for: cmsRecoveryURL, after: URLError(.secureConnectionFailed),
            httpClient: cmsRecoveryClient(), timeout: 1
        ) { _, _ in throw CancellationError() }
        Issue.record("Cancellation must not become an unavailable recovery")
    } catch is CancellationError {
        // Expected: the provider must stop instead of continuing another address.
    }
}

private func cmsRecoveryClient() -> HTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CMSRecoveryDNSProtocol.self]
    return HTTPClient(session: URLSession(configuration: configuration))
}

private final class CMSRecoveryDNSProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              url.absoluteString == "https://dns.alidns.com/resolve?name=api.wsyzy.net&type=AAAA",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let body = #"{"Status":0,"Answer":[{"type":28,"data":"::1"},{"type":1,"data":"1.1.1.1"},{"type":28,"data":"2606:4700:4700::1111"},{"type":28,"data":"2606:4700:4700::1001"}]}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
