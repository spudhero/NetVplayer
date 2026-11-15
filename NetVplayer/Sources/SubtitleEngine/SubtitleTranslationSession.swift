import Foundation
import Models

/// One translation operation at a time, including while an uncooperative provider drains.
/// All acceptance decisions and timeline changes are serialized on the main actor.
@MainActor
public final class SubtitleTranslationSession {
    public private(set) var document: SubtitleDocument?
    public private(set) var coverage: SubtitleTranslationCoverage?
    public private(set) var owner: UUID?
    public private(set) var generation: UInt64 = 0
    public private(set) var failure: SubtitleTranslationError?
    public var changed: (@MainActor () -> Void)?
    public var failed: (@MainActor (any Error) -> Void)?
    public var completing = false
    private var key: SubtitleTranslationKey?
    private var position = 0.0, speed = 1.0
    private var playing = false, seeking = false
    private var stopped = true, running = false
    private var operation: Task<[Int: String], Error>?
    private let cache: SubtitleTranslationCache
    private let budget: PlaybackBackgroundBudget

    public init(cache: SubtitleTranslationCache = .shared, budget: PlaybackBackgroundBudget = .shared) {
        self.cache = cache; self.budget = budget
    }

    public func bind(owner: UUID, document: SubtitleDocument, key: SubtitleTranslationKey) async throws {
        cancel()
        self.owner = owner; self.document = document; self.key = key
        coverage = nil; failure = nil; completing = false
        let generation = generation
        let restored = try await cache.load(key: key, total: document.cues.count)
        guard self.generation == generation, self.owner == owner else { throw CancellationError() }
        coverage = restored; stopped = false; changed?()
    }

    public func update(position: Double, speed: Double, playing: Bool, seeking: Bool, discontinuity: Bool = false) {
        guard position.isFinite, speed.isFinite, speed > 0 else { return }
        // The UI also passes its pending seek, before the engine publishes the new time.
        if discontinuity || (seeking && !self.seeking) || abs(position - self.position) > 3 || speed != self.speed {
            generation &+= 1; operation?.cancel()
        }
        self.position = max(0, position); self.speed = speed; self.playing = playing; self.seeking = seeking
    }

    public func cancel() {
        generation &+= 1; stopped = true; operation?.cancel(); failure = nil
        changed?()
    }

    public func translation(at position: Double) -> String? {
        guard !stopped, let document, let coverage else { return nil }
        let active = document.cues.filter { $0.start <= position && position < $0.end }
        // A partially translated overlap falls back to the complete original overlap.
        guard !active.isEmpty, active.allSatisfy({ coverage.translations[$0.id] != nil }) else { return nil }
        return active.compactMap { coverage.translations[$0.id] }.joined(separator: "\n")
    }

    public func run(service: any SubtitleTranslationService) async {
        guard let owner, let key, key.translator == service.identity else { return }
        // A new configuration cannot create concurrent work while an older service ignores cancellation.
        while running {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
        }
        guard self.owner == owner, self.key == key, !stopped, !Task.isCancelled else { return }
        running = true
        defer { running = false; operation = nil; changed?() }
        while !Task.isCancelled, !stopped, self.owner == owner, self.key == key {
            guard let document, let coverage, !coverage.complete else { return }
            if seeking {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }; continue
            }
            guard let plan = SubtitleTranslationPlanner.next(document: document, covered: Set(coverage.translations.keys),
                    position: position, speed: speed, playing: playing, now: ProcessInfo.processInfo.systemUptime,
                    completing: completing) else {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }; continue
            }
            let generation = generation
            let request = SubtitleTranslationRequest(cues: plan.cues, context: plan.context,
                sourceLanguage: key.sourceLanguage, targetLanguage: key.targetLanguage, deadline: plan.deadline)
            let bytes = Int64((plan.cues + plan.context).reduce(0) { $0 + $1.text.utf8.count })
            let budget = budget
            let task = Task {
                try await budget.withRead(purpose: .subtitleExtraction, bytes: bytes) {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < request.deadline else { throw SubtitleTranslationError.expired }
                    return try await service.translate(request)
                }
            }
            operation = task
            let expiry = Task {
                do {
                    try await Task.sleep(for: .seconds(max(0, plan.deadline - ProcessInfo.processInfo.systemUptime)))
                    task.cancel()
                } catch { }
            }
            defer { expiry.cancel() }
            do {
                let values = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                expiry.cancel()
                try Task.checkCancellation()
                guard !stopped, self.owner == owner, self.key == key, self.generation == generation else { continue }
                guard !task.isCancelled, ProcessInfo.processInfo.systemUptime < plan.deadline else { throw SubtitleTranslationError.expired }
                let expected = Set(plan.cues.map(\.id))
                guard !values.isEmpty, Set(values.keys).isSubset(of: expected),
                      SubtitleTranslationCache.valid(values, total: document.cues.count) else { throw SubtitleTranslationError.invalidResponse }
                // The cache actor owns the atomic checkpoint. Cancellation before this commit
                // never writes. A seek after acceptance may keep that already accepted checkpoint.
                let saved = try await cache.merge(key: key, total: document.cues.count, translations: values)
                guard !stopped, self.owner == owner, self.key == key, self.generation == generation else { continue }
                self.coverage = saved; failure = nil; changed?()
            } catch {
                expiry.cancel()
                if Task.isCancelled || stopped || self.owner != owner || self.key != key { return }
                if self.generation != generation { continue }
                // A failed or late request leaves uncovered cues untouched. Explicit retry
                // avoids a request storm and preserves the already checkpointed coverage.
                failure = (error as? SubtitleTranslationError) ?? .invalidResponse
                failed?(error)
                changed?(); return
            }
        }
    }
}
