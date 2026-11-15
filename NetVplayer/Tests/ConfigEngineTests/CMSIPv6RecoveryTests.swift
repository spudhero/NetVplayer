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

@Test func sourceResourceTransportDoesNotSpecialCaseUnverifiedPosterCDN() {
    for value in ["https://tupian.ffeiimg.com/upload/vod/20221026-1/fixture.jpg",
                  "http://tupian.ffeiimg.com/upload/vod/a.jpg", "https://tupian.ffeiimg.com:444/upload/vod/a.jpg",
                  "https://tupian.ffeiimg.com.evil.test/upload/vod/a.jpg", "https://user@tupian.ffeiimg.com/upload/vod/a.jpg",
                  "https://tupian.ffeiimg.com/other/a.jpg", "https://tupian.ffeiimg.com/upload/vod/../a.jpg",
                  "https://tupian.ffeiimg.com/upload/vod/a.jpg?target=other", "https://tupian.ffeiimg.com/upload/vod/a.jpg#fragment",
                  "https://tupian.ffeiimg.com/upload/vod/a.html", "https://tupian.ffeiimg.com/upload/vod/a%2Fb.jpg",
                  "https://tupian.ffeiimg.com/upload/vod/a%5Cb.jpg"] {
        #expect(!SourceResourceTransport.supportsPoster(URL(string: value)!))
    }
}

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

@Test(arguments: [true, false])
func testCMSIPv6RecoveryPreservesRequestAndTriesSecondPublicAddress(allowsProxyFallback: Bool) async throws {
    let response = try await CMSIPv6Recovery.recover(
        for: cmsRecoveryURL, after: URLError(.secureConnectionFailed),
        httpClient: cmsRecoveryClient(), timeout: 1, allowsProxyFallback: allowsProxyFallback
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

@Test func testCMSVerifiedIPv6RouteRejectsUnverifiedEndpointsBeforeResolving() async throws {
    for rawURL in ["http://api.wsyzy.net/api.php/provide/vod/", "https://api.wsyzy.net.evil.test/api.php/provide/vod/",
                   "https://api.wsyzy.net:8443/api.php/provide/vod/", "https://user@api.wsyzy.net/api.php/provide/vod/",
                   "https://api.wsyzy.net/other/", "https://api.wsyzy.net/api.php/provide/vod/#fragment"] {
        let response = try await CMSIPv6Recovery.verifiedIPv6Response(
            for: rawURL, headers: [:], httpClient: cmsRecoveryClient(), timeout: 1,
            observation: { _, _, _, _ in Issue.record("An unverified endpoint must not resolve or connect") }
        )
        #expect(response == nil)
    }
}

private actor CMSRaceEvents {
    private var values: [String] = []
    func add(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
    func started() -> Int { values.filter { $0.hasPrefix("start:") }.count }
}

private final class CMSRaceObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, Int?, Int?, Int?)] = []
    func record(_ stage: String, _ status: Int?, _ error: Int?, _ curl: Int?) {
        lock.withLock { values.append((stage, status, error, curl)) }
    }
    func snapshot() -> [(String, Int?, Int?, Int?)] { lock.withLock { values } }
}

private func cmsRaceDNSResponse() -> HTTPResponse {
    // Ignore private/non-AAAA records, deduplicate, then race only the first two public addresses.
    let body = #"{"Status":0,"Answer":[{"type":28,"data":"::1"},{"type":1,"data":"1.1.1.1"},{"type":28,"data":"2606:4700:4700::1111"},{"type":28,"data":"2606:4700:4700::1111"},{"type":28,"data":"2606:4700:4700::1001"},{"type":28,"data":"2001:4860:4860::8888"}]}"#
    return HTTPResponse(data: Data(body.utf8), statusCode: 200,
                        finalURL: URL(string: "https://dns.alidns.com/resolve?name=api.wsyzy.net&type=AAAA"))
}

