// Models/Keep.swift
// 收藏/追剧模型，对应 FongMi: bean/Keep.java

import Foundation

/// 收藏类型
public enum KeepType: Int, Codable, Sendable {
    case vod = 0
    case live = 1
}

/// 收藏记录
public struct Keep: Codable, Identifiable, Sendable {
    public var key: String        // siteKey + vodId 组合键
    public var siteName: String
    public var vodName: String
    public var vodPic: String
    public var vodRemarks: String
    public var latestRemarks: String
    public var type: KeepType
    public var driveProvider: String
    public var driveReferenceURL: String
    public var driveRoute: String
    public var configId: Int
    public var createTime: Date

    public var id: String { key }
    public var hasUpdate: Bool {
        let saved = vodRemarks.trimmingCharacters(in: .whitespacesAndNewlines)
        let latest = latestRemarks.trimmingCharacters(in: .whitespacesAndNewlines)
        return !latest.isEmpty && latest != saved
    }

    public init(
        key: String = "",
        siteName: String = "",
        vodName: String = "",
        vodPic: String = "",
        vodRemarks: String = "",
        latestRemarks: String = "",
        type: KeepType = .vod,
        driveProvider: String = "",
        driveReferenceURL: String = "",
        driveRoute: String = "",
        configId: Int = 0,
        createTime: Date = Date()
    ) {
        self.key = key
        self.siteName = siteName
        self.vodName = vodName
        self.vodPic = vodPic
        self.vodRemarks = vodRemarks
        self.latestRemarks = latestRemarks
        self.type = type
        self.driveProvider = driveProvider
        self.driveReferenceURL = driveReferenceURL
        self.driveRoute = driveRoute
        self.configId = configId
        self.createTime = createTime
    }

    enum CodingKeys: String, CodingKey {
        case key, siteName, vodName, vodPic, vodRemarks, latestRemarks, type
        case driveProvider, driveReferenceURL, driveRoute, configId, createTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.siteName = try container.decodeIfPresent(String.self, forKey: .siteName) ?? ""
        self.vodName = try container.decodeIfPresent(String.self, forKey: .vodName) ?? ""
        self.vodPic = try container.decodeIfPresent(String.self, forKey: .vodPic) ?? ""
        self.vodRemarks = try container.decodeIfPresent(String.self, forKey: .vodRemarks) ?? ""
        self.latestRemarks = try container.decodeIfPresent(String.self, forKey: .latestRemarks) ?? ""
        self.type = try container.decodeIfPresent(KeepType.self, forKey: .type) ?? .vod
        self.driveProvider = try container.decodeIfPresent(String.self, forKey: .driveProvider) ?? ""
        self.driveReferenceURL = try container.decodeIfPresent(String.self, forKey: .driveReferenceURL) ?? ""
        self.driveRoute = try container.decodeIfPresent(String.self, forKey: .driveRoute) ?? ""
        self.configId = try container.decodeIfPresent(Int.self, forKey: .configId) ?? 0
        self.createTime = try container.decodeIfPresent(Date.self, forKey: .createTime) ?? Date()
    }
}
