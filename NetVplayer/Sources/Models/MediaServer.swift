import Foundation

public enum MediaServerKind: String, Codable, CaseIterable, Sendable {
    case emby, jellyfin, plex, zspace, fnos
    public var title: String {
        switch self {
        case .emby: "Emby"
        case .jellyfin: "Jellyfin"
        case .plex: "Plex"
        case .zspace: "极影视"
        case .fnos: "飞牛影视"
        }
    }
}

/// A configured account, never a display-name or a renewable URL identity.
public struct MediaServerConfiguration: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: MediaServerKind
    public var server: String
    public var serverID: String
    public var userID: String
    /// Display identity only; passwords are never persisted. Optional for legacy configurations.
    public var username: String?
    public var deviceID: UUID
    public var allowsHTTP: Bool
    public init(id: UUID = UUID(), name: String = "", kind: MediaServerKind = .jellyfin,
                server: String = "", serverID: String = "", userID: String = "",
                deviceID: UUID = UUID(), allowsHTTP: Bool = false, username: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.server = server
        self.serverID = serverID; self.userID = userID; self.deviceID = deviceID; self.allowsHTTP = allowsHTTP
        self.username = username
    }
    public func validated() throws -> Self {
        var copy = self
        guard let c = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, ["https", "http"].contains(c.scheme?.lowercased() ?? ""),
              c.scheme?.lowercased() != "http" || allowsHTTP,
              c.port == nil || (1...65535).contains(c.port!) else { throw MediaServerError.configuration }
        copy.server = c.url!.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if kind == .fnos, copy.server.hasSuffix("/v") { copy.server = String(copy.server.dropLast(2)) }
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.name.isEmpty { copy.name = kind.title }
        return copy
    }
    public var credentialBinding: String { [kind.rawValue, server, serverID, userID].joined(separator: "\u{0}") }
    public var siteKey: String { "media-server-" + id.uuidString.lowercased() }
    public func site() -> Site { Site(key: siteKey, name: name, type: 3, api: "netvplayer-server://" + id.uuidString.lowercased(), searchable: 1) }
    public func identity(itemID: String, sourceID: String? = nil) -> PlaybackMediaIdentity {
        .init(source: kind.rawValue, account: [id.uuidString, serverID, userID].joined(separator: "\u{0}"),
              item: itemID + (sourceID.map { "\u{0}source:\($0)" } ?? ""))
    }
}

public struct MediaServerReference: Hashable, Sendable {
    public let accountID: UUID
    public let itemID: String
    public let sourceID: String?
    public init(accountID: UUID, itemID: String, sourceID: String? = nil) throws {
        guard Self.validID(itemID), sourceID.map(Self.validID) != false else { throw MediaServerError.response }
        self.accountID = accountID; self.itemID = itemID; self.sourceID = sourceID
    }
    public static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }
    }
    public var itemLocator: String { "netvplayer-media://" + accountID.uuidString.lowercased() + "/" + itemID }
    public var locator: String { itemLocator + (sourceID.map { "?source=" + $0 } ?? "") }
    public func matchesItem(_ locator: String) -> Bool {
        guard let other = Self(locator: locator) else { return false }
        return accountID == other.accountID && itemID == other.itemID
    }
    public init?(locator: String) {
        guard let c = URLComponents(string: locator), c.scheme == "netvplayer-media", let host = c.host,
              let account = UUID(uuidString: host), c.user == nil, c.password == nil, c.port == nil,
              c.fragment == nil else { return nil }
        let queries = c.queryItems ?? []
        guard c.query == nil || (queries.count == 1 && queries[0].name == "source" && queries[0].value != nil),
              let value = try? Self(accountID: account, itemID: String(c.path.dropFirst()), sourceID: queries.first?.value) else { return nil }
        self = value
    }
}

/// An account-bound image identity. It contains neither a remote URL nor credentials.
public struct MediaServerArtworkReference: Hashable, Sendable {
    public static let scheme = "netvplayer-artwork"
    public let item: MediaServerReference
    public let tag: String
    public enum Kind: String, Codable, Sendable { case primary = "Primary", backdrop = "Backdrop" }
    public let kind: Kind
    public init(item: MediaServerReference, tag: String, kind: Kind = .primary) throws {
        guard MediaServerReference.validID(tag) else { throw MediaServerError.response }
        self.item = item; self.tag = tag; self.kind = kind
    }
    public var locator: String {
        "\(Self.scheme)://\(item.accountID.uuidString.lowercased())/\(item.itemID)/\(tag)" + (kind == .backdrop ? "/Backdrop" : "")
    }
    public init?(locator: String) {
        guard let c = URLComponents(string: locator), c.scheme == Self.scheme, let host = c.host,
              let account = UUID(uuidString: host), c.user == nil, c.password == nil, c.port == nil,
              c.query == nil, c.fragment == nil else { return nil }
        let parts = c.path.split(separator: "/", omittingEmptySubsequences: false)
        guard (parts.count == 3 || (parts.count == 4 && parts[3] == "Backdrop")), parts[0].isEmpty,
              let item = try? MediaServerReference(accountID: account, itemID: String(parts[1])),
              let value = try? Self(item: item, tag: String(parts[2]), kind: parts.count == 4 ? .backdrop : .primary) else { return nil }
        self = value
    }
}

