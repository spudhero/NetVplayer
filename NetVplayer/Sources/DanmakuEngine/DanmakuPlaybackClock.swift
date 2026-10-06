import Foundation

/// Maps authoritative media samples onto a monotonic clock between player callbacks.
public struct DanmakuPlaybackClock: Sendable {
    private var anchorPosition = 0.0
    private var anchorTime = 0.0
    private var lastSample: Double?
    private var epoch = ""
    private var rate = 1.0
    public private(set) var isAdvancing = false
    public private(set) var revision: UInt64 = 0

    public init() {}

    public mutating func synchronize(position: Double, uptime: Double, rate: Double, playing: Bool, buffering: Bool, seeking: Bool, epoch: String) {
        let sample = position.isFinite ? max(0, position) : 0
        let safeRate = rate.isFinite ? min(8, max(0.1, rate)) : 1
        let advances = playing && !buffering && !seeking
        let predicted = self.position(at: uptime)
        let discontinuity = self.epoch != epoch || seeking || abs(predicted - sample) > 0.75
        if discontinuity { revision &+= 1 }
        if lastSample != sample || advances != isAdvancing || safeRate != self.rate || discontinuity {
            anchorPosition = sample
            anchorTime = uptime
        }
        self.epoch = epoch
        lastSample = sample
        self.rate = safeRate
        isAdvancing = advances
    }

    public func position(at uptime: Double) -> Double {
        anchorPosition + (isAdvancing ? max(0, uptime - anchorTime) * rate : 0)
    }
}
