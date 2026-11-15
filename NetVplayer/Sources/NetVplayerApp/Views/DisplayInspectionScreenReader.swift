import AppKit
import SwiftUI
import Models

/// A narrow window lookup: never uses NSScreen.main for a different window,
/// never changes its color space, and owns no timer or persistent preference.
struct DisplayInspectionScreenReader: NSViewRepresentable {
    @Binding var description: String

    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.changed = { description = $0 }
        return view
    }

    func updateNSView(_ view: ScreenView, context: Context) {
        view.changed = { description = $0 }
    }

    static func dismantleNSView(_ view: ScreenView, coordinator: ()) {
        view.changed = nil
        NotificationCenter.default.removeObserver(view)
    }

    final class ScreenView: NSView {
        var changed: ((String) -> Void)?
        private var generation = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeScreenProfileNotification,
                             NSWindow.didChangeBackingPropertiesNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: window)
                }
                NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                    name: NSApplication.didChangeScreenParametersNotification, object: nil)
            }
            refresh()
        }

        @objc private func refresh() {
            generation += 1
            let expected = generation
            let text: String
            if let screen = window?.screen {
                let profile = screen.colorSpace?.localizedName ?? L10n.text("色彩配置未知")
                text = screen.localizedName + " · " + profile
            } else {
                text = L10n.text("显示器信息不可用")
            }
            // Window attachment can occur during a SwiftUI update.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected else { return }
                self.changed?(text)
            }
        }
    }
}
