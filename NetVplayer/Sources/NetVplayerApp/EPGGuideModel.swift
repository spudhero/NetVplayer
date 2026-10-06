import Foundation
import Combine
import Models

@MainActor
final class EPGGuideModel: ObservableObject {
    typealias Loader = @Sendable (Channel, DateInterval, Bool) async -> EpgLoadResult
    @Published private(set) var rows: [String: EpgLoadResult] = [:]
    @Published private(set) var loading = Set<String>()
    private(set) var generation = UUID()
    private var window = DateInterval(start: Date(), duration: 6 * 3_600)
    private var visible: [String: Channel] = [:]
    private var queue: [String] = []
    private var forced = Set<String>()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var loader: Loader?
    static let maximumRows = 32
    static let maximumConcurrent = 4
    static let maximumBytes = 8 * 1_024 * 1_024

    func reset(window: DateInterval, loader: @escaping Loader) {
        stop()
        self.window = window
        self.loader = loader
    }

    func stop() {
        generation = UUID()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll(); queue.removeAll(); visible.removeAll(); forced.removeAll()
        rows.removeAll(); loading.removeAll()
    }

    func appear(id: String, channel: Channel, generation: UUID) {
        guard generation == self.generation, visible[id] == nil, visible.count < Self.maximumRows else { return }
        visible[id] = channel
        queue.append(id)
        pump()
    }

    func disappear(id: String, generation: UUID) {
        guard generation == self.generation else { return }
        visible[id] = nil; rows[id] = nil
        queue.removeAll { $0 == id }; forced.remove(id)
        // A cancelled loader can still be finishing a shared import. Keep its slot until completion.
        tasks[id]?.cancel()
        pump()
    }

    func retry(id: String) {
        guard visible[id] != nil, tasks[id] == nil else { return }
        forced.insert(id)
        if !queue.contains(id) { queue.append(id) }
        pump()
    }

    private func pump() {
        guard let loader else { return }
        while tasks.count < Self.maximumConcurrent, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let channel = visible[id], tasks[id] == nil else { continue }
            let generation = generation, window = window, force = forced.remove(id) != nil
            loading.insert(id)
            tasks[id] = Task { [weak self] in
                let result = await loader(channel, window, force)
                guard let self, self.generation == generation else { return }
                self.tasks[id] = nil
                self.loading.remove(id)
                if self.visible[id] != nil {
                    if Task.isCancelled {
                        self.queue.append(id)
                    } else {
                        var bounded = result
                        if result.availability == .unavailable, let old = self.rows[id], !old.data.items.isEmpty {
                            bounded.data = old.data
                            bounded.availability = .stale
                        }
                        let otherCost = self.rows.filter { $0.key != id }.values.reduce(0) { $0 + Self.cost($1.data.items) }
                        var remaining = max(0, Self.maximumBytes - otherCost)
                        bounded.data.items = Array(bounded.data.items.prefix(128)).filter { item in
                            let cost = Self.cost([item])
                            guard cost <= remaining else { return false }
                            remaining -= cost
                            return true
                        }
                        self.rows[id] = bounded
                    }
                }
                self.pump()
            }
        }
    }

    private static func cost(_ items: [EpgItem]) -> Int {
        items.reduce(0) { $0 + $1.title.utf8.count + 128 }
    }
}
