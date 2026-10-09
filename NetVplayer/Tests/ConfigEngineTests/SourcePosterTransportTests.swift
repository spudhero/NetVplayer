import Foundation
import ImageIO
import Networking
import Testing
@testable import ProxyServer

private let posterURL = URL(string: "https://img1.wsyzy.org/upload/vod/fixture/poster.jpg?token=fixture")!
private let posterIPv6 = "2606:4700:4700::1111"
private let secondPosterIPv6 = "2606:4700:4700::1001"

@Test func posterIPv6PreservesURLAndHeadersAndRecoversSecondAddress() async throws {
    let headers = ["Referer": "https://img1.wsyzy.org", "User-Agent": "Fixture", "Cookie": "fixture=1"]
    let result = try await SourceResourceTransport.posterResponse(
        for: posterURL, headers: headers, timeout: 15,
        resolve: { budget in
            #expect(budget <= 3)
            return ["::1", "2001:db8::1", posterIPv6, posterIPv6, secondPosterIPv6]
        }, load: { url, address, actualHeaders, budget in
            #expect(url == posterURL)
            #expect(actualHeaders == headers)
            #expect(budget > 0 && budget <= 4)
            if address == posterIPv6 { throw CurlRangeTransportError(code: 7, message: "fixture connection failure") }
            #expect(address == secondPosterIPv6)
            return HTTPResponse(data: Data([1, 2, 3]), statusCode: 200, finalURL: url)
        }
    )
    #expect(result.data == Data([1, 2, 3]))
}

@Test func posterTransportFallsBackToOrdinaryDNSWhenIPv6IsUnavailable() async throws {
    let probe = PosterTransportProbe()
    let result = try await SourceResourceTransport.posterResponse(
        for: posterURL, headers: [:], timeout: 15,
        resolve: { _ in [posterIPv6] }, load: { url, address, _, budget in
            await probe.record(address)
            if address != nil { throw CurlRangeTransportError(code: 28, message: "fixture timeout") }
            #expect(budget < 15)
            return HTTPResponse(data: Data(), statusCode: 200, finalURL: url)
        }
    )
    #expect(result.statusCode == 200)
    #expect(await probe.routes == [posterIPv6, nil])
}

