import AppKit
import SwiftUI

enum PlayerShortcutCommand: Equatable {
    case togglePlayPause
    case seekBackward
    case seekForward
    case volumeUp
    case volumeDown
    case enterFullScreen
    case exitFullScreen
}

enum PlayerKeyboardShortcutPolicy {
    static let seekInterval: Double = 10
    static let volumeStep: Float = 0.05

    static func toggledPlaybackState(from isPlaying: Bool) -> Bool {
        !isPlaying
    }

    static func command(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> PlayerShortcutCommand? {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard modifierFlags.intersection(disallowedModifiers).isEmpty else { return nil }

        switch keyCode {
        case 49:
            return .togglePlayPause
        case 123:
            return .seekBackward
        case 124:
            return .seekForward
        case 125:
            return .volumeDown
        case 126:
            return .volumeUp
        case 36, 76:
            return .enterFullScreen
        case 53:
            return .exitFullScreen
        default:
            return nil
        }
    }

    static func shouldDispatch(
        _ command: PlayerShortcutCommand,
        isRepeat: Bool,
        isFullScreen: Bool = false
    ) -> Bool {
        if isRepeat {
            switch command {
            case .togglePlayPause, .enterFullScreen, .exitFullScreen:
                return false
            default:
                break
            }
        }

        switch command {
        case .enterFullScreen:
            return !isFullScreen
        case .exitFullScreen:
            return isFullScreen
        default:
            return true
        }
    }
}

enum PlayerScrollShortcutPolicy {
    static let preciseDeltaThreshold: CGFloat = 10

    static func deviceDeltaY(
        fromScrollingDeltaY deltaY: CGFloat,
        isDirectionInvertedFromDevice: Bool
    ) -> CGFloat {
        isDirectionInvertedFromDevice ? -deltaY : deltaY
    }

    static func command(forDeltaY deltaY: CGFloat) -> PlayerShortcutCommand? {
        guard deltaY != 0 else { return nil }
        return deltaY > 0 ? .volumeUp : .volumeDown
    }
}

enum PlayerPointerShortcutAction: Equatable {
    case togglePlayPause
    case toggleFullScreen
}

enum PlayerPointerShortcutPolicy {
    static let singleClickCount = 1
    static let fullScreenClickCount = 2

    static func action(forClickCount clickCount: Int) -> PlayerPointerShortcutAction? {
        switch clickCount {
        case singleClickCount:
            return .togglePlayPause
        case fullScreenClickCount:
            return .toggleFullScreen
        default:
            return nil
        }
    }

    static func videoGestureMask(hasPlayback: Bool, hasBlockingUI: Bool) -> GestureMask {
        hasPlayback && !hasBlockingUI ? .all : .none
    }
}

@MainActor
final class PlayerWindowContext: ObservableObject {
    private(set) weak var window: NSWindow?
    @Published private(set) var isFullScreen = false
    @Published private(set) var contentSize = CGSize.zero
    @Published private(set) var isAlwaysOnTop = false
    private var lastRegularWindowFrame: CGRect?
    private let preferenceStore: PlayerWindowPreferenceStore?

    init(preferenceStore: PlayerWindowPreferenceStore? = nil) {
        self.preferenceStore = preferenceStore
    }

    var isCompact: Bool {
        CompactPlayerLayoutPolicy.isCompact(contentSize: contentSize)
    }

    func attach(_ window: NSWindow) {
        let isNewWindow = self.window !== window
        self.window = window
        updateFullScreenState(window.styleMask.contains(.fullScreen), for: window)
        if isNewWindow {
            restorePersistedFrameIfAvailable(for: window)
        }
        updateWindowMetrics(for: window)
    }

    func detach(_ window: NSWindow?) {
        guard self.window === window else { return }
        setAlwaysOnTop(false)
        self.window = nil
        isFullScreen = false
        contentSize = .zero
        lastRegularWindowFrame = nil
    }

    func updateFullScreenState(_ isFullScreen: Bool, for window: NSWindow) {
        guard self.window === window else { return }
        guard self.isFullScreen != isFullScreen else { return }
        self.isFullScreen = isFullScreen
    }

