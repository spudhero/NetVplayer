import Foundation
import Models
import Networking
import ProviderSDK
import ProviderRuntime
import ProxyServer

enum DevelopmentAndroidStreamTransport {
    static func validate(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value), parts.scheme == "http", parts.host == "127.0.0.1",
              let port = parts.port, (1...65535).contains(port), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.hasPrefix("/android-stream/"),
              UUID(uuidString: String(parts.path.dropFirst("/android-stream/".count))) != nil,
              let url = parts.url else { throw DevelopmentAndroidCatVodProxyAdapter.invalidDescriptor() }
        return url
    }

    static func send(_ payload: ProviderProxyPayload, headOnly: Bool,
                     sendHead: @escaping @Sendable (ProxyStreamingResponseHead) async throws -> Void,
                     sendBody: @escaping @Sendable (Data) async throws -> Void) async throws {
        guard let raw = payload.localStreamURL else { throw DevelopmentAndroidCatVodProxyAdapter.invalidDescriptor() }
        let url = try validate(raw)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let http = HTTPClient(session: session, allowedOrigin: url)
        let release: @Sendable () async -> Void = {
            _ = try? await http.request(url: raw, method: .delete, timeout: 3,
                allowsProxyFallback: false, redactsURLInLogs: true, handlesCookies: false)
        }
        do {
            let response = try ProviderProxyResponseAdapter.response(from: payload)
            let length = payload.headers.first { $0.key.lowercased() == "content-length" }.flatMap { Int($0.value) }
            guard length == nil || length! >= 0 else { throw DevelopmentAndroidCatVodProxyAdapter.invalidDescriptor() }
            let head = ProxyStreamingResponseHead(statusCode: response.statusCode, contentType: response.contentType,
                contentLength: length, headers: response.headers, closeConnection: true)
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if headOnly { try await sendHead(head) }
                else {
                    _ = try await http.stream(url: raw, timeout: 60, allowsProxyFallback: false, redactsURLInLogs: true,
                        shouldStream: { stream in
                            guard stream.statusCode == 200, stream.finalURL == url else {
                                throw ProviderErrorPayload(code: "android_proxy_stream_expired", message: "原版媒体流已失效，请重新播放", retryable: true)
                            }
                            try await sendHead(head)
                            return true
                        }, receive: sendBody)
                }
            } onCancel: { Task { await release() } }
            await release()
            session.invalidateAndCancel()
        } catch {
            await release()
            session.invalidateAndCancel()
            throw error
        }
    }
}
