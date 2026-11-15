import Foundation

/// Bounded per-search fanout plus a process-wide alias permit pool. Retries are
/// for transient alias reads only; provider-wide error policy belongs to matcher.
public struct TMDBAliasPolicy: Sendable {
    public let concurrency: Int
    public let requestTimeout: Duration
    public let totalTimeout: Duration
    public let retryBudget: Int
    public let retryDelay: Duration
    public init(concurrency: Int = 4, requestTimeout: Duration = .seconds(6), totalTimeout: Duration = .seconds(12),
                retryBudget: Int = 4, retryDelay: Duration = .milliseconds(200)) {
        self.concurrency = max(1, min(4, concurrency))
        self.requestTimeout = max(.milliseconds(1), min(.seconds(6), requestTimeout))
        self.totalTimeout = max(.milliseconds(1), min(.seconds(12), totalTimeout))
        self.retryBudget = max(0, min(4, retryBudget)); self.retryDelay = max(.zero, min(.seconds(1), retryDelay))
    }
}

actor TMDBAliasRetries {
    private var remaining: Int
    init(_ remaining: Int) { self.remaining = remaining }
    func take() -> Bool { guard remaining > 0 else { return false }; remaining -= 1; return true }
}

actor TMDBAliasLimiter {
    static let shared = TMDBAliasLimiter()
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    func acquire() async throws {
        try Task.checkCancellation()
        if active < 4 { active += 1; return }
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
    func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().1.resume(returning: true) }
    }
}
