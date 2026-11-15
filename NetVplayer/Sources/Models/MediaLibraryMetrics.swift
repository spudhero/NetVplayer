import Foundation

/// Numeric diagnostics only. A poster milestone means its metadata address is
/// available, not that its pixels have been downloaded or presented on screen.
public struct MediaLibraryMetrics: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case completed, cancelled, paused }
    public var runID: UUID
    public var elapsedSeconds: TimeInterval = 0
    public var firstFileSeconds: TimeInterval?
    public var scanFinishedSeconds: TimeInterval?
    public var matchStartedSeconds: TimeInterval?
    public var firstOnlineMetadataSeconds: TimeInterval?
    public var firstOnlinePosterAddressSeconds: TimeInterval?
    public var matchFinishedSeconds: TimeInterval?
    public var matchOutcome: Outcome?
    /// Provider method invocations, not HTTP request counts (aliases may fan out).
    public var providerSearchCalls = 0
    public var providerDetailCalls = 0
    /// Reused search/detail results (including joined inflight work), plus records
    /// already matched. One file can reuse both a search and a detail response.
    public var cacheHits = 0
    public var candidates = 0
    public var processed = 0
    public var matched = 0
    public var needsConfirmation = 0
    public var unmatched = 0
    public var failedItems: Int?
    public var matchQueuePeak: Int?
    public var matchBackpressureWaits: Int?
    public init(runID: UUID = UUID()) { self.runID = runID }

    public func projected() -> Self {
        var result = self
        func duration(_ value: TimeInterval?) -> TimeInterval? {
            value.flatMap { $0.isFinite && $0 >= 0 ? min($0, 7 * 24 * 3600) : nil }
        }
        result.elapsedSeconds = duration(elapsedSeconds) ?? 0
        for key in [\Self.firstFileSeconds, \.scanFinishedSeconds, \.matchStartedSeconds,
                    \.firstOnlineMetadataSeconds, \.firstOnlinePosterAddressSeconds, \.matchFinishedSeconds] {
            result[keyPath: key] = duration(result[keyPath: key])
        }
        for key in [\Self.providerSearchCalls, \.providerDetailCalls, \.cacheHits, \.candidates,
                    \.processed, \.matched, \.needsConfirmation, \.unmatched] {
            result[keyPath: key] = min(10_000_000, max(0, result[keyPath: key]))
        }
        result.matchQueuePeak = matchQueuePeak.map { min(10_000_000, max(0, $0)) }
        result.failedItems = failedItems.map { min(10_000_000, max(0, $0)) }
        result.matchBackpressureWaits = matchBackpressureWaits.map { min(10_000_000, max(0, $0)) }
        return result
    }
}
