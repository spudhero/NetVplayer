// LiveEngine/LivePlaybackPlanner.swift
// Pure helpers for ordering live playback fallback attempts.

import Foundation
import Models

public struct LivePlaybackAttempt: Sendable {
    public let channel: Channel
    public let urlIndex: Int
    public let url: String

    public init(channel: Channel, urlIndex: Int, url: String) {
        self.channel = channel
        self.urlIndex = urlIndex
        self.url = url
    }
}

public enum LivePlaybackPlanner {
    public static func attempts(
        startingFrom channel: Channel,
        selectedGroup: ChannelGroup?,
        preferredIndex: Int,
        maxChannels: Int = 3
    ) -> [LivePlaybackAttempt] {
        var channels: [Channel] = [channel]
        if let selectedGroup {
            channels.append(contentsOf: selectedGroup.channels.filter { $0.id != channel.id }.prefix(max(0, maxChannels - 1)))
        }

        return channels.prefix(maxChannels).flatMap { candidate in
            orderedURLIndexes(channel: candidate, preferredIndex: candidate.id == channel.id ? preferredIndex : 0)
                .map { LivePlaybackAttempt(channel: candidate, urlIndex: $0, url: candidate.urls[$0]) }
        }
    }

    public static func orderedURLIndexes(channel: Channel, preferredIndex: Int) -> [Int] {
        guard !channel.urls.isEmpty else { return [] }
        let safePreferred = min(max(preferredIndex, 0), channel.urls.count - 1)
        return [safePreferred] + channel.urls.indices.filter { $0 != safePreferred }
    }
}
