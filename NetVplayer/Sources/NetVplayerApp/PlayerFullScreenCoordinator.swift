import AppKit
import ObjectiveC
import ApplicationCore
import os

/// The window owns this bridge; the bridge holds the window weakly and leaves its delegate intact.
@MainActor
final class PlayerFullScreenCoordinator: NSObject {
    private static var associationKey: UInt8 = 0
    private static let logger = Logger(subsystem: "com.netvplayer.app", category: "Windowing")
    private weak var window: NSWindow?
    private var watchdog: Timer?
    private let toggleNative: @MainActor (NSWindow) -> Void
    private let actualState: @MainActor (NSWindow) -> Bool
    private let uptime: @MainActor () -> TimeInterval
    private(set) var state = FullScreenTransitionState()
    var onStateChange: (@MainActor (Bool) -> Void)?

    static func attached(to window: NSWindow) -> PlayerFullScreenCoordinator {
        if let existing = objc_getAssociatedObject(window, &associationKey) as? PlayerFullScreenCoordinator { return existing }
        let coordinator = PlayerFullScreenCoordinator(window: window)
        objc_setAssociatedObject(window, &associationKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return coordinator
    }

    static func detach(from window: NSWindow) {
        (objc_getAssociatedObject(window, &associationKey) as? PlayerFullScreenCoordinator)?.stop()
        objc_setAssociatedObject(window, &associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    init(window: NSWindow, toggleNative: @escaping @MainActor (NSWindow) -> Void = { $0.toggleFullScreen(nil) },
         actualState: @escaping @MainActor (NSWindow) -> Bool = { $0.styleMask.contains(.fullScreen) },
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.window = window; self.toggleNative = toggleNative; self.actualState = actualState; self.uptime = uptime
        super.init()
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(observed(_:)), name: name, object: window)
        }
    }

    func toggle() {
        guard let window, !state.isClosed else { return }
        apply(state.toggle(actual: actualState(window), now: uptime()))
    }

    func request(_ target: Bool) {
        guard let window, !state.isClosed else { return }
        apply(state.request(target, actual: actualState(window), now: uptime()))
    }

    /// Failed native animations and lost callbacks share the same bounded recovery path.
    func reconcile() {
        guard let window, !state.isClosed else { stop(); return }
        let prior = state.transition
        let action = state.recover(actual: actualState(window), isLiveResize: window.inLiveResize, now: uptime())
        if prior != nil, state.transition != prior {
            Self.logger.info("Fullscreen reconciled: window=\(window.windowNumber, privacy: .public) actual=\(self.actualState(window), privacy: .public)")
            onStateChange?(actualState(window))
        }
        apply(action)
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        NotificationCenter.default.removeObserver(self)
        state.close(); onStateChange = nil; window = nil
    }

    @objc private func observed(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window, !state.isClosed else { return }
        switch notification.name {
        case NSWindow.willCloseNotification:
            Self.detach(from: window)
            stop()
        case NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification:
            state.began(target: notification.name == NSWindow.willEnterFullScreenNotification, now: uptime())
            armWatchdog()
        default:
            let completedTarget = notification.name == NSWindow.didEnterFullScreenNotification
            if let transition = state.transition, transition.target != completedTarget { return }
            let action = state.completed(actual: actualState(window), now: uptime())
            onStateChange?(actualState(window))
            apply(action)
        }
    }

    private func apply(_ action: Bool?) {
        if let target = action, let window, target != actualState(window), !state.isClosed {
            armWatchdog()
            toggleNative(window)
        }
        if state.transition == nil { watchdog?.invalidate(); watchdog = nil }
        else { armWatchdog() }
    }

    private func armWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                self.reconcile()
            }
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
