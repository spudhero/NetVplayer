import Foundation

/// Tracks intent only; the native window remains the authority for its actual state.
public struct FullScreenTransitionState: Sendable {
    public struct Transition: Sendable, Equatable {
        public var target: Bool
        public var startedAt: TimeInterval
    }
    public private(set) var transition: Transition?
    public private(set) var desired: Bool?
    public private(set) var isClosed = false
    public init() {}

    public mutating func toggle(actual: Bool, now: TimeInterval) -> Bool? {
        request(!(desired ?? transition?.target ?? actual), actual: actual, now: now)
    }

    public mutating func request(_ target: Bool, actual: Bool, now: TimeInterval) -> Bool? {
        guard !isClosed else { return nil }
        desired = target
        return beginIfNeeded(actual: actual, now: now)
    }

    /// Also observes transitions started by the native green button or system shortcut.
    public mutating func began(target: Bool, now: TimeInterval) {
        guard !isClosed else { return }
        if transition == nil { desired = target }
        if transition?.target != target { transition = Transition(target: target, startedAt: now) }
    }

    public mutating func completed(actual: Bool, now: TimeInterval) -> Bool? {
        guard !isClosed, let prior = transition else { return nil }
        transition = nil
        // Release failed requests rather than retrying indefinitely. A newer opposite intent survives.
        if desired == prior.target && actual != prior.target { desired = nil }
        return beginIfNeeded(actual: actual, now: now)
    }

    public mutating func recover(actual: Bool, isLiveResize: Bool, now: TimeInterval) -> Bool? {
        guard let transition, now - transition.startedAt >= 5, !isLiveResize else { return nil }
        return completed(actual: actual, now: now)
    }

    public mutating func close() { isClosed = true; transition = nil; desired = nil }

    private mutating func beginIfNeeded(actual: Bool, now: TimeInterval) -> Bool? {
        guard transition == nil, let desired else { return nil }
        guard desired != actual else { self.desired = nil; return nil }
        transition = Transition(target: desired, startedAt: now)
        return desired
    }
}
