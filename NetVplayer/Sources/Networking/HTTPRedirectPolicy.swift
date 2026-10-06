import Foundation
import Models

/// Shared URLSession redirect rules. Transport remains owned by the request's session.
public enum HTTPRedirectPolicy {
    public static let maximumRedirects = 20

    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    public static func isLoopback(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        let ipv4 = host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
        let parts = ipv4.split(separator: ".", omittingEmptySubsequences: false)
        let loopbackIPv4 = parts.count == 4 && parts.first == "127" && parts.allSatisfy { UInt8($0) != nil }
        return host == "localhost" || host == "::1" || loopbackIPv4
    }

    public static func redirected(_ previous: URLRequest, proposed: URLRequest, status: Int,
                                  allowedOrigin: URL? = nil, hop: Int) -> URLRequest? {
        guard hop <= maximumRedirects, let source = previous.url, let target = proposed.url,
              ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              target.host != nil, target.user == nil, target.password == nil,
              [301, 302, 303, 307, 308].contains(status) else { return nil }
        if let allowedOrigin, !sameOrigin(allowedOrigin, target) { return nil }

        var result = previous
        result.url = target
        result.setValue(nil, forHTTPHeaderField: "Host")
        let method = previous.httpMethod?.uppercased() ?? "GET"
        if (status == 303 && method != "HEAD") || ([301, 302].contains(status) && method == "POST") {
            result.httpMethod = "GET"
            result.httpBody = nil
            result.httpBodyStream = nil
            for field in ["Content-Type", "Content-Length", "Transfer-Encoding"] {
                result.setValue(nil, forHTTPHeaderField: field)
            }
        } else if previous.httpBodyStream != nil {
            return nil // A one-shot stream cannot be safely replayed for 307/308.
        }
        if !sameOrigin(source, target) {
            for field in ["Authorization", "Proxy-Authorization", "Cookie", "X-Api-Key", "X-Auth-Token", "X-Emby-Token", "X-MediaBrowser-Token"] {
                result.setValue(nil, forHTTPHeaderField: field)
            }
        }
        if source.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http" {
            result.setValue(nil, forHTTPHeaderField: "Referer")
        }
        return result
    }
}

public final class HTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let allowedOrigin: URL?
    private var previous: URLRequest?
    private var hops = 0

    public init(initialRequest: URLRequest? = nil, allowedOrigin: URL? = nil) {
        self.previous = initialRequest
        self.allowedOrigin = allowedOrigin
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(redirected(task: task, response: response, proposed: request))
    }

    public func redirected(task: URLSessionTask, response: HTTPURLResponse, proposed request: URLRequest) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        hops += 1
        let previousRequest = previous ?? task.currentRequest ?? task.originalRequest
        let result = previousRequest.flatMap {
            HTTPRedirectPolicy.redirected($0, proposed: request, status: response.statusCode, allowedOrigin: allowedOrigin, hop: hops)
        }
        previous = result
        return result
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        HTTPRangeTransportMetrics.record(task: task, metrics: metrics)
    }
}

private enum HTTPRangeTransportMetrics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var samples = 0

    static func record(task: URLSessionTask, metrics: URLSessionTaskMetrics) {
        guard task.originalRequest?.value(forHTTPHeaderField: "Range") != nil,
              let transaction = metrics.transactionMetrics.last,
              lock.withLock({
                  guard samples < 12 else { return false }
                  samples += 1
                  return true
              }) else { return }
        let wait = transaction.requestStartDate.flatMap { request in
            transaction.fetchStartDate.map { request.timeIntervalSince($0) }
        } ?? 0
        DiagnosticLog.write("[HTTP_RANGE_TRANSPORT] protocol=\(transaction.networkProtocolName ?? "unknown") proxy=\(transaction.isProxyConnection) reused=\(transaction.isReusedConnection) waitMs=\(Int(wait * 1000)) totalMs=\(Int(metrics.taskInterval.duration * 1000))")
    }
}
