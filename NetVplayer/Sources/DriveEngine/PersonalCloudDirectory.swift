import Foundation
import Models
import Networking

/// An item in the authenticated user's drive. No share transfer or temporary file is involved.
public struct CloudDirectoryEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let parentID: String
    public let driveID: String
    public let pickCode: String
    public let path: String
    public let size: Int64
    public let isDirectory: Bool

    public init(id: String, name: String, parentID: String = "", driveID: String = "",
                pickCode: String = "", path: String = "", size: Int64 = 0, isDirectory: Bool) {
        self.id = id; self.name = name; self.parentID = parentID; self.driveID = driveID
        self.pickCode = pickCode; self.path = path; self.size = max(0, size); self.isDirectory = isDirectory
    }
}

public struct CloudDirectoryPage: Sendable {
    public let entries: [CloudDirectoryEntry]
    public let nextCursor: String?
    public let driveID: String
    public let updatedCredential: CloudCredential?

    public init(entries: [CloudDirectoryEntry], nextCursor: String? = nil, driveID: String = "",
                updatedCredential: CloudCredential? = nil) {
        self.entries = entries; self.nextCursor = nextCursor; self.driveID = driveID
        self.updatedCredential = updatedCredential
    }
}

/// Read-only directory and original-file APIs shared by the folder picker and file-service adapter.
public struct PersonalCloudDirectoryClient: Sendable {
    public static let supportedProviders: [DriveProvider] = [.quark, .uc, .ali, .baidu, .p115]
    private let quark: QuarkDriveClient
    private let uc: UCDriveClient
    private let ali: AliDriveClient
    private let baidu: BaiduDriveClient
    private let p115: P115DriveClient

    public init(httpClient: HTTPClient = .shared) {
        quark = .init(httpClient: httpClient); uc = .init(httpClient: httpClient)
        ali = .init(httpClient: httpClient); baidu = .init(httpClient: httpClient)
        p115 = .init(httpClient: httpClient)
    }

    public static func rootID(for provider: DriveProvider) -> String {
        provider == .baidu ? "/" : provider == .ali ? "root" : "0"
    }

    public func list(folderID: String, driveID: String = "", cursor: String? = nil,
                     credential: CloudCredential) async throws -> CloudDirectoryPage {
        try Task.checkCancellation()
        try Self.validate(credential)
        guard !folderID.isEmpty else { throw DriveEngineError.unsupported("网盘目录标识为空") }
        let page: CloudDirectoryPage
        switch credential.provider {
        case .quark: page = try await quark.personalDirectory(folderID: folderID, cursor: cursor, credential: credential)
        case .uc: page = try await uc.personalDirectory(folderID: folderID, cursor: cursor, credential: credential)
        case .ali: page = try await ali.personalDirectory(folderID: folderID, driveID: driveID, cursor: cursor, credential: credential)
        case .baidu: page = try await baidu.personalDirectory(folderID: folderID, cursor: cursor, credential: credential)
        case .p115: page = try await p115.personalDirectory(folderID: folderID, cursor: cursor, credential: credential)
        default: throw DriveEngineError.unsupported("此网盘暂不支持个人目录")
        }
        try Task.checkCancellation()
        guard page.entries.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
              Set(page.entries.map(\.id)).count == page.entries.count,
              page.nextCursor == nil || (!page.entries.isEmpty && page.nextCursor != cursor) else {
            throw DriveMappingVerification.unconfirmed(credential.provider)
        }
        return page
    }

    public func download(entry: CloudDirectoryEntry, credential: CloudCredential) async throws -> CloudDriveLink {
        try Task.checkCancellation()
        try Self.validate(credential)
        guard !entry.isDirectory, !entry.id.isEmpty else { throw DriveEngineError.noDownloadURL(entry.name) }
        let link: CloudDriveLink
        switch credential.provider {
        case .quark: link = try await quark.personalDirectoryDownload(entry: entry, credential: credential)
        case .uc: link = try await uc.personalDirectoryDownload(entry: entry, credential: credential)
        case .ali: link = try await ali.personalDirectoryDownload(entry: entry, credential: credential)
        case .baidu: link = try await baidu.personalDirectoryDownload(entry: entry, credential: credential)
        case .p115: link = try await p115.personalDirectoryDownload(entry: entry, credential: credential)
        default: throw DriveEngineError.unsupported("此网盘暂不支持个人目录")
        }
        try Task.checkCancellation()
        // This contract supplies byte ranges for the original file. A transcoded playlist
        // has a different size and cannot masquerade as that seekable resource.
        guard let url = URL(string: link.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.pathExtension.lowercased() != "m3u8", !url.path.lowercased().contains("/m3u8/") else {
            throw DriveEngineError.noDownloadURL(entry.name)
        }
        return link
    }

    private static func validate(_ credential: CloudCredential) throws {
        guard supportedProviders.contains(credential.provider) else {
            throw DriveEngineError.unsupported("此网盘暂不支持个人目录")
        }
        if credential.provider != .ali {
            guard credential.kind == .cookie, !credential.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DriveEngineError.loginRequired(credential.provider)
            }
        }
    }
}

enum CloudDirectoryPaging {
    static func integer(_ cursor: String?, first: Int, provider: DriveProvider) throws -> Int {
        guard let cursor else { return first }
        guard let value = Int(cursor), value >= first, value < Int.max / 1000 else {
            throw DriveEngineError.unsupported("无效的网盘分页标识")
        }
        return value
    }

    static func hasNext(count: Int, offset: Int, limit: Int, total: Int?, hasMore: Bool = false,
                        provider: DriveProvider) throws -> Bool {
        guard count <= limit, total.map({ $0 >= 0 && $0 >= offset + count }) ?? true else {
            throw DriveMappingVerification.unconfirmed(provider)
        }
        let more = hasMore || (total.map({ offset + count < $0 }) ?? (count == limit))
        guard !more || count == limit else { throw DriveMappingVerification.unconfirmed(provider) }
        return more
    }

    static func updatedCookie(_ cookie: String, credential: CloudCredential) -> CloudCredential {
        var updated = credential
        if !cookie.isEmpty { updated.secret = cookie }
        updated.updatedAt = Date()
        return updated
    }

    static func metadata(_ entry: CloudDirectoryEntry, provider: DriveProvider) -> [String: String] {
        [DrivePlaybackMetadataKey.provider: provider.rawValue,
         DrivePlaybackMetadataKey.personalFileID: entry.id,
         DrivePlaybackMetadataKey.driveID: entry.driveID,
         DrivePlaybackMetadataKey.size: String(entry.size),
         DrivePlaybackMetadataKey.route: DrivePlaybackRoute.originalDownload,
         DrivePlaybackMetadataKey.temporarySavedFile: "false"]
    }
}
