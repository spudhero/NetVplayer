import Foundation

/// Opt-in VOD experiment. Bounds scale from the installed engine's actual base
/// wait; observed waits drive adaptation. No provider-specific cache constants.
public struct VODRebufferExperiment: Sendable {
    public let enabled: Bool
    public let baseline: Double
    public let maximum: Double
    public let stablePeriod: Double
    public private(set) var target: Double
    private var lastRecovery: Double?
    private var observedWait = 0.0
    public init(enabled: Bool = false, baseline: Double = 1) {
        self.enabled = enabled
        self.baseline = baseline.isFinite ? max(0.1, baseline) : 1
        maximum = max(self.baseline, min(8, self.baseline * 4))
        target = self.baseline
        stablePeriod = max(30, self.baseline * 24)
    }
    public mutating func recovered(wait: Double, now: Double) {
        guard enabled, wait.isFinite, wait >= 0 else { return }
        observedWait = observedWait == 0 ? wait : 0.5 * observedWait + 0.5 * wait
        if let previous = lastRecovery, now - previous <= max(12, baseline * 8) {
            target = min(maximum, max(target, baseline + observedWait * 0.5))
        }
        lastRecovery = now
    }
    public mutating func tick(now: Double) {
        guard enabled, let recovery = lastRecovery, now - recovery >= stablePeriod else { return }
        target = baseline; observedWait = 0; lastRecovery = nil
    }
}
