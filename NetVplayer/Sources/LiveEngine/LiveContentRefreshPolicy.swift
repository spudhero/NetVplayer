import Foundation
import Models

public struct LiveChannelSelectionKey: Sendable, Equatable {
    public let groupName: String
    public let channelName: String
    public let channelNumber: String
    public let tvgID: String

    public init(groupName: String, channel: Channel) {
        self.groupName = groupName
        self.channelName = channel.name
        self.channelNumber = channel.number
        self.tvgID = channel.tvgId
    }
}

public enum LiveContentRefreshPolicy {
    public static let maximumRemoteCacheAge: TimeInterval = 15 * 60

    public static func shouldRefresh(
        sourceURL: String,
        groupsAreEmpty: Bool,
        loadedAt: Date?,
        now: Date = Date(),
        maximumAge: TimeInterval = maximumRemoteCacheAge
    ) -> Bool {
        if groupsAreEmpty { return true }

        guard let scheme = URLComponents(string: sourceURL)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        guard let loadedAt else { return true }
        return now.timeIntervalSince(loadedAt) >= maximumAge
    }

    public static func shouldRefresh(after probe: LiveProbeResult) -> Bool {
        guard !probe.isPlayable else { return false }

        switch probe.statusCode {
        case 401, 403, 410, 419, 440, 605:
            return true
        default:
            let lower = probe.bodyPrefix.lowercased()
            return lower.contains("expired")
                || lower.contains("signature")
                || lower.contains("token invalid")
                || lower.contains("鉴权")
                || lower.contains("签名")
                || lower.contains("过期")
        }
    }

    public static func shouldRefresh(afterPlaybackFailure message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("http 401")
            || lower.contains("http 403")
            || lower.contains("http 410")
            || lower.contains("http 419")
            || lower.contains("http 440")
            || lower.contains("http 605")
            || lower.contains("expired")
            || lower.contains("signature")
    }

    public static func matchingSelection(
        for key: LiveChannelSelectionKey,
        in groups: [ChannelGroup]
    ) -> (group: ChannelGroup, channel: Channel)? {
        if let preferredGroup = groups.first(where: { $0.name == key.groupName }),
           let channel = preferredGroup.channels.first(where: { matches($0, key: key) }) {
            return (preferredGroup, channel)
        }

        for group in groups where group.name != key.groupName {
            if let channel = group.channels.first(where: { matches($0, key: key) }) {
                return (group, channel)
            }
        }
        return nil
    }

    private static func matches(_ channel: Channel, key: LiveChannelSelectionKey) -> Bool {
        if !key.tvgID.isEmpty, channel.tvgId == key.tvgID {
            return true
        }
        if !key.channelNumber.isEmpty,
           channel.number == key.channelNumber,
           channel.name == key.channelName {
            return true
        }
        return channel.name == key.channelName
    }
}
