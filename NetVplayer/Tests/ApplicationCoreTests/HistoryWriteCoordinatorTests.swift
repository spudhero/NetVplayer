import Foundation
import Testing
import Models
import ApplicationCore

struct HistoryWriteCoordinatorTests {
    @Test func deletedSnapshotCannotBeWrittenAfterDeletion() throws {
        let persistence = HistoryMemoryPersistence()
        let writer = HistoryWriteCoordinator(persistence: persistence)
        let ticket = writer.reserve()
        try writer.replace(with: [])
        #expect(try !writer.save([History(key: "removed")], ticket: ticket))
        #expect(persistence.loadHistory().isEmpty)
    }

    @Test func laterSnapshotWinsAndClearInvalidatesAllOutstandingWrites() throws {
        let persistence = HistoryMemoryPersistence()
        let writer = HistoryWriteCoordinator(persistence: persistence)
        let first = writer.reserve()
        let second = writer.reserve()
        #expect(try writer.save([History(key: "new")], ticket: second))
        #expect(try !writer.save([History(key: "old")], ticket: first))
        try writer.clear()
        #expect(try !writer.save([History(key: "new")], ticket: second))
        #expect(persistence.loadHistory().isEmpty)
    }

    @Test func deletionWaitsForAnAlreadyStartedWriteAndRemainsFinal() async throws {
        let persistence = HistoryMemoryPersistence(blockFirstWrite: true)
        let writer = HistoryWriteCoordinator(persistence: persistence)
        let ticket = writer.reserve()
        let write = Task.detached { try writer.save([History(key: "old")], ticket: ticket) }
        #expect(await persistence.waitForWrite())
        let deletion = Task.detached { try writer.replace(with: []) }
        persistence.release.signal()
        _ = try await write.value
        try await deletion.value
        #expect(persistence.loadHistory().isEmpty)
        #expect(try !writer.save([History(key: "late")], ticket: ticket))
    }
}

private final class HistoryMemoryPersistence: ApplicationLibraryPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var history: [History] = []
    private var blockFirstWrite: Bool
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    init(blockFirstWrite: Bool = false) { self.blockFirstWrite = blockFirstWrite }
    func waitForWrite() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.started.wait(timeout: .now() + 3) == .success)
            }
        }
    }
    func loadHistory() -> [History] {
        lock.lock(); defer { lock.unlock() }
        return history
    }
    func saveHistory(_ items: [History]) throws {
        lock.lock(); defer { lock.unlock() }
        if blockFirstWrite {
            blockFirstWrite = false
            started.signal()
            guard release.wait(timeout: .now() + 3) == .success else { throw TestFailure.timeout }
        }
        history = items
    }
    func clearHistoryRecords() throws { try saveHistory([]) }
    func loadConfigs() -> [Config] { [] }
    func saveConfigs(_ configs: [Config]) throws {}
    func loadKeeps() -> [Keep] { [] }
    func saveKeeps(_ items: [Keep]) throws {}
    enum TestFailure: Error { case timeout }
}