@Test(arguments: [60, 51, 23])
func posterTransportDoesNotRetryCertificateOrBodyLimitErrors(code: Int32) async throws {
    let probe = PosterTransportProbe()
    do {
        _ = try await SourceResourceTransport.posterResponse(
            for: posterURL, headers: [:], timeout: 15,
            resolve: { _ in [posterIPv6, secondPosterIPv6] }, load: { _, address, _, _ in
                await probe.record(address)
                throw CurlRangeTransportError(code: code, message: "fixture terminal error")
            }
        )
        Issue.record("A terminal transport failure must propagate")
    } catch let error as CurlRangeTransportError { #expect(error.code == code) }
    #expect(await probe.routes == [posterIPv6])
}

@Test func posterTransportRejectsChangedDestinationWithoutRetrying() async throws {
    let probe = PosterTransportProbe()
    do {
        _ = try await SourceResourceTransport.posterResponse(
            for: posterURL, headers: [:], timeout: 15,
            resolve: { _ in [posterIPv6] }, load: { _, address, _, _ in
                await probe.record(address)
                return HTTPResponse(data: Data(), statusCode: 200, finalURL: URL(string: "https://example.com/redirect"))
            }
        )
        Issue.record("A changed destination must be rejected")
    } catch let error as URLError { #expect(error.code == .badServerResponse) }
    #expect(await probe.routes == [posterIPv6])
}

@Test func posterTransportCountsDNSAgainstTheWholeDeadline() async throws {
    do {
        _ = try await SourceResourceTransport.posterResponse(
            for: posterURL, headers: [:], timeout: 0.01,
            resolve: { _ in try await Task.sleep(for: .milliseconds(20)); return [posterIPv6] },
            load: { _, _, _, _ in
                Issue.record("The expired whole-request budget must prevent another connection")
                throw URLError(.unknown)
            }
        )
        Issue.record("An expired deadline must fail")
    } catch let error as URLError { #expect(error.code == .timedOut) }
}

@Test func posterTransportCancellationDoesNotStartAnotherRoute() async throws {
    let probe = PosterTransportProbe()
    do {
        _ = try await SourceResourceTransport.posterResponse(
            for: posterURL, headers: [:], timeout: 15,
            resolve: { _ in [posterIPv6, secondPosterIPv6] }, load: { _, address, _, _ in
                await probe.record(address)
                throw CancellationError()
            }
        )
        Issue.record("Cancellation must propagate")
    } catch is CancellationError {}
    #expect(await probe.routes == [posterIPv6])
}

@Test func posterDNSCoalescesConsumersAndHonorsTTL() async throws {
    let probe = PosterTransportProbe()
    let resolver = SourcePosterAddressResolver { _ in
        await probe.record(nil)
        try await Task.sleep(for: .milliseconds(40))
        return posterDNSResponse(ttl: 1)
    }
    try await withThrowingTaskGroup(of: [String].self) { group in
        for _ in 0..<8 { group.addTask { try await resolver.addresses(timeout: 3) } }
        for try await value in group { #expect(value == [posterIPv6]) }
    }
    #expect(try await resolver.addresses(timeout: 3) == [posterIPv6])
    #expect(await probe.routes.count == 1)
    let uncached = SourcePosterAddressResolver { _ in
        await probe.record(nil)
        return posterDNSResponse(ttl: 0)
    }
    _ = try await uncached.addresses(timeout: 3)
    _ = try await uncached.addresses(timeout: 3)
    #expect(await probe.routes.count == 3)
}

@Test func posterDNSCancellationPreservesAnotherConsumer() async throws {
    let resolver = SourcePosterAddressResolver { _ in
        try await Task.sleep(for: .milliseconds(100))
        return posterDNSResponse(ttl: 1)
    }
    let first = Task { try await resolver.addresses(timeout: 3) }
    let second = Task { try await resolver.addresses(timeout: 3) }
    try await Task.sleep(for: .milliseconds(20))
    first.cancel()
    do { _ = try await first.value; Issue.record("Cancelled consumer must fail") } catch is CancellationError {}
    #expect(try await second.value == [posterIPv6])
}

@Test func posterDNSLastConsumerCancelsLookup() async throws {
    let probe = PosterTransportProbe()
    let resolver = SourcePosterAddressResolver { _ in
        await probe.record(nil)
        do { try await Task.sleep(for: .seconds(30)) } catch {
            await probe.record("cancelled")
            throw error
        }
        return posterDNSResponse(ttl: 1)
    }
    let task = Task { try await resolver.addresses(timeout: 3) }
    while await probe.routes.isEmpty { await Task.yield() }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled consumer must fail") } catch is CancellationError {}
    for _ in 0..<100 where await probe.routes.count < 2 { await Task.yield() }
    #expect(await probe.routes == [nil, "cancelled"])
}

@Test func posterDNSRejectsRedirectsAndPrivateAddresses() async throws {
    let resolver = SourcePosterAddressResolver { _ in
        HTTPResponse(data: Data(#"{"Status":0,"Answer":[{"type":28,"data":"::1","TTL":100}]}"#.utf8),
                     statusCode: 200, finalURL: SourcePosterAddressResolver.endpoint)
    }
    #expect(try await resolver.addresses(timeout: 3).isEmpty)
    let redirected = SourcePosterAddressResolver { _ in
        var response = posterDNSResponse(ttl: 1)
        response = HTTPResponse(data: response.data, statusCode: 200, finalURL: URL(string: "https://example.com/dns"))
        return response
    }
    #expect(try await redirected.addresses(timeout: 3).isEmpty)
}

/// Explicit local QA uses the same production libcurl path, not the system curl binary.
@Test func verifiedGuangyingPostersDecodeThroughProductionTransport() async throws {
    guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_GUANGYING_POSTER_QA_FILE"] else { return }
    struct Sample: Decodable { let url: String }
    let values = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    try await withThrowingTaskGroup(of: Void.self) { group in
        for item in values {
            let url = try #require(URL(string: item.url))
            group.addTask {
                let response = try await SourceResourceTransport.response(
                    for: url, headers: ["Referer": "https://img1.wsyzy.org", "User-Agent": "Mozilla/5.0"], timeout: 15
                )
                #expect(response.statusCode == 200)
                let image = try #require(CGImageSourceCreateWithData(response.data as CFData, nil))
                #expect(CGImageSourceCreateImageAtIndex(image, 0, nil) != nil)
            }
        }
        try await group.waitForAll()
    }
}

private actor PosterTransportProbe {
    var routes: [String?] = []
    func record(_ address: String?) { routes.append(address) }
}

private func posterDNSResponse(ttl: Int) -> HTTPResponse {
    HTTPResponse(data: Data("{\"Status\":0,\"Answer\":[{\"type\":28,\"data\":\"\(posterIPv6)\",\"TTL\":\(ttl)}]}".utf8),
                 statusCode: 200, finalURL: SourcePosterAddressResolver.endpoint)
}
