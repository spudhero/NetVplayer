import SwiftUI
import AppKit

/// Registers the native scene window without replacing SwiftUI's window identifier.
struct StartupWindowRegistration: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow
    var windows: NetVplayerWindowCoordinator = .shared

    final class Probe: NSView {
        var onWindowAvailable: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindowAvailable?(window) }
        }
    }
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.onWindowAvailable = { window in
            windows.registerMainWindow(window) { openWindow(id: AppWindowID.main) }
        }
        if let window = nsView.window { nsView.onWindowAvailable?(window) }
    }
}
