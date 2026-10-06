// LiveEngine/LiveChannelMerger.swift

import Foundation
import Models

enum LiveChannelMerger {
    static func merge(groups: [ChannelGroup]) -> [ChannelGroup] {
        groups.map { sourceGroup in
            var group = sourceGroup
            group.channels = merge(channels: sourceGroup.channels)
            return group
        }
    }

    private static func merge(channels: [Channel]) -> [Channel] {
        var merged: [Channel] = []
        var candidateIndices: [String: [Int]] = [:]

        for sourceChannel in channels {
            var channel = sourceChannel
            channel.urls = uniqueURLs(channel.urls)

            guard let key = identityKey(for: channel) else {
                merged.append(channel)
                continue
            }

            let matchingIndex = candidateIndices[key]?.first { index in
                hasCompatiblePlaybackConfiguration(merged[index], channel)
            }

            if let matchingIndex {
                merged[matchingIndex] = merging(merged[matchingIndex], with: channel)
            } else {
                candidateIndices[key, default: []].append(merged.count)
                merged.append(channel)
            }
        }

        return merged
    }

    private static func identityKey(for channel: Channel) -> String? {
        let name = normalizedIdentity(channel.name)
        if !name.isEmpty { return "name:\(name)" }

        let number = normalizedIdentity(channel.number)
        if !number.isEmpty { return "number:\(number)" }
        return nil
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func uniqueURLs(_ urls: [String]) -> [String] {
        var seen: Set<String> = []
        return urls.compactMap { rawURL in
            let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, seen.insert(url).inserted else { return nil }
            return url
        }
    }

    private static func merging(_ existing: Channel, with incoming: Channel) -> Channel {
        var channel = existing
        channel.urls = uniqueURLs(existing.urls + incoming.urls)
        if channel.number.isEmpty { channel.number = incoming.number }
        if channel.logo.isEmpty { channel.logo = incoming.logo }
        if channel.epg.isEmpty { channel.epg = incoming.epg }
        if channel.epgName.isEmpty { channel.epgName = incoming.epgName }
        if channel.tvgId.isEmpty { channel.tvgId = incoming.tvgId }
        if channel.tvgName.isEmpty { channel.tvgName = incoming.tvgName }
        if channel.format.isEmpty { channel.format = incoming.format }
        return channel
    }

    private static func hasCompatiblePlaybackConfiguration(_ lhs: Channel, _ rhs: Channel) -> Bool {
        lhs.ua == rhs.ua
            && lhs.origin == rhs.origin
            && lhs.referer == rhs.referer
            && lhs.header == rhs.header
            && lhs.parseFlag == rhs.parseFlag
            && lhs.clickScript == rhs.clickScript
            && catchupMatches(lhs.catchup, rhs.catchup)
            && drmMatches(lhs.drm, rhs.drm)
    }

    private static func catchupMatches(_ lhs: Catchup?, _ rhs: Catchup?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.source == rhs.source && lhs.type == rhs.type && lhs.days == rhs.days
        default:
            return false
        }
    }

    private static func drmMatches(_ lhs: Drm?, _ rhs: Drm?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.key == rhs.key
                && lhs.type == rhs.type
                && lhs.licenseUrl == rhs.licenseUrl
                && lhs.licenseHeader == rhs.licenseHeader
                && lhs.forceKey == rhs.forceKey
        default:
            return false
        }
    }
}
