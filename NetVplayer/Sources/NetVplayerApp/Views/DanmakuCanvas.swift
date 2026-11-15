import AppKit
import CoreVideo
import QuartzCore
import SwiftUI
import DanmakuEngine

/// Shadows are baked into a private sRGB bitmap with thread-local drawing state.
enum DanmakuTextRasterizer {
    static let padding: CGFloat = 4

    static func laneHeight(font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + padding * 2
    }

    static func width(text: String, font: NSFont) -> CGFloat {
        min(2_400, ceil((text as NSString).size(withAttributes: [.font: font]).width) + padding * 2)
    }

    static func image(text: String, color hexColor: String, font: NSFont, size: CGSize, scale: CGFloat) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else { return nil }
        let width = ceil(size.width * scale), height = ceil(size.height * scale)
        guard width * height <= Double(2 * 1_024 * 1_024 / 4),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let pixels = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                  bytesPerRow: Int(width) * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let hex = Int(hexColor.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        let color = NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                            blue: Double(hex & 255) / 255, alpha: 1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: pixels, flipped: false)
        pixels.scaleBy(x: scale, y: scale)
        // CGContext shadows use device-space dimensions, independent of the CTM.
        // Keep the 1.5pt blur and 1pt downward offset consistent at 1x and 2x.
        pixels.setShadow(offset: CGSize(width: 0, height: -scale), blur: 1.5 * scale,
                         color: CGColor(gray: 0, alpha: 0.9))
        // A cue is a single line. Overlong cues keep the existing 2400pt cap;
        // clipping cannot wrap a second line into another lane.
        (text as NSString).draw(at: NSPoint(x: padding, y: padding),
                               withAttributes: [.font: font, .foregroundColor: color])
        return pixels.makeImage()
    }
}

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
    var requestedActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }
    var stateDescription: String {
        lock.lock(); defer { lock.unlock() }
        return "requested=\(active)"
    }

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
    var visibility: NSKeyValueObservation?
    func clear() {
        visibility?.invalidate(); visibility = nil
        tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
    }
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
    private var clock = DanmakuPlaybackClock()
    private var layoutEngine = DanmakuLaneLayout()
    private var epoch = ""
    private var fontSize = 28
    private var offset = 0.0
    private var opacity = 0.8
    private var scale = 1.0
    let glyphs: DanmakuGlyphPreparation
    private var laneHeight = 0.0
    private var glyphClockRevision: UInt64 = 0
    private var snapshotting = false
    private var spriteLayers: [String: CALayer] = [:]
    private let observations = DanmakuWindowObservations()
    private lazy var driver = DanmakuDisplayDriver { [weak self] in self?.renderFrame() }
    private var closed = false
    private var activityUpdatePending = false
    private(set) var windowVisibilityChanges = 0
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(glyphs: DanmakuGlyphPreparation = DanmakuGlyphPreparation()) {
        self.glyphs = glyphs
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        glyphs.onPrepared = { [weak self] in self?.renderFrame() }
    }
    required init?(coder: NSCoder) { nil }

    func configure(_ input: DanmakuCanvas) {
        let effectiveFont = DanmakuOverlayPolicy.effectiveFontSize(input.fontSize)
        let backingScale = window?.backingScaleFactor ?? 2
        let replacesLayout = epoch != input.epoch || fontSize != effectiveFont || offset != Double(input.offsetMs) / 1_000
        let changesGlyphs = replacesLayout || scale != backingScale
        epoch = input.epoch
        fontSize = effectiveFont
        offset = Double(input.offsetMs) / 1_000
        scale = backingScale
        laneHeight = DanmakuTextRasterizer.laneHeight(font: NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .semibold))
        if replacesLayout { layoutEngine.replace(cues: input.cues) }
        opacity = min(1, max(0, input.opacity))
        clock.synchronize(position: input.position, uptime: ProcessInfo.processInfo.systemUptime,
                          rate: input.rate, playing: input.playing, buffering: input.buffering, seeking: input.seeking, epoch: input.epoch)
        if changesGlyphs || glyphClockRevision != clock.revision {
            invalidateGlyphs()
            glyphClockRevision = clock.revision
        }
        renderFrame()
        updateActivity()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observations.clear()
        closed = false
        if let window {
            observations.visibility = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.windowVisibilityChanges += 1
                    self?.updateActivity()
                    self?.scheduleActivityUpdate()
                }
            }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                           NSWindow.didDeminiaturizeNotification, NSWindow.didUpdateNotification,
                           NSWindow.willCloseNotification] {
                observations.tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    let updating = note.name == NSWindow.didUpdateNotification
                    MainActor.assumeIsolated {
                        if closing { self?.stop() } else {
                            // A quick orderOut/orderFront can coalesce occlusion
                            // notifications. Window updates reconcile only a
                            // changed activity decision, without extra frames.
                            if !updating || self?.driver.requestedActive != self?.shouldRefresh {
                                self?.updateActivity()
                                self?.scheduleActivityUpdate()
                            }
                        }
                    }
                })
            }
        }
        viewDidChangeBackingProperties()
        updateActivity()
        scheduleActivityUpdate()
    }

    override func layout() { super.layout(); updateActivity() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let backingScale = window?.backingScaleFactor ?? 2
        guard scale != backingScale else { return }
        scale = backingScale
        invalidateGlyphs()
        renderFrame()
    }
    func stop() {
        closed = true
        driver.setActive(false)
        observations.clear()
        invalidateGlyphs()
    }
    var isRefreshing: Bool { driver.isRunning }
    var frameActivityDescription: String {
        "visible=\(visible) advancing=\(clock.isAdvancing) closed=\(closed) hidden=\(isHiddenOrHasHiddenAncestor) running=\(driver.isRunning) \(driver.stateDescription)"
    }

    /// One frame for visual regression snapshots; this never starts a display link.
    func snapshotImage() async -> CGImage? {
        snapshotting = true
        defer { snapshotting = false }
        renderFrame(allowSnapshot: true)
        // An explicit snapshot may await cold preparation. Display-link frames
        // never wait, measure text, or draw glyphs.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while glyphs.isWorking, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
            renderFrame(allowSnapshot: true)
        }
        guard bounds.width > 0, bounds.height > 0,
              let context = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8,
                  bytesPerRow: Int(bounds.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
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

    private func updateActivity() {
        driver.setActive(shouldRefresh)
        if visible { renderFrame() }
    }

    private var shouldRefresh: Bool {
        visible && bounds.width > 0 && bounds.height > 0 && clock.isAdvancing
    }

    private func scheduleActivityUpdate() {
        guard !activityUpdatePending else { return }
        activityUpdatePending = true
        // AppKit can deliver occlusion changes before isVisible settles on
        // restore. Coalesce one follow-up sample after notification delivery.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activityUpdatePending = false
            self.updateActivity()
        }
    }

    private func renderFrame(allowSnapshot: Bool = false) {
        // Lifecycle notifications own link activity. A transient hidden frame
        // must not stop the link when AppKit coalesces a quick hide/restore.
        guard (visible || allowSnapshot || snapshotting), !closed, bounds.width > 0, bounds.height > 0 else { return }
        let time = max(0, clock.position(at: ProcessInfo.processInfo.systemUptime) + offset)
        let sprites = layoutEngine.advance(to: time, width: bounds.width, height: bounds.height,
            laneHeight: laneHeight, revision: clock.revision) { cue in
                glyphs.glyph(for: key(for: cue)).map { Double($0.size.width) }
            }
        var retained = Set<String>()
        var visibleCost = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = Float(opacity)
        for sprite in sprites {
            let laneCount = max(1, Int(bounds.height * (sprite.cue.mode == .bottom ? 0.3 : 0.55) / sprite.height))
            // Cropped lanes retain their reservations in the layout engine.
            guard sprite.lane < laneCount,
                  let bitmap = glyphs.glyph(for: key(for: sprite.cue)), let image = bitmap.image,
                  visibleCost + bitmap.cost <= DanmakuGlyphPreparation.byteLimit else { continue }
            visibleCost += bitmap.cost
            retained.insert(sprite.cue.id)
            let spriteLayer = spriteLayers[sprite.cue.id] ?? CALayer()
            spriteLayer.name = sprite.cue.id
            if spriteLayer.superlayer == nil { layer?.addSublayer(spriteLayer) }
            spriteLayer.contents = image
            spriteLayer.contentsScale = scale
            let y = sprite.cue.mode == .bottom
                ? bounds.height - Double(sprite.lane + 1) * sprite.height
                : Double(sprite.lane) * sprite.height
            spriteLayer.frame = CGRect(x: sprite.x(at: time), y: y, width: bitmap.size.width, height: bitmap.size.height)
            spriteLayers[sprite.cue.id] = spriteLayer
        }
        for id in Array(spriteLayers.keys) where !retained.contains(id) { spriteLayers.removeValue(forKey: id)?.removeFromSuperlayer() }
        CATransaction.commit()
        let active = sprites.map { key(for: $0.cue) }
        let upcoming = layoutEngine.preparationCandidates(through: time + 1, limit: DanmakuGlyphPreparation.entryLimit)
        var seen = Set<DanmakuGlyphKey>()
        let requested = Array((active + upcoming.map { key(for: $0) }).filter { seen.insert($0).inserted }
            .prefix(DanmakuGlyphPreparation.entryLimit))
        glyphs.request(requested, protecting: Set(active))
    }

    private func key(for cue: DanmakuCue) -> DanmakuGlyphKey {
        DanmakuGlyphKey(text: cue.text, color: cue.color, fontSize: fontSize, scale: scale)
    }

    private func invalidateGlyphs() {
        for spriteLayer in spriteLayers.values { spriteLayer.removeFromSuperlayer() }
        spriteLayers.removeAll()
        glyphs.invalidate()
    }
}
