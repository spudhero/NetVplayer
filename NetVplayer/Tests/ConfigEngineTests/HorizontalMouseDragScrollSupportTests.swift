import AppKit
import CoreGraphics
import Testing
@testable import NetVplayerApp

@Suite("Horizontal mouse drag scrolling")
struct HorizontalMouseDragScrollSupportTests {
    @Test
    func testDraggingLeftAdvancesFromTheCurrentOffset() {
        #expect(HorizontalMouseDragScrollPolicy.targetOffset(
            startOffset: 120,
            translation: -45,
            contentWidth: 640,
            viewportWidth: 240
        ) == 165)
    }

    @Test
    func testDraggingRightRevealsEarlierContent() {
        #expect(HorizontalMouseDragScrollPolicy.targetOffset(
            startOffset: 180,
            translation: 55,
            contentWidth: 640,
            viewportWidth: 240
        ) == 125)
    }

    @Test
    func testDragClampsAtBothEdges() {
        #expect(HorizontalMouseDragScrollPolicy.targetOffset(
            startOffset: 20,
            translation: 80,
            contentWidth: 640,
            viewportWidth: 240
        ) == 0)
        #expect(HorizontalMouseDragScrollPolicy.targetOffset(
            startOffset: 380,
            translation: -80,
            contentWidth: 640,
            viewportWidth: 240
        ) == 400)
    }

    @Test
    func testContentThatFitsTheViewportDoesNotMove() {
        #expect(HorizontalMouseDragScrollPolicy.targetOffset(
            startOffset: 35,
            translation: -100,
            contentWidth: 220,
            viewportWidth: 240
        ) == 0)
    }

    @Test
    func testSubthresholdPointerMovementRemainsClickEligible() {
        #expect(HorizontalMouseDragActivationPolicy.decision(
            translation: .zero
        ) == .pending)
        #expect(HorizontalMouseDragActivationPolicy.decision(
            translation: CGPoint(x: 3, y: 1)
        ) == .pending)
        #expect(HorizontalMouseDragActivationPolicy.decision(
            translation: CGPoint(x: 7, y: 2)
        ) == .pending)
    }

    @Test
    func testHorizontalMovementBeginsDraggingAtEightPoints() {
        #expect(HorizontalMouseDragActivationPolicy.decision(
            translation: CGPoint(x: 8, y: 0)
        ) == .beginDrag)
        #expect(HorizontalMouseDragActivationPolicy.decision(
            translation: CGPoint(x: -8, y: 2)
        ) == .beginDrag)
    }

    @Test
    func testVerticalIntentDoesNotBecomeHorizontalDragging() {
        #expect(HorizontalMouseDragActivationPolicy.decision(
            translation: CGPoint(x: 2, y: 8)
        ) == .rejectDrag)
        #expect(HorizontalMouseDragActivationPolicy.decision(
            translation: CGPoint(x: 8, y: 8)
        ) == .rejectDrag)
    }

    @Test @MainActor
    func testControllerAttachesOnePrimaryMousePanToTheDocumentViewAndRemovesIt() throws {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 240, height: 40))
        let documentView = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 40))
        scrollView.documentView = documentView
        let controller = HorizontalMouseDragScrollController()
        let originalClipRecognizers = Set(
            scrollView.contentView.gestureRecognizers.map(ObjectIdentifier.init)
        )
        let originalDocumentRecognizers = Set(
            documentView.gestureRecognizers.map(ObjectIdentifier.init)
        )

        controller.attach(to: scrollView)
        controller.attach(to: scrollView)

        let addedDocumentRecognizers = documentView.gestureRecognizers.filter {
            !originalDocumentRecognizers.contains(ObjectIdentifier($0))
        }
        let panRecognizer = try #require(
            addedDocumentRecognizers.first as? HorizontalMousePanGestureRecognizer
        )
        #expect(addedDocumentRecognizers.count == 1)
        #expect(scrollView.contentView.gestureRecognizers.allSatisfy {
            originalClipRecognizers.contains(ObjectIdentifier($0))
        })
        #expect(panRecognizer.delaysPrimaryMouseButtonEvents)

        controller.detach()
        #expect(!documentView.gestureRecognizers.contains { $0 === panRecognizer })
    }

    @Test @MainActor
    func testPanGestureCannotBePreemptedByAButtonPressGesture() throws {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 240, height: 40))
        let documentView = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 40))
        scrollView.documentView = documentView
        let controller = HorizontalMouseDragScrollController()

        controller.attach(to: scrollView)

        let panRecognizer = try #require(
            documentView.gestureRecognizers.first as? HorizontalMousePanGestureRecognizer
        )
        let buttonPressRecognizer = NSPressGestureRecognizer()
        #expect(!panRecognizer.canBePrevented(by: buttonPressRecognizer))
        #expect(panRecognizer.canPrevent(buttonPressRecognizer))
    }

    @Test @MainActor
    func testSelectionGateSuppressesOnlyTheClickProducedByDragRelease() {
        let gate = HorizontalMouseDragSelectionGate()

        #expect(!gate.shouldSuppressSelection())
        gate.dragDidBegin()
        gate.dragDidEnd()

        #expect(gate.shouldSuppressSelection())
        #expect(!gate.shouldSuppressSelection())
    }

    @Test @MainActor
    func testBlankAreaDragDoesNotSuppressTheNextIntentionalClick() async {
        let gate = HorizontalMouseDragSelectionGate()

        gate.dragDidBegin()
        gate.dragDidEnd()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(!gate.shouldSuppressSelection())
    }
}
