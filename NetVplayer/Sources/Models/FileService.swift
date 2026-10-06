import Foundation

public enum FileServiceKind: String, Codable, CaseIterable, Sendable {
    case webDAV, alist, openList, smb, local
    public var title: String { switch self {
    case .webDAV: "WebDAV"; case .alist: "AList"; case .openList: "OpenList"
    case .smb: "SMB"; case .local: "本地目录"
    } }
    public var defaultPort: Int { self == .smb ? 445 : 443 }
}

public enum MetadataSource: String, Codable, CaseIterable, Sendable {
    case automatic, tmdb, douban, local
    public var title: String { switch self {
    case .automatic: "自动"; case .tmdb: "TMDB"; case .douban: "豆瓣"; case .local: "仅本地"
    } }
}

public enum MediaLibraryKind: String, Codable, CaseIterable, Sendable {
    case movies, television, mixed
    public var title: String { switch self {
    case .movies: "电影"; case .television: "剧集"; case .mixed: "混合"
    } }
}

/// Contains no login credentials. Local access bookmarks stay on this Mac, outside portable backups.
public struct FileServiceConfiguration: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: FileServiceKind
    public var address: String
    public var port: Int?
    public var rootPath: String
    public var share: String
    public var domain: String
    public var guest: Bool
    public init(id: UUID = UUID(), name: String = "", kind: FileServiceKind = .webDAV,
                address: String = "", port: Int? = nil, rootPath: String = "/", share: String = "",
                domain: String = "", guest: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.address = address
        self.port = port; self.rootPath = rootPath; self.share = share; self.domain = domain; self.guest = guest
    }
    public var siteKey: String { "files-" + id.uuidString.lowercased() }
    public var endpointIdentity: String { "\(kind.rawValue)|\(address)|\(port ?? 0)|\(share)|\(domain)|\(guest)" }
    public func validated() throws -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else { throw FileServiceError.invalidConfiguration("请填写服务名称") }
        if let port, !(1...65535).contains(port) { throw FileServiceError.invalidConfiguration("端口须为 1–65535") }
        copy.rootPath = try FileServicePath.normalize(rootPath)
        if kind != .local {
            var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.contains("://") { value = (kind == .smb ? "smb://" : "https://") + value }
            guard var components = URLComponents(string: value), let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil, components.query == nil,
                  components.fragment == nil else { throw FileServiceError.invalidConfiguration("地址须包含主机，账号密码请单独填写") }
            let schemes = kind == .smb ? ["smb"] : ["http", "https"]
            guard schemes.contains(components.scheme?.lowercased() ?? "") else {
                throw FileServiceError.invalidConfiguration("地址协议与服务类型不符")
            }
            if let port { components.port = port }
            if kind == .smb {
                guard !share.isEmpty, !share.contains("/"), !share.contains("\\") else {
                    throw FileServiceError.invalidConfiguration("请填写共享名，例如 Movies")
                }
                components.path = ""; components.port = port ?? components.port ?? 445
            }
            guard let url = components.url else { throw FileServiceError.invalidConfiguration("地址格式无效") }
            copy.address = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return copy
    }
    public func site() -> Site {
        Site(key: siteKey, name: name, type: 3, api: "netvplayer-files://" + id.uuidString.lowercased(), searchable: 0)
    }
}

public struct MediaLibraryConfiguration: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var serviceID: UUID
    public var name: String
    public var path: String
    public var kind: MediaLibraryKind
    public var metadataSource: MetadataSource
    public init(id: UUID = UUID(), serviceID: UUID, name: String, path: String = "/",
                kind: MediaLibraryKind = .mixed, metadataSource: MetadataSource = .automatic) {
        self.id = id; self.serviceID = serviceID; self.name = name; self.path = path
        self.kind = kind; self.metadataSource = metadataSource
    }
}

public enum FileServicePath {
    /// Paths are relative to the configured root. Never permit escaping that root.
    public static func normalize(_ path: String) throws -> String {
        guard !path.contains("\0"), !path.contains("\\") else { throw FileServiceError.path("路径包含无效字符") }
        let parts = path.split(separator: "/")
        guard !parts.contains("..") else { throw FileServiceError.path("路径不能超出服务根目录") }
        return "/" + parts.filter { $0 != "." }.joined(separator: "/")
    }
    public static func join(_ parent: String, _ child: String) throws -> String {
        try normalize(parent + "/" + child)
    }
    public static func parent(_ path: String) -> String {
        "/" + path.split(separator: "/").dropLast().joined(separator: "/")
    }
}

public struct FileResourceReference: Codable, Hashable, Sendable {
    public var serviceID: UUID
    public var libraryID: UUID?
    public var path: String
    public init(serviceID: UUID, libraryID: UUID? = nil, path: String) throws {
        self.serviceID = serviceID; self.libraryID = libraryID; self.path = try FileServicePath.normalize(path)
    }
    public var locator: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "nvfile:" + ((try? encoder.encode(self)) ?? Data()).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    public init?(locator: String) {
        guard locator.hasPrefix("nvfile:"), locator.count < 32768 else { return nil }
        var encoded = String(locator.dropFirst(7)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let value = try? JSONDecoder().decode(Self.self, from: data),
              let normalized = try? FileServicePath.normalize(value.path), normalized == value.path else { return nil }
        self = value
    }
}

public struct FileEntry: Codable, Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var size: Int64
    public var modifiedAt: Date?
    public var version: String?
    public var id: String { path }
    public init(path: String, name: String, isDirectory: Bool, isSymbolicLink: Bool = false,
                size: Int64 = 0, modifiedAt: Date? = nil, version: String? = nil) {
        self.path = path; self.name = name; self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink; self.size = size; self.modifiedAt = modifiedAt; self.version = version
    }
}

public struct FileEntryPage: Sendable {
    public var entries: [FileEntry]
    public var nextCursor: String?
    public init(entries: [FileEntry], nextCursor: String? = nil) { self.entries = entries; self.nextCursor = nextCursor }
}

public enum FileServiceError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String), authentication, permission(String), path(String), network(String)
    case authorizationExpired, unavailable, protocolFailure(String)
    public var errorDescription: String? { switch self {
    case .invalidConfiguration(let text), .protocolFailure(let text): text
    case .authentication: "认证失败，请检查账号和密码"
    case .permission(let text): "目录权限不足：" + text
    case .path(let text): "目录或文件不存在：" + text
    case .network(let text): "连接失败：" + text
    case .authorizationExpired: "目录授权已失效，请重新选择文件夹"
    case .unavailable: "文件来源不可用，请在设置中重新添加服务"
    } }
}
