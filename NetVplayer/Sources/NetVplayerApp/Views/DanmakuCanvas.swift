import AppKit
import CoreVideo
import QuartzCore
import SwiftUI
import DanmakuEngine

/// CVDisplayLink never touches AppKit and can enqueue at most one main-thread frame.
private final class DanmakuDisplayDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var link: CVDisplayLink?
    private var active = false
    private var pending = false
    private let frame: @MainActor @Sendable () -> Void

    init(frame: @escaping @MainActor @Sendable () -> Void) {
        self.frame = frame
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
                guard let context else { return kCVReturnError }
                Unmanaged<DanmakuDisplayDriver>.fromOpaque(context).takeUnretainedValue().requestFrame()
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func setActive(_ value: Bool) {
        lock.lock()
        let changed = active != value
        active = value
        lock.unlock()
        guard changed, let link else { return }
        if value { CVDisplayLinkStart(link) } else { CVDisplayLinkStop(link) }
    }

    var isRunning: Bool { link.map(CVDisplayLinkIsRunning) ?? false }

    private func requestFrame() {
        lock.lock()
        guard active, !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pending = false
            let active = self.active
            self.lock.unlock()
            if active { self.frame() }
        }
    }

    deinit { if let link { CVDisplayLinkStop(link) } }
}

private final class DanmakuWindowObservations {
    var tokens: [NSObjectProtocol] = []
    func clear() { tokens.forEach(NotificationCenter.default.removeObserver); tokens = [] }
    deinit { clear() }
}

struct DanmakuCanvas: NSViewRepresentable {
    let cues: [DanmakuCue]
    let epoch: String
    let position: Double
    let rate: Double
    let playing: Bool
    let buffering: Bool
    let seeking: Bool
    let offsetMs: Int
    let opacity: Double
    let fontSize: Int

    func makeNSView(context: Context) -> DanmakuCanvasView { DanmakuCanvasView() }
    func updateNSView(_ view: DanmakuCanvasView, context: Context) { view.configure(self) }
    static func dismantleNSView(_ view: DanmakuCanvasView, coordinator: ()) { view.stop() }
}

