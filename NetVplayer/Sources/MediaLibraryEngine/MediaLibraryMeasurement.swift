import Foundation
import Models

/// Shared by scan and match jobs. Monotonic time survives actor interleaving;
/// each run owns its measurement so a late cancelled job cannot overwrite it.
final class MediaLibraryMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MediaLibraryMetrics
    private let elapsed: @Sendable () -> TimeInterval
    init(runID: UUID = UUID(), elapsed: (@Sendable () -> TimeInterval)? = nil) {
        value = .init(runID: runID)
        let start = ContinuousClock.now
        self.elapsed = elapsed ?? {
            let duration = start.duration(to: .now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
    }
    func mark(_ key: WritableKeyPath<MediaLibraryMetrics, TimeInterval?>) {
        lock.withLock { if value[keyPath: key] == nil { value[keyPath: key] = elapsed() } }
    }
    func increment(_ key: WritableKeyPath<MediaLibraryMetrics, Int>, by count: Int = 1) {
        lock.withLock { value[keyPath: key] += count }
    }
    func onlineMetadataAvailable(_ record: MediaRecord) {
        guard record.onlineMetadata.title != nil else { return }
        mark(\.firstOnlineMetadataSeconds)
        if let poster = record.onlineMetadata.poster, !poster.isEmpty { mark(\.firstOnlinePosterAddressSeconds) }
    }
    func finish(_ progress: MetadataMatchProgress, cancelled: Bool, paused: Bool = false) {
        lock.withLock {
            value.matchFinishedSeconds = elapsed()
            value.matchOutcome = cancelled ? .cancelled : !paused && progress.completed == progress.total ? .completed : .paused
            value.processed = progress.completed; value.matched = progress.matched
            value.needsConfirmation = progress.needsConfirmation; value.unmatched = progress.unmatched
            value.failedItems = progress.failed
        }
    }
    func snapshot() -> MediaLibraryMetrics {
        lock.withLock { var copy = value; copy.elapsedSeconds = elapsed(); return copy.projected() }
    }
    func observeQueueDepth(_ depth: Int) {
        lock.withLock { value.matchQueuePeak = max(value.matchQueuePeak ?? 0, depth) }
    }
    func recordBackpressure() {
        lock.withLock { value.matchBackpressureWaits = (value.matchBackpressureWaits ?? 0) + 1 }
    }
}
