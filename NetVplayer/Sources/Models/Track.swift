// Models/Track.swift
// 轨道偏好模型，对应 FongMi: bean/Track.java

import Foundation

/// 轨道类型
public enum TrackType: Int, Codable, Sendable {
    case audio = 0
    case subtitle = 1
}

/// 音轨/字幕轨偏好
public struct Track: Codable, Identifiable, Sendable {
    public var key: String        // 播放 key (siteKey+vodId)
    public var type: TrackType
    public var selectionId: String
    public var name: String
    public var format: String
    public var isSelected: Bool

    public var id: String { "\(key)_\(type.rawValue)_\(selectionId.isEmpty ? name : selectionId)" }

    public init(
        key: String = "",
        type: TrackType = .audio,
        selectionId: String = "",
        name: String = "",
        format: String = "",
        isSelected: Bool = false
    ) {
        self.key = key
        self.type = type
        self.selectionId = selectionId
        self.name = name
        self.format = format
        self.isSelected = isSelected
    }

    enum CodingKeys: String, CodingKey {
        case key, type, selectionId, name, format, isSelected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.type = try container.decodeIfPresent(TrackType.self, forKey: .type) ?? .audio
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.selectionId = try container.decodeIfPresent(String.self, forKey: .selectionId) ?? self.name
        self.format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
        self.isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
    }
}
