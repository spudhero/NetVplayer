import AppKit
import DanmakuEngine

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let root: URL
    init(root: URL) { self.root = root }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                var result = try await exercise()
                result["status"] = "passed"
                try write(result, name: "native-validation.json")
            } catch {
                try? write(["status": "failed", "error": String(describing: error)], name: "native-validation.json")
            }
            NSApp.terminate(nil)
        }
    }

    private func exercise() async throws -> [String: Any] {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 960, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "OV87-06 · native DanmakuCanvas · synthetic text"
        window.level = .floating
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 440))
        window.contentView = content
        var canvases: [DanmakuCanvasView] = []
        let cues = [DanmakuCue(id: "white", timeMs: 0, text: "中文小字：清晰的笔画 · Agj 2026", mode: .top),
                    DanmakuCue(id: "red", timeMs: 0, text: "彩色弹幕：晚霞与海 · Agj", mode: .top, color: "CC5533"),
                    DanmakuCue(id: "yellow", timeMs: 0, text: "彩色弹幕：晴空万里 · Agj", mode: .bottom, color: "FFDD22"),
                    DanmakuCue(id: "moving", timeMs: 0, text: "滚动文字 · 视口边缘裁切", mode: .scroll, color: "26B3FF")]
        func configuration(playing: Bool = false, buffering: Bool = false, seeking: Bool = false) -> DanmakuCanvas {
            DanmakuCanvas(cues: cues, epoch: "native", position: 1, rate: 1, playing: playing,
                buffering: buffering, seeking: seeking, offsetMs: 0, opacity: 1, fontSize: 18)
        }
        for column in 0..<2 {
            let background = NSView(frame: NSRect(x: column*480, y: 0, width: 480, height: 440))
            background.wantsLayer = true
            background.layer?.backgroundColor = CGColor(gray: column == 0 ? 0.07 : 0.95, alpha: 1)
            content.addSubview(background)
            let label = NSTextField(labelWithString: "18pt · original fill + soft shadow")
            label.textColor = column == 0 ? .white : .black
            label.frame = NSRect(x: 16, y: 400, width: 448, height: 24)
            background.addSubview(label)
            let canvas = DanmakuCanvasView()
            canvas.frame = NSRect(x: 0, y: 16, width: 480, height: 370)
            background.addSubview(canvas)
            canvases.append(canvas)
        }
        defer { canvases.forEach { $0.stop() }; window.close() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait { window.isVisible && window.occlusionState.contains(.visible) }
        for canvas in canvases {
            canvas.configure(configuration())
            _ = try require(await canvas.snapshotImage(), "prepared snapshot")
        }
        content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
        let bitmap = try require(content.bitmapImageRepForCachingDisplay(in: content.bounds), "native bitmap")
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try require(bitmap.representation(using: .png, properties: [:]), "native PNG")
            .write(to: root.appendingPathComponent("native-window.png"))
        let canvas = canvases[0]
        canvas.configure(configuration(playing: true))
        try check(canvas.isRefreshing, "visible playing canvas must refresh")
        let before = try require(canvas.layer?.sublayers?.last?.frame.minX, "scroll layer")
        try await Task.sleep(for: .milliseconds(250))
        let after = try require(canvas.layer?.sublayers?.last?.frame.minX, "scroll layer after frames")
        try check(after < before, "real display-link frames must move the cue")
        canvas.configure(configuration())
        try check(!canvas.isRefreshing, "pause must stop")
        canvas.configure(configuration(playing: true, buffering: true))
        try check(!canvas.isRefreshing, "buffering must stop")
        canvas.configure(configuration(playing: true, seeking: true))
        try check(!canvas.isRefreshing, "seeking must stop")
        canvas.configure(configuration(playing: true))
        window.orderOut(nil)
        try await wait { !canvas.isRefreshing }
        window.orderFrontRegardless()
        try await wait { window.occlusionState.contains(.visible) }
        canvas.configure(configuration(playing: true))
        try check(canvas.isRefreshing, "reopen must resume")
        window.miniaturize(nil)
        try await wait { window.isMiniaturized && !canvas.isRefreshing }
        window.deminiaturize(nil)
        try await wait { !window.isMiniaturized && window.occlusionState.contains(.visible) }
        canvas.configure(configuration(playing: true))
        try check(canvas.isRefreshing, "deminiaturize must resume")
        let backingScale = window.backingScaleFactor
        window.close()
        try check(!canvas.isRefreshing, "close must stop")
        return ["backingScale": backingScale, "visibleWindow": true, "actualDisplayLinkMotion": true,
            "scrollDelta": after-before, "pauseBufferSeekStopped": true, "orderOutStopped": true,
            "miniaturizeStopped": true, "deminiaturizeResumed": true, "closeStopped": true,
            "storage": "no AppState, UserDefaults, provider, EPG, media or user data instantiated",
            "scaleScope": "1x and 2x raster matrix; native window uses the attached display only"]
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try check(predicate(), "native state deadline exceeded")
    }

    private func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeFailure(description: message) }
    }

    private func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ProbeFailure(description: message) }
        return value
    }

    private func write(_ value: [String: Any], name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(name), options: .atomic)
    }
}

@main
private struct NativeProbe {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { return }
        let app = NSApplication.shared
        let delegate = ProbeDelegate(root: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
