// LiveEngine/M3UParser.swift
// M3U/M3U8 格式解析器

import Foundation
import Models
import Networking

/// M3U 格式解析器
public struct M3UParser: Sendable {

    private struct PendingChannel {
        var channel: Channel
        var groupName: String
    }

    public static func parse(text: String) -> [ChannelGroup] {
        var groups: [String: ChannelGroup] = [:]
        var groupOrder: [String] = []
        let lines = text.components(separatedBy: .newlines)
        var pendingChannel: PendingChannel?
        var pendingGroupName = ""
        var pendingHeaders: [String: String] = [:]
        var pendingDRM: Drm?
        var rootEPG = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("#EXTM3U") {
                rootEPG = attributes(in: trimmed)["x-tvg-url"] ?? attributes(in: trimmed)["url-tvg"] ?? rootEPG
            } else if trimmed.hasPrefix("#EXTINF:") {
                pendingChannel = parseExtInf(trimmed, fallbackGroupName: pendingGroupName, rootEPG: rootEPG)
            } else if trimmed.hasPrefix("#EXTGRP:") {
                pendingGroupName = String(trimmed.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.hasPrefix("#EXTVLCOPT:") {
                pendingHeaders.merge(parseVLCOption(trimmed)) { _, new in new }
            } else if trimmed.hasPrefix("#EXTHTTP:") {
                pendingHeaders.merge(parseHeaderText(String(trimmed.dropFirst("#EXTHTTP:".count)))) { _, new in new }
            } else if trimmed.hasPrefix("#KODIPROP:") {
                pendingDRM = applyKodiProperty(trimmed, drm: pendingDRM)
            } else if !trimmed.hasPrefix("#") {
                guard var pending = pendingChannel else { continue }
                let parsedURL = parseURLAndHeaders(trimmed)
                pending.channel.urls = [parsedURL.url]
                pending.channel.header.merge(pendingHeaders) { _, new in new }
                pending.channel.header.merge(parsedURL.headers) { _, new in new }
                if pending.channel.drm == nil { pending.channel.drm = pendingDRM }
                if pending.channel.format.isEmpty { pending.channel.format = formatForURL(parsedURL.url) }

                let groupName = pending.groupName.isEmpty ? "未分组" : pending.groupName
                if groups[groupName] == nil {
                    groups[groupName] = channelGroup(from: groupName)
                    groupOrder.append(groupName)
                }
                groups[groupName]?.channels.append(pending.channel)

                pendingChannel = nil
                pendingHeaders = [:]
                pendingDRM = nil
            }
        }

        return groupOrder.compactMap { groups[$0] }
    }

    private static func parseExtInf(_ line: String, fallbackGroupName: String, rootEPG: String) -> PendingChannel {
        let attrs = attributes(in: line)
        var channel = Channel()

        channel.tvgId = attrs["tvg-id"] ?? ""
        channel.tvgName = attrs["tvg-name"] ?? ""
        channel.number = attrs["tvg-chno"] ?? attrs["channel-number"] ?? attrs["chno"] ?? attrs["tvg-num"] ?? attrs["number"] ?? ""
        channel.logo = attrs["tvg-logo"] ?? ""
        channel.epg = attrs["tvg-url"] ?? attrs["x-tvg-url"] ?? rootEPG
        channel.epgName = channel.tvgName
        if channel.epgName.isEmpty { channel.epgName = channel.tvgId }
        channel.ua = attrs["user-agent"] ?? attrs["http-user-agent"] ?? ""
        channel.referer = attrs["referrer"] ?? attrs["referer"] ?? ""
        channel.format = attrs["type"] ?? ""

        if let catchup = catchup(from: attrs) {
            channel.catchup = catchup
        }

        if let lastComma = line.lastIndex(of: ",") {
            let name = String(line[line.index(after: lastComma)...]).trimmingCharacters(in: .whitespaces)
            channel.name = channel.tvgName.isEmpty ? name : channel.tvgName
            if channel.epgName.isEmpty { channel.epgName = channel.name }
        }

        let groupName = attrs["group-title"] ?? fallbackGroupName
        return PendingChannel(channel: channel, groupName: groupName)
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

    private static func catchup(from attrs: [String: String]) -> Catchup? {
        let source = attrs["catchup-source"] ?? attrs["catchup-days-source"] ?? ""
        let type = attrs["catchup"] ?? attrs["catchup-type"] ?? ""
        let days = Int(attrs["catchup-days"] ?? attrs["catchup-days-number"] ?? "") ?? 0

        if source.isEmpty, type.isEmpty, days == 0 {
            return nil
        }
        return Catchup(source: source, type: type, days: days)
    }

    private static func attributes(in line: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let pattern = #"([A-Za-z0-9_-]+)=("([^"]*)"|'([^']*)'|[^\s,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attrs }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in regex.matches(in: line, range: nsRange) {
            guard let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }
            let key = String(line[keyRange]).lowercased()
            var value = String(line[valueRange])
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            attrs[key] = value
        }
        return attrs
    }

    private static func parseVLCOption(_ line: String) -> [String: String] {
        let option = String(line.dropFirst("#EXTVLCOPT:".count))
        let pair = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return [:] }
        let key = normalizedHeaderKey(String(pair[0]))
        let value = String(pair[1])
        return value.isEmpty ? [:] : [URLHelper.fixHeaderKey(key): value]
    }

    private static func applyKodiProperty(_ line: String, drm: Drm?) -> Drm? {
        let option = String(line.dropFirst("#KODIPROP:".count))
        let pair = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return drm }

        var updated = drm ?? Drm()
        switch pair[0] {
        case "inputstream.adaptive.license_type":
            updated.type = String(pair[1])
        case "inputstream.adaptive.license_key":
            updated.key = String(pair[1])
        case "inputstream.adaptive.license_url":
            updated.licenseUrl = String(pair[1])
        default:
            break
        }

        return updated.type.isEmpty && updated.key.isEmpty && updated.licenseUrl.isEmpty ? drm : updated
    }

    private static func parseURLAndHeaders(_ value: String) -> (url: String, headers: [String: String]) {
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let url = normalizedStreamURL(String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines))
        guard parts.count == 2 else { return (url, [:]) }
        return (url, parseHeaderText(String(parts[1])))
    }

    static func normalizedStreamURL(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var result = ""
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x25 {
                if index + 2 < scalars.count,
                   isHexDigit(scalars[index + 1]),
                   isHexDigit(scalars[index + 2]) {
                    result.unicodeScalars.append(scalar)
                    result.unicodeScalars.append(scalars[index + 1])
                    result.unicodeScalars.append(scalars[index + 2])
                    index += 3
                    continue
                }
                result.append("%25")
            } else if scalar.value == 0x20 || (0x09...0x0D).contains(scalar.value) {
                result.append(String(format: "%%%02X", scalar.value))
            } else {
                result.unicodeScalars.append(scalar)
            }
            index += 1
        }
        return result
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66:
            return true
        default:
            return false
        }
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
