import Foundation
import Networking
import Models

public struct ResolvedFileResource: Sendable {
    public var url: URL
    public var headers: [String: String]
    public init(url: URL, headers: [String: String] = [:]) { self.url = url; self.headers = headers }
}

public protocol FileServiceClient: Sendable {
    func connect() async throws
    func list(path: String, cursor: String?) async throws -> FileEntryPage
    func stat(path: String) async throws -> FileEntry
    func read(path: String, range: Range<Int64>) async throws -> Data
    func resolve(path: String) async throws -> ResolvedFileResource
    func disconnect() async
}

public extension FileServiceClient {
    func allEntries(path: String) async throws -> [FileEntry] {
        var entries: [FileEntry] = [], cursor: String?, seenCursors = Set<String>(), seenPaths = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await list(path: path, cursor: cursor)
            let fresh = page.entries.filter { seenPaths.insert($0.path).inserted }
            entries += fresh
            cursor = page.nextCursor
            if let cursor {
                guard seenCursors.insert(cursor).inserted, !fresh.isEmpty else {
                    throw FileServiceError.protocolFailure("服务分页未向前推进，未完成目录读取")
                }
            }
        } while cursor != nil
        return entries
    }
    func disconnect() async {}
}

/// Reject cross-origin redirects before sending service credentials to a different host.
final class FileHTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let next = request.url,
              Self.sameOrigin(original, next) else { completionHandler(nil); return }
        var redirected = request
        // CFNetwork drops explicit Basic credentials even for Apache's same-origin
        // directory slash redirect. Restore them only after the origin check above.
        if let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            redirected.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        HTTPRedirectPolicy.sameOrigin(lhs, rhs)
    }
}

struct FileHTTPTransport: Sendable {
    /// A 206 body belongs to the advertised range, not merely to the same URL.
    /// Short, valid subranges can be retried by the disc reader; shifted or
    /// truncated responses must never enter its shared byte cache.
    static func validateRange(data: Data, response: HTTPURLResponse, requested: Range<Int64>) throws {
        if response.statusCode == 200, requested.lowerBound == 0, data.count <= requested.count { return }
        guard response.statusCode == 206,
              let value = response.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes ") else {
            throw FileServiceError.protocolFailure("服务器不支持范围读取")
        }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        let bounds = parts.first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
        guard parts.count == 2, bounds.count == 2,
              let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start == requested.lowerBound, end >= start, end < requested.upperBound,
              Int64(data.count) == end - start + 1,
              parts[1] == "*" || Int64(parts[1]).map({ $0 > end }) == true else {
            throw FileServiceError.protocolFailure("服务器返回了不匹配的范围数据")
        }
    }
    let session: URLSession
    typealias RequestHandler = @Sendable (URL, String, [String: String], Data?) async throws -> (Data, HTTPURLResponse)
    let requestHandler: RequestHandler?
    init(session: URLSession? = nil, requestHandler: RequestHandler? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: FileHTTPRedirectDelegate(), delegateQueue: nil)
        self.requestHandler = requestHandler
    }
    func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                 maximumBytes: Int = 8 * 1024 * 1024) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = 30; headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        do {
            if let requestHandler {
                let result = try await requestHandler(url, method, headers, body)
                guard result.0.count <= maximumBytes else { throw FileServiceError.protocolFailure("服务响应超出读取上限") }
                if result.1.statusCode == 401 { throw FileServiceError.authentication }
                guard (200..<300).contains(result.1.statusCode) else { throw FileServiceError.protocolFailure("服务返回 HTTP \(result.1.statusCode)") }
                return result
            }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw FileServiceError.protocolFailure("无效 HTTP 响应") }
            switch response.statusCode {
            case 200..<300: break
            case 401: throw FileServiceError.authentication
            case 403: throw FileServiceError.permission(url.lastPathComponent)
            case 404: throw FileServiceError.path(url.lastPathComponent)
            default: throw FileServiceError.protocolFailure("服务返回 HTTP \(response.statusCode)")
            }
            var data = Data()
            for try await byte in bytes {
                if data.count >= maximumBytes { throw FileServiceError.protocolFailure("服务响应超出读取上限") }
                data.append(byte)
            }
            return (data, response)
        } catch let error as FileServiceError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw FileServiceError.network((error as NSError).localizedDescription) }
    }
}
