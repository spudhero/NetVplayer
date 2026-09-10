// Models/History.swift
// 播放历史模型，对应 FongMi: bean/History.java

import Foundation
import CryptoKit

/// 播放历史记录
public struct History: Codable, Identifiable, Equatable, Sendable {
    public var key: String         // siteKey + vodId 组合键
    public var siteKey: String
    public var vodId: String
    public var vodPic: String
    public var vodName: String
    public var vodFlag: String
    public var vodRemarks: String
    public var episodeUrl: String
    public var episodeKey: String
    public var episodeName: String
    public var revSort: Bool       // 是否倒序
    public var revPlay: Bool       // 是否反向播放
    public var opening: Int64      // 片头跳过时间(ms)
    public var ending: Int64       // 片尾跳过时间(ms)
    public var position: Int64     // 播放位置(ms)
    public var duration: Int64     // 总时长(ms)
    public var speed: Float        // 播放倍速
    public var scale: Int          // 画面比例
    public var driveProvider: String
    public var driveReferenceURL: String
    public var driveRoute: String
    public var configId: Int
    public var createTime: Date

    public var id: String { key }

    public init(
        key: String = "",
        siteKey: String = "",
        vodId: String = "",
        vodPic: String = "",
        vodName: String = "",
        vodFlag: String = "",
        vodRemarks: String = "",
        episodeUrl: String = "",
        episodeKey: String = "",
        episodeName: String = "",
        revSort: Bool = false,
        revPlay: Bool = false,
        opening: Int64 = 0,
        ending: Int64 = 0,
        position: Int64 = 0,
        duration: Int64 = 0,
        speed: Float = 1.0,
        scale: Int = 0,
        driveProvider: String = "",
        driveReferenceURL: String = "",
        driveRoute: String = "",
        configId: Int = 0,
        createTime: Date = Date()
    ) {
        self.key = key
        self.siteKey = siteKey
        self.vodId = vodId
        self.vodPic = vodPic
        self.vodName = vodName
        self.vodFlag = vodFlag
        self.vodRemarks = vodRemarks
        self.episodeUrl = episodeUrl
        self.episodeKey = episodeKey.isEmpty
            ? HistoryPersistencePolicy.episodeKey(
                siteKey: siteKey,
                vodId: vodId,
                vodFlag: vodFlag,
                episodeURL: episodeUrl
            )
            : episodeKey
        self.episodeName = episodeName
        self.revSort = revSort
        self.revPlay = revPlay
        self.opening = opening
        self.ending = ending
        self.position = position
        self.duration = duration
        self.speed = speed
        self.scale = scale
        self.driveProvider = driveProvider
        self.driveReferenceURL = driveReferenceURL
        self.driveRoute = driveRoute
        self.configId = configId
        self.createTime = createTime
    }

    enum CodingKeys: String, CodingKey {
        case key, siteKey, vodId, vodPic, vodName, vodFlag, vodRemarks, episodeUrl, episodeKey, episodeName
        case revSort, revPlay, opening, ending, position, duration, speed, scale
        case driveProvider, driveReferenceURL, driveRoute, configId, createTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.siteKey = try container.decodeIfPresent(String.self, forKey: .siteKey) ?? ""
        self.vodId = try container.decodeIfPresent(String.self, forKey: .vodId) ?? ""
        self.vodPic = try container.decodeIfPresent(String.self, forKey: .vodPic) ?? ""
        self.vodName = try container.decodeIfPresent(String.self, forKey: .vodName) ?? ""
        self.vodFlag = try container.decodeIfPresent(String.self, forKey: .vodFlag) ?? ""
        self.vodRemarks = try container.decodeIfPresent(String.self, forKey: .vodRemarks) ?? ""
        self.episodeUrl = try container.decodeIfPresent(String.self, forKey: .episodeUrl) ?? ""
        self.episodeKey = try container.decodeIfPresent(String.self, forKey: .episodeKey) ?? ""
        if episodeKey.isEmpty {
            episodeKey = HistoryPersistencePolicy.episodeKey(
                siteKey: siteKey,
                vodId: vodId,
                vodFlag: vodFlag,
                episodeURL: episodeUrl
            )
        }
        self.episodeName = try container.decodeIfPresent(String.self, forKey: .episodeName) ?? ""
        self.revSort = try container.decodeIfPresent(Bool.self, forKey: .revSort) ?? false
        self.revPlay = try container.decodeIfPresent(Bool.self, forKey: .revPlay) ?? false
        self.opening = try container.decodeIfPresent(Int64.self, forKey: .opening) ?? 0
        self.ending = try container.decodeIfPresent(Int64.self, forKey: .ending) ?? 0
        self.position = try container.decodeIfPresent(Int64.self, forKey: .position) ?? 0
        self.duration = try container.decodeIfPresent(Int64.self, forKey: .duration) ?? 0
        self.speed = try container.decodeIfPresent(Float.self, forKey: .speed) ?? 1.0
        self.scale = try container.decodeIfPresent(Int.self, forKey: .scale) ?? 0
        self.driveProvider = try container.decodeIfPresent(String.self, forKey: .driveProvider) ?? ""
        self.driveReferenceURL = try container.decodeIfPresent(String.self, forKey: .driveReferenceURL) ?? ""
        self.driveRoute = try container.decodeIfPresent(String.self, forKey: .driveRoute) ?? ""
        self.configId = try container.decodeIfPresent(Int.self, forKey: .configId) ?? 0
        self.createTime = try container.decodeIfPresent(Date.self, forKey: .createTime) ?? Date()
    }

    /// 播放进度百分比
    public var progress: Double {
        guard duration > 0 else { return 0 }
        return Double(position) / Double(duration)
    }
}

