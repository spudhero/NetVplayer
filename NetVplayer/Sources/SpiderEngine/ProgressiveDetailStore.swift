import Foundation
import Models

struct ProgressiveDetailKey: Hashable, Sendable {
    let site: Site
    let id: String
}

/// Holds only ongoing expansion and its hand-off result. Final results are owned
/// by the app's bounded detail cache; Provider wire and persisted models stay unchanged.
actor ProgressiveDetailStore {
    private struct Entry {
        let id: UUID
        let startedAt: Date
        var result: Result
        var task: Task<Void, Never>?
        var access: UInt64
    }
    private struct Fetch {
        let id: UUID
        let task: Task<Result, Error>
    }
    private var entries: [ProgressiveDetailKey: Entry] = [:]
    private var fetching: [ProgressiveDetailKey: Fetch] = [:]
    private var serial: UInt64 = 0

    func result(
        for key: ProgressiveDetailKey,
        resolver: RemoteProviderDriveShareResolver,
        load: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        serial &+= 1
        if var entry = entries[key] {
            if Date().timeIntervalSince(entry.startedAt) < 600 {
                let result = entry.result
                if entry.task == nil { entries[key] = nil }
                else { entry.access = serial; entries[key] = entry }
                return result
            }
            entry.task?.cancel()
            entries[key] = nil
        }
        if let existing = fetching[key] { return try await existing.task.value }
        let requestID = UUID()
        let task = Task {
            let raw = try await load()
            return try self.install(raw, key: key, id: requestID, resolver: resolver)
        }
        fetching[key] = Fetch(id: requestID, task: task)
        do {
            return try await task.value
        } catch {
            if fetching[key]?.id == requestID { fetching[key] = nil }
            throw error
        }
    }

    private func install(_ raw: Result, key: ProgressiveDetailKey, id: UUID, resolver: RemoteProviderDriveShareResolver) throws -> Result {
        guard fetching[key]?.id == id else { throw CancellationError() }
        fetching[key] = nil
        let initial = resolver.provisional(raw)
        guard initial.list.contains(where: { $0.vodPlayUrl.contains("netvplayer-pending:") }) else {
            return initial
        }
        if entries.count >= 32, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: oldest)?.task?.cancel()
        }
        entries[key] = Entry(id: id, startedAt: Date(), result: initial, access: serial)
        let expansion = Task {
            let final = await resolver.resolve(raw) { update in
                await self.update(update, key: key, id: id, finished: false)
            }
            self.update(final, key: key, id: id, finished: true)
        }
        entries[key]?.task = expansion
        return initial
    }

    private func update(_ result: Result, key: ProgressiveDetailKey, id: UUID, finished: Bool) {
        guard entries[key]?.id == id else { return }
        entries[key]?.result = result
        if finished { entries[key]?.task = nil }
    }

    func clear() {
        for entry in entries.values { entry.task?.cancel() }
        for fetch in fetching.values { fetch.task.cancel() }
        entries.removeAll()
        fetching.removeAll()
    }
}
