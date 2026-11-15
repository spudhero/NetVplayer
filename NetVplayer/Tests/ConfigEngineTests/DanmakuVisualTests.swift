import AppKit
import Testing
import DanmakuEngine
@testable import NetVplayerApp

@Suite(.serialized) @MainActor
struct DanmakuVisualTests {
    private let sample = "中文小字：清晰的笔画 · Agj 2026"
    private let colors = ["FFFFFF", "FFDD22", "CC5533", "26B3FF"]

    @Test func fillShadowPixelsAndScaleBounds() throws {
        var rows: [[String: Any]] = []
        for fontSize in [18, 28, 40, 72] {
            let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .semibold)
            let size = CGSize(width: DanmakuTextRasterizer.width(text: sample, font: font),
                              height: DanmakuTextRasterizer.laneHeight(font: font))
            for hex in colors {
                var previousBounds: CGRect?
                for scale in [1.0, 2.0] {
                    let image = try #require(DanmakuTextRasterizer.image(text: sample, color: hex, font: font, size: size, scale: scale))
                    let fill = try drawReference(text: sample, hex: hex, font: font, size: size, scale: scale, legacy: false)
                    #expect(image.colorSpace?.name == CGColorSpace.sRGB)
                    #expect(image.alphaInfo == .premultipliedLast)
                    #expect(image.width == Int(size.width * scale))
                    #expect(image.height == Int(size.height * scale))
                    let bytes = try #require(image.dataProvider?.data) as Data
                    let fillBytes = try #require(fill.dataProvider?.data) as Data
                    var core = 0, preserved = 0, shadow = 0, border = 0
                    var minX = image.width, minY = image.height, maxX = 0, maxY = 0
                    for y in 0..<image.height { for x in 0..<image.width {
                        let index = y * image.bytesPerRow + x * 4
                        let alpha = bytes[index + 3]
                        if fillBytes[index + 3] >= 250 {
                            core += 1
                            if (0..<3).allSatisfy({ abs(Int(bytes[index+$0])-Int(fillBytes[index+$0])) <= 4 }) { preserved += 1 }
                        }
                        if fillBytes[index + 3] == 0, alpha > 4,
                           (0..<3).allSatisfy({ bytes[index+$0] <= 4 }) { shadow += 1 }
                        if alpha > 0 {
                            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                            if x == 0 || x == image.width-1 || y == 0 || y == image.height-1 { border += 1 }
                        }
                    } }
                    #expect(core > 50)
                    #expect(preserved == core, "Every opaque glyph pixel must retain its original color")
                    #expect(shadow > 20)
                    #expect(border == 0, "\(fontSize)pt \(scale)x: glyphs and blur need transparent margins")
                    let bounds = CGRect(x: Double(minX)/scale, y: Double(minY)/scale,
                                        width: Double(maxX-minX+1)/scale, height: Double(maxY-minY+1)/scale)
                    if let previousBounds {
                        #expect(abs(bounds.minX-previousBounds.minX) <= 1.5)
                        #expect(abs(bounds.minY-previousBounds.minY) <= 1.5)
                        #expect(abs(bounds.maxX-previousBounds.maxX) <= 1.5)
                        #expect(abs(bounds.maxY-previousBounds.maxY) <= 1.5)
                    }
                    previousBounds = bounds
                    rows.append(["fontSize": fontSize, "scale": scale, "color": hex,
                                 "pixels": [image.width, image.height], "opaqueFillPixels": core,
                                 "preservedFillPixels": preserved, "shadowPixels": shadow, "borderPixels": border,
                                 "inkBoundsInPoints": [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]])
                }
            }
        }
        if let root = try evidenceRoot() {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("pixel-matrix.json"))
        }
    }

    @Test func viewportClipsOnlyAtItsEdgesAndLongCuesStayOnOneLine() async throws {
        let canvas = DanmakuCanvasView()
        canvas.frame = NSRect(x: 0, y: 0, width: 240, height: 240)
        defer { canvas.stop() }
        canvas.configure(configuration(cues: [
            DanmakuCue(id: "top", timeMs: 0, text: "中文 Agj", mode: .top),
            DanmakuCue(id: "bottom", timeMs: 0, text: "中文 Agj", mode: .bottom, color: "CC5533")
        ], fontSize: 72))
        _ = try #require(await canvas.snapshotImage())
        let layers = try #require(canvas.layer?.sublayers)
        #expect(layers.count == 2)
        #expect(layers.allSatisfy { $0.frame.minY >= 0 && $0.frame.maxY <= canvas.bounds.height })
        #expect(layers.allSatisfy { $0.frame.height >= 93 })
        #expect(canvas.layer?.masksToBounds == true)
        let font = NSFont.systemFont(ofSize: 72, weight: .semibold)
        let long = String(repeating: "中文 Agj ", count: 80)
        let width = DanmakuTextRasterizer.width(text: long, font: font)
        #expect(width == 2_400)
        let image = try #require(DanmakuTextRasterizer.image(text: long, color: "FFFFFF", font: font,
            size: CGSize(width: width, height: DanmakuTextRasterizer.laneHeight(font: font)), scale: 1))
        #expect(image.width == 2_400)
        #expect(image.height == 93)
        if let root = try evidenceRoot() {
            try save(try #require(await canvas.snapshotImage()), to: root.appendingPathComponent("canvas-edge-72pt.png"))
            try save(image, to: root.appendingPathComponent("long-cue-capped.png"))
        }
    }

    @Test func bitmapReuseMemoryBudgetAndEpochInvalidation() async throws {
        let canvas = DanmakuCanvasView()
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 6_000)
        defer { canvas.stop() }
        let cues = (0..<120).map { DanmakuCue(id: "cue-\($0)", timeMs: 0,
            text: "\($0) " + String(repeating: "密集弹幕", count: 25), mode: .top) }
        canvas.configure(configuration(cues: cues, fontSize: 18))
        _ = try #require(await canvas.snapshotImage())
        let first = try #require(canvas.layer?.sublayers)
        #expect(!first.isEmpty)
        let firstImage = first[0].contents as AnyObject?
        for _ in 0..<12 {
            _ = try #require(await canvas.snapshotImage())
            let layers = try #require(canvas.layer?.sublayers)
            #expect(layers.count <= 120)
            let images = try layers.map(layerImage)
            let bytes = images.reduce(0) { $0 + $1.bytesPerRow * $1.height }
            #expect(bytes <= 12 * 1_024 * 1_024)
            #expect(images.allSatisfy { $0.bytesPerRow * $0.height <= 2 * 1_024 * 1_024 })
        }
        #expect(firstImage === (canvas.layer?.sublayers?.first?.contents as AnyObject?))
        canvas.configure(configuration(cues: [DanmakuCue(id: "new", timeMs: 0, text: "新会话", mode: .top)], epoch: "new"))
        _ = try #require(await canvas.snapshotImage())
        #expect(canvas.layer?.sublayers?.count == 1)
        #expect(firstImage !== (canvas.layer?.sublayers?.first?.contents as AnyObject?))
        #expect(!canvas.isRefreshing)
    }

    @Test func visualComparisonPanels() throws {
        guard let root = try evidenceRoot() else { return }
        for scale in [1.0, 2.0] {
            let panel = try context(width: Int(1000*scale), height: Int(650*scale))
            panel.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: panel, flipped: false)
            for (column, legacy) in [true, false].enumerated() {
                let x = CGFloat(column*500)
                for (background, brightness) in [0.07, 0.95].enumerated() {
                    let y = CGFloat(325-background*325)
                    panel.setFillColor(CGColor(gray: brightness, alpha: 1))
                    panel.fill(CGRect(x: x, y: y, width: 500, height: 325))
                    let label = "\(legacy ? "Before: fill + stroke -3" : "After: fill + soft shadow") / \(Int(scale))x"
                    (label as NSString).draw(at: NSPoint(x: x+16, y: y+288), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 16), .foregroundColor: brightness < 0.5 ? NSColor.white : NSColor.black])
                    for (row, hex) in colors.enumerated() {
                        let font = NSFont.systemFont(ofSize: 18, weight: .semibold)
                        let text = [sample, "彩色弹幕：晴空万里 · Agj", "彩色弹幕：晚霞与海 · Agj", "蓝色弹幕：影像与声音 · Agj"][row]
                        let size = legacy ? CGSize(width: (text as NSString).size(withAttributes: [.font: font]).width+8, height: 28)
                            : CGSize(width: DanmakuTextRasterizer.width(text: text, font: font), height: DanmakuTextRasterizer.laneHeight(font: font))
                        let image = try legacy ? drawReference(text: text, hex: hex, font: font, size: size, scale: scale, legacy: true)
                            : #require(DanmakuTextRasterizer.image(text: text, color: hex, font: font, size: size, scale: scale))
                        panel.draw(image, in: CGRect(x: x+16, y: y+240-CGFloat(row*44), width: CGFloat(image.width)/scale, height: CGFloat(image.height)/scale))
                    }
                    let font = NSFont.systemFont(ofSize: 28, weight: .semibold), text = "弹幕 28pt · Agj"
                    let size = legacy ? CGSize(width: (text as NSString).size(withAttributes: [.font: font]).width+8, height: 38)
                        : CGSize(width: DanmakuTextRasterizer.width(text: text, font: font), height: DanmakuTextRasterizer.laneHeight(font: font))
                    let image = try legacy ? drawReference(text: text, hex: "FFFFFF", font: font, size: size, scale: scale, legacy: true)
                        : #require(DanmakuTextRasterizer.image(text: text, color: "FFFFFF", font: font, size: size, scale: scale))
                    panel.draw(image, in: CGRect(x: x+16, y: y+32, width: CGFloat(image.width)/scale, height: CGFloat(image.height)/scale))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try save(try #require(panel.makeImage()), to: root.appendingPathComponent("comparison-\(Int(scale))x.png"))
        }
    }

    @Test func canvasEvidence() async throws {
        guard let directory = ProcessInfo.processInfo.environment["NETVPLAYER_DANMAKU_EVIDENCE"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canvas = DanmakuCanvasView()
        canvas.frame = NSRect(x: 0, y: 0, width: 960, height: 320)
        defer { canvas.stop() }
        for size in [18, 28, 72] {
            canvas.configure(DanmakuCanvas(cues: [
                DanmakuCue(id: "white", timeMs: 0, text: "中文小字：清晰的笔画 · Agj 2026", mode: .top),
                DanmakuCue(id: "red", timeMs: 0, text: "彩色弹幕：晚霞与海 · Agj", mode: .top, color: "CC5533"),
                DanmakuCue(id: "yellow", timeMs: 0, text: "彩色弹幕：晴空万里 · Agj", mode: .bottom, color: "FFDD22")
            ], epoch: "visual-\(size)", position: 1, rate: 1, playing: false, buffering: false,
               seeking: false, offsetMs: 0, opacity: 1, fontSize: size))
            let image = try #require(await canvas.snapshotImage())
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("canvas-\(size)pt.png"))
            #expect(!canvas.isRefreshing)
        }
    }

    private func layerImage(_ layer: CALayer) throws -> CGImage {
        let contents = try #require(layer.contents)
        try #require(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID)
        return contents as! CGImage
    }

    private func configuration(cues: [DanmakuCue], epoch: String = "pixels", fontSize: Int = 28,
                               playing: Bool = false, buffering: Bool = false, seeking: Bool = false) -> DanmakuCanvas {
        DanmakuCanvas(cues: cues, epoch: epoch, position: 1, rate: 1, playing: playing, buffering: buffering,
                      seeking: seeking, offsetMs: 0, opacity: 1, fontSize: fontSize)
    }

    private func context(width: Int, height: Int) throws -> CGContext {
        try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    // Frozen local baseline from 049827f2; never used by the product.
    // The fill-only branch independently checks that opaque glyph interiors survive the shadow.
    private func drawReference(text: String, hex: String, font: NSFont, size: CGSize, scale: CGFloat, legacy: Bool) throws -> CGImage {
        let cg = try context(width: Int(ceil(size.width*scale)), height: Int(ceil(size.height*scale)))
        let value = Int(hex, radix: 16)!
        let color = NSColor(srgbRed: Double((value>>16)&255)/255, green: Double((value>>8)&255)/255,
                            blue: Double(value&255)/255, alpha: 1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        cg.scaleBy(x: scale, y: scale)
        if legacy {
            (text as NSString).draw(in: CGRect(x: 4, y: 2, width: size.width-8, height: size.height-2),
                withAttributes: [.font: font, .foregroundColor: color, .strokeColor: NSColor.black, .strokeWidth: -3])
        } else {
            (text as NSString).draw(at: NSPoint(x: 4, y: 4), withAttributes: [.font: font, .foregroundColor: color])
        }
        return try #require(cg.makeImage())
    }

    private func evidenceRoot() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_DANMAKU_EVIDENCE"] else { return nil }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func save(_ image: CGImage, to url: URL) throws {
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }
}
