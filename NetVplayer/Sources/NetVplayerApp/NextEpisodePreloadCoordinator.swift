import Foundation
import Models
import PlayerEngine

struct PlaybackPreloadKey: Hashable, Sendable {
    let siteKey: String
    let vodID: String
    let playFlag: String
    let currentEpisodeURL: String
    let targetEpisodeURL: String
    let playbackGeneration: UInt64
}

struct PreparedEpisodePlayback: Sendable {
    let key: PlaybackPreloadKey
    let site: Site
    let episode: Episode
    var spec: PlaySpec
    var decision: PlaybackPreloadDecision
    var mediaBytes: Int64
    let preparedAt: Date

    func isFresh(at date: Date = Date(), ttl: TimeInterval = 90) -> Bool {
        date.timeIntervalSince(preparedAt) >= 0 && date.timeIntervalSince(preparedAt) <= ttl
    }
}

@MainActor
final class NextEpisodePreloadCoordinator {
    typealias Operation = @MainActor @Sendable (
        PlaybackPreloadDecision,
        PreparedEpisodePlayback?
    ) async -> PreparedEpisodePlayback?

    private struct Slot {
        let id: UUID
        let key: PlaybackPreloadKey
        let decision: PlaybackPreloadDecision
        let task: Task<PreparedEpisodePlayback?, Never>
        var prepared: PreparedEpisodePlayback?
        var desiredDecision: PlaybackPreloadDecision
    }

    private enum PublicationResult {
        case accepted(upgrade: PlaybackPreloadDecision?)
        case consumed
        case rejected
    }

    private var slot: Slot?
    private var expiryTask: Task<Void, Never>?
    private var consumedTaskIDs: Set<UUID> = []
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 90) {
        self.ttl = ttl
    }

    var currentKey: PlaybackPreloadKey? { slot?.key }

    /// A speculative SDK result may replace an unconsumed, completed preload.
    /// Consuming metadata transfers ownership to playback and rejects late upgrades.
    func upgradeMediaIfUnconsumed(_ replacement: PreparedEpisodePlayback, expectedURL: String) -> PreparedEpisodePlayback? {
        guard var current = slot, current.key == replacement.key,
              let previous = current.prepared, previous.spec.url == expectedURL,
              previous.isFresh(ttl: ttl), previous.decision == .metadataAndMedia else { return nil }
        current.prepared = replacement
        slot = current
        return previous
    }

    @discardableResult
    func request(
        key: PlaybackPreloadKey,
        decision: PlaybackPreloadDecision,
        onDiscard: @escaping @MainActor @Sendable (PreparedEpisodePlayback) -> Void,
        operation: @escaping Operation
    ) -> Bool {
        guard decision != .none else { return false }

        if let current = slot,
           current.key == key,
           current.decision >= decision,
           current.prepared?.isFresh(ttl: ttl) != false {
            return false
        }

        if var current = slot,
           current.key == key,
           current.prepared == nil {
            guard decision > current.desiredDecision else { return false }
            current.desiredDecision = decision
            slot = current
            return true
        }

        var reusable: PreparedEpisodePlayback?
        if let current = slot, let prepared = current.prepared {
            if current.key == key, prepared.isFresh(ttl: ttl) {
                reusable = prepared
            } else {
                onDiscard(prepared)
            }
        }
        slot?.task.cancel()
        expiryTask?.cancel()
        expiryTask = nil
        let id = UUID()
        let task: Task<PreparedEpisodePlayback?, Never> = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return nil }
            let prepared = await operation(decision, reusable)
            guard !Task.isCancelled else {
                if let prepared { onDiscard(prepared) }
                return nil
            }
            guard let self else {
                if let prepared { onDiscard(prepared) }
                return nil
            }
            switch self.publish(prepared, id: id, key: key, decision: decision) {
            case let .accepted(upgrade):
                if let upgrade {
                    self.request(
                        key: key,
                        decision: upgrade,
                        onDiscard: onDiscard,
                        operation: operation
                    )
                } else {
                    self.scheduleExpiry(id: id, key: key, onDiscard: onDiscard)
                }
            case .consumed:
                break
            case .rejected:
                if let prepared { onDiscard(prepared) }
                return nil
            }
            return prepared
        }
        slot = Slot(
            id: id,
            key: key,
            decision: decision,
            task: task,
            prepared: reusable,
            desiredDecision: decision
        )
        return true
    }

    func consume(key: PlaybackPreloadKey) async -> PreparedEpisodePlayback? {
        while true {
            guard let current = slot, current.key == key else { return nil }
            let prepared: PreparedEpisodePlayback?
            if let cached = current.prepared {
                prepared = cached
                if current.decision > cached.decision {
                    consumedTaskIDs.insert(current.id)
                    DiagnosticLog.write(
                        "[NEXT_PRELOAD] stage=consume-while-media-upgrade decision=\(cached.decision.rawValue) bytes=\(cached.mediaBytes)"
                    )
                }
            } else {
                prepared = await current.task.value
            }
            if let latest = slot,
               latest.key == key,
               latest.id != current.id {
                continue
            }
            guard let prepared, prepared.key == key, prepared.isFresh(ttl: ttl) else {
                invalidate()
                return nil
            }
            expiryTask?.cancel()
            expiryTask = nil
            slot = nil
            return prepared
        }
    }

    @discardableResult
    func invalidate() -> PreparedEpisodePlayback? {
        slot?.task.cancel()
        expiryTask?.cancel()
        expiryTask = nil
        let prepared = slot?.prepared
        slot = nil
        return prepared
    }

    private func publish(
        _ prepared: PreparedEpisodePlayback?,
        id: UUID,
        key: PlaybackPreloadKey,
        decision: PlaybackPreloadDecision
    ) -> PublicationResult {
        if consumedTaskIDs.remove(id) != nil {
            return .consumed
        }
        guard var current = slot,
              current.id == id,
              current.key == key,
              current.decision == decision else { return .rejected }
        let upgrade = current.desiredDecision > decision
            ? current.desiredDecision
            : nil
        guard let prepared else {
            slot = nil
            // A media upgrade requires successful metadata; failure is not a new request.
            return .accepted(upgrade: nil)
        }
        current.prepared = prepared
        slot = current
        return .accepted(upgrade: upgrade)
    }

    private func scheduleExpiry(
        id: UUID,
        key: PlaybackPreloadKey,
        onDiscard: @escaping @MainActor @Sendable (PreparedEpisodePlayback) -> Void
    ) {
        expiryTask?.cancel()
        let nanoseconds = UInt64(max(0, ttl) * 1_000_000_000)
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.slot?.id == id,
                  self.slot?.key == key else { return }
            if let prepared = self.invalidate() {
                onDiscard(prepared)
            }
        }
    }
}
