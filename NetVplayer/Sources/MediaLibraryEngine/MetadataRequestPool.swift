import Foundation

/// Limits apply separately to the search and detail pools. Only successful empty
/// searches are negative entries; failures and incomplete coverage are never cached.
public struct MetadataCachePolicy: Sendable {
    public var positiveTTL: Duration
    public var negativeTTL: Duration
    public var positiveCapacity: Int
    public var negativeCapacity: Int
    public var maximumBytes: Int
    public init(positiveTTL: Duration = .seconds(1800), negativeTTL: Duration = .seconds(60),
                positiveCapacity: Int = 256, negativeCapacity: Int = 128, maximumBytes: Int = 4 * 1024 * 1024) {
        self.positiveTTL = max(.zero, min(.seconds(1800), positiveTTL))
        self.negativeTTL = max(.zero, min(.seconds(60), negativeTTL))
        self.positiveCapacity = max(0, min(256, positiveCapacity))
        self.negativeCapacity = max(0, min(128, negativeCapacity))
        self.maximumBytes = max(0, min(4 * 1024 * 1024, maximumBytes))
    }
}

enum MetadataCacheDisposition { case positive, negative, uncached }

private final class MetadataWaiterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

/// Completion owns cache publication. A cancelled last waiter detaches the flight
/// before cancelling its transport; a late uncooperative result cannot replace a
/// newer flight or repopulate the cache. Cancelling one waiter leaves others alive.
actor MetadataRequestPool<Value: Sendable> {
    struct Response: Sendable { let value: Value; let reused: Bool }
    struct Statistics: Sendable { let positive: Int; let negative: Int; let bytes: Int; let flights: Int; let waiters: Int }
    private struct Entry {
        let value: Value
        let inserted: ContinuousClock.Instant
        let expires: ContinuousClock.Instant
        let cost: Int
        let negative: Bool
        var access: UInt64
    }
    private struct Waiter {
        let continuation: CheckedContinuation<Response, any Error>
        let cancellation: MetadataWaiterCancellation
        let reused: Bool
    }
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }
    private var entries: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private var bytes = 0
    private var access: UInt64 = 0
    private let policy: MetadataCachePolicy
    private let disposition: @Sendable (Value) -> MetadataCacheDisposition
    private let cost: @Sendable (Value) -> Int
    private let now: @Sendable () -> ContinuousClock.Instant
    init(policy: MetadataCachePolicy = .init(), disposition: @escaping @Sendable (Value) -> MetadataCacheDisposition,
         cost: @escaping @Sendable (Value) -> Int, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.policy = policy; self.disposition = disposition; self.cost = cost; self.now = now
    }
    func value(for key: String, cachedAfter: ContinuousClock.Instant? = nil,
               operation: @escaping @Sendable () async throws -> Value) async throws -> Response {
        try Task.checkCancellation()
        prune()
        if var entry = entries[key], cachedAfter == nil || entry.inserted >= cachedAfter! {
            access &+= 1; entry.access = access; entries[key] = entry
            return .init(value: entry.value, reused: true)
        }
        // A forced refresh supersedes older positive/negative evidence even when
        // the refresh later fails. It must not reveal the old miss again.
        if cachedAfter != nil { remove(key) }
        let waiterID = UUID(), cancellation = MetadataWaiterCancellation()
        let response: Response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = flights[key] {
                    flight.waiters[waiterID] = .init(continuation: continuation, cancellation: cancellation, reused: true)
                    flights[key] = flight
                } else {
                    let flightID = UUID()
                    let task = Task {
                        let result: Result<Value, any Error>
                        do { result = .success(try await operation()) }
                        catch { result = .failure(error) }
                        self.complete(key: key, id: flightID, result: result)
                    }
                    flights[key] = .init(id: flightID, task: task, waiters: [waiterID: .init(
                        continuation: continuation, cancellation: cancellation, reused: false)])
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(key: key, waiterID: waiterID) }
        }
        try Task.checkCancellation()
        return response
    }
    private func cancel(key: String, waiterID: UUID) {
        guard var flight = flights[key], let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty { flights[key] = nil; flight.task.cancel() }
        else { flights[key] = flight }
    }
    private func complete(key: String, id: UUID, result: Result<Value, any Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights[key] = nil
        let live = flight.waiters.values.filter { !$0.cancellation.isCancelled }
        if !live.isEmpty, case .success(let value) = result { insert(value, key: key) }
        for waiter in flight.waiters.values {
            if waiter.cancellation.isCancelled { waiter.continuation.resume(throwing: CancellationError()) }
            else { waiter.continuation.resume(with: result.map { .init(value: $0, reused: waiter.reused) }) }
        }
    }
    private func remove(_ key: String) { if let entry = entries.removeValue(forKey: key) { bytes -= entry.cost } }
    private func prune() {
        let instant = now()
        for key in entries.keys where entries[key]!.expires <= instant { remove(key) }
    }
    private func insert(_ value: Value, key: String) {
        prune()
        let negative: Bool
        switch disposition(value) {
        case .uncached: return
        case .positive: negative = false
        case .negative: negative = true
        }
        let ttl = negative ? policy.negativeTTL : policy.positiveTTL
        let capacity = negative ? policy.negativeCapacity : policy.positiveCapacity
        let size = max(0, cost(value)) + key.utf8.count
        guard ttl > .zero, capacity > 0, size <= policy.maximumBytes else { return }
        remove(key)
        while entries.values.filter({ $0.negative == negative }).count >= capacity {
            if let oldest = entries.filter({ $0.value.negative == negative }).min(by: { $0.value.access < $1.value.access })?.key { remove(oldest) }
        }
        while bytes + size > policy.maximumBytes {
            if let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key { remove(oldest) }
        }
        let instant = now(); access &+= 1
        entries[key] = .init(value: value, inserted: instant, expires: instant.advanced(by: ttl), cost: size, negative: negative, access: access)
        bytes += size
    }
    func statistics() -> Statistics {
        prune()
        let negatives = entries.values.filter(\.negative).count
        return .init(positive: entries.count - negatives, negative: negatives, bytes: bytes, flights: flights.count,
                     waiters: flights.values.reduce(0) { $0 + $1.waiters.count })
    }
}
