// PlayerEngine/MPVTrackListParser.swift
// Offline parser for mpv track-list node/map JSON shapes.

import Foundation

public struct PlayerTrackListSnapshot: Equatable, Sendable {
    public var audioTracks: [PlayerTrackInfo]
    public var subtitleTracks: [PlayerTrackInfo]
    public var selectedAudioTrackID: String?
    public var selectedSubtitleTrackID: String?
    public var source: String

    public init(
        audioTracks: [PlayerTrackInfo] = [],
        subtitleTracks: [PlayerTrackInfo] = [],
        selectedAudioTrackID: String? = nil,
        selectedSubtitleTrackID: String? = nil,
        source: String = ""
    ) {
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.selectedAudioTrackID = selectedAudioTrackID
        self.selectedSubtitleTrackID = selectedSubtitleTrackID
        self.source = source
    }

    public var isEmpty: Bool {
        audioTracks.isEmpty && subtitleTracks.isEmpty
    }
}

public enum MPVTrackListParserError: LocalizedError, Equatable {
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "mpv track-list JSON 无法解析"
        }
    }
}

public enum MPVTrackListParser {
    public static func parse(json: String, source: String = "track-list") throws -> PlayerTrackListSnapshot {
        guard let data = json.data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MPVTrackListParserError.invalidJSON
        }
        return parse(items: raw, source: source)
    }

    public static func parse(items: [[String: Any]], source: String = "track-list") -> PlayerTrackListSnapshot {
        var audioTracks: [PlayerTrackInfo] = []
        var subtitleTracks: [PlayerTrackInfo] = []
        var selectedAudioTrackID: String?
        var selectedSubtitleTrackID: String?

        for item in items {
            guard let kind = trackKind(from: item),
                  let id = stringValue(item["id"]), id != "no" else {
                continue
            }
            let title = firstString(item, keys: ["title", "name", "label"])
            let language = firstString(item, keys: ["lang", "language"])
            let format = firstString(item, keys: ["codec", "format", "demuxer-via-codec"])
            let track = PlayerTrackInfo(
                id: id,
                kind: kind,
                name: title,
                language: language,
                format: format,
                isExternal: boolValue(item["external"]) ?? false
            )

            if kind == .audio {
                audioTracks.append(track)
                if boolValue(item["selected"]) == true {
                    selectedAudioTrackID = id
                }
            } else {
                subtitleTracks.append(track)
                if boolValue(item["selected"]) == true {
                    selectedSubtitleTrackID = id
                }
            }
        }

        return PlayerTrackListSnapshot(
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            selectedAudioTrackID: selectedAudioTrackID,
            selectedSubtitleTrackID: selectedSubtitleTrackID,
            source: source
        )
    }

    private static func trackKind(from item: [String: Any]) -> PlayerTrackKind? {
        let type = firstString(item, keys: ["type", "kind"]).lowercased()
        if type == "audio" { return .audio }
        if type == "sub" || type == "subs" || type == "subtitle" { return .subtitle }
        return nil
    }

    private static func firstString(_ item: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = stringValue(item[key]), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let int as Int:
            return String(int)
        case let int64 as Int64:
            return String(int64)
        case let double as Double where double.rounded() == double:
            return String(Int(double))
        case let double as Double:
            return String(double)
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let int as Int:
            return int != 0
        case let string as String:
            let lower = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["yes", "true", "1", "selected"].contains(lower) { return true }
            if ["no", "false", "0"].contains(lower) { return false }
            return nil
        default:
            return nil
        }
    }
}
