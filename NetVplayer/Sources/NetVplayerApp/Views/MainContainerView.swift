// NetVplayerApp/Views/MainContainerView.swift
// 主容器视图 — 侧边栏 + 详情区

import SwiftUI
import AppKit
import OSLog
import Models
import PlayerEngine

/// 主容器视图
struct MainContainerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var playerWindowContext = PlayerWindowContext(preferenceStore: .main)

    var body: some View {
        let palette = appState.appearancePalette
        Group {
            if appState.isPlayerPresented {
                PlayerView(
                    playerState: appState.playerState,
                    windowContext: playerWindowContext
                )
                .frame(
                    minWidth: CompactPlayerLayoutPolicy.minimumContentSize.width,
                    minHeight: CompactPlayerLayoutPolicy.minimumContentSize.height
                )
                .preferredColorScheme(.dark)
            } else {
                ZStack {
                    AppThemeRootBackground(
                        palette: palette,
                        forceOpaque: appState.selectedTab == .liveStream
                    )

                    // This sidebar is fully theme-owned. NavigationSplitView adds its own
                    // light material before our tint, which washes out the shared backdrop.
                    HSplitView {
                        SidebarView(selectedTab: $appState.selectedTab)
                            .padding(.leading, HomeVisualPolicy.primarySidebarOuterInset)
                            .padding(.top, HomeVisualPolicy.primarySidebarTopInset)
                            .padding(.bottom, HomeVisualPolicy.primarySidebarOuterInset)
                            .frame(
                                minWidth: HomeVisualPolicy.primarySidebarPaneMinWidth,
                                idealWidth: HomeVisualPolicy.primarySidebarPaneIdealWidth,
                                maxWidth: HomeVisualPolicy.primarySidebarPaneMaxWidth,
                                maxHeight: .infinity
                            )
                            .ignoresSafeArea(edges: .top)

                        Group {
                            switch appState.selectedTab {
                            case .vodHome:
                                VodHomeView()
                            case .search:
                                SearchView()
                            case .liveStream:
                                Color.black
                            case .history:
                                HistoryView()
                            case .favorites:
                                FavoritesView()
                            case .webHome:
                                WebHomeView()
                            case .settings:
                                SettingsView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .tint(palette.accent)

                    if appState.isDetailPresented, let vod = appState.detailVod {
                        GeometryReader { proxy in
                            let layout = VodDetailLayoutPolicy.layout(in: proxy.size)

                            ZStack {
                                Color.black.opacity(0.56)
                                    .ignoresSafeArea()
                                VodDetailView(vod: vod, layout: layout)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: AppSurfaceVisualPolicy.panelCornerRadius,
                                            style: .continuous
                                        )
                                    )
                                    .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                            }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                        .zIndex(10)
                    }
                }
                .frame(
                    minWidth: CompactPlayerLayoutPolicy.regularThreshold.width,
                    minHeight: CompactPlayerLayoutPolicy.regularThreshold.height
                )
                .preferredColorScheme(palette.preferredColorScheme)
            }
        }
        .environment(\.appThemePalette, palette)
        .sheet(item: $appState.cloudAuthRequest) { request in
            CloudAuthView(request: request) { credential in
                try await appState.completeCloudAuth(credential: credential)
            }
            .environment(\.appThemePalette, palette)
        }
        .background {
            PlayerWindowChromeController(
                isPlaybackPresented: appState.isPlayerPresented,
                isHomePresented: appState.selectedTab == .vodHome,
                onWindowClose: stopPlaybackForWindowClose,
                windowContext: playerWindowContext
            )
                .frame(width: 0, height: 0)
        }
        .onChange(of: appState.livePlayerOpenRequestSerial) { _, _ in
            openWindow(id: AppWindowID.livePlayer)
        }
        .onChange(of: appState.selectedTab) { _, _ in
            appState.restoreVodHomeSiteIfNeeded()
        }
        .onChange(of: appState.isDetailPresented) { _, _ in
            appState.restoreVodHomeSiteIfNeeded()
        }
        .onChange(of: appState.isPlayerPresented) { _, _ in
            appState.restoreVodHomeSiteIfNeeded()
        }
    }

    private func stopPlaybackForWindowClose() {
        guard appState.isPlayerPresented else { return }
        appState.saveCurrentPlaybackProgress()
        appState.cleanupDrivePlaybackIfNeeded(spec: appState.playerState.currentSpec)
        MPVPlayerEngine.vod.stop()
        appState.isPlayerPresented = false
    }
}

struct LivePlayerWindowView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var windowContext = PlayerWindowContext(preferenceStore: .live)

    var body: some View {
        LiveStreamView(
            playerState: appState.livePlayerState,
            windowContext: windowContext,
            onExit: closeWindow
        )
            .frame(
                minWidth: CompactPlayerLayoutPolicy.minimumContentSize.width,
                minHeight: CompactPlayerLayoutPolicy.minimumContentSize.height
            )
            .preferredColorScheme(.dark)
            .background {
                PlayerWindowChromeController(
                    isPlaybackPresented: true,
                    isHomePresented: false,
                    windowContext: windowContext
                )
                .frame(width: 0, height: 0)
            }
            .task {
                await appState.activateLivePlayerWindow()
            }
            .onDisappear(perform: cleanupPlaybackIfNeeded)
    }

    private func closeWindow() {
        cleanupPlaybackIfNeeded()
        dismissWindow(id: AppWindowID.livePlayer)
    }

    private func cleanupPlaybackIfNeeded() {
        guard appState.isLivePlayerPresented else { return }
        MPVPlayerEngine.live.stop()
        appState.liveError = nil
        appState.dismissLivePlayer()
    }
}

