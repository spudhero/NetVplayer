import Darwin
import Foundation
import Models
import Networking

/// This CDN's IPv4 endpoint can close TLS while its published IPv6 endpoint works.
/// Keep the original HTTPS hostname and only resolve this confirmed compatibility case.
enum HLSIPv6Recovery {
    static func supports(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "hd.kuktxu.com"
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    static func isPublicIPv6(_ value: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, value, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        // Global unicast only: exclude mapped IPv4, ULA, link-local and multicast.
        guard bytes[0] & 0xe0 == 0x20,
              Array(bytes.prefix(4)) != [0x20, 0x01, 0x0d, 0xb8],
              let url = URL(string: "https://[\(value)]") else { return false }
        return (try? ProxyAccessPolicy.validateFinalURL(url)) != nil
    }

    static func addresses(from data: Data) -> [String] {
        struct DNSResponse: Decodable {
            struct Answer: Decodable { let type: Int; let data: String }
            let Status: Int
            let Answer: [Answer]?
        }
        guard let result = try? JSONDecoder().decode(DNSResponse.self, from: data),
              result.Status == 0 else { return [] }
        var seen = Set<String>()
        return (result.Answer ?? []).compactMap { answer in
            guard answer.type == 28, isPublicIPv6(answer.data),
                  seen.insert(answer.data).inserted else { return nil }
            return answer.data
        }
    }

    static func response(
        for url: URL,
        headers: [String: String],
        httpClient: HTTPClient,
        timeout: TimeInterval
    ) async throws -> HTTPResponse? {
        guard supports(url) else { return nil }
        do {
            // Fresh lookup avoids pinning rotating CDN endpoints beyond their DNS TTL.
            let dns = try await httpClient.request(
                url: "https://dns.alidns.com/resolve?name=hd.kuktxu.com&type=AAAA",
                method: .get, timeout: min(timeout, 5), redactsURLInLogs: true
            )
            guard dns.statusCode == 200,
                  let address = addresses(from: dns.data).first else { return nil }
            try Task.checkCancellation()
            let result = try await CurlRangeTransport.getHLSOverIPv6(
                url: url, address: address, headers: headers, timeout: timeout
            )
            try ProxyAccessPolicy.validateFinalURL(result.response.finalURL)
            guard (200..<300).contains(result.response.statusCode) else { return nil }
            DiagnosticLog.write("[PROXY_HLS_IPV6] host=hd.kuktxu.com status=\(result.response.statusCode) bytes=\(result.response.data.count)")
            return result.response
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            // Networks without IPv6 retain the ordinary URLSession path.
            DiagnosticLog.write("[PROXY_HLS_IPV6_UNAVAILABLE] host=hd.kuktxu.com errorType=\(type(of: error))")
            return nil
        }
    }
}
