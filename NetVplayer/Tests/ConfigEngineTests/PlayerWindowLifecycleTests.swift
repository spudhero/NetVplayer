import AppKit
import Combine
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

        #expect(window.contentMinSize == CompactPlayerLayoutPolicy.minimumContentSize)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == true)

        PlayerWindowChromePolicy.configurePlaybackPresentation(window, isCompact: false)

        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == false)
    }

    @Test func fullSizeContentWindowPreservesMinimumPlayerLayout() {
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

    @Test func detailIsReadyBeforePlayerPresentationEnds() async {
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
        appState.detailVod = Vod(vodId: "window-restore", vodName: "Window Restore")
        appState.isPlayerPresented = true
        var sawPlayerDismissal = false
        let observation = appState.$isPlayerPresented.dropFirst().sink { presented in
            guard !presented else { return }
            sawPlayerDismissal = true
            #expect(appState.isDetailPresented)
        }
        defer { observation.cancel() }

        appState.beginPlayerDismissalReturningToDetail()

        #expect(!appState.isPlayerPresented)
        #expect(appState.isDetailPresented)
        #expect(sawPlayerDismissal)
        await appState.waitForPlayerDismissalCleanup()
        #expect(appState.isDetailPresented)
    }

    @Test func dismissalCleanupCannotCoverOrCancelAReopenedPlayer() async {
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
        appState.detailVod = Vod(vodId: "reopened-player", vodName: "Reopened Player")
        appState.isPlayerPresented = true
        appState.beginPlayerDismissalReturningToDetail()

        appState.isDetailPresented = false
        appState.isPlayerPresented = true
        appState.isPlayerLoading = true
        await appState.waitForPlayerDismissalCleanup()

        #expect(appState.isPlayerPresented)
        #expect(appState.isPlayerLoading)
        #expect(!appState.isDetailPresented)
    }

    @Test func dismissalCleanupCannotReopenAClosedDetail() async {
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
        appState.detailVod = Vod(vodId: "closed-detail", vodName: "Closed Detail")
        appState.isPlayerPresented = true
        appState.beginPlayerDismissalReturningToDetail()

        appState.isDetailPresented = false
        await appState.waitForPlayerDismissalCleanup()

        #expect(!appState.isDetailPresented)
        #expect(!appState.isPlayerPresented)
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

    @Test func unchangedRegularWindowMetricsDoNotInvalidatePlayerViews() {
        let context = PlayerWindowContext()
        let window = makeWindow(contentSize: CGSize(width: 960, height: 640))
        context.attach(window)
        var changes = 0
        let subscription = context.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        for _ in 0..<3 {
            context.attach(window)
            context.updateWindowMetrics(for: window)
        }
        #expect(changes == 0)

        window.setContentSize(CGSize(width: 1_100, height: 700))
        context.updateWindowMetrics(for: window)
        #expect(changes > 0)
        let settledChanges = changes
        context.attach(window)
        context.updateWindowMetrics(for: window)
        #expect(changes == settledChanges)
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
        _ = NSApplication.shared
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
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

    @Test func floatingWindowReusesAttachedWindowAndRestoresItsRegularFrame() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let context = PlayerWindowContext()
        #expect(!context.enterFloatingWindow())
        let window = makeWindow(contentSize: CGSize(width: 1100, height: 700))
        let frame = CGRect(x: screen.visibleFrame.midX - window.frame.width / 2,
                           y: screen.visibleFrame.midY - window.frame.height / 2,
                           width: window.frame.width, height: window.frame.height)
        window.setFrame(frame, display: false)
        context.attach(window)
        let originalAspect = window.contentAspectRatio
        let originalIncrements = window.contentResizeIncrements
        context.updateVideoAspectRatio(2.39)
        #expect(context.enterFloatingWindow())
        #expect(context.window === window)
        #expect(context.isCompact && context.isAlwaysOnTop)
        #expect(window.level == .floating)
        let videoSize = window.contentRect(forFrameRect: window.frame).size
        #expect(abs(videoSize.width - 480) < 1)
        #expect(abs(videoSize.width / videoSize.height - 2.39) < 0.01)
        #expect(screen.visibleFrame.contains(window.frame))
        #expect(context.toggleAlwaysOnTop())
        #expect(!context.isAlwaysOnTop && window.level == .normal)
        #expect(context.restoreRegularWindow())
        #expect(!context.isCompact && !context.isAlwaysOnTop)
        #expect(window.level == .normal)
        #expect(window.frame.size == frame.size)
        #expect(window.contentAspectRatio == originalAspect)
        #expect(window.contentResizeIncrements == originalIncrements)
        // Restoring normalizes the origin to whole screen points.
        #expect(abs(window.frame.minX - frame.minX) <= 1)
        #expect(abs(window.frame.minY - frame.minY) <= 1)
        context.detach(window)
    }

    @Test func repeatedFloatingRequestsKeepOriginalRestoreFrameAndDetachClearsPin() throws {
        _ = NSApplication.shared
        let context = PlayerWindowContext()
        let window = makeWindow(contentSize: CGSize(width: 1100, height: 700))
        window.center()
        context.attach(window)
        let frame = window.frame
        #expect(context.enterFloatingWindow())
        #expect(context.enterFloatingWindow())
        #expect(context.restoreRegularWindow())
        #expect(window.frame == frame)
        #expect(context.enterFloatingWindow())
        context.detach(window)
        #expect(window.level == .normal)
        #expect(!context.isAlwaysOnTop)
        #expect(!context.enterFloatingWindow())
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

}