enum MainWindowTitlebarInteractionPolicy {
    static let regionHeight: CGFloat = 22
    static let leadingControlExclusionWidth: CGFloat = 128
    static let sidebarBlankRegionWidth = HomeVisualPolicy.sidebarMinWidth
    static let defaultSidebarWidth = HomeVisualPolicy.primarySidebarPaneIdealWidth
    static let fallbackRestoredWindowSize = CGSize(width: 1_200, height: 800)
    static let zoomFrameTolerance: CGFloat = 1
    static let sidebarNavigationTopDistance = HomeVisualPolicy.primarySidebarNavigationTopDistance
    static let homeCategoryTopDistance = HomeVisualPolicy.contentTopPadding
        + HomeVisualPolicy.headerHeight
        + 12
    static let homeHeaderControlTopDistance = HomeVisualPolicy.headerControlTopInset
    static let homeHeaderControlBottomDistance = homeHeaderControlTopDistance
        + HomeVisualPolicy.headerControlHeight
    static func shouldToggleZoom(clickCount: Int, isFullScreen: Bool = false) -> Bool {
        clickCount == 2 && !isFullScreen
    }

    static func playerNavigationRegionHeight(contentLayoutSize: CGSize) -> CGFloat {
        max(
            regionHeight,
            PlayerHUDVisualPolicy.topBarHeight
                * PlayerHUDLayoutPolicy.scale(for: contentLayoutSize)
        )
    }

    static func zoomTransition(
        currentFrame: CGRect,
        visibleFrame: CGRect,
        restoreFrame: CGRect?
    ) -> (targetFrame: CGRect, nextRestoreFrame: CGRect?) {
        guard framesMatch(currentFrame, visibleFrame) else {
            return (visibleFrame, currentFrame)
        }

        let fallbackSize = CGSize(
            width: min(fallbackRestoredWindowSize.width, visibleFrame.width),
            height: min(fallbackRestoredWindowSize.height, visibleFrame.height)
        )
        let fallbackFrame = CGRect(
            x: visibleFrame.midX - fallbackSize.width / 2,
            y: visibleFrame.midY - fallbackSize.height / 2,
            width: fallbackSize.width,
            height: fallbackSize.height
        )
        let restoredFrame = PlayerWindowPresentationPolicy.frameClampedToVisibleScreen(
            restoreFrame ?? fallbackFrame,
            visibleFrame: visibleFrame
        )
        return (restoredFrame, nil)
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= zoomFrameTolerance
            && abs(lhs.minY - rhs.minY) <= zoomFrameTolerance
            && abs(lhs.width - rhs.width) <= zoomFrameTolerance
            && abs(lhs.height - rhs.height) <= zoomFrameTolerance
    }