    func updateWindowMetrics(for window: NSWindow) {
        guard self.window === window else { return }
        let measuredSize = window.contentLayoutRect.size
        if contentSize != measuredSize {
            contentSize = measuredSize
        }

        guard !CompactPlayerLayoutPolicy.isCompact(contentSize: measuredSize) else {
            return
        }
        setAlwaysOnTop(false)
        guard !isFullScreen else { return }
        lastRegularWindowFrame = window.frame
        if let screen = window.screen ?? NSScreen.main {
            preferenceStore?.save(
                frame: window.frame,
                visibleFrame: screen.visibleFrame,
                screenIdentifier: PlayerWindowPreferenceStore.screenIdentifier(for: screen)
            )
        }
    }

    @discardableResult
    func toggleAlwaysOnTop() -> Bool {
        guard window != nil, isCompact else { return false }
        setAlwaysOnTop(!isAlwaysOnTop)
        return true
    }

    @discardableResult
    func restoreRegularWindow() -> Bool {
        guard let window,
              let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return false
        }

        setAlwaysOnTop(false)
        let fallbackFrameSize = PlayerWindowChromePolicy.minimumFrameSize(
            preserving: CompactPlayerLayoutPolicy.regularThreshold,
            in: window
        )
        let targetFrame = PlayerWindowPresentationPolicy.restoredWindowFrame(
            lastRegularFrame: lastRegularWindowFrame,
            currentFrame: window.frame,
            fallbackFrameSize: fallbackFrameSize,
            visibleFrame: visibleFrame
        )
        window.setFrame(targetFrame, display: true, animate: false)
        updateWindowMetrics(for: window)
        return true
    }

    func finishPlayback(restoreRegularWindowIfNeeded: Bool) {
        if restoreRegularWindowIfNeeded, isCompact {
            _ = restoreRegularWindow()
        } else {
            setAlwaysOnTop(false)
        }
    }

    private func restorePersistedFrameIfAvailable(for window: NSWindow) {
        guard let preference = preferenceStore?.preference else { return }
        let screen = preference.screenIdentifier.flatMap { identifier in
            NSScreen.screens.first {
                PlayerWindowPreferenceStore.screenIdentifier(for: $0) == identifier
            }
        } ?? window.screen ?? NSScreen.main
        guard let screen else { return }
        let minimumSize = PlayerWindowChromePolicy.minimumFrameSize(
            preserving: CompactPlayerLayoutPolicy.regularThreshold,
            in: window
        )
        guard let frame = PlayerWindowPreferencePolicy.restoredFrame(
            preference: preference,
            visibleFrame: screen.visibleFrame,
            minimumSize: minimumSize
        ) else { return }
        window.setFrame(frame, display: false, animate: false)
        lastRegularWindowFrame = frame
    }

    private func setAlwaysOnTop(_ enabled: Bool) {
        guard let window else {
            if isAlwaysOnTop {
                isAlwaysOnTop = false
            }
            return
        }
        window.level = enabled ? .floating : .normal
        if isAlwaysOnTop != enabled {
            isAlwaysOnTop = enabled
        }
    }
}

struct PlayerShortcutMonitor: NSViewRepresentable {
    let isPlaybackControlEnabled: Bool
    let isScrollVolumeEnabled: Bool
    let onCommand: (PlayerShortcutCommand, NSWindow) -> Void

    init(
        isPlaybackControlEnabled: Bool,
        isScrollVolumeEnabled: Bool,
        onCommand: @escaping (PlayerShortcutCommand, NSWindow) -> Void
    ) {
        self.isPlaybackControlEnabled = isPlaybackControlEnabled
        self.isScrollVolumeEnabled = isScrollVolumeEnabled
        self.onCommand = onCommand
    }

    @MainActor
    final class MonitoringView: NSView {
        var windowDidChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowDidChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        var isPlaybackControlEnabled: Bool
        var isScrollVolumeEnabled: Bool {
            didSet {
                if !isScrollVolumeEnabled {
                    preciseScrollAccumulator = 0
                }
            }
        }
        var onCommand: (PlayerShortcutCommand, NSWindow) -> Void

