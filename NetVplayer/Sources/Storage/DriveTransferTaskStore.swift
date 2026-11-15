import Foundation
import Models

/// Small atomic journal. Loading is local only; malformed/future data fails
/// closed and is never silently replaced by an empty queue.
public final class DriveTransferTaskStore: @unchecked Sendable {
    public static let shared = DriveTransferTaskStore(storage: TestRuntime.isRunning
        ? StorageManager(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("NetVplayerTaskTests-" + UUID().uuidString))
        : .shared)
    public static let filename = "drive_transfer_tasks.json"
    private let storage: StorageManager
    public let diagnostics: TaskDiagnosticStore
    private let maximumRecords: Int
    private let lock = NSRecursiveLock()
    private struct Envelope: Codable {
        var version: Int
        var records: [DriveTransferTask]
    }

    public init(storage: StorageManager, maximumRecords: Int = 256) {
        self.storage = storage; self.maximumRecords = max(1, maximumRecords)
        diagnostics = storage === StorageManager.shared ? .shared : TaskDiagnosticStore(storage: storage)
    }

    private func synchronized<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            do { return try storage.withJournalLock(Self.filename, operation: operation) }
            catch let error as DriveTaskRecoveryError { throw error }
            catch { throw DriveTaskRecoveryError.storageUnavailable }
        }
    }

    public func records() throws -> [DriveTransferTask] {
        try synchronized { try load() }
    }

    private func load() throws -> [DriveTransferTask] {
        do {
            let envelope = try storage.loadBounded(Envelope.self, from: Self.filename, maximumBytes: 8 * 1024 * 1024)
            guard (1...2).contains(envelope.version), envelope.records.count <= maximumRecords,
                  Set(envelope.records.map(\.id)).count == envelope.records.count,
                  envelope.records.allSatisfy({ record in
                      (0...2).contains(record.remainingReadRetries) && record.previousIDs.count <= 4096
                          && (record.submitted || [.notSubmitted, .failed].contains(record.phase))
                          && (![.fileConfirmed, .playbackAddressPending].contains(record.phase) || record.fileID?.isEmpty == false)
                          && (!record.completed || !record.protectsUncertainWrite && record.phase != .outcomeUnknown)
                  }) else {
                throw DriveTaskRecoveryError.storageUnavailable
            }
            // v1 used the same evidence fields. Its exhausted/unknown budget is
            // conservatively migrated without granting additional retry attempts.
            if envelope.version == 1 { try write(envelope.records) }
            return envelope.records
        } catch {
            let ns = error as NSError
            if (ns.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(ns.code))
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)) { return [] }
            throw DriveTaskRecoveryError.storageUnavailable
        }
    }

    private func write(_ records: [DriveTransferTask]) throws {
        do {
            let envelope = Envelope(version: 2, records: records)
            guard try JSONEncoder().encode(envelope).count <= 8 * 1024 * 1024 else {
                throw DriveTaskRecoveryError.capacityReached
            }
            try storage.save(envelope, to: Self.filename)
        } catch let error as DriveTaskRecoveryError { throw error }
        catch { throw DriveTaskRecoveryError.storageUnavailable }
    }

    public func insert(_ record: DriveTransferTask, now: Date = Date()) throws {
        try synchronized {
            var all = try load()
            guard !all.contains(where: { $0.id == record.id }) else { throw DriveTaskRecoveryError.staleRecord }
            guard !all.contains(where: { !$0.completed && $0.scope.sourceKey == record.scope.sourceKey
                && $0.scope.accountReference == record.scope.accountReference }) else { throw DriveTaskRecoveryError.requiresReview }
            all.removeAll { !$0.protectsUncertainWrite && ($0.completed || $0.cancelled || $0.phase == .failed)
                && now.timeIntervalSince($0.updatedAt) > 30 * 24 * 3600 }
            while all.count >= maximumRecords {
                guard let index = all.indices.filter({ !all[$0].protectsUncertainWrite
                    && (all[$0].completed || all[$0].cancelled || all[$0].phase == .failed) })
                    .min(by: { all[$0].updatedAt < all[$1].updatedAt }) else { throw DriveTaskRecoveryError.capacityReached }
                all.remove(at: index)
            }
            all.append(record)
            try write(all)
            try? diagnostics.record(.transfer(record))
        }
    }

    public func replace(_ record: DriveTransferTask, expected: DriveTransferTask) throws {
        try synchronized {
            var all = try load()
            guard let index = all.firstIndex(where: { $0.id == expected.id }), all[index] == expected else {
                throw DriveTaskRecoveryError.staleRecord
            }
            guard record.id == expected.id, record.scope == expected.scope, record.previousIDs.count <= 4096 else {
                throw DriveTaskRecoveryError.storageUnavailable
            }
            all[index] = record
            try write(all)
            try? diagnostics.record(.transfer(record))
        }
    }

    public func cancel(_ id: UUID) throws {
        try synchronized {
            var all = try load()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return }
            all[index].cancelled = true
            all[index].updatedAt = Date()
            try write(all)
            try? diagnostics.record(.transfer(all[index]))
        }
    }
}
