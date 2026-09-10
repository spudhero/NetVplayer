// Models/Episode.swift
// 剧集模型，对应 FongMi: bean/Episode.java

import Foundation

/// 剧集/集数
public struct Episode: Codable, Identifiable, Sendable {
    public var name: String
    public var url: String
    public var isSelected: Bool
    public var artwork: String?
    public var overview: String?
    public var released: String?
    public var season: Int?
    public var number: Int?

    public var id: String { "\(name)_\(url)" }

    public init(
        name: String = "",
        url: String = "",
        isSelected: Bool = false,
        artwork: String? = nil,
        overview: String? = nil,
        released: String? = nil,
        season: Int? = nil,
        number: Int? = nil
    ) {
        self.name = name
        self.url = url
        self.isSelected = isSelected
        self.artwork = artwork
        self.overview = overview
        self.released = released
        self.season = season
        self.number = number
    }

    /// 从 "集名$url#集名$url" 格式解析
    public static func parse(from text: String) -> [Episode] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: "#").compactMap { item in
            let parts = item.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            return Episode(name: String(parts[0]), url: String(parts[1]))
        }
    }
}
