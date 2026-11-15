import Foundation

/// Smaller values run first. Geometry is quantized so scrolling does not send
/// an update for every pixel; keys/credentials never enter scheduling state.
struct PosterDemand: Comparable, Sendable {
    enum Tier: Int, Sendable { case visible, nearby, prefetch, inactive }
    var tier: Tier
    var distance = 0
    var row = 0
    var column = 0
    static let visible = Self(tier: .visible)
    static let nearby = Self(tier: .nearby)
    static let prefetch = Self(tier: .prefetch)
    static let inactive = Self(tier: .inactive)
    var isSpeculative: Bool { tier != .visible }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier.rawValue < rhs.tier.rawValue }
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        if lhs.row != rhs.row { return lhs.row < rhs.row }
        return lhs.column < rhs.column
    }
}

/// The token bridges MainActor geometry and the pipeline actor. Reading the
/// latest value at admission closes the update-before-registration race.
final class PosterDemandToken: @unchecked Sendable {
    private let lock = NSLock()
    private var demand: PosterDemand
    init(_ demand: PosterDemand = .visible) { self.demand = demand }
    var value: PosterDemand { lock.withLock { demand } }
    func update(_ demand: PosterDemand) { lock.withLock { self.demand = demand } }
}

/// Capacity loss is transient, not an HTTP/image failure or a negative cache hit.
struct PosterWorkDeferred: Error, Sendable {}

extension Notification.Name {
    static let posterWorkCapacityDidChange = Notification.Name("netVplayerPosterWorkCapacityDidChange")
}

struct PosterWorkMetrics: Sendable {
    var active = 0
    var queued = 0
    var peakActive = 0
    var peakQueued = 0
    var started = 0
    var maximumWaitSeconds: Double = 0
}

/// Owned exclusively by PosterImagePipeline's actor. Continuations replace the
/// former 20 ms permit polling. Running synchronous decodes keep their lease
/// until they really return, even when their last consumer has cancelled.
final class PosterWorkQueue {
    private struct Waiting {
        let continuation: CheckedContinuation<Void, Error>
        var demand: PosterDemand
        let sequence: UInt64
        let enqueued: ContinuousClock.Instant
    }
    private let limit: Int
    private let speculativeLimit: Int
    private let maximumWaiting: Int
    private let permits: (PosterDemand) -> Bool
    private var active: [UUID: PosterDemand] = [:]
    private var waiting: [UUID: Waiting] = [:]
    private var sequence: UInt64 = 0
    private(set) var metrics = PosterWorkMetrics()

    init(limit: Int, speculativeLimit: Int, maximumWaiting: Int, permits: @escaping (PosterDemand) -> Bool = { _ in true }) {
        self.permits = permits
        self.limit = max(1, limit)
        self.speculativeLimit = min(self.limit, max(1, speculativeLimit))
        self.maximumWaiting = max(1, maximumWaiting)
    }

    func enqueue(id: UUID, demand: PosterDemand, continuation: CheckedContinuation<Void, Error>) {
        guard waiting.count < maximumWaiting else {
            continuation.resume(throwing: PosterWorkDeferred())
            return
        }
        sequence &+= 1
        waiting[id] = Waiting(continuation: continuation, demand: demand, sequence: sequence, enqueued: .now)
        drain()
    }

    func update(id: UUID, demand: PosterDemand) {
        if active[id] != nil { active[id] = demand }
        if waiting[id] != nil { waiting[id]?.demand = demand }
        // The owner batches updates across shared consumers before draining.
    }

    func cancel(id: UUID) {
        waiting.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
        recordCounts()
    }

    func release(id: UUID) {
        active[id] = nil
        drain()
    }

    func drain() {
        while active.count < limit {
            let speculativeCount = active.values.filter(\.isSpeculative).count
            let candidate = waiting.filter {
                permits($0.value.demand) && (!$0.value.demand.isSpeculative || speculativeCount < speculativeLimit)
            }.min {
                if $0.value.demand != $1.value.demand { return $0.value.demand < $1.value.demand }
                return $0.value.sequence < $1.value.sequence
            }
            guard let (id, work) = candidate else { break }
            waiting[id] = nil
            active[id] = work.demand
            metrics.started += 1
            let elapsed = work.enqueued.duration(to: .now).components
            metrics.maximumWaitSeconds = max(metrics.maximumWaitSeconds,
                Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            work.continuation.resume()
        }
        recordCounts()
    }

    private func recordCounts() {
        metrics.active = active.count
        metrics.queued = waiting.count
        metrics.peakActive = max(metrics.peakActive, active.count)
        metrics.peakQueued = max(metrics.peakQueued, waiting.count)
    }
}
