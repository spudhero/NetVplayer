// Models/Vod.swift
// 视频数据模型，对应 FongMi: bean/Vod.java

import Foundation

/// 视频点播模型
public struct Vod: Codable, Identifiable, Sendable {
    // MARK: - 基础信息
    public var vodId: String
    public var vodName: String
    public var vodPic: String
    public var vodYear: String
    public var vodArea: String
    public var vodContent: String
    public var vodActor: String
    public var vodDirector: String
    public var vodRemarks: String
    public var typeName: String
    public var vodBackground: String
    public var vodLogo: String
    public var episodeDetails: [Episode]

    // MARK: - 播放数据
    /// 播放源名称，多源用 "$$$" 分隔
    public var vodPlayFrom: String
    /// 播放地址列表，格式: "集名$url#集名$url"，多源用 "$$$" 分隔
    public var vodPlayUrl: String

    // MARK: - 运行时
    public var siteKey: String

    public var id: String { vodId }

    public init(
        vodId: String = "",
        vodName: String = "",
        vodPic: String = "",
        vodYear: String = "",
        vodArea: String = "",
        vodContent: String = "",
        vodActor: String = "",
        vodDirector: String = "",
        vodRemarks: String = "",
        typeName: String = "",
        vodBackground: String = "",
        vodLogo: String = "",
        episodeDetails: [Episode] = [],
        vodPlayFrom: String = "",
        vodPlayUrl: String = "",
        siteKey: String = ""
    ) {
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.vodYear = vodYear
        self.vodArea = vodArea
        self.vodContent = vodContent
        self.vodActor = vodActor
        self.vodDirector = vodDirector
        self.vodRemarks = vodRemarks
        self.typeName = typeName
        self.vodBackground = vodBackground
        self.vodLogo = vodLogo
        self.episodeDetails = episodeDetails
        self.vodPlayFrom = vodPlayFrom
        self.vodPlayUrl = vodPlayUrl
        self.siteKey = siteKey
    }

    // MARK: - 解析播放源

    /// 解析出所有播放线路 (Flag)
    public func parseFlags() -> [Flag] {
        let froms = vodPlayFrom.components(separatedBy: "$$$")
        let urls = vodPlayUrl.components(separatedBy: "$$$")
        let detailByURL = Dictionary(episodeDetails.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var flags: [Flag] = []
        for (index, name) in froms.enumerated() where !name.isEmpty {
            let episodeStr = index < urls.count ? urls[index] : ""
            let episodes = Episode.parse(from: episodeStr).map { parsed in
                guard var detailed = detailByURL[parsed.url] else { return parsed }
                if detailed.name.isEmpty { detailed.name = parsed.name }
                return detailed
            }
            flags.append(Flag(name: name, episodes: episodes))
        }
        return flags
    }

    enum CodingKeys: String, CodingKey {
        case vodId = "vod_id"
        case vodName = "vod_name"
        case vodPic = "vod_pic"
        case vodYear = "vod_year"
        case vodArea = "vod_area"
        case vodContent = "vod_content"
        case vodActor = "vod_actor"
        case vodDirector = "vod_director"
        case vodRemarks = "vod_remarks"
        case typeName = "type_name"
        case vodBackground = "vod_background"
        case vodLogo = "vod_logo"
        case episodeDetails = "episode_details"
        case vodPlayFrom = "vod_play_from"
        case vodPlayUrl = "vod_play_url"
        case siteKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if let vodIdVal = try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .vodId) {
            self.vodId = vodIdVal.stringValue
        } else {
            self.vodId = ""
        }
        
        self.vodName = try container.decodeIfPresent(String.self, forKey: .vodName) ?? ""
        self.vodPic = try container.decodeIfPresent(String.self, forKey: .vodPic) ?? ""
        self.vodYear = try container.decodeIfPresent(String.self, forKey: .vodYear) ?? ""
        self.vodArea = try container.decodeIfPresent(String.self, forKey: .vodArea) ?? ""
        self.vodContent = try container.decodeIfPresent(String.self, forKey: .vodContent) ?? ""
        self.vodActor = try container.decodeIfPresent(String.self, forKey: .vodActor) ?? ""
        self.vodDirector = try container.decodeIfPresent(String.self, forKey: .vodDirector) ?? ""
        self.vodRemarks = try container.decodeIfPresent(String.self, forKey: .vodRemarks) ?? ""
        self.typeName = try container.decodeIfPresent(String.self, forKey: .typeName) ?? ""
        self.vodBackground = try container.decodeIfPresent(String.self, forKey: .vodBackground) ?? ""
        self.vodLogo = try container.decodeIfPresent(String.self, forKey: .vodLogo) ?? ""
        self.episodeDetails = try container.decodeIfPresent([Episode].self, forKey: .episodeDetails) ?? []
        self.vodPlayFrom = try container.decodeIfPresent(String.self, forKey: .vodPlayFrom) ?? ""
        self.vodPlayUrl = try container.decodeIfPresent(String.self, forKey: .vodPlayUrl) ?? ""
        self.siteKey = try container.decodeIfPresent(String.self, forKey: .siteKey) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vodId, forKey: .vodId)
        try container.encode(vodName, forKey: .vodName)
        try container.encode(vodPic, forKey: .vodPic)
        try container.encode(vodYear, forKey: .vodYear)
        try container.encode(vodArea, forKey: .vodArea)
        try container.encode(vodContent, forKey: .vodContent)
        try container.encode(vodActor, forKey: .vodActor)
        try container.encode(vodDirector, forKey: .vodDirector)
        try container.encode(vodRemarks, forKey: .vodRemarks)
        try container.encode(typeName, forKey: .typeName)
        if !vodBackground.isEmpty { try container.encode(vodBackground, forKey: .vodBackground) }
        if !vodLogo.isEmpty { try container.encode(vodLogo, forKey: .vodLogo) }
        if !episodeDetails.isEmpty { try container.encode(episodeDetails, forKey: .episodeDetails) }
        try container.encode(vodPlayFrom, forKey: .vodPlayFrom)
        try container.encode(vodPlayUrl, forKey: .vodPlayUrl)
        try container.encode(siteKey, forKey: .siteKey)
    }
}
