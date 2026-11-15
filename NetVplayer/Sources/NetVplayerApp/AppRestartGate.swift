import Foundation

/// A lease covers the whole update/translation restart, including asynchronous cleanup.
/// Releasing an old lease cannot release its successor or invoke a stale SDK callback.
@MainActor
final class AppRestartGate {
    static let shared = AppRestartGate()

    enum Owner { case update, language }
    struct Lease: Equatable {
        let owner: Owner
        fileprivate let generation = UUID()
    }

    private(set) var lease: Lease?
    private var preparation: Task<Bool, Never>?
    private var prepared = false
    private var delivered = false

    func acquire(_ owner: Owner) -> Lease? {
        guard lease == nil else { return nil }
        let value = Lease(owner: owner)
        lease = value
        return value
    }

    func owns(_ value: Lease) -> Bool { lease == value }

    func release(_ value: Lease) {
        guard owns(value) else { return }
        // Cancellation invalidates the continuation, not the underlying startup cleanup.
        lease = nil
        preparation = nil
        prepared = false
        delivered = false
    }

    func prepare(_ value: Lease, cleanup: @escaping @MainActor () async -> Bool) async -> Bool {
        guard owns(value) else { return false }
        if prepared { return true }
        let task: Task<Bool, Never>
        if let preparation { task = preparation }
        else {
            task = Task { @MainActor in await cleanup() }
            preparation = task
        }
        let completed = await task.value
        guard owns(value) else { return false }
        if completed { prepared = true }
        else { preparation = nil } // A real failure may be retried; no deadline means success.
        return completed
    }

    @discardableResult
    func deliver(_ value: Lease, action: () throws -> Void) rethrows -> Bool {
        guard owns(value), prepared, !delivered else { return false }
        // Consume before calling reentrant framework code. A throwing helper launch is retryable.
        delivered = true
        do { try action() }
        catch { delivered = false; throw error }
        return true
    }
}
