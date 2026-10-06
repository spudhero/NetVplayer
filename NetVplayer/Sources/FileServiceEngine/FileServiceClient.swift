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
        completionHandler(request)
    }
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        HTTPRedirectPolicy.sameOrigin(lhs, rhs)
    }
}

struct FileHTTPTransport: Sendable {
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
