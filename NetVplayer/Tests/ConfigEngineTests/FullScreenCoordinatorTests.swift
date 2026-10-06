import AppKit
import Testing
@testable import NetVplayerApp

@Suite("Fullscreen bridge")
@MainActor
struct FullScreenCoordinatorTests {
    @Test func lostNativeCallbackReconcilesWithoutReplacingDelegate() {
        let window = makeWindow()
        let delegate = Delegate()
        window.delegate = delegate
        let fixture = Fixture()
        let bridge = PlayerFullScreenCoordinator(window: window, toggleNative: { _ in fixture.toggles += 1 }, actualState: { _ in fixture.actual }, uptime: { fixture.time })
        defer { bridge.stop() }
        bridge.onStateChange = { fixture.reported.append($0) }
        bridge.toggle(); bridge.toggle()
        #expect(fixture.toggles == 1)
        fixture.actual = true; fixture.time = 6
        bridge.reconcile()
        #expect(fixture.reported == [true])
        #expect(fixture.toggles == 2)
        // A duplicate enter completion must not finish the newer exit transition.
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(bridge.state.transition?.target == false)
        fixture.actual = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        #expect(bridge.state.transition == nil)
        #expect(window.delegate === delegate)
    }

    @Test func failedNativeRequestCanRetryAndClosingPreventsReactivation() {
        let window = makeWindow()
        let fixture = Fixture()
        let bridge = PlayerFullScreenCoordinator(window: window, toggleNative: { _ in fixture.toggles += 1 }, actualState: { _ in false }, uptime: { fixture.time })
        bridge.request(true)
        fixture.time = 6; bridge.reconcile()
        #expect(bridge.state.transition == nil)
        bridge.request(true)
        #expect(fixture.toggles == 2)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        bridge.toggle(); bridge.reconcile()
        #expect(bridge.state.isClosed)
        #expect(fixture.toggles == 2)
    }

    @Test func associatedBridgeDoesNotRetainWindowAndRebindReleasesPrevious() {
        let context = PlayerWindowContext()
        weak var weakFirst: NSWindow?
        let second = makeWindow()
        let oldBridge = autoreleasepool {
            let first = makeWindow()
            weakFirst = first
            let bridge = PlayerFullScreenCoordinator.attached(to: first)
            context.attach(first)
            context.attach(second)
            return bridge
        }
        #expect(oldBridge.state.isClosed)
        #expect(weakFirst == nil)
        context.detach(second)
    }

    @MainActor private final class Fixture {
        var time = 0.0
        var actual = false
        var toggles = 0
        var reported: [Bool] = []
    }
    private final class Delegate: NSObject, NSWindowDelegate {}
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