/// Server-provided presentation data, separate from NAS records and playback credentials.
public struct MediaServerDetail: Codable, Sendable {
    public var metadata: MediaMetadata
    public var rating: Double?
    public var officialRating: String?
    public var files: [MediaServerFileDetail]
    public init(metadata: MediaMetadata, rating: Double? = nil, officialRating: String? = nil,
                files: [MediaServerFileDetail] = []) {
        self.metadata = metadata; self.rating = rating; self.officialRating = officialRating; self.files = files
    }
}

public struct MediaServerFileDetail: Codable, Identifiable, Sendable {
    public var id: String
    public var episodeURL: String
    public var name: String
    public var sourceID: String?
    public var supportsOriginalPlayback: Bool?
    public var container: String?
    public var size: Int64?
    public var width: Int?
    public var height: Int?
    public var videoCodec: String?
    public var videoRange: String?
    public var audio: [String]
    public var subtitles: [String]
    public init(id: String, episodeURL: String, name: String, container: String? = nil, size: Int64? = nil,
                width: Int? = nil, height: Int? = nil, videoCodec: String? = nil, videoRange: String? = nil,
                audio: [String] = [], subtitles: [String] = [], sourceID: String? = nil, supportsOriginalPlayback: Bool? = nil) {
        self.id = id; self.episodeURL = episodeURL; self.name = name; self.container = container; self.size = size
        self.width = width; self.height = height; self.videoCodec = videoCodec; self.videoRange = videoRange
        self.audio = audio; self.subtitles = subtitles
        self.sourceID = sourceID; self.supportsOriginalPlayback = supportsOriginalPlayback
    }
    public var playbackLocator: String? {
        guard supportsOriginalPlayback != false, let sourceID,
              let reference = MediaServerReference(locator: episodeURL) else { return nil }
        return try? MediaServerReference(accountID: reference.accountID, itemID: reference.itemID, sourceID: sourceID).locator
    }
}

public struct MediaServerChapter: Sendable {
    public var title: String
    public var seconds: Double
    public init(title: String, seconds: Double) { self.title = title; self.seconds = seconds }
}

/// Trusted in-process ownership. No credentials, media URLs or server session IDs.
public struct MediaServerPlayback: Sendable {
    public let leaseID: UUID
    public let identity: PlaybackMediaIdentity
    public let resumeSeconds: Double
    public let chapters: [MediaServerChapter]
    public let externalSubtitleIndices: [String: Int]
    public init(leaseID: UUID, identity: PlaybackMediaIdentity, resumeSeconds: Double = 0, chapters: [MediaServerChapter] = [], externalSubtitleIndices: [String: Int] = [:]) {
        self.leaseID = leaseID; self.identity = identity; self.resumeSeconds = resumeSeconds; self.chapters = chapters; self.externalSubtitleIndices = externalSubtitleIndices
    }
}

public struct MediaServerPlaybackSnapshot: Equatable, Sendable {
    public var seconds: Double
    public var paused: Bool
    public var muted: Bool
    public var volume: Int
    public var rate: Double
    public var audioIndex: Int?
    public var subtitleIndex: Int?
    public init(seconds: Double = 0, paused: Bool = false, muted: Bool = false, volume: Int = 100,
                rate: Double = 1, audioIndex: Int? = nil, subtitleIndex: Int? = nil) {
        self.seconds = seconds.isFinite ? max(0, min(seconds, Double(Int64.max / 10_000_000) - 1)) : 0
        self.paused = paused; self.muted = muted; self.volume = min(100, max(0, volume))
        self.rate = rate.isFinite && rate > 0 ? min(16, rate) : 1
        self.audioIndex = audioIndex; self.subtitleIndex = subtitleIndex
    }
    public var ticks: Int64 { Int64(seconds * 10_000_000) }
}

public enum MediaServerError: Error, LocalizedError, Equatable {
    case configuration, authentication, response, originalUnavailable, selectedSourceUnavailable, cancelled, http(Int), network(Int)
    public var errorDescription: String? {
        switch self {
        case .configuration: L10n.text("请填写有效的媒体服务器地址；HTTP 须明确启用。")
        case .authentication: L10n.text("媒体服务器登录已失效，请重新连接账号。")
        case .response: L10n.text("媒体服务器响应无效或超出读取上限。")
        case .originalUnavailable: L10n.text("此条目暂不能读取原始文件；当前客户端不请求转码。")
        case .selectedSourceUnavailable: L10n.text("所选版本已不可用或无法原始播放，请刷新详情后重新选择。")
        case .cancelled: L10n.text("媒体服务器播放会话已关闭。")
        case .http(let status): L10n.text("媒体服务器返回 HTTP {0}。", [String(status)])
        case .network(let code): L10n.text("媒体服务器连接失败（{0}）。", [String(code)])
        }
    }
}
