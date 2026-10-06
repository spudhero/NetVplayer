import Foundation
import Models
import Storage

public actor AListClient: FileServiceClient {
    private let configuration: FileServiceConfiguration
    private let credentials: FileServiceCredentials
    private let base: URL
    private let transport: FileHTTPTransport
    private let extraHeaders: [String: String]
    private var token: String = ""
    public init(configuration: FileServiceConfiguration, credentials: FileServiceCredentials = .init(), session: URLSession? = nil,
                additionalHeaders: [String: String] = [:],
                requestHandler: (@Sendable (URL, String, [String: String], Data?) async throws -> (Data, HTTPURLResponse))? = nil) throws {
        self.configuration = try configuration.validated(); self.credentials = credentials
        self.base = URL(string: self.configuration.address)!
        self.transport = FileHTTPTransport(session: session, requestHandler: requestHandler); self.extraHeaders = additionalHeaders
    }
    private func absolutePath(_ path: String) throws -> String { try FileServicePath.join(configuration.rootPath, path) }
    public func connect() async throws {
        if !credentials.username.isEmpty { try await login() }
        _ = try await list(path: "/", cursor: nil)
    }
    /// Compatibility adapters share business-status validation and reauthentication with the native file-service client.
    public func requestJSON(endpoint: String, body: Data) async throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw FileServiceError.protocolFailure("无效请求") }
        let result = try await post(endpoint, body: object)
        return try JSONSerialization.data(withJSONObject: ["code": 200, "data": result])
    }
    public func authenticatedHeaders() -> [String: String] {
        var headers = extraHeaders
        if !token.isEmpty { headers["Authorization"] = token }
        return headers
    }
    private func login() async throws {
        guard !credentials.username.isEmpty else { throw FileServiceError.authentication }
        let body = try JSONSerialization.data(withJSONObject: ["username": credentials.username, "password": credentials.password])
        let (data, _) = try await transport.request(base.appendingPathComponent("api/auth/login"), method: "POST",
            headers: extraHeaders.merging(["Content-Type": "application/json"]) { _, new in new }, body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], (object["code"] as? Int) == 200,
              let value = (object["data"] as? [String: Any])?["token"] as? String, !value.isEmpty else { throw FileServiceError.authentication }
        token = value
    }
    private func post(_ endpoint: String, body: [String: Any], retry: Bool = true) async throws -> [String: Any] {
        var headers = extraHeaders; headers["Content-Type"] = "application/json"
        headers["Client-Id"] = "NetVplayer-" + configuration.id.uuidString
        if !token.isEmpty { headers["Authorization"] = token }
        do {
            let payload = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await transport.request(base.appendingPathComponent(endpoint), method: "POST", headers: headers, body: payload)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FileServiceError.protocolFailure("无效 AList/OpenList 响应") }
            let code = object["code"] as? Int ?? 0, message = object["message"] as? String ?? ""
            if code != 200 {
                let expired = code == 401 || message.localizedCaseInsensitiveContains("token") || message.localizedCaseInsensitiveContains("guest user is disabled")
                if expired, retry, !credentials.username.isEmpty {
                    try await login(); return try await post(endpoint, body: body, retry: false)
                }
                if expired { throw FileServiceError.authentication }
                if code == 403 || message.localizedCaseInsensitiveContains("password") { throw FileServiceError.permission(body["path"] as? String ?? "/") }
                if code == 404 { throw FileServiceError.path(body["path"] as? String ?? "/") }
                throw FileServiceError.protocolFailure("AList/OpenList 业务错误 \(code)：\(message)")
            }
            guard let data = object["data"] as? [String: Any] else { throw FileServiceError.protocolFailure("服务未返回目录或文件数据") }
            return data
        } catch FileServiceError.authentication where retry && !credentials.username.isEmpty {
            try await login(); return try await post(endpoint, body: body, retry: false)
        }
    }
    public func list(path: String, cursor: String?) async throws -> FileEntryPage {
        let page = cursor.flatMap(Int.init) ?? 1
        guard page > 0, page < 100000 else { throw FileServiceError.protocolFailure("无效目录分页") }
        let fullPath = try absolutePath(path)
        let data = try await post("api/fs/list", body: ["path": fullPath, "password": credentials.directoryPassword(for: fullPath),
                                                      "page": page, "per_page": 200, "refresh": false])
        let content: [[String: Any]]
        if let values = data["content"] as? [[String: Any]] { content = values }
        else if data["content"] is NSNull, (data["total"] as? NSNumber)?.intValue == 0 { content = [] }
        else { throw FileServiceError.protocolFailure("服务未返回完整目录数据，旧索引已保留") }
        let entries = try content.compactMap { object -> FileEntry? in
            guard let name = object["name"] as? String, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
            let date = (object["modified"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return FileEntry(path: try FileServicePath.join(path, name), name: name, isDirectory: object["is_dir"] as? Bool ?? false,
                             size: (object["size"] as? NSNumber)?.int64Value ?? 0, modifiedAt: date, version: object["hashinfo"] as? String)
        }
        let total = (data["total"] as? NSNumber)?.intValue
        let hasMore = data["has_more"] as? Bool ?? total.map { page * 200 < $0 } ?? (content.count == 200)
        return .init(entries: entries, nextCursor: hasMore ? String(page + 1) : nil)
    }
    private func file(_ path: String) async throws -> [String: Any] {
        let path = try absolutePath(path)
        return try await post("api/fs/get", body: ["path": path, "password": credentials.directoryPassword(for: path)])
    }
    public func stat(path: String) async throws -> FileEntry {
        let object = try await file(path)
        return FileEntry(path: path, name: object["name"] as? String ?? (path as NSString).lastPathComponent,
                         isDirectory: object["is_dir"] as? Bool ?? false, size: (object["size"] as? NSNumber)?.int64Value ?? 0,
                         modifiedAt: (object["modified"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
    }
    public func resolve(path: String) async throws -> ResolvedFileResource {
        let object = try await file(path)
        guard let raw = object["raw_url"] as? String, let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else {
            throw FileServiceError.protocolFailure("服务未返回有效文件播放地址")
        }
        // External object-storage URLs must never receive this service's Authorization header.
        var headers = FileHTTPRedirectDelegate.sameOrigin(base, url) ? extraHeaders : [:]
        if FileHTTPRedirectDelegate.sameOrigin(base, url), !token.isEmpty { headers["Authorization"] = token }
        return .init(url: url, headers: headers)
    }
    public func read(path: String, range: Range<Int64>) async throws -> Data {
        guard !range.isEmpty, range.lowerBound >= 0, range.count <= 4 * 1024 * 1024 else { return Data() }
        let resource = try await resolve(path: path)
        let headers = resource.headers.merging(["Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)"]) { _, new in new }
        let (data, response) = try await transport.request(resource.url, headers: headers, maximumBytes: Int(range.count))
        guard response.statusCode == 206 || range.lowerBound == 0 else { throw FileServiceError.protocolFailure("服务器不支持范围读取") }
        return data
    }
}
