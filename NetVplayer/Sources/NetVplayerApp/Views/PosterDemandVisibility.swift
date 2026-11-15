import AppKit
import SwiftUI

/// A native clip observer also covers nested horizontal actor rails. It does
/// withdraws only this window's consumers when hidden; shared consumers survive.
struct PosterDemandVisibility: NSViewRepresentable {
    var enabled = true
    let changed: @MainActor (PosterDemand) -> Void
    func makeNSView(context: Context) -> PosterDemandVisibilityView {
        let view = PosterDemandVisibilityView()
        view.changed = changed
        view.observationEnabled = enabled
        return view
    }
    func updateNSView(_ view: PosterDemandVisibilityView, context: Context) {
        view.changed = changed
        view.observationEnabled = enabled
        view.scheduleRefresh()
    }
    static func dismantleNSView(_ view: PosterDemandVisibilityView, coordinator: ()) {
        view.stopObserving()
        view.changed = nil
    }
}

final class PosterDemandVisibilityView: NSView {
    var changed: (@MainActor (PosterDemand) -> Void)?
    var observationEnabled = true {
        didSet {
            guard oldValue != observationEnabled else { return }
            lastDemand = nil
            scheduleRefresh()
        }
    }
    private var observations: [NSObjectProtocol] = []
    private var clips: [NSClipView] = []
    private var scheduled = false
    private var lastDemand: PosterDemand?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeClips() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeClips() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); scheduleRefresh() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); scheduleRefresh() }
    override func layout() { super.layout(); scheduleRefresh() }
    override func viewDidHide() { super.viewDidHide(); scheduleRefresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); scheduleRefresh() }

    private func observeClips() {
        stopObserving()
        var ancestor = superview
        while let view = ancestor {
            if let clip = view as? NSClipView {
                clips.append(clip)
                clip.postsBoundsChangedNotifications = true
                clip.postsFrameChangedNotifications = true
                for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                    observations.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) {
                        [weak self] _ in MainActor.assumeIsolated { self?.scheduleRefresh() }
                    })
                }
            }
            ancestor = view.superview
        }
        if let window {
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated { self?.scheduleRefresh() }
                })
            }
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        scheduleRefresh()
    }

    func stopObserving() {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        clips.removeAll()
    }

    func scheduleRefresh() {
        guard !scheduled else { return }
        scheduled = true
        // Never publish SwiftUI state while AppKit/SwiftUI is laying out views.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            let demand = self.currentDemand()
            guard demand != self.lastDemand else { return }
            self.lastDemand = demand
            self.changed?(demand)
        }
    }

    func currentDemand() -> PosterDemand {
        guard observationEnabled, let window, let content = window.contentView,
              window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible),
              !NSApplication.shared.isHidden, !isHiddenOrHasHiddenAncestor else { return .inactive }
        var viewport = content.convert(content.bounds, to: nil)
        for clip in clips { viewport = viewport.intersection(clip.convert(clip.bounds, to: nil)) }
        return Self.demand(frame: convert(bounds, to: nil), viewport: viewport)
    }

    static func demand(frame: CGRect, viewport: CGRect) -> PosterDemand {
        guard !frame.isEmpty, !viewport.isEmpty, !frame.isNull, !viewport.isNull,
              !frame.isInfinite, !viewport.isInfinite,
              [frame.minX, frame.minY, frame.maxX, frame.maxY, viewport.minX, viewport.minY,
               viewport.maxX, viewport.maxY].allSatisfy(\.isFinite) else { return .inactive }
        let visible = frame.intersection(viewport)
        let tier: PosterDemand.Tier
        if !visible.isNull && !visible.isEmpty { tier = .visible }
        else if frame.intersects(viewport.insetBy(dx: -viewport.width, dy: -viewport.height)) { tier = .nearby }
        else { return .inactive }
        let dx = max(0, max(viewport.minX - frame.maxX, frame.minX - viewport.maxX))
        let dy = max(0, max(viewport.minY - frame.maxY, frame.minY - viewport.maxY))
        func bucket(_ value: CGFloat) -> Int { Int(max(-1_000_000, min(1_000_000, value / 32))) }
        return PosterDemand(tier: tier, distance: bucket(dx + dy),
            row: bucket(viewport.maxY - frame.maxY), column: bucket(frame.minX - viewport.minX))
    }
}
