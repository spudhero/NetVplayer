import Foundation

/// Shared pressure signal, with hysteresis, for next-media, SDK, and preview work.
/// Player sessions are independent; any active network player can reserve bandwidth.
public final class PlaybackBackgroundBudget: @unchecked Sendable {
    public static let shared = PlaybackBackgroundBudget()
    private let lock = NSLock()
    private var permittedSessions: [String: Bool] = [:]
    private var suspendedUntil = Date.distantPast
    private var foregroundReads = 0
    private var windows: [UUID: Bool] = [:]
    private var tracksWindows = false
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var publishedWindowPermission = true
    private var publishedOptionalPermission = true
    private var cooldownWake: DispatchWorkItem?

    /// Window visibility gates optional artwork/feed work only. Media read-ahead
    /// retains its independent byte/slot and congestion contract below.
    public var permitsVisibleWork: Bool { lock.withLock { windowPermittedLocked } }
    public var permitsOptionalWork: Bool { lock.withLock { windowPermittedLocked && permitsLocked } }
    private var windowPermittedLocked: Bool { !tracksWindows || windows.values.contains(true) }

    public func updateWindow(_ id: UUID, visible: Bool) {
        lock.withLock { tracksWindows = true; windows[id] = visible }
        notifyPermissionChange()
    }

    public func removeWindow(_ id: UUID) {
        _ = lock.withLock { windows.removeValue(forKey: id) }
        notifyPermissionChange()
    }

    /// Subscribe before checking permission, so recovery cannot be lost between
    /// checking the gate and parking a task. Each observer retains one wake only.
    public func permissionChanges() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.withLock { observers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.observers.removeValue(forKey: id) }
            }
            continuation.yield(())
        }
    }

    private func notifyPermissionChange() {
        let listeners = lock.withLock { () -> [AsyncStream<Void>.Continuation] in
            let visible = windowPermittedLocked, optional = visible && permitsLocked
            guard visible != publishedWindowPermission || optional != publishedOptionalPermission else { return [] }
            publishedWindowPermission = visible; publishedOptionalPermission = optional
            return Array(observers.values)
        }
        for listener in listeners { listener.yield(()) }
    }

    public func waitForOptionalPermission() async throws {
        for await _ in permissionChanges() {
            try Task.checkCancellation()
            if permitsOptionalWork { return }
        }
        throw CancellationError()
    }
    private var reservations: [UUID: Int64] = [:]
    private var waiting: [UUID: Int] = [:]
    private let maximumConcurrentReads: Int
    private let maximumBytes: Int64

    public init(maximumConcurrentReads: Int = 2, maximumBytes: Int64 = PlaybackTransferProfile.backgroundByteLimit) {
        self.maximumConcurrentReads = max(1, maximumConcurrentReads)
        self.maximumBytes = max(1, maximumBytes)
    }

    public func update(session: String, bufferedAhead: Double,
                       isLoading: Bool, isSeeking: Bool, isBuffering: Bool) {
        defer { notifyPermissionChange() }
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

    public func remove(session: String) {
        _ = lock.withLock { permittedSessions.removeValue(forKey: session) }
        notifyPermissionChange()
    }
    public func suspendBackgroundWork(for seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        lock.withLock {
            suspendedUntil = max(suspendedUntil, Date().addingTimeInterval(max(0, seconds)))
            cooldownWake?.cancel()
            let wake = DispatchWorkItem { [weak self] in self?.notifyPermissionChange() }
            cooldownWake = wake
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, suspendedUntil.timeIntervalSinceNow), execute: wake)
        }
        notifyPermissionChange()
    }
    public var permitsBackgroundWork: Bool {
        lock.withLock { permitsLocked }
    }

    private var permitsLocked: Bool {
        Date() >= suspendedUntil && foregroundReads == 0 && !permittedSessions.values.contains(false)
    }

    public var reservedBytes: Int64 { lock.withLock { reservations.values.reduce(0, +) } }
    public var activeBackgroundReads: Int { lock.withLock { reservations.count } }
    public var waitingReadCount: Int { lock.withLock { waiting.count } }

    /// Read-ahead, preview, subtitle and next-item ranges share these slots/bytes.
    /// Foreground misses bypass the queue. Current-media read-ahead must keep
    /// filling a low buffer; auxiliary work waits until foreground pressure ends.
    public func withRead<T: Sendable>(owner: PlaybackReadOwner? = PlaybackReadScope.owner,
                                     purpose: PlaybackReadPurpose = .nextEpisode, bytes: Int64,
                                     operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let priority = PlaybackReadScope.priority
        let purpose = owner?.purpose ?? priority?.purpose ?? purpose
        try owner?.check()
        if !purpose.isBackground {
            lock.withLock { foregroundReads += 1 }
            notifyPermissionChange()
            defer { lock.withLock { foregroundReads -= 1 }; notifyPermissionChange() }
            let value = try await operation()
            try owner?.check()
            return value
        }
        // Callers must split speculation into bounded ranges. Reserving a
        // smaller number than the actual read would only hide over-budget I/O.
        guard bytes >= 0, bytes <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        let id = UUID()
        let reservation = max(1, bytes)
        var promoted = false
        lock.withLock { waiting[id] = purpose.priority }
        defer { lock.withLock {
            waiting.removeValue(forKey: id); reservations.removeValue(forKey: id)
            if promoted { foregroundReads -= 1 }
        }; notifyPermissionChange() }
        while true {
            try Task.checkCancellation()
            try owner?.check()
            let admitted = lock.withLock {
                if priority?.isForeground == true {
                    foregroundReads += 1; promoted = true; waiting.removeValue(forKey: id); return true
                }
                // Read-ahead supplies the current movie. Pausing it until that
                // movie has enough data serializes each range behind demand and
                // can prevent the buffer from recovering. Keep its slot/byte
                // bounds and explicit congestion cooldown, but let it overlap
                // foreground reads even when bufferedAhead is below the gate.
                let permitted = purpose == .readAhead ? Date() >= suspendedUntil : permitsLocked
                guard permitted, reservations.count < maximumConcurrentReads,
                      reservations.values.reduce(0, +) <= maximumBytes - reservation,
                      !waiting.values.contains(where: { $0 > purpose.priority }) else { return false }
                waiting.removeValue(forKey: id); reservations[id] = reservation
                return true
            }
            notifyPermissionChange()
            if admitted { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let value = try await operation()
        try owner?.check()
        return value
    }

    public func waitForBackgroundPermission() async throws {
        while !permitsBackgroundWork {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
        }
        try Task.checkCancellation()
    }
}
