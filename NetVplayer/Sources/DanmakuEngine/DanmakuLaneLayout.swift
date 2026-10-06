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
        cue.mode == .scroll ? viewportWidth - speed * (time - startsAt) : (viewportWidth - width) / 2
    }
}

/// A bounded event scheduler. Lane occupancy is evaluated at each cue's media timestamp.
public struct DanmakuLaneLayout: Sendable {
    public static let maximumVisible = 120
    public static let maximumAdmissionsPerFrame = 512
    private var cues: [DanmakuCue] = []
    private var cursor = 0
    private var previousTime: Double?
    private var width = 0.0
    private var height = 0.0
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
                                 revision: UInt64, measure: (DanmakuCue) -> Double) -> [DanmakuSprite] {
        guard time.isFinite, width > 0, height > 0, laneHeight > 0 else { return [] }
        let reset = previousTime == nil || time < (previousTime ?? time) || time - (previousTime ?? time) > 1
            || self.width != width || self.height != height || self.revision != revision
        if reset {
            sprites = []
            cursor = lowerBound(max(0, time - 7))
        }
        self.width = width
        self.height = height
        self.revision = revision
        previousTime = time
        let topCount = max(1, Int(height * 0.55 / laneHeight))
        let bottomCount = max(1, Int(height * 0.3 / laneHeight))
        var examined = 0
        while cursor < cues.count, Double(cues[cursor].timeMs) / 1_000 <= time,
              examined < Self.maximumAdmissionsPerFrame {
            let cue = cues[cursor]
            cursor += 1
            examined += 1
            let start = Double(cue.timeMs) / 1_000
            sprites.removeAll { $0.endsAt <= start }
            guard sprites.count < Self.maximumVisible else { droppedCount += 1; continue }
            let textWidth = max(1, min(2_400, measure(cue)))
            let duration = cue.mode == .scroll ? 7.0 : 4.0
            let speed = cue.mode == .scroll ? (width + textWidth) / duration : 0
            let lanes = cue.mode == .bottom ? bottomCount : topCount
            var chosen: Int?
            for lane in 0..<lanes {
                let occupants = sprites.filter { $0.lane == lane && ($0.cue.mode == .bottom) == (cue.mode == .bottom) }
                let fits = occupants.allSatisfy { prior in
                    guard prior.cue.mode == .scroll, cue.mode == .scroll else { return false }
                    let separation = width - (prior.x(at: start) + prior.width) - 12
                    guard separation >= 0 else { return false }
                    // If the newcomer is faster, it may catch up only after the prior cue leaves.
                    return speed <= prior.speed || separation / (speed - prior.speed) >= prior.endsAt - start
                }
                if fits { chosen = lane; break }
            }
            guard let lane = chosen else { droppedCount += 1; continue }
            sprites.append(DanmakuSprite(cue: cue, lane: lane, width: textWidth, height: laneHeight,
                                          viewportWidth: width, startsAt: start, endsAt: start + duration, speed: speed))
        }
        if cursor < cues.count, Double(cues[cursor].timeMs) / 1_000 <= time {
            let afterBurst = upperBound(time)
            droppedCount += afterBurst - cursor
            cursor = afterBurst
        }
        sprites.removeAll { $0.endsAt <= time }
        return sprites
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