public enum HistoryPersistencePolicy {
    public static let maximumLocatorByteCount = 4_096
    private static let allowedOpaqueLocatorCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:$|,@/+"
    )
    private static let sensitiveWords: Set<String> = [
        "authorization", "bearer", "cookie", "credential", "expires", "jwt",
        "password", "secret", "session", "signature", "stoken", "ticket", "token"
    ]
    private static let allowedDriveQueryNames: Set<String> = [
        "share", "pwd_id", "fid", "file_name", "collection",
        "personal_drive_id", "personal_file_id", "pick_code", "size"
    ]

    public static func sanitized(_ history: History) -> History {
        var value = history
        if !history.episodeUrl.isEmpty {
            value.episodeKey = episodeKey(
                siteKey: history.siteKey,
                vodId: history.vodId,
                vodFlag: history.vodFlag,
                episodeURL: history.episodeUrl
            )
        } else if !isValidEpisodeKey(history.episodeKey) {
            value.episodeKey = ""
        }
        value.episodeUrl = sanitizedEpisodeLocator(history.episodeUrl)
        value.driveReferenceURL = sanitizedDriveReference(history.driveReferenceURL)
        return value
    }

    public static func episodeKey(
        siteKey: String,
        vodId: String,
        vodFlag: String,
        episodeURL: String
    ) -> String {
        guard !episodeURL.isEmpty else { return "" }
        let locator = stableEpisodeIdentityMaterial(episodeURL)
        let identity = [siteKey, vodId, vodFlag, locator].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "episode:v1:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sanitizedEpisodeLocator(_ rawValue: String) -> String {
        let value = trimmed(rawValue)
        guard !value.isEmpty else { return "" }
        let driveReference = sanitizedDriveReference(value)
        if !driveReference.isEmpty {
            return driveReference
        }
        if let components = URLComponents(string: value),
           components.scheme?.lowercased() == "file",
           components.user == nil,
           components.password == nil,
           components.percentEncodedQuery == nil,
           components.fragment == nil,
           components.host?.isEmpty != false,
           let url = components.url,
           url.isFileURL,
           !url.path.isEmpty {
            return url.standardizedFileURL.absoluteString
        }
        guard !value.contains("://"),
              value.unicodeScalars.allSatisfy({ allowedOpaqueLocatorCharacters.contains($0) }),
              !containsSensitiveWord(value) else {
            return ""
        }
        return value
    }

    public static func sanitizedDriveReference(_ rawValue: String) -> String {
        let value = trimmed(rawValue)
        guard !value.isEmpty,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "netvplayer-drive" || scheme == "pikpak",
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            return ""
        }
        if scheme == "pikpak" {
            guard components.host?.lowercased() == "file",
                  !components.path.dropFirst().isEmpty,
                  components.percentEncodedQuery == nil else {
                return ""
            }
            return components.url?.absoluteString ?? ""
        }

        guard components.host?.isEmpty == false else { return "" }
        components.queryItems = (components.queryItems ?? []).compactMap { item in
            let name = item.name.lowercased()
            if name == "passcode" || name == "fid_token" {
                return URLQueryItem(name: item.name, value: "")
            }
            guard allowedDriveQueryNames.contains(name) else { return nil }
            if name == "share", let rawShare = item.value {
                return URLQueryItem(name: item.name, value: sanitizedShareURL(rawShare))
            }
            return item
        }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        return components.url?.absoluteString ?? ""
    }

    private static func trimmed(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumLocatorByteCount,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return ""
        }
        return trimmed
    }

    private static func containsSensitiveWord(_ value: String) -> Bool {
        let words = value.lowercased().split { character in
            !character.isLetter && !character.isNumber
        }
        return words.contains { sensitiveWords.contains(String($0)) }
    }

    private static func sanitizedShareURL(_ value: String) -> String {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil else {
            return ""
        }
        components.queryItems = components.queryItems?.filter { item in
            !containsSensitiveWord(item.name)
                && item.name.caseInsensitiveCompare("pwd") != .orderedSame
                && item.name.caseInsensitiveCompare("passcode") != .orderedSame
        }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        return components.url?.absoluteString ?? ""
    }

    private static func stableEpisodeIdentityMaterial(_ rawValue: String) -> String {
        let value = trimmed(rawValue)
        guard !value.isEmpty else { return "" }
        if let separator = value.firstIndex(of: "$") {
            let locatorStart = value.index(after: separator)
            let locator = String(value[locatorStart...])
            if let scheme = URLComponents(string: locator)?.scheme?.lowercased(),
               ["http", "https", "file", "netvplayer-drive", "pikpak"].contains(scheme) {
                return String(value[...separator]) + stableEpisodeIdentityMaterial(locator)
            }
        }
        let driveReference = sanitizedDriveReference(value)
        if !driveReference.isEmpty {
            return canonicalizedURLIdentity(driveReference)
        }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return value
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        components.queryItems = components.queryItems?.filter { item in
            !isSensitiveQueryName(item.name)
        }
        return canonicalizedURLIdentity(components.url?.absoluteString ?? value)
    }

    private static func canonicalizedURLIdentity(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.queryItems = components.queryItems?.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return (lhs.value ?? "") < (rhs.value ?? "")
        }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        return components.url?.absoluteString ?? value
    }

    private static func isSensitiveQueryName(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return [
            "auth", "cookie", "expire", "key", "passcode", "password",
            "session", "sign", "stoken", "ticket", "timestamp", "token",
            "wssecret", "wstime"
        ].contains { normalized.contains($0) }
    }

    private static func isValidEpisodeKey(_ value: String) -> Bool {
        let prefix = "episode:v1:"
        guard value.hasPrefix(prefix) else { return false }
        let digest = value.dropFirst(prefix.count)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}
