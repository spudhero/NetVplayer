import AppKit
import Testing
import DanmakuEngine
@testable import NetVplayerApp

@MainActor
@Test func danmakuCanvasRasterizesOffscreenAndDoesNotRefreshWhenDetached() async throws {
    let canvas = DanmakuCanvasView()
    canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 450)
    defer { canvas.stop() }
    let configuration = DanmakuCanvas(
        cues: [DanmakuCue(id: "sample", timeMs: 0, text: "弹幕位图测试 · Hello 2026", mode: .top)],
        epoch: "render-test", position: 1, rate: 1, playing: true, buffering: false,
        seeking: false, offsetMs: 0, opacity: 1, fontSize: 28)
    canvas.configure(configuration)
    #expect(!canvas.isRefreshing)
    let image = try #require(await canvas.snapshotImage())
    #expect(canvas.glyphs.count > 0, "cache=\(canvas.glyphs.count) batches=\(canvas.glyphs.completedBatches) pending=\(canvas.glyphs.pendingCount) working=\(canvas.glyphs.isWorking) generation=\(canvas.glyphs.generation)")
    let pixels = NSBitmapImageRep(cgImage: image)
    let bytes = try #require(pixels.bitmapData)
    let hasVisiblePixels = (0..<(pixels.bytesPerRow * pixels.pixelsHigh)).contains { bytes[$0] > 0 }
    #expect(hasVisiblePixels)
    let png = try #require(pixels.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/private/tmp/netplayer-danmaku-preview.png"))
    #expect(!canvas.isRefreshing)
}

@MainActor
@Test func danmakuRasterHasExplicitSRGBAndReadableWhiteColoredFillAndSoftShadow() async throws {
    let canvas = DanmakuCanvasView()
    canvas.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    defer { canvas.stop() }
    for (hex, target) in [("FFFFFF", [1.0,1,1]), ("CC5533", [0.8,1.0/3,0.2])] {
        canvas.configure(DanmakuCanvas(
            cues: [DanmakuCue(id: hex, timeMs: 0, text: "MMMM 可读性", mode: .top, color: hex)],
            epoch: hex, position: 1, rate: 1, playing: false, buffering: false,
            seeking: false, offsetMs: 0, opacity: 1, fontSize: 40))
        let image = try #require(await canvas.snapshotImage())
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
        #expect(image.alphaInfo == .premultipliedLast)
        let provider = try #require(image.dataProvider?.data)
        let bytes = provider as Data
        var fillCount = 0, shadowCount = 0
        var closest = [CGFloat](), distance = Double.infinity
        for y in 0..<image.height { for x in 0..<image.width {
            let offset = y*image.bytesPerRow + x*4
            let alpha = bytes[offset+3]
            if alpha > 8, alpha < 245, (0..<3).allSatisfy({ bytes[offset+$0] <= 4 }) { shadowCount += 1 }
            guard alpha > 250 else { continue }
            // colorAt creates a device NSColor and can reinterpret already
            // tagged samples through the current monitor. Read the explicitly
            // sRGB CGImage bytes without adding that unrelated conversion.
            let values = (0..<3).map { CGFloat(bytes[offset+$0])/255 }
            let error = zip(values, target).reduce(0) { $0 + abs(Double($1.0)-$1.1) }
            if error < distance { distance = error; closest = values }
            if zip(values, target).allSatisfy({ abs($0-$1) <= 4.0/255 }) { fillCount += 1 }
        } }
        #expect(fillCount > 30, "\(hex): closest \(closest), error \(distance)")
        // The shadow is translucent; the original opaque glyph color is retained.
        #expect(shadowCount > 10)
    }
}
