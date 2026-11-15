import AppKit

private struct ProbeError: Error { let message: String }
private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }

/// Wheel phases are supplied directly to the production input seam, without global input.
private final class WheelEvent: NSEvent {
    let target: NSWindow
    let targetNumber: Int
    let point: NSPoint
    let delta: CGFloat
    let inputPhase: NSEvent.Phase
    @MainActor init(window: NSWindow, point: NSPoint, delta: CGFloat, phase: NSEvent.Phase) {
        target = window; self.point = point; self.delta = delta; inputPhase = phase
        targetNumber = window.windowNumber
        super.init()
    }
    required init?(coder: NSCoder) { nil }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { targetNumber }
    override var locationInWindow: NSPoint { point }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
    override var scrollingDeltaY: CGFloat { delta }
    override var scrollingDeltaX: CGFloat { 0 }
    override var deltaY: CGFloat { delta }
    override var deltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { inputPhase }
    override var momentumPhase: NSEvent.Phase { [] }
}

@MainActor
private final class Delegate: NSObject, NSApplicationDelegate {
    let output: URL
    var stage = "launch"
    var events: [[String: Any]] = []
    init(output: URL) { self.output = output }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 65) { [self] in
            try? write(["status": "failed", "stage": stage, "error": "watchdog expired", "events": events])
            NSApp.terminate(nil)
        }
        Task { @MainActor in
            do {
                var record = try await exercise()
                record["status"] = "passed"
                try write(record)
            } catch {
                try? write(["status": "failed", "stage": stage, "error": String(describing: error), "events": events])
            }
            NSApp.terminate(nil)
        }
    }

    private func exercise() async throws -> [String: Any] {
        let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 640, height: 400),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "OV91-05 · isolated search scroll demand"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let scroll = NSScrollView(frame: NSRect(x: 120, y: 0, width: 504, height: 400))
        scroll.setAccessibilityLabel("Search result list")
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 500, height: 1600))
        let probe = SearchScrollDemandView(frame: .zero)
        var demands = 0
        let scope = SearchScrollScope(generation: 1, siteKey: nil)
        probe.configure(scope: scope) { demands += 1 }
        document.addSubview(probe)
        scroll.documentView = document
        container.addSubview(scroll)
        window.contentView = container
        defer { probe.stop(); window.close() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await pause()

        func move(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func wheel(_ delta: CGFloat, phase: NSEvent.Phase = [], sidebar: Bool = false) throws {
            let event = WheelEvent(window: window, point: NSPoint(x: sidebar ? 40 : 360, y: 200), delta: delta, phase: phase)
            events.append(["window": event.windowNumber, "phase": event.phase.rawValue, "delta": event.scrollingDeltaY])
            probe.observe(event)
        }

        stage = "layout must not request"
        for _ in 0..<10 {
            document.setFrameSize(NSSize(width: 500, height: 1700))
            move(1250)
            document.setFrameSize(NSSize(width: 500, height: 1600))
            move(1200)
            window.setContentSize(NSSize(width: 640, height: 410))
        }
        try await pause()
        try check(demands == 0, "layout/resize/programmatic scroll must stay idle")

        stage = "upward and sidebar wheel"
        try wheel(40)
        try wheel(-40, sidebar: true)
        try await pause()
        try check(demands == 0, "upward and sidebar input must not request")

        stage = "one downward gesture"
        move(1200)
        try wheel(-30, phase: .began)
        try await pause()
        try check(demands == 1, "downward gesture at bottom must request")
        for _ in 0..<10 { try wheel(-30, phase: .changed) }
        // A result publication can change the document height during the same gesture.
        document.setFrameSize(NSSize(width: 500, height: 2000))
        move(1600)
        try wheel(-30, phase: .changed)
        try await pause()
        try check(demands == 1, "one gesture must not chain when results reflow")

        stage = "new gesture and filter invalidation"
        try wheel(-30, phase: .ended)
        try wheel(-30, phase: .began)
        try await pause()
        try check(demands == 2, "a fresh gesture must request the next batch")
        try wheel(-30)
        probe.configure(scope: SearchScrollScope(generation: 1, siteKey: "other")) { demands += 1 }
        try await pause()
        try check(demands == 2, "queued old filter input must be rejected")
        try wheel(-30)
        try await pause()
        try check(demands == 3, "fresh wheel after filter switch must work")
        try wheel(-30)
        probe.configure(scope: SearchScrollScope(generation: 2, siteKey: "other")) { demands += 1 }
        try await pause()
        try check(demands == 3, "queued old query input must be rejected")

        stage = "short list and teardown"
        document.setFrameSize(NSSize(width: 500, height: 100))
        move(0)
        try wheel(-30)
        try await pause()
        try check(demands == 4, "downward intent must expand even when the first batch fits")

        stage = "native input monitor"
        document.setFrameSize(NSSize(width: 500, height: 2000))
        move(1400)
        var deviceEvents: [[String: Any]] = []
        let diagnostic = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { event in
            MainActor.assumeIsolated {
                deviceEvents.append(["type": event.type.rawValue, "window": event.windowNumber,
                                     "deltaY": event.type == .scrollWheel ? event.scrollingDeltaY : 0])
            }
            return event
        }
        defer { if let diagnostic { NSEvent.removeMonitor(diagnostic) } }
        if CommandLine.arguments.contains("--device-input") {
            window.title = "OV91-05 · Scroll down in right pane"
            let label = NSTextField(labelWithString: "Scroll down in the right pane · isolated fixture")
            label.frame = NSRect(x: 160, y: 220, width: 470, height: 30)
            container.addSubview(label)
            try write(["status": "awaiting_device_input", "window": window.windowNumber])
            let deadline = ContinuousClock.now.advanced(by: .seconds(45))
            while demands < 5 && .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try check(demands == 5 && !deviceEvents.isEmpty, "native device input must pass the installed production event monitor: \(demands), \(deviceEvents)")
        }
        let expectedDemands = CommandLine.arguments.contains("--device-input") ? 5 : 4
        probe.stop()
        try wheel(-30)
        try await pause()
        try check(demands == expectedDemands, "detached observer must not request")
        return ["demands": demands, "events": events, "layoutCycles": 10,
                "oneBatchPerGesture": true, "filterAndGenerationReject": true,
                "shortList": true, "sidebarAndUpwardIgnore": true, "teardown": true,
                "nativeInputEvents": deviceEvents, "nativeDeviceInput": CommandLine.arguments.contains("--device-input"),
                "wheelDelivery": "synthetic NSEvent into production observe seam; separate native monitor check",
                "storage": "isolated AppKit host; no AppState, accounts, history or product app"]
    }

    private func pause() async throws { try await Task.sleep(for: .milliseconds(80)) }
    private func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeError(message: message) }
    }
    private func write(_ record: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-validation.json"))
    }
}

@main
private struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(output: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
