import Foundation
import Models
import Networking

private final class MediaServerHTTPSession: Sendable {
    let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
}

/// Bounded metadata and Range reads; all errors contain numeric status only.
public struct MediaServerTransport: Sendable {
    public typealias Handler = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    private let handler: Handler?
    private let network: MediaServerHTTPSession?
    public init(handler: Handler? = nil) {
        self.handler = handler
        network = handler == nil ? MediaServerHTTPSession() : nil
    }
    public func request(_ request: URLRequest, maximumBytes: Int, origin: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        do {
            let result: (Data, HTTPURLResponse)
            if let handler { result = try await handler(request, maximumBytes) }
            else {
                // Reuse connections across bounded media ranges. Redirect state
                // belongs to this task so concurrent requests cannot share auth.
                let redirects = HTTPRedirectDelegate(initialRequest: request, allowedOrigin: origin,
                    sensitiveURLValues: [request.value(forHTTPHeaderField: "X-Emby-Token") ?? "", request.value(forHTTPHeaderField: "X-Plex-Token") ?? ""])
                let (bytes, response) = try await network!.session.bytes(for: request, delegate: redirects)
                guard let response = response as? HTTPURLResponse else { throw MediaServerError.response }
                guard (200..<300).contains(response.statusCode) else { throw MediaServerError.http(response.statusCode) }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < maximumBytes else { throw MediaServerError.response }
                    data.append(byte)
                }
                result = (data, response)
            }
            try Task.checkCancellation()
            guard result.0.count <= maximumBytes else { throw MediaServerError.response }
            guard (200..<300).contains(result.1.statusCode) else { throw MediaServerError.http(result.1.statusCode) }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as MediaServerError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw MediaServerError.network((error as NSError).code) }
    }
    static func validateRange(_ data: Data, response: HTTPURLResponse, range: Range<Int64>, size: Int64) throws {
        guard Int64(data.count) == range.count else { throw MediaServerError.response }
        if response.statusCode == 200, range.lowerBound == 0, range.upperBound == size { return }
        guard response.statusCode == 206,
              response.value(forHTTPHeaderField: "Content-Range") == "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)" else { throw MediaServerError.response }
    }
}
