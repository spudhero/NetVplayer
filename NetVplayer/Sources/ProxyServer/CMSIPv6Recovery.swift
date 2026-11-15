import Foundation
import Models
import Networking

/// The verified CMS endpoint can fail TLS or time out over IPv4 while its public IPv6 works.
/// Recovery keeps HTTPS/SNI verification, rejects redirects and caps the response at 4 MiB.
public enum CMSIPv6Recovery {
    /// Only stage names and numeric metadata; no endpoint, query, address or header values.
    public typealias Observation = @Sendable (String, Int?, Int?, Int?) -> Void
    static func supports(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "api.wsyzy.net"
            && (url.port == nil || url.port == 443)
            && URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/api.php/provide/vod/"
            && url.user == nil && url.password == nil
    }

    static func shouldAttempt(_ url: URL, after error: Error) -> Bool {
        supports(url) && [.secureConnectionFailed, .networkConnectionLost, .timedOut].contains((error as? URLError)?.code)
    }

    public static func response(
        for url: String, after error: Error, headers: [String: String],
        httpClient: HTTPClient, timeout: TimeInterval
    ) async throws -> HTTPResponse? {
        try await response(for: url, after: error, headers: headers, httpClient: httpClient,
                           timeout: timeout, allowsProxyFallback: true)
    }

    public static func response(
        for url: String,
        after error: Error,
        headers: [String: String],
        httpClient: HTTPClient,
        timeout: TimeInterval,
        allowsProxyFallback: Bool
    ) async throws -> HTTPResponse? {
        try await recover(for: url, after: error, httpClient: httpClient, timeout: timeout,
                          allowsProxyFallback: allowsProxyFallback) { url, address in
            try await CurlRangeTransport.getCMSOverIPv6(
                url: url, address: address, headers: headers, timeout: timeout
            ).response
        }
    }

    /// Select the already verified IPv6 route without first exhausting an IPv4 request.
    public static func verifiedIPv6Response(
        for rawURL: String, headers: [String: String], httpClient: HTTPClient,
        timeout: TimeInterval, allowsProxyFallback: Bool = false, observation: Observation? = nil
    ) async throws -> HTTPResponse? {
        let dnsURL = URL(string: "https://dns.alidns.com/resolve?name=api.wsyzy.net&type=AAAA")!
        let dnsClient = allowsProxyFallback ? httpClient : httpClient.constrained(to: dnsURL)
        return try await verifiedIPv6Response(
            for: rawURL, timeout: timeout, observation: observation,
            resolve: { remaining in
                try await dnsClient.request(
                    url: dnsURL.absoluteString, method: .get, timeout: remaining,
                    allowsProxyFallback: allowsProxyFallback, redactsURLInLogs: true
                )
            }, load: { url, address, remaining in
                try await CurlRangeTransport.getCMSOverIPv6(
                    url: url, address: address, headers: headers, timeout: remaining
                ).response
            }
        )
    }

