import Testing
import DanmakuEngine

struct DanmakuResizeTests {
    @Test func reverseScrollRetainsConstantSpeedThroughPreparationResizeAndSeek() throws {
        var layout = DanmakuLaneLayout()
        layout.replace(cues: [DanmakuCue(id: "reverse", timeMs: 0, text: "反向", mode: .reverseScroll)])
        #expect(layout.advance(to: 1, width: 2_000, height: 400, laneHeight: 40, revision: 1) { _ in nil }.isEmpty)
        let original = try #require(layout.advance(to: 1.5, width: 2_000, height: 400, laneHeight: 40, revision: 1) { _ in 600 }.first)
        #expect(original.startsAt == 0 && original.speed == 120)
        #expect(original.x(at: 1.5) == -420)
        let resized = try #require(layout.advance(to: 12, width: 320, height: 80, laneHeight: 40, revision: 1) { _ in 600 }.first)
        #expect(resized.viewportWidth == original.viewportWidth)
        #expect(resized.endsAt == original.endsAt && resized.x(at: 12) == original.x(at: 12))
        let rebuilt = try #require(layout.advance(to: 12, width: 2_000, height: 400, laneHeight: 40, revision: 2) { _ in 600 }.first)
        #expect(rebuilt.x(at: 12) == original.x(at: 12) && rebuilt.endsAt == original.endsAt)
    }

    @Test func resizingPreservesAdmittedTrajectoryAndCursor() throws {
        var layout = DanmakuLaneLayout()
        layout.replace(cues: [DanmakuCue(id: "moving", timeMs: 0, text: "宽弹幕"),
                              DanmakuCue(id: "fixed", timeMs: 0, text: "固定", mode: .bottom)])
        let original = layout.advance(to: 1, width: 800, height: 400, laneHeight: 40, revision: 1) { _ in 600 }
        #expect(original.count == 2)
        for step in 1...100 {
            let time = 1 + Double(step) / 100
            let frame = layout.advance(to: time, width: step.isMultiple(of: 2) ? 320 : 2_000,
                height: step.isMultiple(of: 3) ? 80 : 800, laneHeight: 40, revision: 1) { _ in 600 }
            #expect(frame.map(\.cue.id) == original.map(\.cue.id))
            for (sprite, prior) in zip(frame, original) {
                #expect(sprite.lane == prior.lane)
                #expect(sprite.startsAt == prior.startsAt && sprite.endsAt == prior.endsAt)
                #expect(sprite.viewportWidth == prior.viewportWidth && sprite.speed == prior.speed)
                #expect(sprite.x(at: time) == prior.x(at: time))
            }
        }
        #expect(layout.droppedCount == 0)
        let afterDisplayGap = layout.advance(to: 4.5, width: 2_000, height: 800, laneHeight: 40, revision: 1) { _ in 600 }
        #expect(afterDisplayGap.map(\.cue.id) == ["moving"])
        #expect(afterDisplayGap.first?.viewportWidth == 800)
        #expect(afterDisplayGap.first?.x(at: 4.5) == original.first?.x(at: 4.5))
    }

    @Test func croppedTopAndBottomLanesKeepTheirOccupantsUntilExpiry() {
        var layout = DanmakuLaneLayout()
        let cues = (0..<3).flatMap { index in
            [DanmakuCue(id: "top\(index)", timeMs: 0, text: "顶", mode: .top),
             DanmakuCue(id: "bottom\(index)", timeMs: 0, text: "底", mode: .bottom)]
        } + [DanmakuCue(id: "intruder", timeMs: 1_200, text: "新", mode: .top),
             DanmakuCue(id: "later", timeMs: 4_100, text: "后", mode: .top)]
        layout.replace(cues: cues)
        let original = layout.advance(to: 1, width: 800, height: 400, laneHeight: 40, revision: 1) { _ in 80 }
        #expect(original.count == 6)
        let cropped = layout.advance(to: 1.2, width: 200, height: 70, laneHeight: 40, revision: 1) { _ in 80 }
        #expect(cropped.map(\.cue.id) == original.map(\.cue.id))
        let restored = layout.advance(to: 1.3, width: 800, height: 400, laneHeight: 40, revision: 1) { _ in 80 }
        #expect(restored.map(\.cue.id) == original.map(\.cue.id))
        #expect(layout.droppedCount == 1)
        for time in [2.0, 3.0, 4.0, 4.2] {
            _ = layout.advance(to: time, width: 800, height: 400, laneHeight: 40, revision: 1) { _ in 80 }
        }
        #expect(layout.sprites.map(\.cue.id) == ["later"])
        #expect(layout.sprites.first?.lane == 0)
    }

    @Test func wideViewportExtendsLifetimeAndSeekReconstructionBeyondSevenSeconds() throws {
        var layout = DanmakuLaneLayout()
        layout.replace(cues: [DanmakuCue(id: "wide", timeMs: 0, text: "长"),
                              DanmakuCue(id: "expired", timeMs: 0, text: "固定", mode: .top)])
        let original = try #require(layout.advance(to: 0, width: 2_000, height: 400, laneHeight: 40, revision: 1) { _ in 600 }.first)
        for time in 1...12 {
            _ = layout.advance(to: Double(time), width: 2_000, height: 400, laneHeight: 40, revision: 1) { _ in 600 }
        }
        #expect(layout.sprites.map(\.cue.id) == ["wide"])
        let rebuilt = try #require(layout.advance(to: 12, width: 2_000, height: 400, laneHeight: 40, revision: 2) { _ in 600 }.first)
        #expect(rebuilt.x(at: 12) == original.x(at: 12))
        #expect(rebuilt.endsAt == original.endsAt)
        #expect(rebuilt.speed == 120)
    }

    @Test func missingMetricsWaitWithoutRewindingAndExpiredFixedCuesAreSkipped() throws {
        var layout = DanmakuLaneLayout()
        layout.replace(cues: [DanmakuCue(id: "late", timeMs: 0, text: "尚未准备")])
        #expect(layout.advance(to: 1, width: 800, height: 400, laneHeight: 40, revision: 1) { _ in nil }.isEmpty)
        #expect(layout.preparationCandidates(through: 2, limit: 4).map(\.id) == ["late"])
        let sprite = try #require(layout.advance(to: 1.5, width: 800, height: 400, laneHeight: 40, revision: 1) { _ in 80 }.first)
        #expect(sprite.startsAt == 0)
        #expect(sprite.x(at: 1.5) == 620)
        layout.replace(cues: [DanmakuCue(id: "expired", timeMs: 0, text: "旧", mode: .top)])
        #expect(layout.advance(to: 5, width: 800, height: 400, laneHeight: 40, revision: 2) { _ in nil }.isEmpty)
        #expect(layout.preparationCandidates(through: 6, limit: 128).isEmpty)
    }
}