@Test func testCMSVerifiedIPv6RaceCancelsSlowerSiblingOnFirstValidResponse() async throws {
    let events = CMSRaceEvents()
    let start = ContinuousClock.now
    let response = try await CMSIPv6Recovery.verifiedIPv6Response(
        for: cmsRecoveryURL, timeout: 1, resolve: { timeout in
            #expect(timeout > 0 && timeout <= 1)
            return cmsRaceDNSResponse()
        }, load: { url, address, timeout in
            #expect(timeout > 0 && timeout <= 1)
            await events.add("start:" + address)
            do {
                while await events.started() < 2 { try await Task.sleep(for: .milliseconds(1)) }
                if address == "2606:4700:4700::1111" {
                    try await Task.sleep(for: .seconds(3))
                    Issue.record("A successful sibling must cancel this connection")
                }
            } catch {
                await events.add("cancelled:" + address)
                throw error
            }
            return HTTPResponse(data: Data("original-verified-body".utf8), statusCode: 200, finalURL: url)
        }
    )
    #expect(response?.text == "original-verified-body")
    #expect(response?.finalURL?.absoluteString == cmsRecoveryURL)
    let observed = await events.snapshot()
    #expect(observed.filter { $0.hasPrefix("start:") }.count == 2)
    #expect(observed.contains("cancelled:2606:4700:4700::1111"))
    #expect(start.duration(to: .now) < .seconds(1))
}

@Test func testCMSVerifiedIPv6RaceUsesOneDeadlineIncludingDNS() async throws {
    let events = CMSRaceEvents()
    let start = ContinuousClock.now
    do {
        _ = try await CMSIPv6Recovery.verifiedIPv6Response(
            for: cmsRecoveryURL, timeout: 2, resolve: { timeout in
                #expect(timeout > 0 && timeout <= 2)
                // Leave scheduling headroom while consuming a measurable part
                // of the shared budget before either connection starts.
                try await Task.sleep(for: .milliseconds(250))
                return cmsRaceDNSResponse()
            }, load: { _, address, timeout in
                #expect(timeout > 0 && timeout < 1.8)
                await events.add("start:" + address)
                do { try await Task.sleep(for: .seconds(10)) }
                catch { await events.add("cancelled:" + address); throw error }
                Issue.record("The common deadline must cancel both connections")
                throw URLError(.unknown)
            }
        )
        Issue.record("No connection completed inside the common deadline")
    } catch let error as URLError {
        #expect(error.code == .timedOut)
    }
    let observed = await events.snapshot()
    #expect(observed.filter { $0.hasPrefix("start:") }.count == 2)
    #expect(observed.filter { $0.hasPrefix("cancelled:") }.count == 2)
    #expect(start.duration(to: .now) < .seconds(5))
}

@Test func testCMSVerifiedIPv6RaceNeverAcceptsCertificateFailures() async throws {
    let observations = CMSRaceObservations()
    let response = try await CMSIPv6Recovery.verifiedIPv6Response(
        for: cmsRecoveryURL, timeout: 1, observation: { observations.record($0, $1, $2, $3) },
        resolve: { _ in cmsRaceDNSResponse() }, load: { _, address, _ in
            if address == "2606:4700:4700::1111" {
                throw CurlRangeTransportError(code: 60, message: "fixture certificate verification failed")
            }
            throw URLError(.serverCertificateUntrusted)
        }
    )
    #expect(response == nil)
    let recorded = observations.snapshot()
    #expect(recorded.filter { $0.0 == "ipv6.address.error" }.count == 2)
    #expect(recorded.contains { $0.3 == 60 })
    #expect(recorded.contains { $0.2 == URLError.Code.serverCertificateUntrusted.rawValue })
    #expect(!recorded.contains { $0.0 == "ipv6.address.success" })
}

@Test(arguments: [301, 403, 503, 200])
func testCMSVerifiedIPv6RaceRejectsNonSuccessAndChangedDestination(status: Int) async throws {
    let response = try await CMSIPv6Recovery.verifiedIPv6Response(
        for: cmsRecoveryURL, timeout: 1, resolve: { _ in cmsRaceDNSResponse() }, load: { url, _, _ in
            HTTPResponse(data: Data(), statusCode: status,
                         finalURL: status == 200 ? URL(string: "https://example.com/intercepted") : url)
        }
    )
    #expect(response == nil)
}

@Test func testCMSVerifiedIPv6RacePropagatesCallerCancellationToBothConnections() async throws {
    let events = CMSRaceEvents()
    let task = Task {
        try await CMSIPv6Recovery.verifiedIPv6Response(
            for: cmsRecoveryURL, timeout: 2, resolve: { _ in cmsRaceDNSResponse() }, load: { _, address, _ in
                await events.add("start:" + address)
                do { try await Task.sleep(for: .seconds(3)) }
                catch { await events.add("cancelled:" + address); throw error }
                Issue.record("Caller cancellation must stop both connections")
                throw URLError(.unknown)
            }
        )
    }
    for _ in 0..<200 {
        if await events.started() == 2 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await events.started() == 2)
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await events.snapshot().filter { $0.hasPrefix("cancelled:") }.count == 2)
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
