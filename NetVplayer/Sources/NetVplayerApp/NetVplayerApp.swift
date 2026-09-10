// NetVplayerApp/NetVplayerApp.swift
// macOS App 主入口

import SwiftUI
import Models
import ConfigEngine
import PlayerEngine
import NodeBundleRuntime

#if os(macOS)
import AppKit

@MainActor
final class NetVplayerWindowCoordinator {
    static let shared = NetVplayerWindowCoordinator()

    let appState: AppState
    private var fallbackWindow: NSWindow?

    private init() {
        let isVisualRegression = PlayerVisualRegressionConfiguration.current != nil
        appState = AppState(
            loadDefaultConfig: !isVisualRegression,
            startProxyServer: !isVisualRegression
        )
    }

    func showFallbackWindowIfNeeded() {
        if let visibleWindow = NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }) {
            visibleWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if fallbackWindow == nil {
            let rootView: AnyView
            if let configuration = PlayerVisualRegressionConfiguration.current {
                rootView = AnyView(
                    PlayerView(
                        playerState: appState.playerState,
                        windowContext: PlayerWindowContext(),
                        visualRegressionConfiguration: configuration
                    )
                    .environmentObject(appState)
                )
            } else {
                rootView = AnyView(
                    MainContainerView()
                        .environmentObject(appState)
                )
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "NetVplayer"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: rootView)
            window.center()
            fallbackWindow = window
        }

        fallbackWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class NetVplayerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        applyBundledDockIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let configuration = PlayerVisualRegressionConfiguration.current {
            showMainWindowIfNeeded()
            PlayerVisualRegressionCaptureController.schedule(configuration: configuration)
        } else {
            showMainWindowIfNeeded(after: 0.2)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        showMainWindowIfNeeded()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await NodeBundleRuntimeRegistry.shared.shutdown() }
    }

    private func applyBundledDockIcon() {
        NSApp.applicationIconImage = NetVplayerApplicationIcon.image
    }

    private func showMainWindowIfNeeded(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let visibleWindow = NSApp.windows.first { $0.isVisible && !$0.isMiniaturized }
            if let visibleWindow {
                visibleWindow.makeKeyAndOrderFront(nil)
            } else {
                let sent = NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
                if !sent {
                    NetVplayerWindowCoordinator.shared.showFallbackWindowIfNeeded()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NetVplayerWindowCoordinator.shared.showFallbackWindowIfNeeded()
                }
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
#endif

enum AppWindowID {
    static let livePlayer = "live-player"
}

@main
struct NetVplayerApp: App {
    @StateObject private var appState: AppState
    private let visualRegressionConfiguration: PlayerVisualRegressionConfiguration?
    #if os(macOS)
    @NSApplicationDelegateAdaptor(NetVplayerAppDelegate.self) private var appDelegate
    #endif

    init() {
        let visualRegressionConfiguration = PlayerVisualRegressionConfiguration.current
        self.visualRegressionConfiguration = visualRegressionConfiguration
        if visualRegressionConfiguration == nil {
            DiagnosticLog.beginSession()
            FeedbackReportFileStore.cleanupExpiredReports()
        }
        #if os(macOS)
        let sharedAppState = NetVplayerWindowCoordinator.shared.appState
        visualRegressionConfiguration?.apply(to: sharedAppState)
        _appState = StateObject(wrappedValue: sharedAppState)
        #else
        let newAppState = AppState()
        visualRegressionConfiguration?.apply(to: newAppState)
        _appState = StateObject(wrappedValue: newAppState)
        #endif

        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
        if visualRegressionConfiguration == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NetVplayerWindowCoordinator.shared.showFallbackWindowIfNeeded()
            }
        }
        #endif
        // 清理旧缓存以防之前防盗链返回的“DOUYU”灰色图片被强缓存影响显示
        URLCache.shared.removeAllCachedResponses()
    }

    var body: some Scene {
        WindowGroup {
            if let visualRegressionConfiguration {
                PlayerView(
                    playerState: appState.playerState,
                    windowContext: PlayerWindowContext(),
                    visualRegressionConfiguration: visualRegressionConfiguration
                )
                .environmentObject(appState)
            } else {
                MainContainerView()
                    .environmentObject(appState)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(
            width: visualRegressionConfiguration?.viewport.width ?? 1200,
            height: visualRegressionConfiguration?.viewport.height ?? 800
        )
        .commands {
            CommandGroup(after: .help) {
                Button("报告问题…") {
                    appState.openFeedback()
                    #if os(macOS)
                    NetVplayerWindowCoordinator.shared.showFallbackWindowIfNeeded()
                    #endif
                }
            }
        }

        Window("直播播放器", id: AppWindowID.livePlayer) {
            LivePlayerWindowView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(
            width: PlayerWindowPresentationPolicy.referenceContentSize.width,
            height: PlayerWindowPresentationPolicy.referenceContentSize.height
        )
    }
}