    static func contains(
        locationInWindow: CGPoint,
        contentLayoutRect: CGRect,
        windowFrameHeight: CGFloat,
        isPlaybackPresented: Bool = false,
        isHomePresented: Bool = false,
        sidebarWidth: CGFloat = defaultSidebarWidth
    ) -> Bool {
        let distanceFromTop = windowFrameHeight - locationInWindow.y
        guard distanceFromTop >= 0 else { return false }

        let topInteractionHeight = isPlaybackPresented
            ? playerNavigationRegionHeight(contentLayoutSize: contentLayoutRect.size)
            : regionHeight
        if distanceFromTop <= topInteractionHeight {
            return locationInWindow.x >= leadingControlExclusionWidth
        }

        guard !isPlaybackPresented, isHomePresented else { return false }

        let isSidebarPresented = sidebarWidth >= sidebarBlankRegionWidth - 1

        if isSidebarPresented, locationInWindow.x <= sidebarWidth {
            let titlebarHeight = max(0, windowFrameHeight - contentLayoutRect.maxY)
            guard distanceFromTop > max(titlebarHeight, regionHeight) else { return false }
            return distanceFromTop < sidebarNavigationTopDistance
        }

        if (homeHeaderControlTopDistance...homeHeaderControlBottomDistance).contains(distanceFromTop) {
            let sitePickerControlMinX = sidebarWidth
                + HomeVisualPolicy.contentHorizontalPadding
                + HomeVisualPolicy.headerLeadingInset(isSidebarPresented: isSidebarPresented)
            let sitePickerControlMaxX = sitePickerControlMinX + HomeVisualPolicy.sitePickerWidth
            let searchControlMaxX = contentLayoutRect.maxX - HomeVisualPolicy.contentHorizontalPadding
            let searchControlMinX = searchControlMaxX - HomeVisualPolicy.searchIdealWidth
            let isInsideSitePicker = (sitePickerControlMinX...sitePickerControlMaxX)
                .contains(locationInWindow.x)
            let isInsideSearch = (searchControlMinX...searchControlMaxX)
                .contains(locationInWindow.x)
            guard !isInsideSitePicker, !isInsideSearch else { return false }
        }

        return distanceFromTop < homeCategoryTopDistance
    }
}

enum PlayerWindowChromePolicy {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.netvplayer.app",
        category: "Windowing"
    )

    @MainActor
    static func configureFullScreenPlayback(_ window: NSWindow) {
        window.styleMask.insert(.resizable)
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    @MainActor
    static func configurePlaybackPresentation(_ window: NSWindow, isCompact: Bool) {
        configureFullScreenPlayback(window)
        window.minSize = minimumFrameSize(
            preserving: CompactPlayerLayoutPolicy.minimumContentSize,
            in: window
        )
        setNativeWindowButtonsHidden(isCompact, in: window)
    }

    @MainActor
    static func configureBrowsingPresentation(_ window: NSWindow) {
        window.minSize = minimumFrameSize(
            preserving: CompactPlayerLayoutPolicy.regularThreshold,
            in: window
        )
        setNativeWindowButtonsHidden(false, in: window)
    }

    @MainActor
    static func minimumFrameSize(preserving contentLayoutSize: CGSize, in window: NSWindow) -> CGSize {
        let chromeWidth = max(0, window.frame.width - window.contentLayoutRect.width)
        let chromeHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        return CGSize(
            width: contentLayoutSize.width + chromeWidth,
            height: contentLayoutSize.height + chromeHeight
        )
    }

    @MainActor
    private static func setNativeWindowButtonsHidden(_ isHidden: Bool, in window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = isHidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = isHidden
        window.standardWindowButton(.zoomButton)?.isHidden = isHidden
    }

    @MainActor
    static func toggleFullScreen(_ window: NSWindow) {
        configureFullScreenPlayback(window)
        window.makeKey()
        let wasFullScreen = window.styleMask.contains(.fullScreen)
        let wasKeyWindow = window.isKeyWindow
        let behavior = window.collectionBehavior.rawValue
        logger.info(
            "Fullscreen requested: window=\(window.windowNumber, privacy: .public) fullScreen=\(wasFullScreen, privacy: .public) key=\(wasKeyWindow, privacy: .public) behavior=\(behavior, privacy: .public)"
        )
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak window] in
            guard let window else { return }
            let isFullScreen = window.styleMask.contains(.fullScreen)
            let isKeyWindow = window.isKeyWindow
            let isVisible = window.isVisible
            logger.info(
                "Fullscreen settled: window=\(window.windowNumber, privacy: .public) fullScreen=\(isFullScreen, privacy: .public) key=\(isKeyWindow, privacy: .public) visible=\(isVisible, privacy: .public)"
            )
        }
    }
}

