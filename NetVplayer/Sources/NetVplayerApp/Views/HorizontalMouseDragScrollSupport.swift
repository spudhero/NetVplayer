import AppKit
import SwiftUI

enum HorizontalMouseDragScrollPolicy {
    static func targetOffset(
        startOffset: CGFloat,
        translation: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        let maximumOffset = max(contentWidth - viewportWidth, 0)
        return min(max(startOffset - translation, 0), maximumOffset)
    }
}

enum HorizontalMouseDragActivationDecision: Equatable {
    case pending
    case beginDrag
    case rejectDrag
}

enum HorizontalMouseDragActivationPolicy {
    static let minimumDistance: CGFloat = 8

    static func decision(
        translation: CGPoint,
        minimumDistance: CGFloat = minimumDistance
    ) -> HorizontalMouseDragActivationDecision {
        let horizontalDistance = abs(translation.x)
        let verticalDistance = abs(translation.y)

        if horizontalDistance >= minimumDistance,
           horizontalDistance > verticalDistance {
            return .beginDrag
        }
        if verticalDistance >= minimumDistance,
           verticalDistance >= horizontalDistance {
            return .rejectDrag
        }
        return .pending
    }
}

final class HorizontalMousePanGestureRecognizer: NSGestureRecognizer {
    private var initialLocationInWindow: NSPoint?
    private var latestLocationInWindow: NSPoint?

    override func canBePrevented(by preventingGestureRecognizer: NSGestureRecognizer) -> Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        initialLocationInWindow = event.locationInWindow
        latestLocationInWindow = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        latestLocationInWindow = event.locationInWindow

        switch state {
        case .possible:
            switch HorizontalMouseDragActivationPolicy.decision(
                translation: translation(in: view)
            ) {
            case .pending:
                break
            case .beginDrag:
                state = .began
            case .rejectDrag:
                state = .failed
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        latestLocationInWindow = event.locationInWindow

        switch state {
        case .began, .changed:
            state = .ended
        case .possible:
            state = .failed
        default:
            break
        }
    }

    override func reset() {
        super.reset()
        initialLocationInWindow = nil
        latestLocationInWindow = nil
    }

    func translation(in view: NSView?) -> NSPoint {
        guard let initialLocationInWindow,
              let latestLocationInWindow else { return .zero }
        guard let view else {
            return NSPoint(
                x: latestLocationInWindow.x - initialLocationInWindow.x,
                y: latestLocationInWindow.y - initialLocationInWindow.y
            )
        }

        let initialLocation = view.convert(initialLocationInWindow, from: nil)
        let latestLocation = view.convert(latestLocationInWindow, from: nil)
        return NSPoint(
            x: latestLocation.x - initialLocation.x,
            y: latestLocation.y - initialLocation.y
        )
    }
}

@MainActor
final class HorizontalMouseDragSelectionGate {
    private var isDragging = false
    private var suppressNextSelection = false
    private var dragGeneration = 0

    func dragDidBegin() {
        dragGeneration += 1
        isDragging = true
        suppressNextSelection = true
    }

    func dragDidEnd() {
        isDragging = false
        let completedGeneration = dragGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.dragGeneration == completedGeneration,
                  !self.isDragging else { return }
            self.suppressNextSelection = false
        }
    }

    func shouldSuppressSelection() -> Bool {
        guard isDragging || suppressNextSelection else { return false }
        suppressNextSelection = false
        return true
    }
}

struct HorizontalMouseDragScrollProbe: NSViewRepresentable {
    let selectionGate: HorizontalMouseDragSelectionGate

    func makeNSView(context: Context) -> HorizontalMouseDragScrollProbeView {
        let view = HorizontalMouseDragScrollProbeView(selectionGate: selectionGate)
        view.enableAttachment()
        return view
    }

    func updateNSView(_ nsView: HorizontalMouseDragScrollProbeView, context: Context) {
        nsView.enableAttachment()
    }

    static func dismantleNSView(_ nsView: HorizontalMouseDragScrollProbeView, coordinator: ()) {
        nsView.disableAttachment()
    }
}

final class HorizontalMouseDragScrollProbeView: NSView {
    private let dragController: HorizontalMouseDragScrollController
    private var isAttachmentEnabled = false
    private var isAttachmentScheduled = false

