// Storage/LiveLineHealthStore.swift
// JSON-backed live line quality cache.

import Foundation
import Models

public final class LiveLineHealthStore: @unchecked Sendable {
    public static let shared = LiveLineHealthStore()

    private let storage: StorageManager
    private let filename = "live_line_health.json"
    private let lock = NSLock()
    private var events: [LiveLineHealthEvent]

    public init(storage: StorageManager = .shared) {
        self.storage = storage
        self.events = (try? storage.load([LiveLineHealthEvent].self, from: filename)) ?? []
        pruneLocked(now: Date())
    }

    public func record(_ event: LiveLineHealthEvent) {
        lock.lock()
        events.append(event)
        pruneLocked(now: Date())
        let snapshot = events
        lock.unlock()
        try? storage.save(snapshot, to: filename)
    }

    public func summaries(now: Date = Date()) -> [LiveLineHealthSummary] {
        lock.lock()
        let snapshot = events
        lock.unlock()
        return LiveLineHealthPolicy.summaries(from: snapshot, now: now)
    }

    public func clear() {
        lock.lock()
        events = []
        lock.unlock()
        try? storage.save([LiveLineHealthEvent](), to: filename)
    }

    private func pruneLocked(now: Date) {
        events = LiveLineHealthPolicy.prune(events, now: now)
    }
}