@MainActor
final class DanmakuCanvasView: NSView {
    private struct Bitmap { var image: CGImage; var size: CGSize; var cost: Int }
    private var clock = DanmakuPlaybackClock()
    private var layoutEngine = DanmakuLaneLayout()
    private var epoch = ""
    private var fontSize = 28
    private var offset = 0.0
    private var opacity = 0.8
    private var scale = 1.0
    private var bitmapCache: [String: Bitmap] = [:]
    private var cacheOrder: [String] = []
    private var cacheCost = 0
    private var spriteLayers: [String: CALayer] = [:]
    private let observations = DanmakuWindowObservations()
    private lazy var driver = DanmakuDisplayDriver { [weak self] in self?.renderFrame() }
    private var closed = false
    private let bitmapBudget = 12 * 1_024 * 1_024
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }

    func configure(_ input: DanmakuCanvas) {
        let effectiveFont = DanmakuOverlayPolicy.effectiveFontSize(input.fontSize)
        let backingScale = window?.backingScaleFactor ?? 2
        if epoch != input.epoch || fontSize != effectiveFont || offset != Double(input.offsetMs) / 1_000 || scale != backingScale {
            epoch = input.epoch
            fontSize = effectiveFont
            offset = Double(input.offsetMs) / 1_000
            scale = backingScale
            layoutEngine.replace(cues: input.cues)
            bitmapCache = [:]; cacheOrder = []; cacheCost = 0
        }
        opacity = min(1, max(0, input.opacity))
        clock.synchronize(position: input.position, uptime: ProcessInfo.processInfo.systemUptime,
                          rate: input.rate, playing: input.playing, buffering: input.buffering, seeking: input.seeking, epoch: input.epoch)
        renderFrame()
        updateActivity()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observations.clear()
        closed = false
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observations.tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        if closing { self?.closed = true }
                        self?.updateActivity()
                    }
                })
            }
        }
        updateActivity()
    }

    override func layout() { super.layout(); renderFrame() }
    func stop() { driver.setActive(false); observations.clear() }
    var isRefreshing: Bool { driver.isRunning }

    /// One frame for visual regression snapshots; this never starts a display link.
    func snapshotImage() -> CGImage? {
        guard bounds.width > 0, bounds.height > 0,
              let context = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8,
                  bytesPerRow: Int(bounds.width) * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        layer?.bounds = bounds
        renderFrame(allowSnapshot: true)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        layer?.render(in: context)
        return context.makeImage()
    }

    private var visible: Bool {
        !closed && window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
    }

    private func updateActivity() { driver.setActive(visible && clock.isAdvancing) }

    private func renderFrame(allowSnapshot: Bool = false) {
        guard (visible || allowSnapshot), bounds.width > 0, bounds.height > 0 else { driver.setActive(false); return }
        let time = max(0, clock.position(at: ProcessInfo.processInfo.systemUptime) + offset)
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .semibold)
        let sprites = layoutEngine.advance(to: time, width: bounds.width, height: bounds.height,
            laneHeight: Double(fontSize + 10), revision: clock.revision) { cue in
                min(2_400, (cue.text as NSString).size(withAttributes: [.font: font]).width + 8)
            }
        var retained = Set<String>()
        var visibleCost = 0
        var rasterizations = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = Float(opacity)
        for sprite in sprites {
            let estimatedCost = Int(ceil(sprite.width * scale)) * Int(ceil(sprite.height * scale)) * 4
            guard visibleCost + estimatedCost <= bitmapBudget,
                  let bitmap = bitmap(for: sprite, font: font, rasterizations: &rasterizations) else { continue }
            visibleCost += bitmap.cost
            retained.insert(sprite.cue.id)
            let spriteLayer = spriteLayers[sprite.cue.id] ?? CALayer()
            if spriteLayer.superlayer == nil { layer?.addSublayer(spriteLayer) }
            spriteLayer.contents = bitmap.image
            spriteLayer.contentsScale = scale
            let y = sprite.cue.mode == .bottom
                ? max(0, bounds.height - Double(sprite.lane + 1) * sprite.height)
                : Double(sprite.lane) * sprite.height
            spriteLayer.frame = CGRect(x: sprite.x(at: time), y: y, width: bitmap.size.width, height: bitmap.size.height)
            spriteLayers[sprite.cue.id] = spriteLayer
        }
        for id in Array(spriteLayers.keys) where !retained.contains(id) { spriteLayers.removeValue(forKey: id)?.removeFromSuperlayer() }
        CATransaction.commit()
    }

    private func bitmap(for sprite: DanmakuSprite, font: NSFont, rasterizations: inout Int) -> Bitmap? {
        let key = "\(sprite.cue.text)|\(sprite.cue.color)|\(fontSize)|\(scale)"
        if let cached = bitmapCache[key] { return cached }
        guard rasterizations < 12 else { return nil }
        rasterizations += 1
        let size = CGSize(width: sprite.width, height: sprite.height)
        let pixelsWide = Int(ceil(size.width * scale))
        let pixelsHigh = Int(ceil(size.height * scale))
        let cost = pixelsWide * pixelsHigh * 4
        guard cost <= 2 * 1_024 * 1_024,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                  bytesPerRow: pixelsWide * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = size
        let hex = Int(sprite.cue.color.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        let color = NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                            blue: Double(hex & 255) / 255, alpha: 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        (sprite.cue.text as NSString).draw(in: CGRect(x: 4, y: 2, width: size.width - 8, height: size.height - 2),
            withAttributes: [.font: font, .foregroundColor: color, .strokeColor: NSColor.black, .strokeWidth: -3])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { return nil }
        while cacheCost + cost > bitmapBudget || cacheOrder.count >= 128 {
            guard !cacheOrder.isEmpty else { break }
            let oldest = cacheOrder.removeFirst()
            cacheCost -= bitmapCache.removeValue(forKey: oldest)?.cost ?? 0
        }
        let result = Bitmap(image: image, size: size, cost: cost)
        bitmapCache[key] = result
        cacheOrder.append(key)
        cacheCost += cost
        return result
    }
}
