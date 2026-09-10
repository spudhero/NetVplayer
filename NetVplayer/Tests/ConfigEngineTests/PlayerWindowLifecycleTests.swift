import AppKit
import Models
import Testing
@testable import NetVplayerApp

@Suite("Player window lifecycle")
@MainActor
struct PlayerWindowLifecycleTests {
    @Test func closeMonitorOnlyHandlesItsBoundWindowOnce() {
        let monitoredWindow = makeWindow()
        let unrelatedWindow = makeWindow()
        let monitor = PlayerWindowCloseMonitor()
        var closeCount = 0

        monitor.monitor(monitoredWindow) {
            closeCount += 1
        }

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: unrelatedWindow
        )
        #expect(closeCount == 0)

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: monitoredWindow
        )
        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: monitoredWindow
        )
        #expect(closeCount == 1)
    }

    @Test func closeMonitorCanRebindToAReopenedWindow() {
        let firstWindow = makeWindow()
        let reopenedWindow = makeWindow()
        let monitor = PlayerWindowCloseMonitor()
        var closeCount = 0

        monitor.monitor(firstWindow) {
            closeCount += 1
        }
        monitor.monitor(reopenedWindow) {
            closeCount += 10
        }

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: firstWindow
        )
        #expect(closeCount == 0)

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: reopenedWindow
        )
        #expect(closeCount == 10)
    }

    @Test func playbackWindowIsConfiguredForNativeFullScreen() {
        let window = makeWindow()
        window.collectionBehavior = [.fullScreenNone, .fullScreenAuxiliary]

        PlayerWindowChromePolicy.configureFullScreenPlayback(window)

        #expect(window.styleMask.contains(.resizable))
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!window.collectionBehavior.contains(.fullScreenNone))
        #expect(!window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test func compactPlaybackUsesHardMinimumAndHidesNativeWindowButtons() {
        let window = makeWindow(contentSize: CGSize(width: 427, height: 240))

        PlayerWindowChromePolicy.configurePlaybackPresentation(window, isCompact: true)

        #expect(window.contentMinSize == CGSize(width: 427, height: 240))
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == true)

        PlayerWindowChromePolicy.configurePlaybackPresentation(window, isCompact: false)

        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == false)
    }

    @Test func fullSizeContentWindowPreservesA240PointPlayerLayout() {
        let window = makeWindow(contentSize: CGSize(width: 800, height: 600))
        window.styleMask.insert(.fullSizeContentView)
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        #expect(titlebarHeight > 0)

        PlayerWindowChromePolicy.configurePlaybackPresentation(window, isCompact: true)

        #expect(
            window.minSize
                == CGSize(
                    width: CompactPlayerLayoutPolicy.minimumContentSize.width,
                    height: CompactPlayerLayoutPolicy.minimumContentSize.height + titlebarHeight
                )
        )
        window.setFrame(
            CGRect(origin: window.frame.origin, size: window.minSize),
            display: false
        )
        #expect(window.contentLayoutRect.size == CompactPlayerLayoutPolicy.minimumContentSize)
    }

    @Test func browsingRestoresRegularMinimumAndNativeWindowButtons() {
        let window = makeWindow(contentSize: CGSize(width: 427, height: 240))
        PlayerWindowChromePolicy.configurePlaybackPresentation(window, isCompact: true)

        PlayerWindowChromePolicy.configureBrowsingPresentation(window)

        #expect(window.contentMinSize == CGSize(width: 960, height: 640))
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == false)
    }

    @Test func playbackDismissalNeverMutatesTheNormalWindowFrame() {
        #expect(
            PlayerWindowLifecyclePolicy.dismissalAction(isFullScreen: false) == .none
        )
    }

    @Test func playbackDismissalStillExitsNativeFullScreen() {
        #expect(
            PlayerWindowLifecyclePolicy.dismissalAction(isFullScreen: true) == .exitFullScreen
        )
    }

    @Test func detailPresentationWaitsForPlayerWindowRestoration() async throws {
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
        appState.detailVod = Vod(vodId: "window-restore", vodName: "Window Restore")
        appState.isPlayerPresented = true

        appState.beginPlayerDismissalReturningToDetail()

        #expect(!appState.isPlayerPresented)
        #expect(!appState.isDetailPresented)
        #expect(appState.isDetailReturnPendingAfterPlayerExit)

        try await waitUntil { appState.isDetailPresented }

        #expect(appState.isDetailPresented)
        #expect(!appState.isDetailReturnPendingAfterPlayerExit)
    }

    @Test func staleWindowRestorationCannotCoverAReopenedPlayer() async throws {
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
        appState.detailVod = Vod(vodId: "reopened-player", vodName: "Reopened Player")
        appState.isPlayerPresented = true
        appState.beginPlayerDismissalReturningToDetail()

        appState.isPlayerPresented = true
        try await waitUntil { !appState.isDetailReturnPendingAfterPlayerExit }

        #expect(appState.isPlayerPresented)
        #expect(!appState.isDetailPresented)
        #expect(!appState.isDetailReturnPendingAfterPlayerExit)
    }

    @Test func playerWindowContextKeepsOnlyItsAttachedWeakWindow() {
        let context = PlayerWindowContext()
        let window = makeWindow()
        let unrelatedWindow = makeWindow()

        context.attach(window)
        #expect(context.window === window)
        #expect(!context.isFullScreen)

        context.updateFullScreenState(true, for: unrelatedWindow)
        #expect(!context.isFullScreen)

        context.updateFullScreenState(true, for: window)
        #expect(context.isFullScreen)

        context.detach(unrelatedWindow)
        #expect(context.window === window)
        #expect(context.isFullScreen)

        context.detach(window)
        #expect(context.window == nil)
        #expect(!context.isFullScreen)
    }

    @Test func playerWindowContextMeasuresTheUsableContentLayout() {
        let context = PlayerWindowContext()
        let window = makeWindow(contentSize: CGSize(width: 800, height: 600))
        window.styleMask.insert(.fullSizeContentView)

        context.attach(window)

        #expect(context.contentSize == window.contentLayoutRect.size)
        #expect(context.contentSize.height < window.contentView?.bounds.height ?? 0)
    }

    @Test func compactPinIsSessionLocalAndClearsAfterManualExpansion() {
        let context = PlayerWindowContext()
        let window = makeWindow(contentSize: CGSize(width: 427, height: 240))
        context.attach(window)

        #expect(context.isCompact)
        #expect(context.toggleAlwaysOnTop())
        #expect(context.isAlwaysOnTop)
        #expect(window.level == .floating)

        window.setContentSize(CGSize(width: 960, height: 640))
        context.updateWindowMetrics(for: window)

        #expect(!context.isCompact)
        #expect(!context.isAlwaysOnTop)
        #expect(window.level == .normal)
    }

    @Test func pinCannotBeEnabledOutsideCompactPlayback() {
        let context = PlayerWindowContext()
        let window = makeWindow(contentSize: CGSize(width: 960, height: 640))
        context.attach(window)

        #expect(!context.isCompact)
        #expect(!context.toggleAlwaysOnTop())
        #expect(window.level == .normal)
    }

    @Test func enteringFullScreenFromCompactPlaybackClearsFloatingLevel() {
        let context = PlayerWindowContext()
        let window = makeWindow(contentSize: CGSize(width: 427, height: 240))
        context.attach(window)
        #expect(context.toggleAlwaysOnTop())

        context.updateFullScreenState(true, for: window)
        window.setContentSize(CGSize(width: 1_440, height: 900))
        context.updateWindowMetrics(for: window)

        #expect(context.isFullScreen)
        #expect(!context.isCompact)
        #expect(!context.isAlwaysOnTop)
        #expect(window.level == .normal)
    }

    @Test func restoredFramePrefersLastRegularFrameAndClampsToVisibleScreen() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let restored = PlayerWindowPresentationPolicy.restoredWindowFrame(
            lastRegularFrame: CGRect(x: 900, y: 650, width: 1_000, height: 700),
            currentFrame: CGRect(x: 100, y: 100, width: 427, height: 240),
            fallbackFrameSize: CGSize(width: 960, height: 640),
            visibleFrame: visibleFrame
        )

        #expect(restored.size == CGSize(width: 1_000, height: 700))
        #expect(restored.minX >= visibleFrame.minX)
        #expect(restored.minY >= visibleFrame.minY)
        #expect(restored.maxX <= visibleFrame.maxX)
        #expect(restored.maxY <= visibleFrame.maxY)
    }

    @Test func restoredFrameFallsBackToRegularSizeAroundCurrentCenter() {
        let restored = PlayerWindowPresentationPolicy.restoredWindowFrame(
            lastRegularFrame: nil,
            currentFrame: CGRect(x: 500, y: 400, width: 427, height: 240),
            fallbackFrameSize: CGSize(width: 960, height: 640),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        #expect(restored.size == CGSize(width: 960, height: 640))
        #expect(restored.midX == 500 + 427.0 / 2)
        #expect(restored.midY == 400 + 240.0 / 2)
    }

    @Test func windowPreferenceRestoresNormalizedPositionAcrossScreenSizes() throws {
        let captured = try #require(PlayerWindowPreferencePolicy.capturedPreference(
            frame: CGRect(x: 900, y: 450, width: 800, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_800, height: 1_000),
            screenIdentifier: 7
        ))
        let restored = try #require(PlayerWindowPreferencePolicy.restoredFrame(
            preference: captured,
            visibleFrame: CGRect(x: 100, y: 50, width: 1_200, height: 800),
            minimumSize: CGSize(width: 600, height: 400)
        ))

        #expect(restored.size == CGSize(width: 800, height: 500))
        #expect(restored.minX >= 100)
        #expect(restored.minY >= 50)
        #expect(restored.maxX <= 1_300)
        #expect(restored.maxY <= 850)
        #expect(captured.screenIdentifier == 7)
    }

    @Test func windowPreferenceStorePersistsSanitizesAndResets() throws {
        let suiteName = "NetVplayer.WindowPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "window"
        let store = PlayerWindowPreferenceStore(defaults: defaults, storageKey: key)
        store.save(
            frame: CGRect(x: 100, y: 80, width: 960, height: 640),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            screenIdentifier: 3
        )

        let restoredStore = PlayerWindowPreferenceStore(defaults: defaults, storageKey: key)
        #expect(restoredStore.preference?.frameWidth == 960)
        #expect(restoredStore.preference?.frameHeight == 640)
        #expect(restoredStore.preference?.screenIdentifier == 3)

        restoredStore.reset()
        #expect(restoredStore.preference == nil)
        #expect(defaults.data(forKey: key) == nil)

        let unsupported = PlayerWindowPreference(
            schemaVersion: 99,
            frameWidth: 960,
            frameHeight: 640,
            normalizedCenterX: 0.5,
            normalizedCenterY: 0.5,
            screenIdentifier: nil
        )
        defaults.set(try JSONEncoder().encode(unsupported), forKey: key)
        #expect(PlayerWindowPreferenceStore(defaults: defaults, storageKey: key).preference == nil)
    }

    @Test func windowPreferencePolicyRejectsInvalidAndClampsOversizedValues() throws {
        #expect(PlayerWindowPreferencePolicy.capturedPreference(
            frame: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 640),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            screenIdentifier: nil
        ) == nil)

        let preference = PlayerWindowPreference(
            frameWidth: 50_000,
            frameHeight: 40_000,
            normalizedCenterX: 2,
            normalizedCenterY: -1,
            screenIdentifier: nil
        )
        let restored = try #require(PlayerWindowPreferencePolicy.restoredFrame(
            preference: preference,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            minimumSize: CGSize(width: 600, height: 400)
        ))
        #expect(restored == CGRect(x: 0, y: 0, width: 1_200, height: 800))
    }

    @Test func windowPreferenceStoreIgnoresCorruptDataAndInvalidSaves() throws {
        let suiteName = "NetVplayer.WindowPreferenceCorruptTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "window"
        defaults.set(Data("not-json".utf8), forKey: key)
        let store = PlayerWindowPreferenceStore(defaults: defaults, storageKey: key)
        #expect(store.preference == nil)

        store.save(
            frame: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 640),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            screenIdentifier: nil
        )
        #expect(store.preference == nil)
    }

    @Test func playerWindowContextRestoresAndProtectsRegularPreference() throws {
        let suiteName = "NetVplayer.WindowContextPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlayerWindowPreferenceStore(defaults: defaults, storageKey: "window")
        let screen = try #require(NSScreen.main)
        store.save(
            frame: CGRect(
                x: screen.visibleFrame.midX - 500,
                y: screen.visibleFrame.midY - 350,
                width: 1_000,
                height: 700
            ),
            visibleFrame: screen.visibleFrame,
            screenIdentifier: PlayerWindowPreferenceStore.screenIdentifier(for: screen)
        )
        let context = PlayerWindowContext(preferenceStore: store)
        let window = makeWindow(contentSize: CGSize(width: 600, height: 400))

        context.attach(window)
        let expectedWidth = min(CGFloat(1_000), screen.visibleFrame.width)
        let expectedHeight = min(CGFloat(700), screen.visibleFrame.height)
        #expect(window.frame.width >= expectedWidth)
        #expect(window.frame.height >= expectedHeight)
        #expect(window.frame.width <= screen.visibleFrame.width)
        #expect(window.frame.height <= screen.visibleFrame.height)
        let restoredSaved = try #require(store.preference)

        window.setContentSize(CompactPlayerLayoutPolicy.minimumContentSize)
        context.updateWindowMetrics(for: window)
        #expect(store.preference == restoredSaved)

        context.updateFullScreenState(true, for: window)
        window.setFrame(screen.visibleFrame, display: false)
        context.updateWindowMetrics(for: window)
        #expect(store.preference == restoredSaved)
    }

    @Test func vodAndLiveWindowPreferencesRemainIndependent() throws {
        let suiteName = "NetVplayer.WindowScopeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let main = PlayerWindowPreferenceStore(defaults: defaults, storageKey: "main")
        let live = PlayerWindowPreferenceStore(defaults: defaults, storageKey: "live")
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        main.save(
            frame: CGRect(x: 100, y: 100, width: 1_000, height: 700),
            visibleFrame: visible,
            screenIdentifier: 1
        )
        live.save(
            frame: CGRect(x: 300, y: 200, width: 800, height: 500),
            visibleFrame: visible,
            screenIdentifier: 1
        )

        #expect(main.preference?.frameWidth == 1_000)
        #expect(live.preference?.frameWidth == 800)
        main.reset()
        live.reset()
        #expect(main.preference == nil)
        #expect(live.preference == nil)
    }

    private func makeWindow(contentSize: CGSize = CGSize(width: 320, height: 180)) -> NSWindow {
        NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
