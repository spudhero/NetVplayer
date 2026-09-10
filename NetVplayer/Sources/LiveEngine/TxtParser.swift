// LiveEngine/TxtParser.swift
// TXT 格式解析器（含 #genre# 标记）

import Foundation
import Models
import Networking

/// TXT 格式解析器
public struct TxtParser: Sendable {

    public static func parse(text: String) -> [ChannelGroup] {
        var groups: [ChannelGroup] = []
        var currentGroup: ChannelGroup?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.contains("#genre#") {
                // 新分组
                if let group = currentGroup {
                    groups.append(group)
                }
                let name = trimmed.replacingOccurrences(of: ",#genre#", with: "")
                    .replacingOccurrences(of: "#genre#", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentGroup = channelGroup(from: name)
            } else if trimmed.contains(",") {
                // 频道行: 名称,URL
                let parts = trimmed.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    let name = parts[0].trimmingCharacters(in: .whitespaces)
                    let parsed = parseURLs(String(parts[1]))
                    var channel = Channel(name: name, urls: parsed.urls)
                    channel.header = parsed.headers
                    channel.format = parsed.format
                    currentGroup?.channels.append(channel)
                }
            }
        }

        if let group = currentGroup {
            groups.append(group)
        }

        return groups
    }

    private static func channelGroup(from rawName: String) -> ChannelGroup {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let split = name.lastIndex(of: "_") {
            let title = String(name[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            let password = String(name[name.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !password.isEmpty {
                return ChannelGroup(name: title.isEmpty ? "隐藏分组" : title, isHidden: true, password: password)
            }
        }
        return ChannelGroup(name: name)
    }

    private static func parseURLs(_ value: String) -> (urls: [String], headers: [String: String], format: String) {
        let candidates = value
            .split(whereSeparator: { $0 == "#" || $0 == "$" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var urls: [String] = []
        var headers: [String: String] = [:]
        var format = ""

        for candidate in candidates {
            let parsed = parseURLAndHeaders(candidate)
            if !parsed.url.isEmpty {
                urls.append(parsed.url)
                headers.merge(parsed.headers) { _, new in new }
                if format.isEmpty { format = formatForURL(parsed.url) }
            }
        }

        return (urls, headers, format)
    }

    private static func parseURLAndHeaders(_ value: String) -> (url: String, headers: [String: String]) {
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let url = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard parts.count == 2 else { return (url, [:]) }
        return (url, parseHeaderText(String(parts[1])))
    }

    private static func parseHeaderText(_ text: String) -> [String: String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object.reduce(into: [:]) { result, item in
                if let value = item.value as? String, !value.isEmpty {
                    result[URLHelper.fixHeaderKey(normalizedHeaderKey(item.key))] = value
                }
            }
        }

        return trimmed
            .split(separator: "&")
            .reduce(into: [:]) { result, part in
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { return }
                let key = normalizedHeaderKey(String(pair[0]).removingPercentEncoding ?? String(pair[0]))
                let value = String(pair[1]).removingPercentEncoding ?? String(pair[1])
                if !value.isEmpty {
                    result[URLHelper.fixHeaderKey(key)] = value
                }
            }
    }

    private static func normalizedHeaderKey(_ key: String) -> String {
        switch key.lowercased() {
        case "http-user-agent", "user-agent":
            return "User-Agent"
        case "referrer":
            return "Referer"
        default:
            return key
        }
    }

    private static func formatForURL(_ url: String) -> String {
        let lower = url.lowercased()
        if lower.contains(".m3u8") { return "application/x-mpegURL" }
        if lower.contains(".mp4") { return "video/mp4" }
        if lower.contains(".flv") { return "video/x-flv" }
        if lower.contains(".ts") { return "video/mp2t" }
        return ""
    }
}
