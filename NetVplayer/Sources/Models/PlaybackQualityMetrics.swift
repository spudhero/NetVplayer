import Foundation

public struct PlaybackLatencyDistribution: Codable, Sendable, Equatable {
    public let count: Int
    public let p50: Double?
    public let p95: Double?
    public let samples: [Double]
    init(_ values: [Double]) {
        samples = values; count = values.count
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double? {
            sorted.isEmpty ? nil : sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)]
        }
        p50 = percentile(0.5); p95 = percentile(0.95)
    }
}

public struct PlaybackQualitySnapshot: Codable, Sendable, Equatable {
    public let startupFirstFrame: PlaybackLatencyDistribution
    public let seekFirstFrame: PlaybackLatencyDistribution
    public let stallCount: Int
    public let totalStallSeconds: Double
    public let recoveredStallSeconds: [Double]
    public let restallIntervals: PlaybackLatencyDistribution
    public let cancelledStartups: Int
    public let cancelledSeeks: Int
    public var summary: PlaybackQualitySummary {
        .init(startupSamples: startupFirstFrame.count, startupP50: startupFirstFrame.p50, startupP95: startupFirstFrame.p95,
              seekSamples: seekFirstFrame.count, seekP50: seekFirstFrame.p50, seekP95: seekFirstFrame.p95,
              stallCount: stallCount, totalStallSeconds: totalStallSeconds,
              restallSamples: restallIntervals.count, restallP50: restallIntervals.p50, restallP95: restallIntervals.p95)
    }
}

/// Small, credential-free diagnostic export. Percentiles use the last 256
/// completed samples; stall count and total wait cover this engine's lifetime.
public struct PlaybackQualitySummary: Codable, Sendable, Equatable {
    public let startupSamples: Int
    public let startupP50: Double?
    public let startupP95: Double?
    public let seekSamples: Int
    public let seekP50: Double?
    public let seekP95: Double?
    public let stallCount: Int
    public let totalStallSeconds: Double
    public let restallSamples: Int
    public let restallP50: Double?
    public let restallP95: Double?
}

/// Monotonic timings, bounded history, fresh host swaps only. Startup/seek cache
/// waits and intentional pauses are excluded from rebuffering statistics.
public final class PlaybackQualityMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var startup: [Double] = []
    private var seeks: [Double] = []
    private var stalls: [Double] = []
    private var intervals: [Double] = []
    private var pendingStartup: Double?
    private var pendingSeek: Double?
    private var stallStart: Double?
    private var lastRecovery: Double?
    private var stallCount = 0
    private var stallTotal = 0.0
    private var cancelledStartups = 0
    private var cancelledSeeks = 0
    private var ready = false
    public init(capacity: Int = 256) { self.capacity = max(1, capacity) }
    public func beginLoad(now: Double) {
        lock.withLock {
            cancelPending(now: now)
            lastRecovery = nil; pendingStartup = now; ready = false
        }
    }
    public func beginSeek(now: Double) {
        lock.withLock {
            if pendingSeek != nil { cancelledSeeks += 1 }
            if pendingStartup != nil { cancelledStartups += 1; pendingStartup = nil }
            finishStall(now: now); lastRecovery = nil
            pendingSeek = now; ready = false
        }
    }
    public func mediaReady() { lock.withLock { ready = true } }
    public func presentedFreshFrame(now: Double) {
        lock.withLock {
            guard ready else { return }
            if let start = pendingStartup { append(max(0, now - start), to: &startup); pendingStartup = nil }
            if let start = pendingSeek { append(max(0, now - start), to: &seeks); pendingSeek = nil }
        }
    }
    public func cachePause(_ paused: Bool, eligible: Bool, now: Double) {
        lock.withLock {
            if paused, eligible, pendingStartup == nil, pendingSeek == nil, stallStart == nil {
                if let recovery = lastRecovery { append(max(0, now - recovery), to: &intervals) }
                stallStart = now; stallCount += 1
            } else if !paused || !eligible { finishStall(now: now) }
            if !eligible { lastRecovery = nil }
        }
    }
    public func stop(now: Double) { lock.withLock { cancelPending(now: now); ready = false; lastRecovery = nil } }
    public func snapshot(now: Double = ProcessInfo.processInfo.systemUptime) -> PlaybackQualitySnapshot {
        lock.withLock {
            .init(startupFirstFrame: .init(startup), seekFirstFrame: .init(seeks), stallCount: stallCount,
                  totalStallSeconds: stallTotal + (stallStart.map { max(0, now - $0) } ?? 0),
                  recoveredStallSeconds: stalls, restallIntervals: .init(intervals),
                  cancelledStartups: cancelledStartups, cancelledSeeks: cancelledSeeks)
        }
    }
    private func cancelPending(now: Double) {
        if pendingStartup != nil { cancelledStartups += 1 }; pendingStartup = nil
        if pendingSeek != nil { cancelledSeeks += 1 }; pendingSeek = nil
        finishStall(now: now)
    }
    private func finishStall(now: Double) {
        guard let start = stallStart else { return }
        let duration = max(0, now - start)
        stallTotal += duration; append(duration, to: &stalls)
        stallStart = nil; lastRecovery = now
    }
    private func append(_ value: Double, to values: inout [Double]) {
        guard value.isFinite else { return }
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}
