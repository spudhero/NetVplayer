import AppKit
import SwiftUI

/// Native visibility owns presentation sampling; ordering out/minimizing is not
/// guaranteed to destroy a SwiftUI subtree.
struct PlaybackInformationVisibility: NSViewRepresentable {
    var enabled = true
    let changed: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> PlaybackInformationVisibilityView {
        let view = PlaybackInformationVisibilityView()
        view.changed = changed
        view.samplingEnabled = enabled
        return view
    }
    func updateNSView(_ view: PlaybackInformationVisibilityView, context: Context) {
        view.changed = changed
        view.samplingEnabled = enabled
        view.refreshVisibility()
    }
    static func dismantleNSView(_ view: PlaybackInformationVisibilityView, coordinator: ()) {
        view.stopObserving()
    }
}

final class PlaybackInformationVisibilityView: NSView {
    var changed: (@MainActor (Bool) -> Void)?
    var samplingEnabled = true
    private var notifications: [NSObjectProtocol] = []
    private var lastVisible = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        if let window {
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                notifications.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] notification in
                    let closing = notification.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        if closing { self?.publish(false) } else { self?.refreshVisibility() }
                    }
                })
            }
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibility() }
            })
        }
        refreshVisibility()
    }
    override func viewDidHide() { super.viewDidHide(); refreshVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshVisibility() }

    func refreshVisibility() {
        publish(window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } == true
            && !NSApplication.shared.isHidden && !isHiddenOrHasHiddenAncestor && samplingEnabled)
    }
    func stopObserving() {
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        publish(false)
    }
    private func publish(_ visible: Bool) {
        guard visible != lastVisible else { return }
        lastVisible = visible
        changed?(visible)
    }
}
