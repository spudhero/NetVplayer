import Foundation

public struct DanmakuSprite: Sendable {
    public var cue: DanmakuCue
    public var lane: Int
    public var width: Double
    public var height: Double
    public var viewportWidth: Double
    public var startsAt: Double
    public var endsAt: Double
    public var speed: Double

    public func x(at time: Double) -> Double {
        switch cue.mode {
        case .scroll: return viewportWidth - speed * (time - startsAt)
        case .reverseScroll: return -width + speed * (time - startsAt)
        case .top, .bottom: return (viewportWidth - width) / 2
        }
    }
}

/// A bounded event scheduler. Lane occupancy is evaluated at each cue's media timestamp.
public struct DanmakuLaneLayout: Sendable {
    public static let maximumVisible = 120
    public static let maximumAdmissionsPerFrame = 512
    /// Points per media second: resizing changes travel distance, never speed.
    public static let scrollSpeed = 120.0
    public static let maximumTextWidth = 2_400.0
    private var cues: [DanmakuCue] = []
    private var cursor = 0
    private var previousTime: Double?
    private var revision: UInt64 = 0
    public private(set) var sprites: [DanmakuSprite] = []
    public private(set) var droppedCount = 0

    public init() {}

    public mutating func replace(cues: [DanmakuCue]) {
        self.cues = Array(cues.prefix(DanmakuPayloadParser.maxCueCount)).sorted { $0.timeMs < $1.timeMs }
        previousTime = nil
        sprites = []
        cursor = 0
        droppedCount = 0
    }

    public mutating func advance(to time: Double, width: Double, height: Double, laneHeight: Double,
                                 revision: UInt64, measure: (DanmakuCue) -> Double?) -> [DanmakuSprite] {
        guard time.isFinite, width.isFinite, height.isFinite, laneHeight.isFinite,
              width > 0, height > 0, laneHeight > 0 else { return [] }
        // The media clock identifies seeks. A display gap (full-screen animation,
        // occlusion) must not turn a resize into a synthetic seek.
        let reset = previousTime == nil || time < (previousTime ?? time) || self.revision != revision
        if reset {
            sprites = []
            cursor = lowerBound(max(0, time - max(4, (width + Self.maximumTextWidth) / Self.scrollSpeed)))
        }
        self.revision = revision
        previousTime = time
        let topCount = max(1, Int(height * 0.55 / laneHeight))
        let bottomCount = max(1, Int(height * 0.3 / laneHeight))
        var examined = 0
        while cursor < cues.count, Double(cues[cursor].timeMs) / 1_000 <= time,
              examined < Self.maximumAdmissionsPerFrame {
            let cue = cues[cursor]
            let start = Double(cue.timeMs) / 1_000
            let moving = cue.mode == .scroll || cue.mode == .reverseScroll
            let maximumDuration = moving ? (width + Self.maximumTextWidth) / Self.scrollSpeed : 4
            // Expired history must not make cold preparation replay old fixed cues.
            if start + maximumDuration <= time {
                cursor += 1; examined += 1
                continue
            }
            sprites.removeAll { $0.endsAt <= start }
            if sprites.count >= Self.maximumVisible {
                cursor += 1; examined += 1; droppedCount += 1
                continue
            }
            let speed = moving ? Self.scrollSpeed : 0
            let lanes = cue.mode == .bottom ? bottomCount : topCount
            var chosen: Int?
            for lane in 0..<lanes {
                let occupants = sprites.filter { $0.lane == lane && ($0.cue.mode == .bottom) == (cue.mode == .bottom) }
                let fits = occupants.allSatisfy { prior in
                    guard moving, prior.cue.mode == cue.mode else { return false }
                    let separation = cue.mode == .reverseScroll
                        ? prior.x(at: start) - 12
                        : width - (prior.x(at: start) + prior.width) - 12
                    guard separation >= 0 else { return false }
                    // If the newcomer is faster, it may catch up only after the prior cue leaves.
                    return speed <= prior.speed || separation / (speed - prior.speed) >= prior.endsAt - start
                }
                if fits { chosen = lane; break }
            }
            guard let lane = chosen else {
                cursor += 1; examined += 1; droppedCount += 1
                continue
            }
            // A cache miss suspends admission, not the display callback. Retry at
            // the original media timestamp when background preparation completes.
            guard let measuredWidth = measure(cue) else { break }
            cursor += 1
            examined += 1
            let textWidth = max(1, min(Self.maximumTextWidth, measuredWidth))
            let duration = moving ? (width + textWidth) / speed : 4
            guard start + duration > time else { continue }
            sprites.append(DanmakuSprite(cue: cue, lane: lane, width: textWidth, height: laneHeight,
                                          viewportWidth: width, startsAt: start, endsAt: start + duration, speed: speed))
        }
        if examined == Self.maximumAdmissionsPerFrame, cursor < cues.count, Double(cues[cursor].timeMs) / 1_000 <= time {
            let afterBurst = upperBound(time)
            droppedCount += afterBurst - cursor
            cursor = afterBurst
        }
        sprites.removeAll { $0.endsAt <= time }
        return sprites
    }

    /// A bounded slice from the admission cursor, including a short lookahead.
    public func preparationCandidates(through time: Double, limit: Int) -> [DanmakuCue] {
        guard limit > 0, time.isFinite else { return [] }
        return Array(cues[cursor..<min(cues.count, cursor + limit)].prefix { Double($0.timeMs) / 1_000 <= time })
    }

    private func lowerBound(_ time: Double) -> Int {
        var low = 0; var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if Double(cues[mid].timeMs) / 1_000 < time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func upperBound(_ time: Double) -> Int {
        var low = 0; var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if Double(cues[mid].timeMs) / 1_000 <= time { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
