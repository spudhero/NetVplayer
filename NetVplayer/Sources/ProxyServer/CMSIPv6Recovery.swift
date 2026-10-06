import Foundation
import Models
import Networking

/// The verified CMS endpoint can fail TLS or time out over IPv4 while its public IPv6 works.
/// Recovery keeps HTTPS/SNI verification, rejects redirects and caps the response at 4 MiB.
public enum CMSIPv6Recovery {
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
        for url: String,
        after error: Error,
        headers: [String: String],
        httpClient: HTTPClient,
        timeout: TimeInterval
    ) async throws -> HTTPResponse? {
        try await recover(for: url, after: error, httpClient: httpClient, timeout: timeout) { url, address in
            try await CurlRangeTransport.getCMSOverIPv6(
                url: url, address: address, headers: headers, timeout: timeout
            ).response
        }
    }

    static func recover(
        for rawURL: String,
        after error: Error,
        httpClient: HTTPClient,
        timeout: TimeInterval,
        load: @Sendable (URL, String) async throws -> HTTPResponse
    ) async throws -> HTTPResponse? {
        guard let url = URL(string: rawURL), shouldAttempt(url, after: error) else { return nil }
        do {
            try Task.checkCancellation()
            // Resolve on each recovery instead of pinning rotating upstream addresses.
            let dns = try await httpClient.request(
                url: "https://dns.alidns.com/resolve?name=api.wsyzy.net&type=AAAA",
                method: .get, timeout: min(timeout, 5), redactsURLInLogs: true
            )
            guard dns.statusCode == 200 else { return nil }
            for address in HLSIPv6Recovery.addresses(from: dns.data).prefix(2) {
                do {
                    try Task.checkCancellation()
                    let response = try await load(url, address)
                    try Task.checkCancellation()
                    guard (200..<300).contains(response.statusCode),
                          let finalURL = response.finalURL,
                          supports(finalURL), finalURL == url else { continue }
                    DiagnosticLog.write("[CMS_IPV6_RECOVERY] host=api.wsyzy.net status=\(response.statusCode) bytes=\(response.data.count)")
                    return response
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                }
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
        }
        // The caller retains the original failure when IPv6 is unavailable.
        return nil
    }
}
