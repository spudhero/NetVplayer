// NetVplayerApp/NetVplayerApp.swift
// macOS App 主入口

import SwiftUI
import Models
import PlayerEngine

#if os(macOS)
import AppKit

@MainActor
final class NetVplayerWindowCoordinator {
    static let shared = NetVplayerWindowCoordinator()

    private let startup: AppStartupCoordinator
    private let canPresentStopped: () -> Bool
    private weak var mainWindow: NSWindow?
    private var openMainWindow: (() -> Void)?
    private var pendingShow = false

    init(startup: AppStartupCoordinator = AppStartup.shared,
         canPresentStopped: @escaping () -> Bool = {
             AppRelaunchCoordinator.shared.failure != nil || AppUpdateCoordinator.shared.restartFailure != nil
         }) {
        self.startup = startup
        self.canPresentStopped = canPresentStopped
    }

    func registerMainWindow(_ window: NSWindow, open: @escaping () -> Void) {
        mainWindow = window
        openMainWindow = open
        if pendingShow {
            pendingShow = false
            present(window)
        }
    }

    func showMainWindow() {
        guard startup.phase != .stopped || canPresentStopped() else { return }
        if let window = mainWindow, window.isVisible || window.isMiniaturized {
            present(window)
        } else if let openMainWindow {
            // Only SwiftUI's singleton Window scene may create/recreate the window.
            openMainWindow()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Launch may deliver a reopen/file event before the scene attaches.
            pendingShow = true
        }
    }

    private func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class NetVplayerAppDelegate: NSObject, NSApplicationDelegate {
    private let windows: NetVplayerWindowCoordinator
    private var terminationReplyTask: Task<Void, Never>?

    override convenience init() { self.init(windows: .shared) }
    init(windows: NetVplayerWindowCoordinator) { self.windows = windows; super.init() }

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppStartup.shared.prepare()
        applyBundledDockIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if MPVCadenceProbe.scheduleIfRequested() { return }
        if MPVPerformanceProbe.scheduleIfRequested() { return }
        if MPVVideoOutputProbe.scheduleIfRequested() { return }
        if MPVHDRPrototype.scheduleIfRequested() { return }

        StartupWindowProbe.scheduleIfRequested()
        #endif
        if DevelopmentAndroidAppAudit.current != nil || PlayerVisualRegressionConfiguration.current != nil {
            // Explicit acceptance runs must also start when scene restoration
            // does not attach StartupRootView. The coordinator is idempotent
            // with the view's ordinary startIfNeeded task.
            AppStartup.shared.startIfNeeded()
        }
        // SwiftUI owns initial presentation; do not race it with a second NSWindow.
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppStartup.shared.enqueue(urls)
        showMainWindowIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindowIfNeeded()
        // The request is handled here; default untitled-window creation must not run too.
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let startup = AppStartup.shared
        // A concurrent Cmd-Q must not exit between cleanup completion and the owning
        // restart's helper/SDK handoff. That owner requests termination again afterwards.
        if restartHandoffPending { return .terminateCancel }
        if startup.phase == .stopped { return .terminateNow }
        guard terminationReplyTask == nil else { return .terminateLater }
        let cleanup = startup.terminate()
        terminationReplyTask = Task { @MainActor in
            let completed = await cleanup.value
            self.terminationReplyTask = nil
            sender.reply(toApplicationShouldTerminate: completed && !self.restartHandoffPending)
            if !completed { self.showMainWindowIfNeeded() }
        }
        return .terminateLater
    }

    private var restartHandoffPending: Bool {
        (AppRestartGate.shared.lease?.owner == .language && !AppRelaunchCoordinator.shared.helperScheduled)
            || AppUpdateCoordinator.shared.isPreparingInstallation
    }

    private func applyBundledDockIcon() {
        NSApp.applicationIconImage = NetVplayerApplicationIcon.image
    }

    private func showMainWindowIfNeeded() { windows.showMainWindow() }

}
#endif

enum AppWindowID {
    static let main = "netvplayer-main"
    static let livePlayer = "live-player"
    static let displayInspection = "display-inspection"
}

@main
struct NetVplayerApp: App {
    @StateObject private var startup: AppStartupCoordinator
    @NSApplicationDelegateAdaptor(NetVplayerAppDelegate.self) private var appDelegate

    init() {
        let startup = AppStartup.shared
        startup.prepare()
        _startup = StateObject(wrappedValue: startup)
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        Window("NetVplayer", id: AppWindowID.main) {
            StartupRootView(startup: startup)
                .background(OptionalWorkWindowVisibility().frame(width: 0, height: 0))
                .background(StartupWindowRegistration().frame(width: 0, height: 0))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: PlayerVisualRegressionConfiguration.current?.viewport.width ?? 1200,
                     height: PlayerVisualRegressionConfiguration.current?.viewport.height ?? 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.text("检查更新")) { AppUpdateCoordinator.shared.checkForUpdates() }
                    .disabled(startup.phase != .ready)
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("显示主窗口")) {
                    NetVplayerWindowCoordinator.shared.showMainWindow()
                }.keyboardShortcut("n")
                Button(L10n.text("打开文件…")) {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = false
                    panel.begin { response in
                        if response == .OK { startup.enqueue(panel.urls) }
                    }
                }.keyboardShortcut("o")
                    .disabled(startup.phase == .terminating || startup.phase == .stopped)
            }
            CommandGroup(after: .help) {
                Button(L10n.text("报告问题…")) {
                    guard startup.phase == .ready, let state = startup.runtime else { return }
                    state.openFeedback()
                    NetVplayerWindowCoordinator.shared.showMainWindow()
                }.disabled(startup.phase != .ready)
            }
        }

        Window(L10n.text("直播播放器"), id: AppWindowID.livePlayer) {
            if startup.phase == .ready, let state = startup.runtime {
                LivePlayerWindowView().environmentObject(state)
                    .background(OptionalWorkWindowVisibility().frame(width: 0, height: 0))
            } else { StartupRecoveryView(startup: startup) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: PlayerWindowPresentationPolicy.referenceContentSize.width,
                     height: PlayerWindowPresentationPolicy.referenceContentSize.height)

        Window(L10n.text("显示测试图与指引"), id: AppWindowID.displayInspection) {
            if startup.phase == .ready { DisplayInspectionView() }
            else { StartupRecoveryView(startup: startup) }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 780)
    }
}
