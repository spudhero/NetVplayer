import AppKit
import Testing
import DanmakuEngine
@testable import NetVplayerApp

@MainActor
@Test func danmakuCanvasRasterizesOffscreenAndDoesNotRefreshWhenDetached() throws {
    let canvas = DanmakuCanvasView()
    canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 450)
    defer { canvas.stop() }
    let configuration = DanmakuCanvas(
        cues: [DanmakuCue(id: "sample", timeMs: 0, text: "弹幕位图测试 · Hello 2026", mode: .top)],
        epoch: "render-test", position: 1, rate: 1, playing: true, buffering: false,
        seeking: false, offsetMs: 0, opacity: 1, fontSize: 28)
    canvas.configure(configuration)
    #expect(!canvas.isRefreshing)
    let image = try #require(canvas.snapshotImage())
    let pixels = NSBitmapImageRep(cgImage: image)
    let bytes = try #require(pixels.bitmapData)
    let hasVisiblePixels = (0..<(pixels.bytesPerRow * pixels.pixelsHigh)).contains { bytes[$0] > 0 }
    #expect(hasVisiblePixels)
    let png = try #require(pixels.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/private/tmp/netplayer-danmaku-preview.png"))
    #expect(!canvas.isRefreshing)
}
