import Foundation
import Models
import Storage

/// One producer and one consumer per scan. SQLite owns the work; waiters only
/// carry wakeups, so a restart cannot lose accepted files or retain a giant array.
actor ScanMatchQueue {
    let library: MediaLibraryConfiguration
    let revision: String
    let runID: UUID
    let validate: @Sendable () throws -> Void
    private let index: MediaIndex
    private let capacity: Int
    private let measurement: MediaLibraryMeasurement
    private var closed = false
    private var stopped = false
    private var generation = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(library: MediaLibraryConfiguration, revision: String, runID: UUID, index: MediaIndex,
         capacity: Int, measurement: MediaLibraryMeasurement, validate: @escaping @Sendable () throws -> Void) {
        self.library = library; self.revision = revision; self.runID = runID; self.index = index
        self.capacity = max(1, min(capacity, MediaIndex.maximumPendingMatches))
        self.measurement = measurement; self.validate = validate
    }
    func append(_ record: MediaRecord, rematch: Bool) async throws {
        while true {
            let observed = generation
            try checkCurrent()
            guard !closed else { throw MediaScanRecoveryError.superseded }
            let count = try await index.pendingMatchCount(libraryID: library.id)
            try checkCurrent()
            if count < capacity {
                try await index.upsertScanned(record, runID: runID, queueForMatching: true, rematch: rematch, validate: validate)
                measurement.observeQueueDepth(count + 1)
                wake(); return
            }
            measurement.recordBackpressure()
            await wait(after: observed)
        }
    }
    func next() async throws -> MediaIndex.MatchWork? {
        while true {
            let observed = generation
            try checkCurrent()
            let work = try await index.nextMatch(libraryID: library.id, runID: runID)
            try checkCurrent()
            if let work { return work }
            if closed { return nil }
            await wait(after: observed)
        }
    }
    func pendingCount() async throws -> Int { try await index.pendingMatchCount(libraryID: library.id) }
    func consumed() { wake() }
    func finish() { closed = true; wake() }
    func stop() async {
        stopped = true; wake()
        try? await index.interruptMatching(libraryID: library.id, runID: runID)
    }
    private func checkCurrent() throws {
        try Task.checkCancellation()
        guard !stopped else { throw MediaScanRecoveryError.unavailable }
        try validate()
    }
    private func wake() {
        generation += 1
        let pending = waiters; waiters.removeAll()
        for continuation in pending.values { continuation.resume() }
    }
    private func wait(after observed: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || generation != observed || stopped { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    private func cancelWaiter(_ id: UUID) { waiters.removeValue(forKey: id)?.resume() }
}
