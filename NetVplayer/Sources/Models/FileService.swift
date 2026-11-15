import Foundation

public enum FileServiceKind: String, Codable, CaseIterable, Sendable {
    case webDAV, alist, openList, smb, ftp, sftp, local, cloudDrive
    public var title: String { switch self {
    case .webDAV: "WebDAV"; case .alist: "AList"; case .openList: "OpenList"
    case .smb: "SMB"; case .ftp: "FTP / FTPS"; case .sftp: "SFTP"; case .local: "本地目录"; case .cloudDrive: "网盘目录"
    } }
    public var defaultPort: Int { switch self { case .smb: 445; case .ftp: 21; case .sftp: 22; default: 443 } }
}

/// An account connection, never a cookie or token. Reauthorizing a different account invalidates it.
public struct CloudDirectoryBinding: Codable, Equatable, Sendable {
    public var provider: DriveProvider
    public var accountID: String
    public init(provider: DriveProvider, accountID: String) { self.provider = provider; self.accountID = accountID }
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
    /// OpenSSH SHA256 fingerprint, verified before sending SFTP credentials.
    public var sshHostKeySHA256: String?
    public var cloudDirectory: CloudDirectoryBinding?
    public init(id: UUID = UUID(), name: String = "", kind: FileServiceKind = .webDAV,
                address: String = "", port: Int? = nil, rootPath: String = "/", share: String = "",
                domain: String = "", guest: Bool = false, sshHostKeySHA256: String? = nil,
                cloudDirectory: CloudDirectoryBinding? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.address = address
        self.port = port; self.rootPath = rootPath; self.share = share; self.domain = domain; self.guest = guest
        self.sshHostKeySHA256 = sshHostKeySHA256
        self.cloudDirectory = cloudDirectory
    }
    public var siteKey: String { "files-" + id.uuidString.lowercased() }
    public var endpointIdentity: String {
        let value = "\(kind.rawValue)|\(address)|\(port ?? 0)|\(share)|\(domain)|\(guest)"
        if let cloudDirectory, kind == .cloudDrive { return value + "|" + cloudDirectory.provider.rawValue + "|" + cloudDirectory.accountID }
        return kind == .sftp ? value + "|" + (sshHostKeySHA256 ?? "") : value
    }
    public func validated() throws -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else { throw FileServiceError.invalidConfiguration("请填写服务名称") }
        if let port, !(1...65535).contains(port) { throw FileServiceError.invalidConfiguration("端口须为 1–65535") }
        copy.rootPath = try FileServicePath.normalize(rootPath)
        if kind == .cloudDrive {
            guard let binding = cloudDirectory, [.quark, .uc, .ali, .baidu, .p115].contains(binding.provider),
                  UUID(uuidString: binding.accountID) != nil else {
                throw FileServiceError.invalidConfiguration("请重新选择已登录的网盘账号")
            }
            copy.address = binding.provider.displayName
            copy.port = nil; copy.share = ""; copy.domain = ""; copy.guest = false; copy.sshHostKeySHA256 = nil
        } else if kind != .local {
            var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultScheme: String = switch kind { case .smb: "smb"; case .ftp: "ftp"; case .sftp: "sftp"; default: "https" }
            if !value.contains("://") { value = defaultScheme + "://" + value }
            guard var components = URLComponents(string: value), let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil, components.query == nil,
                  components.fragment == nil else { throw FileServiceError.invalidConfiguration("地址须包含主机，账号密码请单独填写") }
            let schemes: [String] = switch kind { case .smb: ["smb"]; case .ftp: ["ftp", "ftps"]; case .sftp: ["sftp"]; default: ["http", "https"] }
            guard schemes.contains(components.scheme?.lowercased() ?? "") else {
                throw FileServiceError.invalidConfiguration("地址协议与服务类型不符")
            }
            if let port { components.port = port }
            if let resolvedPort = components.port, !(1...65535).contains(resolvedPort) {
                throw FileServiceError.invalidConfiguration("端口须为 1–65535")
            }
            if kind == .ftp || kind == .sftp {
                // Keep endpoint and root separate so relative paths never escape the configured root.
                if !components.path.isEmpty && components.path != "/" {
                    copy.rootPath = try FileServicePath.join(components.path, copy.rootPath)
                }
                components.path = ""
                if kind == .sftp, sshHostKeySHA256?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    copy.sshHostKeySHA256 = nil
                }
                if kind == .sftp, let fingerprint = sshHostKeySHA256?.trimmingCharacters(in: .whitespacesAndNewlines), !fingerprint.isEmpty {
                    let raw = fingerprint.hasPrefix("SHA256:") ? String(fingerprint.dropFirst(7)) : fingerprint
                    let padded = raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)
                    guard let digest = Data(base64Encoded: padded), digest.count == 32 else {
                        throw FileServiceError.invalidConfiguration("SSH 主机指纹须为 SHA256 格式")
                    }
                    copy.sshHostKeySHA256 = "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
                }
            }
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
