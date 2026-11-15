import AppKit
import SwiftUI

@main struct WindowProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { exit(2) }
        Task { @MainActor in
            do {
                try await run()
                try await clips()
                print("OV91_WINDOW_PROBE_PASS")
                exit(0)
            } catch { print("OV91_WINDOW_PROBE_FAIL \(error)"); exit(1) }
        }
        app.run()
    }
    @MainActor static func wait(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { print("PASS \(label)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: label, code: 1)
    }
    @MainActor static func run() async throws {
        let window = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 320, height: 240), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = PlaybackInformationVisibilityView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        var visible = false
        observer.changed = { visible = $0; print("visibility \($0)") }
        window.contentView?.addSubview(observer)
        window.orderFrontRegardless()
        try await wait("show") { visible }
        window.orderOut(nil)
        try await wait("hide") { !visible }
        window.orderFrontRegardless()
        try await wait("reshow") { visible }
        let cover = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.level = .floating
        cover.backgroundColor = .black
        cover.orderFrontRegardless()
        try await wait("occluded") { !visible }
        cover.orderOut(nil)
        try await wait("unoccluded") { visible }
        cover.close()
        window.miniaturize(nil)
        try await wait("minimize") { window.isMiniaturized && !visible }
        window.deminiaturize(nil)
        try await wait("restore") { visible }
        window.close()
        try await wait("close") { !visible }
        observer.stopObserving()
    }
    @MainActor static func clips() async throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 3_000))
        let probe = PosterDemandVisibilityView(frame: NSRect(x: 20, y: 2_600, width: 100, height: 100))
        var demand: PosterDemand?
        probe.changed = { demand = $0 }
        document.addSubview(probe)
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        window.orderFrontRegardless()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 2_500))
        try await wait("poster-visible") { demand?.tier == .visible }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 2_100))
        try await wait("poster-nearby") { demand?.tier == .nearby }
        scroll.contentView.scroll(to: .zero)
        try await wait("poster-far") { demand?.tier == .inactive }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 2_500))
        try await wait("poster-return") { demand?.tier == .visible }
        probe.observationEnabled = false
        try await wait("poster-disable") { demand?.tier == .inactive }
        probe.observationEnabled = true
        try await wait("poster-enable") { demand?.tier == .visible }
        window.orderOut(nil)
        try await wait("poster-window-hidden") { demand?.tier == .inactive }
        guard probe.window === window else { throw NSError(domain: "view detached", code: 1) }
        window.orderFrontRegardless()
        try await wait("poster-window-restored") { demand?.tier == .visible }
        probe.stopObserving()
    }

}
