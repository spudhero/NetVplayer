import AppKit
import SwiftUI

struct SearchScrollScope: Equatable {
    let generation: UInt64
    let siteKey: String?
}

/// Geometry alone cannot express intent: SwiftUI also moves the clip view during reflow.
struct SearchScrollDemandProbe: NSViewRepresentable {
    let scope: SearchScrollScope
    let onDemand: () -> Void

    func makeNSView(context: Context) -> SearchScrollDemandView { SearchScrollDemandView() }

    func updateNSView(_ view: SearchScrollDemandView, context: Context) {
        view.configure(scope: scope, onDemand: onDemand)
    }

    static func dismantleNSView(_ view: SearchScrollDemandView, coordinator: ()) { view.stop() }
}

final class SearchScrollDemandView: NSView {
    private var scope: SearchScrollScope?
    private var onDemand: (() -> Void)?
    private var revision: UInt64 = 0
    private var interaction: UInt64 = 0
    private var claimed = false
    private var draggingScrollbar = false
    private let monitor = SearchScrollEventMonitor()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(scope: SearchScrollScope, onDemand: @escaping () -> Void) {
        if self.scope != scope {
            self.scope = scope
            revision &+= 1
            // A pending event from the previous query/filter must never spend the new budget.
            interaction &+= 1
            claimed = true
            draggingScrollbar = false
        }
        self.onDemand = onDemand
        start()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    private func start() {
        guard window != nil, monitor.token == nil else { return }
        monitor.token = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
    }

    func stop() {
        monitor.remove()
        revision &+= 1
        draggingScrollbar = false
    }

    private var scrollView: NSScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }

    /// Observe input before AppKit dispatch, then measure once after it has scrolled.
    /// Frame/bounds notifications and onAppear never call this path.
    func observe(_ event: NSEvent) {
        guard monitor.token != nil, let window, window.isVisible, !window.isMiniaturized, event.window === window,
              let scroll = scrollView, let document = scroll.documentView else { return }
        let point = scroll.convert(event.locationInWindow, from: nil)
        // Include ThemedScrollView's adjacent custom scrollbar, exclude the source sidebar.
        let inside = NSRect(x: 0, y: 0, width: scroll.bounds.width + 16, height: scroll.bounds.height).contains(point)
        let before = scroll.contentView.bounds.minY
        var wheelDown = false

        func beginInteraction() {
            interaction &+= 1
            claimed = false
        }

        switch event.type {
        case .scrollWheel:
            guard inside else { return }
            if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty) { beginInteraction() }
            wheelDown = event.scrollingDeltaY < 0 && abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            guard wheelDown else { return }
        case .leftMouseDown:
            draggingScrollbar = inside && point.x >= scroll.bounds.width - 1
            if draggingScrollbar { beginInteraction() }
            return
        case .leftMouseUp:
            draggingScrollbar = false
            return
        case .leftMouseDragged:
            guard draggingScrollbar else { return }
        case .keyDown:
            guard let responder = window.firstResponder as? NSView, responder.isDescendant(of: scroll),
                  [UInt16(125), 121, 119, 49].contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return }
            beginInteraction()
        default: return
        }
        guard !claimed else { return }
        let expectedRevision = revision, expectedInteraction = interaction
        DispatchQueue.main.async { [weak self, weak scroll, weak document] in
            guard let self, let scroll, let document, self.window?.isVisible == true,
                  self.revision == expectedRevision, self.interaction == expectedInteraction, !self.claimed else { return }
            let clip = scroll.contentView.bounds
            let offset = max(0, clip.minY)
            let remaining = max(0, document.bounds.height - clip.height - offset)
            guard offset.isFinite, remaining.isFinite, clip.height > 0,
                  wheelDown || offset > before + 0.5,
                  remaining <= max(240, clip.height * 0.5) else { return }
            self.claimed = true
            self.onDemand?()
        }
    }
}

private final class SearchScrollEventMonitor {
    var token: Any?
    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
    deinit { remove() }
}