    /// The development helper has a short loopback read timeout. DNS and at most
    /// two concurrent verified connections share one deadline, including curl's timeout.
    static func verifiedIPv6Response(
        for rawURL: String, timeout: TimeInterval, observation: Observation? = nil,
        resolve: @escaping @Sendable (TimeInterval) async throws -> HTTPResponse,
        load: @escaping @Sendable (URL, String, TimeInterval) async throws -> HTTPResponse
    ) async throws -> HTTPResponse? {
        guard let url = URL(string: rawURL), supports(url), url.fragment == nil else { return nil }
        guard timeout.isFinite, timeout > 0 else { throw URLError(.timedOut) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        return try await withThrowingTaskGroup(of: HTTPResponse?.self) { group in
            group.addTask {
                let dns: HTTPResponse
                do {
                    try Task.checkCancellation()
                    observation?("dns.begin", nil, nil, nil)
                    let budget = remaining(until: deadline)
                    guard budget > 0 else { throw URLError(.timedOut) }
                    dns = try await resolve(min(3, budget))
                    try Task.checkCancellation()
                    observation?("dns.complete", dns.statusCode, nil, nil)
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                    observation?("dns.error", nil, (error as NSError).code, nil)
                    return nil
                }
                guard dns.statusCode == 200, dns.data.count <= 65_536,
                      dns.finalURL?.absoluteString == "https://dns.alidns.com/resolve?name=api.wsyzy.net&type=AAAA" else { return nil }
                var seen = Set<String>()
                let addresses = Array(HLSIPv6Recovery.addresses(from: dns.data)
                    .filter { seen.insert($0).inserted }.prefix(2))
                if addresses.isEmpty { observation?("dns.no-address", nil, nil, nil) }
                return try await raceVerifiedAddresses(
                    url: url, addresses: addresses, deadline: deadline, observation: observation, load: load
                )
            }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { return nil }
            return response
        }
    }

    private static func raceVerifiedAddresses(
        url: URL, addresses: [String], deadline: ContinuousClock.Instant, observation: Observation?,
        load: @escaping @Sendable (URL, String, TimeInterval) async throws -> HTTPResponse
    ) async throws -> HTTPResponse? {
        try await withThrowingTaskGroup(of: HTTPResponse?.self) { group in
            for address in addresses {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let budget = remaining(until: deadline)
                        guard budget > 0 else { throw URLError(.timedOut) }
                        observation?("ipv6.address.begin", nil, nil, nil)
                        let response = try await load(url, address, budget)
                        try Task.checkCancellation()
                        guard (200..<300).contains(response.statusCode), response.finalURL == url,
                              response.data.count <= 4 * 1024 * 1024 else {
                            observation?("ipv6.address.rejected", response.statusCode, nil, nil)
                            return nil
                        }
                        observation?("ipv6.address.success", response.statusCode, nil, nil)
                        return response
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                        observation?("ipv6.address.error", nil, (error as NSError).code,
                                     (error as? CurlRangeTransportError).map { Int($0.code) })
                        return nil
                    }
                }
            }
            defer { group.cancelAll() }
            while let response = try await group.next() {
                if let response {
                    try Task.checkCancellation()
                    return response
                }
            }
            try Task.checkCancellation()
            return nil
        }
    }

    private static func remaining(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let value = ContinuousClock.now.duration(to: deadline).components
        return max(0, Double(value.seconds) + Double(value.attoseconds) / 1e18)
    }

    static func recover(
        for rawURL: String, after error: Error, httpClient: HTTPClient, timeout: TimeInterval,
        load: @Sendable (URL, String) async throws -> HTTPResponse
    ) async throws -> HTTPResponse? {
        try await recover(for: rawURL, after: error, httpClient: httpClient, timeout: timeout,
                          allowsProxyFallback: true, load: load)
    }

    static func recover(
        for rawURL: String,
        after error: Error,
        httpClient: HTTPClient,
        timeout: TimeInterval,
        allowsProxyFallback: Bool,
        load: @Sendable (URL, String) async throws -> HTTPResponse
    ) async throws -> HTTPResponse? {
        guard let url = URL(string: rawURL), shouldAttempt(url, after: error) else { return nil }
        return try await resolvedResponse(for: url, httpClient: httpClient, timeout: timeout,
                                          allowsProxyFallback: allowsProxyFallback, observation: nil, load: load)
    }

    private static func resolvedResponse(
        for url: URL, httpClient: HTTPClient, timeout: TimeInterval, allowsProxyFallback: Bool,
        observation: Observation?, load: @Sendable (URL, String) async throws -> HTTPResponse
    ) async throws -> HTTPResponse? {
        do {
            try Task.checkCancellation()
            observation?("dns.begin", nil, nil, nil)
            // Resolve on each recovery instead of pinning rotating upstream addresses.
            let dnsURL = "https://dns.alidns.com/resolve?name=api.wsyzy.net&type=AAAA"
            let dnsClient = allowsProxyFallback ? httpClient : httpClient.constrained(to: URL(string: dnsURL)!)
            let dns = try await dnsClient.request(
                url: dnsURL,
                method: .get, timeout: min(timeout, 5), allowsProxyFallback: allowsProxyFallback,
                redactsURLInLogs: true
            )
            observation?("dns.complete", dns.statusCode, nil, nil)
            guard dns.statusCode == 200 else { return nil }
            let addresses = HLSIPv6Recovery.addresses(from: dns.data).prefix(2)
            if addresses.isEmpty { observation?("dns.no-address", nil, nil, nil) }
            for address in addresses {
                do {
                    try Task.checkCancellation()
                    observation?("ipv6.address.begin", nil, nil, nil)
                    let response = try await load(url, address)
                    try Task.checkCancellation()
                    guard (200..<300).contains(response.statusCode),
                          let finalURL = response.finalURL,
                          supports(finalURL), finalURL == url else {
                        observation?("ipv6.address.rejected", response.statusCode, nil, nil)
                        continue
                    }
                    observation?("ipv6.address.success", response.statusCode, nil, nil)
                    DiagnosticLog.write("[CMS_IPV6_RECOVERY] host=api.wsyzy.net status=\(response.statusCode) bytes=\(response.data.count)")
                    return response
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                    observation?("ipv6.address.error", nil, (error as NSError).code,
                                 (error as? CurlRangeTransportError).map { Int($0.code) })
                }
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            observation?("dns.error", nil, (error as NSError).code, nil)
        }
        // The caller retains the original failure when IPv6 is unavailable.
        return nil
    }
}