enum PlayerWindowPresentationPolicy {
    static var referenceContentSize: CGSize { PlayerHUDLayoutPolicy.referenceSize }

    static func targetContentSize(currentContentSize: CGSize, visibleFrameSize: CGSize) -> CGSize {
        let reference = referenceContentSize
        guard reference.width > 0, reference.height > 0 else { return currentContentSize }

        let preferredScale = currentContentSize.width / reference.width
        let visibleScale = min(
            visibleFrameSize.width / reference.width,
            visibleFrameSize.height / reference.height
        )
        let maximumScale = min(PlayerHUDLayoutPolicy.maximumWindowedScale, visibleScale)
        let scale: CGFloat
        if maximumScale < PlayerHUDLayoutPolicy.minimumWindowedScale {
            scale = max(0, maximumScale)
        } else {
            scale = min(
                maximumScale,
                max(PlayerHUDLayoutPolicy.minimumWindowedScale, preferredScale)
            )
        }

        return CGSize(width: reference.width * scale, height: reference.height * scale)
    }

    static func frameKeepingCenter(
        currentFrame: CGRect,
        targetFrameSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let size = CGSize(
            width: min(targetFrameSize.width, visibleFrame.width),
            height: min(targetFrameSize.height, visibleFrame.height)
        )
        var origin = CGPoint(
            x: currentFrame.midX - size.width / 2,
            y: currentFrame.midY - size.height / 2
        )
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    static func frameClampedToVisibleScreen(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        frameKeepingCenter(currentFrame: frame, targetFrameSize: frame.size, visibleFrame: visibleFrame)
    }

    static func restoredWindowFrame(
        lastRegularFrame: CGRect?,
        currentFrame: CGRect,
        fallbackFrameSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        if let lastRegularFrame {
            return frameClampedToVisibleScreen(lastRegularFrame, visibleFrame: visibleFrame)
        }
        return frameKeepingCenter(
            currentFrame: currentFrame,
            targetFrameSize: fallbackFrameSize,
            visibleFrame: visibleFrame
        )
    }
}

enum PlayerWindowLifecycleAction: Equatable {
    case none
    case exitFullScreen
}

enum PlayerWindowLifecyclePolicy {
    static func dismissalAction(isFullScreen: Bool) -> PlayerWindowLifecycleAction {
        isFullScreen ? .exitFullScreen : .none
    }
}

@MainActor
final class PlayerWindowCloseMonitor: NSObject {
    private weak var monitoredWindow: NSWindow?
    private var onClose: (() -> Void)?

    func monitor(_ window: NSWindow, onClose: @escaping () -> Void) {
        if monitoredWindow === window {
            self.onClose = onClose
            return
        }
        stopMonitoring()
        monitoredWindow = window
        self.onClose = onClose
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    func stopMonitoring() {
        if let monitoredWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: monitoredWindow
            )
        }
        monitoredWindow = nil
        onClose = nil
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === monitoredWindow else { return }
        let action = onClose
        stopMonitoring()
        action?()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

private struct PlayerWindowChromeController: NSViewRepresentable {
    let isPlaybackPresented: Bool
    let isHomePresented: Bool
    var onWindowClose: (() -> Void)? = nil
    @ObservedObject var windowContext: PlayerWindowContext

