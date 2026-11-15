import Foundation
import Models
import ProviderRuntime
import ProviderSDK
import ProxyServer

/// Fetches only a reference bound from a received original HLS manifest. No
/// source matching, URL edits, alternate lines, or automatic retry is involved.
enum DevelopmentAndroidHLSRemoteTransport {
    static func validate(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              let url = parts.url else { throw DevelopmentAndroidProxyManifest.unsupported() }
        return url
    }

    static func send(url raw: String, headers: [String: String], role: DevelopmentAndroidHLS.Role,
                     headOnly: Bool,
                     mapPlaylist: @escaping @Sendable (ProxyResponse, String) async throws -> ProxyResponse,
                     sendHead: @escaping @Sendable (ProxyStreamingResponseHead) async throws -> Void,
                     sendBody: @escaping @Sendable (Data) async throws -> Void) async throws {
        let url = try validate(raw)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = headOnly ? "HEAD" : "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw DevelopmentAndroidProxyManifest.unsupported() }
            var responseHeaders: [String: String] = [:]
            for (key, value) in http.allHeaderFields { responseHeaders[String(describing: key)] = String(describing: value) }
            // URLSession delivers decoded gzip/deflate/br bytes. Do not relay
            // their encoded length or tell the player to decode them again.
            let encoding = responseHeaders.first { $0.key.lowercased() == "content-encoding" }?.value.lowercased()
            let decoded = encoding.map { ["gzip", "x-gzip", "deflate", "br"].contains($0) } ?? false
            if decoded {
                responseHeaders = responseHeaders.filter { !["content-encoding", "content-length", "content-md5", "digest"].contains($0.key.lowercased()) }
            }
            let rawResponse = try ProviderProxyResponseAdapter.response(from: ProviderProxyPayload(
                statusCode: http.statusCode, contentType: http.mimeType, headers: responseHeaders))
            let length = responseHeaders.first { $0.key.lowercased() == "content-length" }.flatMap { Int($0.value) }
            if role == .playlist && !headOnly {
                var body = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard body.count < 2 * 1024 * 1024 else { throw DevelopmentAndroidProxyManifest.unsupported() }
                    body.append(byte)
                }
                let original = ProxyResponse(statusCode: rawResponse.statusCode, contentType: rawResponse.contentType,
                    data: body, headers: rawResponse.headers, closeConnection: true)
                let mapped = try await mapPlaylist(original, http.url?.absoluteString ?? raw)
                try await sendHead(ProxyStreamingResponseHead(statusCode: mapped.statusCode, contentType: mapped.contentType,
                    contentLength: mapped.data.count, headers: mapped.headers, closeConnection: true))
                if !mapped.data.isEmpty { try await sendBody(mapped.data) }
            } else {
                try await sendHead(ProxyStreamingResponseHead(statusCode: rawResponse.statusCode, contentType: rawResponse.contentType,
                    contentLength: length, headers: rawResponse.headers, closeConnection: true))
                if headOnly { return }
                var chunk = Data()
                chunk.reserveCapacity(64 * 1024)
                var first = true
                for try await byte in bytes {
                    try Task.checkCancellation()
                    chunk.append(byte)
                    // Make the sniff decision promptly; subsequent chunks stay bounded.
                    let limit = first ? DevelopmentAndroidHLS.sniffBytes : 64 * 1024
                    if chunk.count == limit {
                        try await sendBody(chunk)
                        chunk.removeAll(keepingCapacity: true)
                        first = false
                    }
                }
                if !chunk.isEmpty { try await sendBody(chunk) }
            }
        } onCancel: { session.invalidateAndCancel() }
    }
}
