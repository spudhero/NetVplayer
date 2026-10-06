// Models/SiteHealth.swift
// Local source health events and weighted summaries.

import Foundation

public enum SiteHealthEventType: String, Codable, Sendable, CaseIterable {
    case search
    case detail
    case play

    public var weight: Double {
        switch self {
        case .play: return 3
        case .detail: return 2
        case .search: return 1
        }
    }
}

public struct SiteHealthEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var eventType: SiteHealthEventType
    public var siteKey: String
    public var siteName: String
    public var success: Bool
    public var durationMs: Int
    public var errorCategory: AppFailureCategory?
    public var timestamp: Date
    public var host: String

    public init(
        id: UUID = UUID(),
        eventType: SiteHealthEventType,
        siteKey: String,
        siteName: String,
        success: Bool,
        durationMs: Int = 0,
        errorCategory: AppFailureCategory? = nil,
        timestamp: Date = Date(),
        host: String = ""
    ) {
        self.id = id
        self.eventType = eventType
        self.siteKey = siteKey
        self.siteName = siteName
        self.success = success
        self.durationMs = max(0, durationMs)
        self.errorCategory = errorCategory
        self.timestamp = timestamp
        self.host = Self.sanitizedHost(from: host)
    }

    public static func sanitizedHost(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), let host = url.host {
            return host.lowercased()
        }
        if trimmed.contains("://") {
            return ""
        }
        return trimmed
            .components(separatedBy: "/").first?
            .components(separatedBy: "?").first?
            .lowercased() ?? ""
    }
}

public struct SiteHealthSummary: Codable, Sendable, Equatable {
    public var siteKey: String
    public var siteName: String
    public var score: Double
    public var eventCount: Int
    public var successCount: Int
    public var failureCount: Int
    public var averageDurationMs: Int
    public var lastEventAt: Date?
    public var lastFailureCategory: AppFailureCategory?

    public init(
        siteKey: String,
        siteName: String = "",
        score: Double = 0.5,
        eventCount: Int = 0,
        successCount: Int = 0,
        failureCount: Int = 0,
        averageDurationMs: Int = 0,
        lastEventAt: Date? = nil,
        lastFailureCategory: AppFailureCategory? = nil
    ) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.score = score
        self.eventCount = eventCount
        self.successCount = successCount
        self.failureCount = failureCount
        self.averageDurationMs = averageDurationMs
        self.lastEventAt = lastEventAt
        self.lastFailureCategory = lastFailureCategory
    }

    public var displayPercent: Int {
        Int((max(0, min(1, score)) * 100).rounded())
    }
}
