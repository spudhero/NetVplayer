import Foundation
import Storage

/// One logical homepage can make two Provider calls for punctuation fallback.
/// Start at the first admission, excluding time spent waiting for a physical slot.
final class SearchPerformanceMeasurement: @unchecked Sendable {
    private let store: SearchPerformanceStore?
    private let identity: String
    private let lock = NSLock()
    private var startedAt: ContinuousClock.Instant?
    private var attempt: SearchPerformanceStore.Attempt?

    init(store: SearchPerformanceStore?, identity: String) {
        self.store = store
        self.identity = identity
    }

    func begin() {
        guard let store else { return }
        lock.lock()
        defer { lock.unlock() }
        guard startedAt == nil else { return }
        startedAt = .now
        attempt = store.beginAttempt(identity: identity)
    }

    func finish(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let store, let attempt, let startedAt else { return }
        let elapsed = startedAt.duration(to: .now).components
        store.record(attempt, success: success,
            durationMs: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        self.attempt = nil
    }
}
