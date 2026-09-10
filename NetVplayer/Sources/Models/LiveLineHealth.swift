// Models/LiveLineHealth.swift
// Local quality history for live channel playback URLs.

import Foundation

public struct LiveLineHealthEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var liveName: String
    public var groupName: String
    public var channelName: String
    public var url: String
    public var lineKey: String
    public var success: Bool
    public var statusCode: Int
    public var ttfbMs: Int
    public var failureCategory: AppFailureCategory?
    public var message: String
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        liveName: String,
        groupName: String,
        channelName: String,
        url: String,
        success: Bool,
        statusCode: Int,
        ttfbMs: Int,
        failureCategory: AppFailureCategory?,
        message: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.liveName = liveName
        self.groupName = groupName
        self.channelName = channelName
        self.url = url
        self.lineKey = Self.lineKey(liveName: liveName, groupName: groupName, channelName: channelName, url: url)
        self.success = success
        self.statusCode = statusCode
        self.ttfbMs = max(0, ttfbMs)
        self.failureCategory = failureCategory
        self.message = message
        self.timestamp = timestamp
    }

    public static func lineKey(liveName: String, groupName: String, channelName: String, url: String) -> String {
        [liveName, groupName, channelName, normalizedURL(url)].joined(separator: "::")
    }

    public static func normalizedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.query = nil
        components.fragment = nil
        return components.string ?? value
    }

    public static func redactedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        let hadQuery = components.query?.isEmpty == false
        components.query = nil
        components.fragment = nil
        let base = components.string ?? value
        return hadQuery ? "\(base)?<redacted>" : base
    }
}

public struct LiveLineHealthSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { lineKey }
    public var lineKey: String
    public var liveName: String
    public var groupName: String
    public var channelName: String
    public var redactedURL: String
    public var eventCount: Int
    public var successCount: Int
    public var failureCount: Int
    public var averageTTFBMs: Int
    public var lastStatusCode: Int
    public var lastMessage: String
    public var lastFailureCategory: AppFailureCategory?
    public var lastEventAt: Date?

    public init(
        lineKey: String,
        liveName: String = "",
        groupName: String = "",
        channelName: String = "",
        redactedURL: String = "",
        eventCount: Int = 0,
        successCount: Int = 0,
        failureCount: Int = 0,
        averageTTFBMs: Int = 0,
        lastStatusCode: Int = 0,
        lastMessage: String = "",
        lastFailureCategory: AppFailureCategory? = nil,
        lastEventAt: Date? = nil
    ) {
        self.lineKey = lineKey
        self.liveName = liveName
        self.groupName = groupName
        self.channelName = channelName
        self.redactedURL = redactedURL
        self.eventCount = eventCount
        self.successCount = successCount
        self.failureCount = failureCount
        self.averageTTFBMs = averageTTFBMs
        self.lastStatusCode = lastStatusCode
        self.lastMessage = lastMessage
        self.lastFailureCategory = lastFailureCategory
        self.lastEventAt = lastEventAt
    }
}

public enum LiveLineHealthPolicy {
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public static func summaries(from events: [LiveLineHealthEvent], now: Date = Date()) -> [LiveLineHealthSummary] {
        let recent = prune(events, now: now)
        let grouped = Dictionary(grouping: recent, by: \.lineKey)
        return grouped.values.map { lineEvents in
            let latest = lineEvents.max { $0.timestamp < $1.timestamp }
            let successCount = lineEvents.filter(\.success).count
            let failureEvents = lineEvents.filter { !$0.success }
            let ttfbValues = lineEvents.map(\.ttfbMs).filter { $0 > 0 }
            return LiveLineHealthSummary(
                lineKey: latest?.lineKey ?? "",
                liveName: latest?.liveName ?? "",
                groupName: latest?.groupName ?? "",
                channelName: latest?.channelName ?? "",
                redactedURL: latest.map { LiveLineHealthEvent.redactedURL($0.url) } ?? "",
                eventCount: lineEvents.count,
                successCount: successCount,
                failureCount: failureEvents.count,
                averageTTFBMs: ttfbValues.isEmpty ? 0 : ttfbValues.reduce(0, +) / ttfbValues.count,
                lastStatusCode: latest?.statusCode ?? 0,
                lastMessage: latest?.message ?? "",
                lastFailureCategory: failureEvents.max { $0.timestamp < $1.timestamp }?.failureCategory,
                lastEventAt: latest?.timestamp
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.lastEventAt, rhs.lastEventAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.channelName < rhs.channelName
            }
        }
    }

    public static func prune(_ events: [LiveLineHealthEvent], now: Date = Date()) -> [LiveLineHealthEvent] {
        let cutoff = now.addingTimeInterval(-retention)
        return events.filter { $0.timestamp >= cutoff }
    }
}
