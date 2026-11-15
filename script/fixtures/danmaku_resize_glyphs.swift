import AppKit
import DanmakuEngine

private struct ProbeError: Error { let message: String }

@MainActor
private final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let output: URL
    var fullScreen = false
    var stage = "launch"
    var diagnosticWindow: NSWindow?
    var diagnosticCanvas: DanmakuCanvasView?
    init(output: URL) { self.output = output }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowDidEnterFullScreen(_ notification: Notification) { fullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { fullScreen = false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [self] in
            try? write(["status": "failed", "error": "native watchdog expired"])
            NSApp.terminate(nil)
        }
        Task { @MainActor in
            do {
                var record = try await exercise()
                record["status"] = "passed"
                try write(record)
            } catch {
                try? write(["status": "failed", "error": String(describing: error),
                    "windowVisible": diagnosticWindow?.isVisible ?? false,
                    "occlusion": diagnosticWindow?.occlusionState.rawValue ?? 0,
                    "windowFrame": diagnosticWindow.map { NSStringFromRect($0.frame) } ?? "none",
                    "appActive": NSApp.isActive, "appHidden": NSApp.isHidden])
            }
            NSApp.terminate(nil)
        }
    }

    private func exercise() async throws -> [String: Any] {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 600),
            styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        diagnosticWindow = window
        window.level = .floating
        window.title = "OV91-04 · synthetic danmaku resize / glyph fixture"
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        let canvas = DanmakuCanvasView()
        diagnosticCanvas = canvas
        canvas.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
        window.contentView = canvas
        defer { canvas.stop(); window.close() }
        let cues = [DanmakuCue(id: "moving", timeMs: 0, text: "轨迹稳定 · Agj", color: "26B3FF")]
            + (0..<4).map { DanmakuCue(id: "top\($0)", timeMs: 0, text: "中文顶端轨道 \($0)", mode: .top, color: "CC5533") }
            + (0..<3).map { DanmakuCue(id: "bottom\($0)", timeMs: 0, text: "中文底端轨道 \($0)", mode: .bottom, color: "FFDD22") }
        func input(position: Double = 1, playing: Bool = false, buffering: Bool = false,
                   seeking: Bool = false, font: Int = 28, epoch: String = "native") -> DanmakuCanvas {
            DanmakuCanvas(cues: cues, epoch: epoch, position: position, rate: 1, playing: playing,
                buffering: buffering, seeking: seeking, offsetMs: 0, opacity: 1, fontSize: font)
        }
        func layers() -> [String: CGRect] {
            Dictionary(uniqueKeysWithValues: (canvas.layer?.sublayers ?? []).compactMap { layer in
                layer.name.map { ($0, layer.frame) }
            })
        }
        stage = "visible"
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait { window.occlusionState.contains(.visible) }
        canvas.configure(input())
        _ = try require(await canvas.snapshotImage(), "initial prepared canvas")
        let initial = layers()
        try check(initial.count == cues.count, "all synthetic lanes must be prepared")
        let moving = try require(initial["moving"], "initial moving lane")
        var minimumLayers = initial.count
        for index in 0..<30 {
            let size = index.isMultiple(of: 2) ? NSSize(width: 320, height: 100) : NSSize(width: 960, height: 600)
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            _ = await canvas.snapshotImage()
            minimumLayers = min(minimumLayers, layers().count)
            if index.isMultiple(of: 2) {
                try check(layers().count < initial.count, "cropped lanes must stop drawing")
            } else {
                try check(layers() == initial, "resize must preserve every original trajectory and reservation")
            }
            try check(!canvas.isRefreshing, "paused resize must not start a display link")
        }
        stage = "enter full screen"
        window.level = .normal
        window.toggleFullScreen(nil)
        try await wait { fullScreen }
        _ = await canvas.snapshotImage()
        try check(layers()["moving"]?.minX == moving.minX, "full screen must not restart the moving cue")
        stage = "exit full screen"
        window.toggleFullScreen(nil)
        try await wait { !fullScreen }
        _ = await canvas.snapshotImage()
        try check(layers() == initial, "full screen round trip must preserve all lanes")
        let image = try require(await canvas.snapshotImage(), "native canvas image")
        try require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), "PNG")
            .write(to: output.appendingPathComponent("native-resize.png"))

        canvas.configure(input(playing: true))
        let before = try require(layers()["moving"]?.minX, "display-link start")
        let startTime = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(250))
        let after = try require(layers()["moving"]?.minX, "display-link end")
        try check(canvas.isRefreshing && after < before, "real display-link frames must move a warm cue")
        stage = "enter full screen"
        window.toggleFullScreen(nil)
        try await wait { fullScreen }
        stage = "exit full screen"
        window.toggleFullScreen(nil)
        try await wait { !fullScreen }
        _ = await canvas.snapshotImage()
        let afterFullScreen = try require(layers()["moving"]?.minX, "moving full-screen round trip")
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        try check(abs((before - afterFullScreen) - elapsed * 120) < 5,
                  "playing full screen must preserve original media-time trajectory across display gaps")
        canvas.configure(input(position: 1.3, playing: true, buffering: true))
        try check(!canvas.isRefreshing, "buffering must stop frames")
        canvas.configure(input(position: 1.3, playing: true, seeking: true))
        let seekGeneration = canvas.glyphs.generation
        _ = await canvas.snapshotImage()
        try check(!canvas.isRefreshing, "seek must stop frames")
        canvas.configure(input(position: 1.3, font: 40))
        _ = await canvas.snapshotImage()
        try check(canvas.glyphs.generation > seekGeneration, "font change must invalidate preparation")
        try check((layers()["moving"]?.height ?? 0) > moving.height, "new font must replace old raster metrics")

        canvas.configure(input(position: 1.3, playing: true, font: 40))
        for cycle in 0..<3 {
            stage = "hide \(cycle)"
            window.orderOut(nil)
            try await wait { !canvas.isRefreshing }
            stage = "restore \(cycle)"
            window.orderFrontRegardless()
            try await wait { window.occlusionState.contains(.visible) && canvas.isRefreshing }
            stage = "miniaturize \(cycle)"
            window.miniaturize(nil)
            try await wait { window.isMiniaturized && !canvas.isRefreshing }
            stage = "deminiaturize \(cycle)"
            window.deminiaturize(nil)
            try await wait { !window.isMiniaturized && window.occlusionState.contains(.visible) && canvas.isRefreshing }
        }
        let scale = window.backingScaleFactor
        try check(canvas.windowVisibilityChanges >= 6, "direct visibility observation must cover the three ordering cycles")
        window.close()
        try check(!canvas.isRefreshing && canvas.glyphs.count == 0, "close must stop and invalidate")
        return ["backingScale": scale, "continuousResizeCount": 30, "initialLayers": initial.count,
            "minimumLayersWhenCropped": minimumLayers, "fullScreenRoundTrip": true, "preservedX": moving.minX,
            "scrollDelta": after - before, "playingFullScreenMediaSeconds": elapsed,
            "playingFullScreenDelta": before - afterFullScreen, "actualDisplayLinkMotion": true, "pauseBufferSeekStopped": true,
            "fontGeneration": true, "hideRestoreMiniaturizeClose": true, "visibilityCycles": 3,
            "windowVisibilityChanges": canvas.windowVisibilityChanges,
            "scaleScope": "attached display only; 1x/2x are separately verified raster jobs, no physical monitor switch claimed",
            "storage": "synthetic cues only; no AppState, accounts, EPG, history or product app"]
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try check(condition(), "native state deadline exceeded at \(stage): visible=\(diagnosticWindow?.isVisible ?? false) occlusion=\(diagnosticWindow?.occlusionState.rawValue ?? 0) canvas=\(diagnosticCanvas?.frameActivityDescription ?? "none") attached=\(diagnosticCanvas?.window === diagnosticWindow) bounds=\(diagnosticCanvas.map { NSStringFromRect($0.bounds) } ?? "none")")
    }
    private func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeError(message: message) }
    }
    private func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ProbeError(message: message) }; return value
    }
    private func write(_ record: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-validation.json"), options: .atomic)
    }
}

@main private struct NativeResizeProbe {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { fatalError("output directory required") }
        let app = NSApplication.shared
        let delegate = Delegate(output: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
