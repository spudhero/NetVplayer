import Foundation

/// Signal units relative to the compositor's SDR white, not measured panel nits.
/// Automatic follows system HDR/native EDR; explicit temporary HDR may change
/// the external display preference before the same public headroom gate.
public struct PlaybackHDRPresentation: Equatable, Codable, Sendable {
    public let referenceWhiteSignalNits: Int
    public let targetPeakSignalNits: Int
    public let maximumLinearComponent: Double
    public let awaitingHeadroom: Bool

    static func plan(headroom: Double?, awaitingHeadroom: Bool) -> Self {
        let ratio = min(10_000.0 / 203, PlaybackVideoOutputPolicy.headroom(headroom) ?? 1)
        let peak = max(203, Int((ratio * 203).rounded(.down)))
        return .init(referenceWhiteSignalNits: 203, targetPeakSignalNits: peak,
                     maximumLinearComponent: Double(peak) / 203, awaitingHeadroom: awaitingHeadroom)
    }

    var options: [String: String] {
        ["target-prim": "bt.709", "target-trc": "linear", "target-peak": String(targetPeakSignalNits),
         "icc-profile-auto": "no", "icc-profile": "", "dither-depth": "no",
         "fbo-format": "rgba32f", "tone-mapping": "bt.2390", "tone-mapping-param": "1",
         "gamut-mapping-mode": "clip", "blend-subtitles": "no"]
    }
}

/// Bounded activation: EDR layers can raise current headroom from an idle 1x.
/// Never submit >1 while waiting, never substitute potential for current, and
/// latch failures until a new media, preference or display configuration event.
struct PlaybackHDRActivation {
    enum Phase: Equatable { case idle, requesting(until: Double), active, failed }
    private(set) var phase = Phase.idle

    mutating func reset() { phase = .idle }
    mutating func fail() { phase = .failed }

    mutating func update(eligible: Bool, currentHeadroom: Double?, now: Double) -> PlaybackHDRPresentation? {
        guard eligible else { reset(); return nil }
        if phase == .failed { return nil }
        if phase == .idle { phase = .requesting(until: now + 3) }
        let current = PlaybackVideoOutputPolicy.headroom(currentHeadroom) ?? 1
        if current > 1.01 {
            phase = .active
            return .plan(headroom: current, awaitingHeadroom: false)
        }
        if case .requesting(let deadline) = phase, now < deadline {
            return .plan(headroom: 1, awaitingHeadroom: true)
        }
        fail()
        return nil
    }
}
