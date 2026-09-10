// Storage/SiteHealthStore.swift
// Lightweight JSON-backed health telemetry for source search/detail/play events.

import Foundation
import Models

public final class SiteHealthStore: @unchecked Sendable {
    public static let shared = SiteHealthStore()

    private let storage: StorageManager
    private let filename = "site_health.json"
    private let retention: TimeInterval = 90 * 24 * 60 * 60
    private var events: [SiteHealthEvent]
    private let lock = NSLock()

    public init(storage: StorageManager = .shared) {
        self.storage = storage
        self.events = (try? storage.load([SiteHealthEvent].self, from: filename)) ?? []
        pruneLocked(now: Date())
    }

    public func record(_ event: SiteHealthEvent) {
        lock.lock()
        events.append(event)
        pruneLocked(now: Date())
        let snapshot = events
        lock.unlock()
        try? storage.save(snapshot, to: filename)
    }

    public func allEvents() -> [SiteHealthEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    public func summaries() -> [String: SiteHealthSummary] {
        lock.lock()
        let snapshot = events
        lock.unlock()
        return Self.summaries(from: snapshot)
    }

    public func clear() {
        lock.lock()
        events = []
        lock.unlock()
        try? storage.save([SiteHealthEvent](), to: filename)
    }

    public static func summaries(from events: [SiteHealthEvent], now: Date = Date()) -> [String: SiteHealthSummary] {
        let cutoff = now.addingTimeInterval(-(90 * 24 * 60 * 60))
        let recentEvents = events.filter { $0.timestamp >= cutoff }
        let grouped = Dictionary(grouping: recentEvents, by: \.siteKey)
        return grouped.mapValues { siteEvents in
            var weightedTotal = 0.0
            var weightedSuccess = 0.0
            var durationTotal = 0
            var durationCount = 0
            var successCount = 0
            var failureCount = 0

            for event in siteEvents {
                let ageDays = max(0, now.timeIntervalSince(event.timestamp) / (24 * 60 * 60))
                let recency = max(0.25, 1.0 - (ageDays / 90.0))
                let weight = event.eventType.weight * recency
                weightedTotal += weight
                if event.success {
                    weightedSuccess += weight
                    successCount += 1
                } else {
                    failureCount += 1
                }
                if event.durationMs > 0 {
                    durationTotal += event.durationMs
                    durationCount += 1
                }
            }

            let latest = siteEvents.max { $0.timestamp < $1.timestamp }
            let lastFailure = siteEvents
                .filter { !$0.success }
                .max { $0.timestamp < $1.timestamp }
            let score = weightedTotal > 0 ? weightedSuccess / weightedTotal : 0.5
            return SiteHealthSummary(
                siteKey: latest?.siteKey ?? "",
                siteName: latest?.siteName ?? "",
                score: score,
                eventCount: siteEvents.count,
                successCount: successCount,
                failureCount: failureCount,
                averageDurationMs: durationCount > 0 ? durationTotal / durationCount : 0,
                lastEventAt: latest?.timestamp,
                lastFailureCategory: lastFailure?.errorCategory
            )
        }
    }

    private func pruneLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        events.removeAll { $0.timestamp < cutoff }
    }
}
