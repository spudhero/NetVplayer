import Foundation
import Models

/// Orders snapshots and destructive edits at the actual persistence boundary.
/// Cancellation alone cannot recall a synchronous write that has already begun.
public final class HistoryWriteCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let persistence: any ApplicationLibraryPersistence
    private var revision = UUID()

    public init(persistence: any ApplicationLibraryPersistence) {
        self.persistence = persistence
    }

    public func reserve() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        revision = UUID()
        return revision
    }

    @discardableResult
    public func save(_ records: [History], ticket: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revision == ticket else { return false }
        try persistence.saveHistory(records)
        return true
    }

    public func replace(with records: [History]) throws {
        lock.lock()
        defer { lock.unlock() }
        revision = UUID()
        try persistence.saveHistory(records)
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        revision = UUID()
        try persistence.clearHistoryRecords()
    }

    /// Imports and migrations use the same gate as delayed progress snapshots.
    public func performReplacement<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        revision = UUID()
        return try operation()
    }
}
