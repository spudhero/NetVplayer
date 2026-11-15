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
    /// Explicit share/directory provenance, independent of the playback URL.
    public var series: EpisodeSeries?

    public var id: String { "\(name)_\(url)" }

    public init(
        name: String = "",
        url: String = "",
        isSelected: Bool = false,
        artwork: String? = nil,
        overview: String? = nil,
        released: String? = nil,
        season: Int? = nil,
        number: Int? = nil,
        series: EpisodeSeries? = nil
    ) {
        self.name = name
        self.url = url
        self.isSelected = isSelected
        self.artwork = artwork
        self.overview = overview
        self.released = released
        self.season = season
        self.number = number
        self.series = series
    }

    /// The shipped FongMi Flag.setEpisodes contract, before any playback action.
    /// Bare entries and empty labels receive their original one-based ordinal;
    /// IDs remain byte-for-byte strings, including whitespace and extra dollars.
    public static func parseOriginalAndroid(from text: String) -> [Episode] {
        var entries = text.components(separatedBy: "#")
        if text.contains("#") {
            // Java String.split(regex) discards trailing empty fields.
            while entries.last == "" { entries.removeLast() }
        }
        // Java String.equals compares exact content, while Swift String equality
        // also equates canonically equivalent Unicode spellings.
        var seen: [Data: Set<Data>] = [:]
        var episodes: [Episode] = []
        for (index, item) in entries.enumerated() {
            let parts = item.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
            let fallback = String(format: "%02d", index + 1)
            let name = parts.count > 1 && !parts[0].isEmpty
                ? originalAndroidTrim(String(parts[0])) : fallback
            let url = parts.count > 1 ? String(parts[1]) : item
            if seen[Data(name.utf8), default: []].insert(Data(url.utf8)).inserted {
                episodes.append(Episode(name: name, url: url))
            }
        }
        return episodes
    }

    static func originalAndroidTrim(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"..."\u{20}"))
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

public struct EpisodeSeries: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String = "") {
        self.id = id
        self.name = name
    }
}
