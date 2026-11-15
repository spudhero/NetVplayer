import AppKit
import SwiftUI
import Foundation
import Sparkle
import Storage
import Models
@testable import PlayerEngine
@testable import NetVplayerApp

@main struct UpdateNativeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = UpdateNativeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        _ = delegate
    }
}

@MainActor final class ProbeLatch {
    var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class UpdateNativeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    var checks: [String: Bool] = [:]
    var windows: [NSWindow] = []
    var coordinator: AppUpdateCoordinator?
    var engine: MPVPlayerEngine?
    var sdkWindows: [String] = []
    var fullScreenEntered = false
    var fullScreenExited = false

    func windowDidEnterFullScreen(_ notification: Notification) { fullScreenEntered = true }
    func windowDidExitFullScreen(_ notification: Notification) { fullScreenExited = true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do { try await verify(); finish("passed") }
            catch { finish("failed", error: String(describing: error)) }
        }
    }
    func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw NSError(domain: "UpdateNativeProbe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: name]) }
        checks[name] = true
    }
    func wait(_ predicate: () -> Bool, seconds: Double = 15) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard predicate() else { throw NSError(domain: "UpdateNativeProbe", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "wait timed out, windows=\(NSApp.windows.map(\.title)) phase=\(String(describing: coordinator?.phase))"]) }
    }
    func window(_ title: String, size: NSSize, content: NSView) -> NSWindow {
        let w = NSWindow(contentRect: .init(x: 240, y: 150, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = title; w.isReleasedWhenClosed = false; w.contentView = content
        w.delegate = self
        w.collectionBehavior.insert(.fullScreenPrimary)
        windows.append(w); w.makeKeyAndOrderFront(nil)
        return w
    }
    func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
    func buttons(_ view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
    }
    func verify() async throws {
        let suite = "com.netvplayer.update-native." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ProbeLatch()
        var cleanupAttempts = 0
        let startup = StartupCoordinator<AppState>(store: nil, factory: { _ in
            AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: true,
                storageManager: StorageManager(storageDirectory: self.output.appendingPathComponent("profile")),
                userPreferences: UserPreferences(defaults: defaults), providerRuntimeBootstrap: nil,
                providerRuntimeRegistrationOverride: { await provider.wait(); return true },
                providerRuntimeStartupOverride: { true })
        }, cleanup: { state in
            cleanupAttempts += 1
            if let engine = self.engine { await engine.stopAndWaitForRetirement() }
            try await state.prepareForApplicationTermination()
            if cleanupAttempts == 1 { throw NSError(domain: "InjectedCleanupFailure", code: 1) }
        }, onTerminationRequested: { $0.beginApplicationTermination() })
        startup.startIfNeeded(); await startup.waitForStartup()
        try await wait { provider.waiting }
        let state = startup.runtime!
        let audio = PlaybackAudioPreferenceStore(defaults: defaults); audio.setMuted(true)
        let e = MPVPlayerEngine(videoSurface: .vod, audioPreferences: audio,
            audioOutputPreferences: .init(defaults: defaults), dialoguePreferences: .init(defaults: defaults),
            colorPreferences: .init(defaults: defaults))
        engine = e; e.playerState = state.playerState
        guard let video = MPVOpenGLVideoView(engine: e, surface: .vod) else { throw NSError(domain: "video", code: 1) }
        let w = window("OV87-08 isolated playback", size: .init(width: 640, height: 360), content: video)
        await e.play(spec: PlaySpec(url: output.appendingPathComponent("fixture.mp4").absoluteString, title: "Original fixture"))
        try await wait { state.playerState.position > 0.2 }
        try require(state.playerState.isPlaying, "real libmpv playback started")
        var clock = Date(timeIntervalSince1970: 1000)
        var ready = true, playing = false
        var failurePresentations = 0
        let gate = AppRestartGate()
        let c = AppUpdateCoordinator(gate: gate, defaults: defaults, context: {
            AppUpdatePresentationContext.capture(startupReady: ready, playbackActive: playing)
        }, cleanup: { await startup.terminate().value }, now: { clock }, showFailure: {
            failurePresentations += 1; w.makeKeyAndOrderFront(nil)
        })
        coordinator = c; c.start(pollAutomatically: false)
        guard let updater = c.controller?.updater else { throw NSError(domain: "sdk", code: 1) }
        if !updater.canCheckForUpdates { try updater.start() } // Preserve the SDK's exact setup error in evidence.
        try require(updater.canCheckForUpdates, "Sparkle start succeeds: \(c.phase)")
        for selector in ["updater:mayPerformUpdateCheck:error:",
                         "updaterShouldPromptForPermissionToCheckForUpdates:",
                         "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
                         "updaterShouldRelaunchApplication:",
                         "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
                         "standardUserDriverWillHandleShowingUpdate:forUpdate:state:"] {
            try require(c.responds(to: NSSelectorFromString(selector)), "SDK selector " + selector)
        }
        try require(!updater.automaticallyChecksForUpdates, "single daily information scheduler")
        // Actual Sparkle URLSession + temporary Ed25519-signed loopback feed; no archive is downloaded.
        c.checkForUpdateInformation()
        try await wait { !c.isCheckingInformation && c.latestAvailable != nil && !updater.sessionInProgress }
        try require(!c.hasNewVersion, "launch grace suppresses reminder")
        clock = clock.addingTimeInterval(31); c.refreshReminder()
        try require(c.hasNewVersion, "idle native window permits badge")
        playing = true; c.refreshReminder()
        try require(!c.hasNewVersion, "playback including paused session suppresses badge")
        // Explicit manual entry uses the real Sparkle user driver even during playback.
        c.checkForUpdates()
        try await wait { NSApp.windows.contains {
            $0.isVisible && self.buttons($0.contentView).contains { $0.title.contains("Later") }
        } }
        let alerts = NSApp.windows.filter { !windows.contains($0) && $0.isVisible }
        sdkWindows = alerts.map(\.title)
        if let content = alerts.first?.contentView { try capture(content, name: "native-sparkle-manual.png") }
        try require(gate.lease?.owner == .update, "manual Sparkle check owns update restart")
        try require(gate.acquire(.language) == nil, "language restart excluded during real SDK session")
        for alert in alerts {
            if let button = buttons(alert.contentView).first(where: { $0.title.contains("Later") }) {
                button.performClick(nil)
            } else { alert.performClose(nil) }
        }
        try await wait { !updater.sessionInProgress && gate.lease == nil }
        try await wait { !NSApp.windows.contains { !self.windows.contains($0) && $0.isVisible } }
        try require(gate.lease == nil, "real SDK dismiss releases restart owner")
        playing = false; c.refreshReminder()
        w.toggleFullScreen(nil)
        try await wait { fullScreenEntered }
        c.refreshReminder(); try require(!c.hasNewVersion, "native full screen suppresses badge")
        w.toggleFullScreen(nil)
        try await wait { fullScreenExited }
        let sheet = NSPanel(contentRect: .init(x: 0, y: 0, width: 240, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        w.beginSheet(sheet, completionHandler: { _ in }); c.refreshReminder()
        try require(!c.hasNewVersion, "native attached sheet suppresses badge")
        w.endSheet(sheet); sheet.orderOut(nil)
        w.miniaturize(nil)
        try await wait { w.isMiniaturized }
        c.refreshReminder()
        try require(!c.hasNewVersion, "native minimization suppresses badge")
        w.deminiaturize(nil)
        try await wait { !w.isMiniaturized && w.isVisible }
        w.makeKeyAndOrderFront(nil)
        ready = false; c.refreshReminder()
        try require(!c.hasNewVersion, "startup and recovery suppress badge")
        ready = true
        let item = SUAppcastItem(dictionary: ["sparkle:version": "2", "sparkle:shortVersionString": "2.0",
            "enclosure": ["url": "http://127.0.0.1/fixture.zip", "sparkle:version": "2", "length": "1"]])!
        try require(!c.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: true),
                    "automatic SDK alert never steals focus")
        var callbacks = 0
        try require(!c.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: { callbacks += 100 }),
                    "stale install callback after cancellation cannot reacquire restart ownership")
        c.checkForUpdates()
        try await wait { gate.lease?.owner == .update && NSApp.windows.contains {
            $0.isVisible && self.buttons($0.contentView).contains { $0.title.contains("Later") }
        } }
        _ = c.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: { callbacks += 1 })
        let status = NSHostingView(rootView: AppUpdateStatusView(updates: c).padding(20).frame(width: 380, height: 220))
        w.contentView = status; w.setContentSize(.init(width: 380, height: 220))
        try capture(status, name: "native-update-ready.png")
        c.installNow(); c.installNow()
        _ = c.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: { callbacks += 100 })
        try await wait { startup.phase == .terminating && !state.playerState.isPlaying }
        try require(callbacks == 0 && provider.waiting, "install waits for actual engine retirement and held Provider task")
        try require(gate.acquire(.language) == nil, "cleanup retains update restart ownership")
        w.close(); w.makeKeyAndOrderFront(nil)
        try require(c.isPreparingInstallation && callbacks == 0, "close and reopen cannot bypass held cleanup")
        w.close()
        provider.release()
        try await wait { c.restartFailure != nil }
        try require(startup.phase == .terminationFailed && callbacks == 0, "cleanup failure stays visible and never installs")
        try require(w.isVisible && failurePresentations == 1, "failed cleanup reopens its closed status window")
        try capture(status, name: "native-update-cleanup-failed.png")
        c.installNow(); c.installNow()
        try await wait { callbacks == 1 }
        try require(startup.phase == .stopped && cleanupAttempts == 2 && callbacks == 1,
                    "retry succeeds after actual cleanup and invokes continuation once")
        c.installNow(); try require(callbacks == 1, "consumed install continuation cannot run twice")
        var relaunchCallbacks = 0
        _ = c.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { relaunchCallbacks += 1 })
        _ = c.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { relaunchCallbacks += 100 })
        try await wait { relaunchCallbacks == 1 }
        try require(cleanupAttempts == 2 && relaunchCallbacks == 1, "SDK postpone continuation joins completed cleanup and ignores duplicates")
        c.updater(updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: SUSparkleErrorDomain, code: 4008))
        try require(gate.lease?.owner == .update, "authorize later retains staged installer restart ownership")
        // Simulate the SDK ending/cancelling that cycle, then a stale callback from another updater.
        c.updater(updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: SUSparkleErrorDomain, code: 4007))
        let languageLease = gate.acquire(.language)!
        let other = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        c.updater(other.updater, didFinishUpdateCycleFor: .updates, error: nil)
        try require(gate.owns(languageLease), "old updater callback cannot release a successor language lease")
        gate.release(languageLease)
    }
    func finish(_ status: String, error: String? = nil) {
        let record: [String: Any] = ["status": status, "checks": checks, "error": error ?? NSNull(),
            "sparkleVersion": "2.10.0 (2064)", "sdkWindows": sdkWindows,
            "backingScale": windows.first?.backingScaleFactor ?? 0,
            "scope": "real signed loopback metadata and manual SDK UI/dismiss; synthetic staged install callbacks; actual local libmpv retirement and isolated AppState Provider cleanup; no production installation"]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-validation.json"))
        windows.forEach { $0.orderOut(nil) }
        NSApp.terminate(nil)
    }
}