    init(selectionGate: HorizontalMouseDragSelectionGate) {
        dragController = HorizontalMouseDragScrollController(selectionGate: selectionGate)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            dragController.detach()
        } else {
            scheduleAttachment()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            dragController.detach()
        } else {
            scheduleAttachment()
        }
    }

    override func layout() {
        super.layout()
        scheduleAttachment()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func enableAttachment() {
        isAttachmentEnabled = true
        scheduleAttachment()
    }

    func disableAttachment() {
        isAttachmentEnabled = false
        dragController.detach()
    }

    private func scheduleAttachment() {
        guard isAttachmentEnabled, !isAttachmentScheduled else { return }
        isAttachmentScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isAttachmentScheduled = false
            guard self.isAttachmentEnabled else { return }

            guard let scrollView = self.nearestScrollView() else {
                self.dragController.detach()
                return
            }
            self.dragController.attach(to: scrollView)
        }
    }

    private func nearestScrollView() -> NSScrollView? {
        if let enclosingScrollView {
            return enclosingScrollView
        }

        guard let contentView = window?.contentView else { return nil }
        let probePoint = convert(
            NSPoint(x: bounds.midX, y: bounds.midY),
            to: nil
        )
        return descendantScrollViews(in: contentView)
            .filter { scrollView in
                scrollView.convert(scrollView.bounds, to: nil)
                    .insetBy(dx: -2, dy: -2)
                    .contains(probePoint)
            }
            .min { lhs, rhs in
                lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
            }
    }

    private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            result.append(scrollView)
        }
        for subview in view.subviews {
            result.append(contentsOf: descendantScrollViews(in: subview))
        }
        return result
    }
}

@MainActor
final class HorizontalMouseDragScrollController: NSObject {
    private let selectionGate: HorizontalMouseDragSelectionGate
    private weak var scrollView: NSScrollView?
    private weak var clipView: NSClipView?
    private weak var gestureHostView: NSView?
    private var panGestureRecognizer: HorizontalMousePanGestureRecognizer?
    private var dragStartOffset: CGFloat?

    init(selectionGate: HorizontalMouseDragSelectionGate = HorizontalMouseDragSelectionGate()) {
        self.selectionGate = selectionGate
    }

    func attach(to scrollView: NSScrollView) {
        let clipView = scrollView.contentView
        guard let gestureHostView = scrollView.documentView else {
            detach()
            return
        }
        guard self.clipView !== clipView
                || self.gestureHostView !== gestureHostView
                || panGestureRecognizer?.view !== gestureHostView else {
            return
        }

        detach()

        let recognizer = HorizontalMousePanGestureRecognizer(
            target: self,
            action: #selector(handlePan(_:))
        )
        recognizer.delaysPrimaryMouseButtonEvents = true
        gestureHostView.addGestureRecognizer(recognizer)

        self.scrollView = scrollView
        self.clipView = clipView
        self.gestureHostView = gestureHostView
        panGestureRecognizer = recognizer
    }

    func detach() {
        if dragStartOffset != nil {
            selectionGate.dragDidEnd()
        }
        if let panGestureRecognizer, let gestureHostView {
            gestureHostView.removeGestureRecognizer(panGestureRecognizer)
        }
        dragStartOffset = nil
        panGestureRecognizer = nil
        gestureHostView = nil
        clipView = nil
        scrollView = nil
    }

    @objc private func handlePan(_ recognizer: HorizontalMousePanGestureRecognizer) {
        guard let scrollView, let clipView else { return }

        switch recognizer.state {
        case .began:
            dragStartOffset = clipView.bounds.origin.x
            selectionGate.dragDidBegin()
            updateScrollPosition(using: recognizer, scrollView: scrollView, clipView: clipView)
        case .changed:
            updateScrollPosition(using: recognizer, scrollView: scrollView, clipView: clipView)
        case .ended, .cancelled, .failed:
            if dragStartOffset != nil {
                selectionGate.dragDidEnd()
            }
            dragStartOffset = nil
        default:
            break
        }
    }

    private func updateScrollPosition(
        using recognizer: HorizontalMousePanGestureRecognizer,
        scrollView: NSScrollView,
        clipView: NSClipView
    ) {
        let startOffset = dragStartOffset ?? clipView.bounds.origin.x
        dragStartOffset = startOffset
        let contentWidth = scrollView.documentView?.frame.width ?? 0
        let targetOffset = HorizontalMouseDragScrollPolicy.targetOffset(
            startOffset: startOffset,
            translation: recognizer.translation(in: clipView).x,
            contentWidth: contentWidth,
            viewportWidth: clipView.bounds.width
        )
        var origin = clipView.bounds.origin
        origin.x = targetOffset
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}
