import AppKit
import Testing
import DanmakuEngine
@testable import NetVplayerApp

private final class GlyphWorkerGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private var mainThreadCalls = 0
    var statistics: (calls: Int, main: Int) {
        lock.lock(); defer { lock.unlock() }
        return (calls, mainThreadCalls)
    }
    func prepare(_ key: DanmakuGlyphKey) -> DanmakuPreparedGlyph {
        lock.lock()
        calls += 1
        if Thread.isMainThread { mainThreadCalls += 1 }
        lock.unlock()
        _ = release.wait(timeout: .now() + 5)
        return DanmakuPreparedGlyph.prepare(key)
    }
}

@MainActor
private final class ScaleFixtureWindow: NSWindow {
    var fixtureScale: CGFloat = 1
    override var backingScaleFactor: CGFloat { fixtureScale }
}

@Suite(.serialized) @MainActor
struct DanmakuGlyphPreparationTests {
    @Test func backingScaleInvalidatesRasterWithoutReplacingAdmittedTrajectory() async throws {
        let window = ScaleFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = DanmakuCanvasView()
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView = canvas
        defer { canvas.stop(); window.close() }
        canvas.configure(DanmakuCanvas(cues: [DanmakuCue(id: "scale", timeMs: 0, text: "倍率轨迹")],
            epoch: "scale", position: 1, rate: 1, playing: false, buffering: false, seeking: false,
            offsetMs: 0, opacity: 1, fontSize: 28))
        _ = await canvas.snapshotImage()
        let originalFrame = try #require(canvas.layer?.sublayers?.first?.frame)
        for scale in [2.0, 1.0] {
            let before = canvas.glyphs.generation
            window.fixtureScale = scale
            canvas.viewDidChangeBackingProperties()
            _ = await canvas.snapshotImage()
            let layer = try #require(canvas.layer?.sublayers?.first)
            #expect(canvas.glyphs.generation > before)
            #expect(layer.frame == originalFrame)
            #expect(abs(Double(layer.contentsScale) - scale) < 0.0001)
            let key = DanmakuGlyphKey(text: "倍率轨迹", color: "#FFFFFF", fontSize: 28, scale: scale)
            let glyph = try #require(canvas.glyphs.glyph(for: key))
            #expect(glyph.image?.width == Int(ceil(originalFrame.width * scale)))
        }
        #expect(!canvas.isRefreshing)
    }

    @Test func invalidationRejectsSeekFontScaleAndEpochBatchesWithoutStartingAnotherWorker() async throws {
        for reason in ["seek", "font", "scale", "epoch"] {
            let gate = GlyphWorkerGate()
            let cache = DanmakuGlyphPreparation(prepare: gate.prepare)
            defer { for _ in 0..<8 { gate.release.signal() } }
            let old = (0..<4).map { key("\(reason)-old\($0)") }
            cache.request(old, protecting: [])
            try await wait { gate.statistics.calls == 1 }
            let reservation = cache.reservedCost
            #expect(reservation > 0)
            cache.invalidate()
            let new = key(reason, font: reason == "font" ? 40 : 28, scale: reason == "scale" ? 1 : 2)
            cache.request([new], protecting: [])
            try await Task.sleep(for: .milliseconds(20))
            #expect(gate.statistics.calls == 1)
            #expect(gate.statistics.main == 0)
            #expect(cache.isWorking && cache.reservedCost == reservation)
            for _ in 0..<4 { gate.release.signal() }
            try await wait { !cache.isWorking }
            #expect(cache.rejectedResults == 4)
            #expect(cache.count == 0 && cache.cost == 0)
            #expect(old.allSatisfy { cache.glyph(for: $0) == nil })
            cache.request([new], protecting: [])
            gate.release.signal()
            try await wait { !cache.isWorking }
            let glyph = try #require(cache.glyph(for: new))
            #expect(glyph.image?.width == Int(ceil(glyph.size.width * new.scale)))
            #expect(cache.count == 1)
        }
    }

    @Test func requestCountAndBitmapMemoryIncludingReservationsStayBoundedAndLayersPinImages() async throws {
        let cache = DanmakuGlyphPreparation()
        let keys = (0..<256).map { key("字\($0)", font: 18, scale: 1) }
        cache.request(keys, protecting: [])
        #expect(cache.pendingCount <= 128)
        try await wait {
            cache.request(Array(keys.prefix(128)), protecting: [])
            #expect(cache.count <= 128)
            #expect(cache.cost + cache.reservedCost <= 12 * 1_024 * 1_024)
            return cache.count == 128 && !cache.isWorking
        }
        let pinned = try #require(cache.glyph(for: keys[0])?.image)
        let next = Array(keys[128...])
        try await wait {
            cache.request(next, protecting: [keys[0]])
            #expect(cache.count <= 128)
            #expect(cache.cost + cache.reservedCost <= 12 * 1_024 * 1_024)
            return !cache.isWorking
        }
        #expect(cache.glyph(for: keys[0])?.image === pinned)

        cache.invalidate()
        let large = (0..<40).map { key("\($0)" + String(repeating: "密", count: 98)) }
        try await wait {
            cache.request(large, protecting: [])
            #expect(cache.cost + cache.reservedCost <= 12 * 1_024 * 1_024)
            return !cache.isWorking
        }
        #expect(cache.count > 0 && cache.count < large.count)
        #expect(cache.cost > 0)
    }

    @Test func blockedWorkerLeavesMainActorResponsiveAndStopRejectsItsResult() async throws {
        let gate = GlyphWorkerGate()
        let cache = DanmakuGlyphPreparation(prepare: gate.prepare)
        let canvas = DanmakuCanvasView(glyphs: cache)
        defer { gate.release.signal(); canvas.stop() }
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        canvas.configure(DanmakuCanvas(cues: [DanmakuCue(id: "cold", timeMs: 0, text: "后台", mode: .top)],
            epoch: "one", position: 1, rate: 1, playing: false, buffering: false, seeking: false,
            offsetMs: 0, opacity: 1, fontSize: 28))
        let snapshot = Task { await canvas.snapshotImage() }
        try await wait { gate.statistics.calls == 1 }
        // This MainActor continuation executes while synchronous rasterization is blocked.
        #expect(cache.isWorking && gate.statistics.main == 0)
        canvas.stop()
        gate.release.signal()
        _ = await snapshot.value
        try await wait { !cache.isWorking }
        #expect(cache.count == 0 && cache.rejectedResults == 1)
        #expect(canvas.layer?.sublayers?.isEmpty != false)
        #expect(!canvas.isRefreshing)
    }

    private func key(_ text: String, font: Int = 28, scale: Double = 2) -> DanmakuGlyphKey {
        DanmakuGlyphKey(text: text, color: "26B3FF", fontSize: font, scale: scale)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "background glyph deadline exceeded")
    }
}
