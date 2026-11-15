import Foundation
import Models

extension Notification.Name { public static let taskDiagnosticsDidChange = Notification.Name("netvplayer.taskDiagnosticsDidChange") }

/// Bounded convenience history; never owns recovery eligibility or retry budgets.
public final class TaskDiagnosticStore: @unchecked Sendable {
    public static let shared = TaskDiagnosticStore(storage: TestRuntime.isRunning
        ? StorageManager(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("TaskDiagnostics-" + UUID().uuidString)) : .shared)
    public static let filename = "recent_task_diagnostics.json"
    public static let retention = TaskDiagnosticsExport.retention
    private let storage: StorageManager
    private let maximumRecords: Int
    private let lock = NSRecursiveLock()
    private struct Envelope: Codable { let version: Int; var records: [TaskDiagnosticRecord] }
    public init(storage: StorageManager, maximumRecords: Int = 100) {
        self.storage = storage; self.maximumRecords = min(100, max(1, maximumRecords))
    }
    private func load() throws -> [TaskDiagnosticRecord] {
        do {
            let value = try storage.loadBounded(Envelope.self, from: Self.filename, maximumBytes: 512 * 1024)
            guard value.version == 1, value.records.count <= 100,
                  Set(value.records.map(\.id)).count == value.records.count,
                  value.records.allSatisfy({ !$0.events.isEmpty && $0.events.count <= 12 && $0.events.allSatisfy { $0.time.timeIntervalSince1970.isFinite } }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return value.records
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(ns.code)
                || ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { return [] }
            throw error
        }
    }
    /// Read-only: no retention writeback, recovery lookup, client or network call.
    public func records(now: Date = Date()) throws -> [TaskDiagnosticRecord] {
        try lock.withLock { try visible(load(), now: now) }
    }
    private func visible(_ records: [TaskDiagnosticRecord], now: Date) -> [TaskDiagnosticRecord] {
        Array(records.compactMap { record -> TaskDiagnosticRecord? in
            var safe = record
            safe.events = record.events.filter {
                $0.time <= now.addingTimeInterval(300) && now.timeIntervalSince($0.time) <= Self.retention
            }.map { $0.projected() }
            return safe.events.isEmpty ? nil : safe
        }.sorted { $0.latest.time > $1.latest.time }.prefix(maximumRecords))
    }
    public func record(_ incoming: TaskDiagnosticRecord, now: Date = Date()) throws {
        guard !incoming.events.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        try lock.withLock {
            try storage.withJournalLock(Self.filename) {
                var records = try visible(load(), now: now)
                if let index = records.firstIndex(where: { $0.id == incoming.id }) {
                    guard records[index].kind == incoming.kind, records[index].provider == incoming.provider,
                          records[index].localSubjectID == incoming.localSubjectID else { return }
                    // Cancellation/completion cannot be revived by late diagnostics.
                    if records[index].latest.state == .cancelled, incoming.latest.state != .cancelled { return }
                    if records[index].latest.state == .completed, ![.completed, .cancelled].contains(incoming.latest.state) { return }
                    let event = incoming.latest.projected()
                    if records[index].latest != event { records[index].events.append(event) }
                    records[index].events = Array(records[index].events.suffix(12))
                } else {
                    records.append(.init(id: incoming.id, kind: incoming.kind, provider: incoming.provider,
                                         localSubjectID: incoming.localSubjectID, event: incoming.latest))
                }
                let envelope = Envelope(version: 1, records: visible(records, now: now))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                guard try encoder.encode(envelope).count <= 512 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
                try storage.save(envelope, to: Self.filename)
            }
        }
        NotificationCenter.default.post(name: .taskDiagnosticsDidChange, object: self)
    }
    public func exportData(now: Date = Date(), activeTaskIDs: Set<UUID> = []) throws -> Data {
        try TaskDiagnosticsExport.data(records: records(now: now), now: now, activeTaskIDs: activeTaskIDs)
    }
}
