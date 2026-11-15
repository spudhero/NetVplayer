import Foundation
import Models

/// Search homepage evidence is independent of the historical mixed site-health log.
public final class SearchPerformanceStore: @unchecked Sendable {
    public static let shared = SearchPerformanceStore()
    public static let maximumSources = 512
    public static let maximumSamplesPerSource = 32
    public static let retention: TimeInterval = 14 * 86_400
    private static let filename = "search_performance_v1.json"

    public struct Attempt: Sendable {
        let identity: String
        let generation: UUID
        public let phase: SearchPerformancePhase
    }

    private let storage: StorageManager
    private let lock = NSLock()
    private let persistenceQueue = DispatchQueue(label: "com.netvplayer.search-performance", qos: .utility)
    private var samples: [String: [SearchPerformanceSample]]
    // A bounded process-local admission history; it is deliberately never restored from disk.
    private var admitted: [String: Date] = [:]
    private var generation = UUID()
    private var revision: UInt64 = 0
    private var writeScheduled = false

    public init(storage: StorageManager = .shared, now: Date = Date()) {
        self.storage = storage
        samples = (try? storage.loadBounded([String: [SearchPerformanceSample]].self,
            from: Self.filename, maximumBytes: 4 * 1_024 * 1_024)) ?? [:]
        pruneLocked(now: now)
    }

    /// Called only after a physical Provider slot was acquired, once per logical homepage.
    public func beginAttempt(identity: String, now: Date = Date()) -> Attempt {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        let phase: SearchPerformancePhase = admitted[identity] == nil ? .first : .subsequent
        admitted[identity] = now
        trimAdmissionsLocked()
        return Attempt(identity: identity, generation: generation, phase: phase)
    }

    public func record(_ attempt: Attempt, success: Bool, durationMs: Double, now: Date = Date()) {
        guard durationMs.isFinite, durationMs >= 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard attempt.generation == generation else { return } // Clearing also invalidates in-flight writers.
        samples[attempt.identity, default: []].append(.init(timestamp: now, phase: attempt.phase,
            success: success, durationMs: min(durationMs, 3_600_000)))
        pruneLocked(now: now)
        scheduleWriteLocked()
    }

    public func summaries(now: Date = Date()) -> [String: SearchPerformanceSummary] {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        return samples.reduce(into: [:]) { result, entry in
            result[entry.key] = SearchPerformanceSummary(samples: entry.value,
                nextPhase: admitted[entry.key] == nil ? .first : .subsequent, now: now)
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        generation = UUID()
        samples.removeAll()
        admitted.removeAll()
        scheduleWriteLocked()
    }

    public func flushPendingWrites() { persistenceQueue.sync {} }

    private func pruneLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        samples = samples.compactMapValues { values in
            let recent = values.filter {
                $0.timestamp >= cutoff && $0.timestamp <= now && $0.durationMs.isFinite
                    && $0.durationMs >= 0 && $0.durationMs <= 3_600_000
            }.sorted { $0.timestamp < $1.timestamp }.suffix(Self.maximumSamplesPerSource)
            return recent.isEmpty ? nil : Array(recent)
        }
        if samples.count > Self.maximumSources {
            let retained = samples.keys.sorted {
                let lhs = samples[$0]?.last?.timestamp ?? .distantPast
                let rhs = samples[$1]?.last?.timestamp ?? .distantPast
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }.prefix(Self.maximumSources)
            samples = Dictionary(uniqueKeysWithValues: retained.map { ($0, samples[$0]!) })
        }
        admitted = admitted.filter { $0.value >= cutoff }
    }

    private func trimAdmissionsLocked() {
        if admitted.count > Self.maximumSources,
           let oldest = admitted.min(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value })?.key {
            admitted[oldest] = nil
        }
    }

    /// At most one queued writer holds the latest bounded snapshot, even during a burst.
    private func scheduleWriteLocked() {
        revision &+= 1
        guard !writeScheduled else { return }
        writeScheduled = true
        persistenceQueue.async { [self] in
            while true {
                lock.lock()
                let snapshot = samples, writingRevision = revision
                lock.unlock()
                try? storage.save(snapshot, to: Self.filename)
                lock.lock()
                if revision == writingRevision {
                    writeScheduled = false
                    lock.unlock()
                    return
                }
                lock.unlock()
            }
        }
    }
}
