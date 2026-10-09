import Foundation
import Models
import Networking

/// Connection compatibility for the catalog and poster endpoints verified on device.
/// The original hostname, TLS validation, query, size limit and cancellation remain intact.
public enum SourceResourceTransport {
    private static let posterAddresses = SourcePosterAddressResolver()
    public static func supportsCatalog(_ url: URL) -> Bool { CMSIPv6Recovery.supports(url) }

    public static func permitsCatalogRecovery(_ url: URL, after error: Error) -> Bool {
        CMSIPv6Recovery.shouldAttempt(url, after: error)
    }

    public static func supportsPoster(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "img1.wsyzy.org"
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
            && url.path.hasPrefix("/upload/vod/")
            && !url.pathComponents.contains(where: { $0 == "." || $0 == ".." || $0.contains("\\") })
    }

    public static func response(
        for url: URL, headers: [String: String], timeout: TimeInterval
    ) async throws -> HTTPResponse {
        guard CMSIPv6Recovery.supports(url) || supportsPoster(url) else {
            throw URLError(.unsupportedURL)
        }
        if supportsPoster(url) {
            return try await posterResponse(
                for: url, headers: headers, timeout: timeout,
                resolve: { try await posterAddresses.addresses(timeout: $0) },
                load: { url, address, headers, timeout in
                    if let address {
                        return try await CurlRangeTransport.getPosterOverIPv6(
                            url: url, address: address, headers: headers, timeout: timeout
                        ).response
                    }
                    return try await CurlRangeTransport.getSourceResource(
                        url: url, headers: headers, timeout: timeout
                    ).response
                }
            )
        }
        let response = try await CurlRangeTransport.getSourceResource(
            url: url, headers: headers, timeout: timeout
        ).response
        guard response.finalURL == url else { throw URLError(.badServerResponse) }
        return response
    }

    /// System fake-IP DNS can leave this CDN waiting until the entire poster timeout.
    /// Resolve its current public AAAA records, preserving the HTTPS hostname and TLS checks.
    /// All attempts share the caller's deadline; networks without IPv6 retain ordinary DNS.
    static func posterResponse(
        for url: URL, headers: [String: String], timeout: TimeInterval,
        resolve: @Sendable (TimeInterval) async throws -> [String],
        load: @Sendable (URL, String?, [String: String], TimeInterval) async throws -> HTTPResponse
    ) async throws -> HTTPResponse {
        guard supportsPoster(url) else { throw URLError(.unsupportedURL) }
        guard timeout.isFinite, timeout > 0 else { throw URLError(.timedOut) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let addresses: [String]
        do {
            try Task.checkCancellation()
            addresses = try await resolve(min(3, remaining(until: deadline)))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            return try await checkedResponse(url, address: nil, headers: headers, deadline: deadline, load: load)
        }
        var seen = Set<String>()
        for address in addresses.filter({ HLSIPv6Recovery.isPublicIPv6($0) && seen.insert($0).inserted }).prefix(2) {
            do {
                let response = try await checkedResponse(
                    url, address: address, headers: headers, deadline: deadline, load: load
                )
                DiagnosticLog.write("[SOURCE_POSTER_IPV6] host=img1.wsyzy.org status=\(response.statusCode) bytes=\(response.data.count)")
                return response
            } catch {
                try Task.checkCancellation()
                guard retryableConnectionFailure(error) else { throw error }
            }
        }
        return try await checkedResponse(url, address: nil, headers: headers, deadline: deadline, load: load)
    }

    private static func checkedResponse(
        _ url: URL, address: String?, headers: [String: String], deadline: ContinuousClock.Instant,
        load: @Sendable (URL, String?, [String: String], TimeInterval) async throws -> HTTPResponse
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let budget = remaining(until: deadline)
        guard budget > 0 else { throw URLError(.timedOut) }
        let response = try await load(url, address, headers, address == nil ? budget : min(4, budget))
        try Task.checkCancellation()
        guard response.finalURL == url else { throw URLError(.badServerResponse) }
        return response
    }

    private static func remaining(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline).components
        return max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }

    private static func retryableConnectionFailure(_ error: Error) -> Bool {
        if let error = error as? CurlRangeTransportError { return [6, 7, 28, 35, 52, 56].contains(error.code) }
        return [.cannotFindHost, .cannotConnectToHost, .timedOut, .secureConnectionFailed, .networkConnectionLost]
            .contains((error as? URLError)?.code)
    }
}

/// One DNS request serves a visible batch of posters. Cancellation removes only that
/// consumer, and the last consumer cancels the lookup. Cache expiry respects DNS TTL.
actor SourcePosterAddressResolver {
    private struct Answer: Decodable { let type: Int; let data: String; let TTL: Int? }
    private struct DNSResponse: Decodable { let Status: Int; let Answer: [Answer]? }
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<[String], Error>]
    }
    private var cached: (addresses: [String], expires: ContinuousClock.Instant)?
    private var flight: Flight?
    private let lookup: @Sendable (TimeInterval) async throws -> HTTPResponse
    static let endpoint = URL(string: "https://dns.alidns.com/resolve?name=img1.wsyzy.org&type=AAAA")!

    init(lookup: @escaping @Sendable (TimeInterval) async throws -> HTTPResponse = { timeout in
        try await HTTPClient.shared.request(
            url: SourcePosterAddressResolver.endpoint.absoluteString, timeout: timeout,
            allowsProxyFallback: false, redactsURLInLogs: true, handlesCookies: false
        )
    }) {
        self.lookup = lookup
    }

    func addresses(timeout: TimeInterval) async throws -> [String] {
        try Task.checkCancellation()
        if let cached, cached.expires > .now { return cached.addresses }
        let consumer = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if flight != nil {
                    flight?.consumers[consumer] = continuation
                } else {
                    let id = UUID()
                    let task = Task {
                        do {
                            let response = try await lookup(timeout)
                            try Task.checkCancellation()
                            finish(id, response: response)
                        } catch { finish(id, error: error) }
                    }
                    flight = Flight(id: id, task: task, consumers: [consumer: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancel(consumer) }
        }
    }

    private func finish(_ id: UUID, response: HTTPResponse) {
        guard let flight, flight.id == id else { return }
        self.flight = nil
        let body = response.statusCode == 200 && response.finalURL == Self.endpoint && response.data.count <= 65_536
            ? try? JSONDecoder().decode(DNSResponse.self, from: response.data) : nil
        let records = body?.Status == 0 ? (body?.Answer ?? []).filter { $0.type == 28 && HLSIPv6Recovery.isPublicIPv6($0.data) } : []
        var seen = Set<String>()
        let addresses = records.map(\.data).filter { seen.insert($0).inserted }
        let ttl = addresses.isEmpty ? 2 : min(60, max(0, records.map { $0.TTL ?? 0 }.min() ?? 0))
        cached = (addresses, .now.advanced(by: .seconds(ttl)))
        DiagnosticLog.write("[SOURCE_POSTER_DNS] host=img1.wsyzy.org publicIPv6=\(addresses.count) ttl=\(ttl)")
        for consumer in flight.consumers.values { consumer.resume(returning: addresses) }
    }

    private func finish(_ id: UUID, error: Error) {
        guard let flight, flight.id == id else { return }
        self.flight = nil
        for consumer in flight.consumers.values { consumer.resume(throwing: error) }
    }

    private func cancel(_ consumer: UUID) {
        guard let continuation = flight?.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(throwing: CancellationError())
        if flight?.consumers.isEmpty == true {
            flight?.task.cancel()
            flight = nil
        }
    }
}