        private weak var monitoredWindow: NSWindow?
        private var eventMonitor: Any?
        private var preciseScrollAccumulator: CGFloat = 0

        init(
            isPlaybackControlEnabled: Bool,
            isScrollVolumeEnabled: Bool,
            onCommand: @escaping (PlayerShortcutCommand, NSWindow) -> Void
        ) {
            self.isPlaybackControlEnabled = isPlaybackControlEnabled
            self.isScrollVolumeEnabled = isScrollVolumeEnabled
            self.onCommand = onCommand
        }

        func monitorInput(in window: NSWindow) {
            guard monitoredWindow !== window else { return }
            stopMonitoring()
            monitoredWindow = window
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) {
                [weak self, weak window] event in
                guard let self,
                      let window,
                      event.window === window else {
                    return event
                }

                switch event.type {
                case .keyDown:
                    return handleKeyDown(event, in: window)
                case .scrollWheel:
                    return handleScrollWheel(event, in: window)
                default:
                    return event
                }
            }
        }

        private func handleKeyDown(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
            guard let command = PlayerKeyboardShortcutPolicy.command(
                forKeyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) else {
                return event
            }

            let isFullScreen = window.styleMask.contains(.fullScreen)
            if command != .exitFullScreen {
                guard isPlaybackControlEnabled, !Self.isTextInputActive(in: window) else {
                    return event
                }
            }

            guard PlayerKeyboardShortcutPolicy.shouldDispatch(
                command,
                isRepeat: event.isARepeat,
                isFullScreen: isFullScreen
            ) else {
                if event.isARepeat || command == .enterFullScreen {
                    return nil
                }
                return event
            }

            onCommand(command, window)
            return nil
        }

        private func handleScrollWheel(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
            guard isScrollVolumeEnabled, event.scrollingDeltaY != 0 else { return event }
            let deltaY = PlayerScrollShortcutPolicy.deviceDeltaY(
                fromScrollingDeltaY: event.scrollingDeltaY,
                isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
            )

            if event.hasPreciseScrollingDeltas {
                preciseScrollAccumulator += deltaY
                guard abs(preciseScrollAccumulator) >= PlayerScrollShortcutPolicy.preciseDeltaThreshold else {
                    return nil
                }
                defer { preciseScrollAccumulator = 0 }
                guard let command = PlayerScrollShortcutPolicy.command(
                    forDeltaY: preciseScrollAccumulator
                ) else {
                    return nil
                }
                onCommand(command, window)
                return nil
            }

            preciseScrollAccumulator = 0
            guard let command = PlayerScrollShortcutPolicy.command(forDeltaY: deltaY) else {
                return event
            }
            onCommand(command, window)
            return nil
        }

        func stopMonitoring() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
            monitoredWindow = nil
            preciseScrollAccumulator = 0
        }

        private static func isTextInputActive(in window: NSWindow) -> Bool {
            window.firstResponder is NSTextView || window.firstResponder is NSTextField
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPlaybackControlEnabled: isPlaybackControlEnabled,
            isScrollVolumeEnabled: isScrollVolumeEnabled,
            onCommand: onCommand
        )
    }

    func makeNSView(context: Context) -> MonitoringView {
        let view = MonitoringView(frame: .zero)
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            if let window {
                coordinator?.monitorInput(in: window)
            } else {
                coordinator?.stopMonitoring()
            }
        }
        return view
    }

    func updateNSView(_ nsView: MonitoringView, context: Context) {
        context.coordinator.isPlaybackControlEnabled = isPlaybackControlEnabled
        context.coordinator.isScrollVolumeEnabled = isScrollVolumeEnabled
        context.coordinator.onCommand = onCommand
        if let window = nsView.window {
            context.coordinator.monitorInput(in: window)
        }
    }

    @MainActor
    static func dismantleNSView(_ nsView: MonitoringView, coordinator: Coordinator) {
        nsView.windowDidChange = nil
        coordinator.stopMonitoring()
    }
}
