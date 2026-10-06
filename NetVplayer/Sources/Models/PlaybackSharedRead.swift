import Foundation

/// Cancellation belongs to a reader, not to everyone sharing the same range.
/// The underlying read is stopped only after its last reader leaves.
public final class PlaybackSharedRead<Value: Sendable>: @unchecked Sendable {
    private struct Waiter {
        let phase: PlaybackTransferPhase
        let continuation: CheckedContinuation<Value, Error>
    }
    private let lock = NSLock()
    private var result: Swift.Result<Value, Error>?
    private var waiters: [UUID: Waiter] = [:]
    private var cancelledWaiters: Set<UUID> = []
    private let task: Task<Value, Error>

    public init(task: Task<Value, Error>) {
        self.task = task
        Task { [weak self] in
            let result = await task.result
            self?.complete(result)
        }
    }

    public var hasForegroundReaders: Bool {
        lock.withLock { waiters.values.contains { Self.isForeground($0.phase) } }
    }

    public var isCancelled: Bool {
        lock.withLock { if case .failure(let error) = result { return error is CancellationError }; return false }
    }

    public func value(phase: PlaybackTransferPhase = .playback) async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let immediate: Swift.Result<Value, Error>? = lock.withLock {
                    if cancelledWaiters.remove(id) != nil { return .failure(CancellationError()) }
                    if let result { return result }
                    waiters[id] = Waiter(phase: phase, continuation: continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    public func cancel() {
        task.cancel()
        complete(.failure(CancellationError()))
    }

    /// Returns true when no foreground reader needs the underlying transfer.
    @discardableResult
    public func cancelBackgroundReaders() -> Bool {
        let state: ([Waiter], Bool) = lock.withLock {
            let removed = waiters.filter { !Self.isForeground($0.value.phase) }
            for id in removed.keys { waiters.removeValue(forKey: id) }
            let stop = waiters.isEmpty
            if stop, result == nil { result = .failure(CancellationError()) }
            return (Array(removed.values), stop)
        }
        for waiter in state.0 { waiter.continuation.resume(throwing: CancellationError()) }
        if state.1 { task.cancel() }
        return state.1
    }

    private func cancelWaiter(_ id: UUID) {
        let state: (Waiter?, Bool) = lock.withLock {
            guard let waiter = waiters.removeValue(forKey: id) else {
                if result == nil { cancelledWaiters.insert(id) }
                return (nil, false)
            }
            let stop = waiters.isEmpty && result == nil
            if stop { result = .failure(CancellationError()) }
            return (waiter, stop)
        }
        state.0?.continuation.resume(throwing: CancellationError())
        if state.1 { task.cancel() }
    }

    private func complete(_ outcome: Swift.Result<Value, Error>) {
        let pending: [Waiter] = lock.withLock {
            guard result == nil else { return [] }
            result = outcome
            let pending = Array(waiters.values)
            waiters.removeAll()
            cancelledWaiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.continuation.resume(with: outcome) }
    }

    private static func isForeground(_ phase: PlaybackTransferPhase) -> Bool {
        phase == .playback || phase == .startup || phase == .seek
    }
}
