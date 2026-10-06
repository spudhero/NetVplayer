import Foundation

/// Shared pressure signal, with hysteresis, for next-media, SDK, and preview work.
/// Player sessions are independent; any active network player can reserve bandwidth.
public final class PlaybackBackgroundBudget: @unchecked Sendable {
    public static let shared = PlaybackBackgroundBudget()
    private let lock = NSLock()
    private var permittedSessions: [String: Bool] = [:]
    private var suspendedUntil = Date.distantPast

    public init() {}

    public func update(session: String, bufferedAhead: Double,
                       isLoading: Bool, isSeeking: Bool, isBuffering: Bool) {
        lock.withLock {
            let ahead = bufferedAhead.isFinite ? max(0, bufferedAhead) : 0
            if isLoading || isSeeking || isBuffering || ahead < PlaybackTransferProfile.pauseBackgroundBelowSeconds {
                permittedSessions[session] = false
            } else if ahead >= PlaybackTransferProfile.resumeBackgroundAtSeconds {
                permittedSessions[session] = true
            } else if permittedSessions[session] == nil {
                permittedSessions[session] = false
            }
        }
    }

    public func remove(session: String) { _ = lock.withLock { permittedSessions.removeValue(forKey: session) } }
    public func suspendBackgroundWork(for seconds: TimeInterval) {
        lock.withLock { suspendedUntil = max(suspendedUntil, Date().addingTimeInterval(max(0, seconds))) }
    }
    public var permitsBackgroundWork: Bool {
        lock.withLock { Date() >= suspendedUntil && !permittedSessions.values.contains(false) }
    }

    public func waitForBackgroundPermission() async throws {
        while !permitsBackgroundWork {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
        }
        try Task.checkCancellation()
    }
}