    @MainActor
    final class Coordinator: NSObject {
        private weak var monitoredWindow: NSWindow?
        private weak var fullScreenWindow: NSWindow?
        private weak var metricsWindow: NSWindow?
        private var titlebarMouseMonitor: Any?
        private var titlebarZoomRestoreFrame: CGRect?
        private let windowCloseMonitor = PlayerWindowCloseMonitor()
        weak var windowContext: PlayerWindowContext?
        var wasPlaybackPresented = false
        var isHomePresented = false

        func monitorWindowClose(in window: NSWindow, action: (() -> Void)?) {
            guard let action else {
                windowCloseMonitor.stopMonitoring()
                return
            }
            windowCloseMonitor.monitor(window, onClose: action)
        }

        func stopMonitoringWindowClose() {
            windowCloseMonitor.stopMonitoring()
        }

        func monitorWindowMetrics(in window: NSWindow) {
            guard metricsWindow !== window else {
                windowContext?.updateWindowMetrics(for: window)
                return
            }
            stopMonitoringWindowMetrics()
            metricsWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerWindowGeometryDidChange(_:)),
                name: NSWindow.didResizeNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerWindowGeometryDidChange(_:)),
                name: NSWindow.didMoveNotification,
                object: window
            )
            windowContext?.updateWindowMetrics(for: window)
        }

