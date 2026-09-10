// Models/PlaybackLinkage.swift
// 本地播放记忆、收藏更新和直播收藏的纯规则。

import Foundation

public struct LiveKeepIdentity: Equatable, Sendable {
    public var liveName: String
    public var groupName: String
    public var channelName: String
    public var channelNumber: String
    public var tvgId: String

    public init(
        liveName: String = "",
        groupName: String = "",
        channelName: String = "",
        channelNumber: String = "",
        tvgId: String = ""
    ) {
        self.liveName = liveName
        self.groupName = groupName
        self.channelName = channelName
        self.channelNumber = channelNumber
        self.tvgId = tvgId
    }
}

public enum PlaybackLinkage {
    public static let liveFavoritesGroupName = "我的收藏"
    public static let disabledSubtitleTrackID = "no"

    public static func vodKey(siteKey: String, vodId: String) -> String {
        "\(siteKey)_\(vodId)"
    }

    public static func vodIdentity(from key: String) -> (siteKey: String, vodId: String) {
        guard let separator = key.firstIndex(of: "_") else {
            return ("", "")
        }
        let siteKey = String(key[..<separator])
        let vodId = String(key[key.index(after: separator)...])
        return (siteKey, vodId)
    }

    public static func history(
        for vod: Vod,
        activeSiteKey: String,
        items: [History]
    ) -> History? {
        let siteKey = vod.siteKey.isEmpty ? activeSiteKey : vod.siteKey
        let key = vodKey(siteKey: siteKey, vodId: vod.vodId)
        return items.first { $0.key == key || ($0.siteKey == siteKey && $0.vodId == vod.vodId) }
    }

    public static func preferredFlag(from history: History?, availableFlags: [String]) -> String? {
        guard let flag = history?.vodFlag, !flag.isEmpty else { return nil }
        return availableFlags.contains(flag) ? flag : nil
    }

    public static func preferredEpisode(from history: History?, episodes: [Episode]) -> Episode? {
        guard let history else { return nil }
        if !history.episodeUrl.isEmpty,
           let exact = episodes.first(where: { $0.url == history.episodeUrl }) {
            return exact
        }
        if !history.episodeKey.isEmpty {
            if let keyed = episodes.first(where: { episode in
                HistoryPersistencePolicy.episodeKey(
                    siteKey: history.siteKey,
                    vodId: history.vodId,
                    vodFlag: history.vodFlag,
                    episodeURL: episode.url
                ) == history.episodeKey
            }) {
                return keyed
            }
        }
        let episodeName = history.episodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !episodeName.isEmpty else { return nil }
        return episodes.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == episodeName
        }
    }

    public static func progressText(for history: History?) -> String? {
        guard let history, history.position > 0 else { return nil }
        let position = format(milliseconds: history.position)
        guard history.duration > 0 else { return "上次看到 \(position)" }
        return "上次看到 \(position) / \(format(milliseconds: history.duration))"
    }

    public static func updatedKeep(
        _ keep: Keep,
        currentRemarks: String,
        acknowledge: Bool
    ) -> Keep {
        let remarks = currentRemarks.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remarks.isEmpty else { return keep }

        var updated = keep
        if acknowledge {
            updated.vodRemarks = remarks
            updated.latestRemarks = ""
        } else if updated.vodRemarks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.vodRemarks = remarks
            updated.latestRemarks = ""
        } else if updated.vodRemarks.trimmingCharacters(in: .whitespacesAndNewlines) != remarks {
            updated.latestRemarks = remarks
        } else {
            updated.latestRemarks = ""
        }
        return updated
    }

    public static func trackPreferenceKey(for spec: PlaySpec) -> String {
        let source = spec.siteKey.isEmpty ? "unknown" : spec.siteKey
        let title = spec.title.isEmpty ? spec.url : spec.title
        return "\(source)_\(title)"
    }

    public static func trackPreference(type: TrackType, for spec: PlaySpec, in tracks: [Track]) -> Track? {
        let key = trackPreferenceKey(for: spec)
        return tracks.last { $0.key == key && $0.type == type && $0.isSelected }
    }

    public static func liveKeepKey(liveName: String, groupName: String, channel: Channel) -> String {
        [
            "live",
            liveName,
            groupName,
            channel.name,
            channel.number,
            channel.tvgId
        ]
            .map(encodeComponent)
            .joined(separator: "|")
    }

    public static func liveKeepIdentity(from key: String) -> LiveKeepIdentity? {
        let parts = key.components(separatedBy: "|").map(decodeComponent)
        guard parts.count >= 6, parts.first == "live" else { return nil }
        return LiveKeepIdentity(
            liveName: parts[1],
            groupName: parts[2],
            channelName: parts[3],
            channelNumber: parts[4],
            tvgId: parts[5]
        )
    }

    public static func matchingLiveChannel(
        for keep: Keep,
        in groups: [ChannelGroup],
        liveName: String
    ) -> (group: ChannelGroup, channel: Channel)? {
        guard keep.type == .live,
              let identity = liveKeepIdentity(from: keep.key),
              identity.liveName == liveName else {
            return nil
        }

        if !identity.groupName.isEmpty,
           let group = groups.first(where: { $0.name == identity.groupName }),
           let channel = group.channels.first(where: { matches($0, identity: identity) }) {
            return (group, channel)
        }

        for group in groups {
            if group.name == identity.groupName { continue }
            if let channel = group.channels.first(where: { matches($0, identity: identity) }) {
                return (group, channel)
            }
        }
        return nil
    }

    public static func liveGuideGroups(
        keeps: [Keep],
        groups: [ChannelGroup],
        liveName: String
    ) -> [ChannelGroup] {
        var seen = Set<String>()
        let favoriteChannels = keeps.compactMap { keep -> Channel? in
            guard let match = matchingLiveChannel(for: keep, in: groups, liveName: liveName) else { return nil }
            let identity = channelIdentity(match.channel)
            guard !seen.contains(identity) else { return nil }
            seen.insert(identity)
            return match.channel
        }
        guard !favoriteChannels.isEmpty else { return groups }
        let favorites = ChannelGroup(name: liveFavoritesGroupName, logo: "", channels: favoriteChannels)
        return [favorites] + groups
    }

    public static func channelIdentity(_ channel: Channel) -> String {
        "\(channel.name)|\(channel.number)|\(channel.tvgId)"
    }

    private static func matches(_ channel: Channel, identity: LiveKeepIdentity) -> Bool {
        guard channel.name == identity.channelName else { return false }
        if !identity.tvgId.isEmpty, channel.tvgId == identity.tvgId { return true }
        if !identity.channelNumber.isEmpty, channel.number == identity.channelNumber { return true }
        return identity.channelNumber.isEmpty && channel.number.isEmpty
    }

    private static func format(milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static var componentAllowedCharacters: CharacterSet {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "|")
        return set
    }

    private static func encodeComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: componentAllowedCharacters) ?? value
    }

    private static func decodeComponent(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
