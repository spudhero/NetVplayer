import Foundation

/// All provider instances share a lane, including browser fallback. A monotonic
/// cooldown starts after completion, so delayed task scheduling cannot bunch up
/// previously reserved slots. This conservatively spaces starts by at least 1s.
actor DoubanRequestLimiter {
    static let shared = DoubanRequestLimiter()
    private let interval: Duration
    private var nextStart: ContinuousClock.Instant?
    private var active = false
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    init(interval: Duration = .seconds(1)) { self.interval = max(.zero, interval) }
    func perform(_ operation: @escaping @Sendable () async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
        try await acquire()
        defer {
            nextStart = .now.advanced(by: interval)
            if waiters.isEmpty { active = false }
            else { waiters.removeFirst().1.resume(returning: true) }
        }
        try Task.checkCancellation()
        if let nextStart { try await Task.sleep(until: nextStart, clock: .continuous) }
        try Task.checkCancellation()
        return try await operation()
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if !active { active = true; return }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        guard acquired else { throw CancellationError() }
    }
    private func cancel(_ id: UUID) {
        guard let position = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: position).1.resume(returning: false)
    }
}
