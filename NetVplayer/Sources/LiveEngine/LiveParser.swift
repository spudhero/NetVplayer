// LiveEngine/LiveParser.swift
// 直播源解析器，对应 FongMi: parser/LiveParser.java

import Foundation
import Models

/// 直播源解析器
public struct LiveParser: Sendable {

    /// 解析直播源文本
    public static func parse(text: String) -> [ChannelGroup] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups: [ChannelGroup]

        if trimmed.contains("#EXTM3U") {
            groups = M3UParser.parse(text: trimmed)
        } else if trimmed.contains("#genre#") {
            groups = TxtParser.parse(text: trimmed)
        } else if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            groups = parseJSON(text: trimmed)
        } else {
            groups = []
        }

        return LiveChannelMerger.merge(groups: groups)
    }

    /// JSON 格式解析
    private static func parseJSON(text: String) -> [ChannelGroup] {
        guard let data = text.data(using: .utf8) else { return [] }

        let decoder = JSONDecoder()
        if let groups = try? decoder.decode([ChannelGroup].self, from: data) {
            return groups
        }
        if let envelope = try? decoder.decode(LiveGroupsEnvelope.self, from: data) {
            return envelope.groups
        }
        if let envelope = try? decoder.decode(LivesEnvelope.self, from: data) {
            return envelope.lives.flatMap { live in
                live.groups.map { $0.applying(live: live) }
            }
        }
        if let live = try? decoder.decode(Live.self, from: data) {
            return live.groups.map { $0.applying(live: live) }
        }
        if let group = try? decoder.decode(ChannelGroup.self, from: data) {
            return [group]
        }

        return []
    }
}

private struct LiveGroupsEnvelope: Decodable {
    let groups: [ChannelGroup]
}

private struct LivesEnvelope: Decodable {
    let lives: [Live]
}
