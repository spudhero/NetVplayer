import Foundation
import Networking

/// Connection compatibility for the catalog and poster endpoints verified on device.
/// The original hostname, TLS validation, query, size limit and cancellation remain intact.
public enum SourceResourceTransport {
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
        let response = try await CurlRangeTransport.getSourceResource(
            url: url, headers: headers, timeout: timeout
        ).response
        guard response.finalURL == url else { throw URLError(.badServerResponse) }
        return response
    }
}
