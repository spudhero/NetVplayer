import AppKit
import Foundation

struct AppUpdatePresentationContext {
    var startupReady = false
    var playbackActive = false
    var applicationActive = false
    var visibleWindow = false
    var fullScreen = false
    var modal = false

    var permitsAutomaticReminder: Bool {
        startupReady && !playbackActive && applicationActive && visibleWindow && !fullScreen && !modal
    }

    @MainActor static func current() -> Self {
        let startup = AppStartup.shared
        let state = startup.runtime
        return capture(startupReady: startup.phase == .ready,
                       playbackActive: state.map {
                           $0.isPlayerPresented || $0.isLivePlayerPresented ||
                           $0.playerState.currentSpec != nil || $0.livePlayerState.currentSpec != nil
                       } ?? false)
    }

    @MainActor static func capture(startupReady: Bool, playbackActive: Bool,
                                   application: NSApplication = .shared) -> Self {
        let windows = application.windows
        return Self(startupReady: startupReady, playbackActive: playbackActive,
                    applicationActive: application.isActive,
                    visibleWindow: windows.contains { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain },
                    fullScreen: windows.contains { $0.styleMask.contains(.fullScreen) },
                    modal: application.modalWindow != nil || windows.contains {
                        $0.attachedSheet != nil || ($0.isVisible && $0.isSheet)
                    })
    }
}