        func stopMonitoringWindowMetrics() {
            guard let metricsWindow else { return }
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResizeNotification,
                object: metricsWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didMoveNotification,
                object: metricsWindow
            )
            self.metricsWindow = nil
        }

        @objc private func playerWindowGeometryDidChange(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  window === metricsWindow else { return }
            windowContext?.updateWindowMetrics(for: window)
        }

        func monitorFullScreenTransitions(in window: NSWindow) {
            guard fullScreenWindow !== window else { return }
            stopMonitoringFullScreenTransitions()
            fullScreenWindow = window
            windowContext?.updateFullScreenState(
                window.styleMask.contains(.fullScreen),
                for: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerWindowDidEnterFullScreen(_:)),
                name: NSWindow.didEnterFullScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerWindowDidExitFullScreen(_:)),
                name: NSWindow.didExitFullScreenNotification,
                object: window
            )
        }

        func stopMonitoringFullScreenTransitions() {
            guard let fullScreenWindow else { return }
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didEnterFullScreenNotification,
                object: fullScreenWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didExitFullScreenNotification,
                object: fullScreenWindow
            )
            self.fullScreenWindow = nil
        }

        @objc private func playerWindowDidEnterFullScreen(_ notification: Notification) {
            if let window = notification.object as? NSWindow {
                windowContext?.updateFullScreenState(true, for: window)
            }
            activatePlayerWindow(from: notification)
        }

        @objc private func playerWindowDidExitFullScreen(_ notification: Notification) {
            if let window = notification.object as? NSWindow {
                windowContext?.updateFullScreenState(false, for: window)
            }
            activatePlayerWindow(from: notification)
        }

        private func activatePlayerWindow(from notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  window === fullScreenWindow else { return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        func monitorTitlebarDoubleClicks(in window: NSWindow) {
            guard monitoredWindow !== window else { return }
            removeTitlebarMouseMonitor()
            monitoredWindow = window
            titlebarMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                [weak self, weak window] event in
                guard let self,
                      let window,
                      event.window === window,
                      MainWindowTitlebarInteractionPolicy.shouldToggleZoom(
                          clickCount: event.clickCount,
                          isFullScreen: window.styleMask.contains(.fullScreen)
                      ),
                      MainWindowTitlebarInteractionPolicy.contains(
                          locationInWindow: event.locationInWindow,
                          contentLayoutRect: window.contentLayoutRect,
                          windowFrameHeight: window.frame.height,
                          isPlaybackPresented: wasPlaybackPresented,
                          isHomePresented: isHomePresented,
                          sidebarWidth: sidebarWidth(in: window)
                      ) else {
                    return event
                }

                guard toggleTitlebarZoom(in: window) else { return event }
                return nil
            }
        }

        private func toggleTitlebarZoom(in window: NSWindow) -> Bool {
            guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
                return false
            }
            let transition = MainWindowTitlebarInteractionPolicy.zoomTransition(
                currentFrame: window.frame,
                visibleFrame: visibleFrame,
                restoreFrame: titlebarZoomRestoreFrame
            )
            titlebarZoomRestoreFrame = transition.nextRestoreFrame

            // AppKit's animated zoom can trap while updating full-size-content windows.
            window.setFrame(transition.targetFrame, display: true, animate: false)
            return true
        }

        private func sidebarWidth(in window: NSWindow) -> CGFloat {
            guard let sidebar = findSidebarSplitView(in: window.contentView)?
                .arrangedSubviews.first else {
                return MainWindowTitlebarInteractionPolicy.defaultSidebarWidth
            }
            return sidebar.isHidden ? 0 : sidebar.frame.width
        }

        private func findSidebarSplitView(in view: NSView?) -> NSSplitView? {
            guard let view else { return nil }
            if let splitView = view as? NSSplitView,
               let width = splitView.arrangedSubviews.first?.frame.width,
               (MainWindowTitlebarInteractionPolicy.sidebarBlankRegionWidth - 1 ...
                HomeVisualPolicy.sidebarMaxWidth + 1)
                .contains(width) {
                return splitView
            }
            for subview in view.subviews {
                if let splitView = findSidebarSplitView(in: subview) {
                    return splitView
                }
            }
            return nil
        }

        func removeTitlebarMouseMonitor() {
            if let titlebarMouseMonitor {
                NSEvent.removeMonitor(titlebarMouseMonitor)
            }
            titlebarMouseMonitor = nil
            monitoredWindow = nil
            titlebarZoomRestoreFrame = nil
        }

        func leavePlayerMode(window: NSWindow) {
            guard PlayerWindowLifecyclePolicy.dismissalAction(
                isFullScreen: window.styleMask.contains(.fullScreen)
            ) == .exitFullScreen else { return }
            window.toggleFullScreen(nil)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            applyChrome(to: view.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            applyChrome(to: nsView.window, coordinator: context.coordinator)
        }
    }

    @MainActor
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        let windowContext = coordinator.windowContext
        let window = nsView.window
        coordinator.windowContext = nil
        coordinator.removeTitlebarMouseMonitor()
        coordinator.stopMonitoringWindowMetrics()
        coordinator.stopMonitoringFullScreenTransitions()
        coordinator.stopMonitoringWindowClose()
        DispatchQueue.main.async { [weak windowContext] in
            windowContext?.detach(window)
        }
    }

    @MainActor
    private func applyChrome(to window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }

        if !isPlaybackPresented, coordinator.wasPlaybackPresented {
            coordinator.leavePlayerMode(window: window)
            coordinator.windowContext?.finishPlayback(restoreRegularWindowIfNeeded: true)
        }

        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = isPlaybackPresented
        window.backgroundColor = isPlaybackPresented ? .black : .clear
        coordinator.windowContext = windowContext
        windowContext.attach(window)
        coordinator.monitorWindowMetrics(in: window)
        coordinator.isHomePresented = isHomePresented
        coordinator.monitorTitlebarDoubleClicks(in: window)
        coordinator.monitorWindowClose(in: window, action: onWindowClose)
        if isPlaybackPresented {
            PlayerWindowChromePolicy.configurePlaybackPresentation(
                window,
                isCompact: windowContext.isCompact
            )
            coordinator.monitorFullScreenTransitions(in: window)
        } else {
            PlayerWindowChromePolicy.configureBrowsingPresentation(window)
            coordinator.stopMonitoringFullScreenTransitions()
        }

        if isPlaybackPresented != coordinator.wasPlaybackPresented {
            coordinator.wasPlaybackPresented = isPlaybackPresented
        }
    }
}
