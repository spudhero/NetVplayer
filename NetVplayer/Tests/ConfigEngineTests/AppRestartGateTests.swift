import Foundation
import Testing
import AppKit
@testable import NetVplayerApp

@Suite(.serialized) @MainActor
struct AppRestartGateTests {
    @Test func ownersExcludeEachOtherAndOldReleaseCannotUnlockNewOwner() throws {
        let gate = AppRestartGate()
        let update = try #require(gate.acquire(.update))
        #expect(gate.acquire(.language) == nil)
        #expect(gate.acquire(.update) == nil)
        gate.release(update)
        let language = try #require(gate.acquire(.language))
        gate.release(update)
        #expect(gate.owns(language))
    }

    @Test func duplicatePreparationJoinsAndDeliveryIsExactlyOnce() async throws {
        let gate = AppRestartGate(), latch = RestartTestLatch()
        let lease = try #require(gate.acquire(.update))
        var cleanups = 0, deliveries = 0
        let cleanup: @MainActor () async -> Bool = { cleanups += 1; await latch.wait(); return true }
        let first = Task { await gate.prepare(lease, cleanup: cleanup) }
        while !latch.waiting { await Task.yield() }
        let second = Task { await gate.prepare(lease, cleanup: cleanup) }
        for _ in 0..<10 { await Task.yield() }
        #expect(!gate.deliver(lease) { deliveries += 1 })
        #expect(cleanups == 1 && deliveries == 0)
        latch.release()
        #expect(await first.value)
        #expect(await second.value)
        #expect(gate.deliver(lease) { deliveries += 1 })
        #expect(!gate.deliver(lease) { deliveries += 1 })
        #expect(deliveries == 1)
    }

    @Test func cancellationRejectsLateCleanupAndDoesNotReleaseSuccessor() async throws {
        let gate = AppRestartGate(), latch = RestartTestLatch()
        let old = try #require(gate.acquire(.update))
        let preparation = Task { await gate.prepare(old) { await latch.wait(); return true } }
        while !latch.waiting { await Task.yield() }
        gate.release(old)
        let new = try #require(gate.acquire(.language))
        latch.release()
        #expect(await !preparation.value)
        #expect(!gate.deliver(old) { Issue.record("stale SDK continuation") })
        #expect(gate.owns(new))
    }

    @Test func failureIsRetryableAndNeverDeliversBeforeSuccess() async throws {
        let gate = AppRestartGate()
        let lease = try #require(gate.acquire(.update))
        #expect(await !gate.prepare(lease) { false })
        #expect(!gate.deliver(lease) { Issue.record("failed cleanup") })
        #expect(await gate.prepare(lease) { true })
        #expect(gate.deliver(lease) {})
    }

    @Test func languageHelperWaitsForActualStartupCleanupAndFailedAttemptReleasesOwner() async throws {
        let gate = AppRestartGate(), latch = RestartTestLatch()
        var attempts = 0, helpers = 0, quits = 0
        enum Failure: Error { case expected }
        let startup = StartupCoordinator<Int>(store: nil, factory: { _ in 1 }, cleanup: { _ in
            attempts += 1
            if attempts == 1 { await latch.wait(); throw Failure.expected }
        })
        startup.startIfNeeded()
        await startup.waitForStartup()
        let language = AppRelaunchCoordinator(gate: gate, cleanup: { await startup.terminate().value },
            launchHelper: { helpers += 1 }, terminate: { quits += 1 })
        try language.relaunch()
        #expect(throws: (any Error).self) { try language.relaunch() }
        while !latch.waiting { await Task.yield() }
        #expect(gate.acquire(.update) == nil && helpers == 0 && quits == 0)
        for _ in 0..<20 { await Task.yield() }
        #expect(startup.phase == .terminating && helpers == 0)
        latch.release()
        await language.waitForRelaunch()
        #expect(startup.phase == .terminationFailed && language.failure != nil)
        #expect(helpers == 0 && quits == 0 && gate.lease == nil)
        try language.relaunch()
        await language.waitForRelaunch()
        #expect(startup.phase == .stopped && language.helperScheduled)
        #expect(helpers == 1 && quits == 1 && attempts == 2)
    }

    @Test func helperLaunchFailureRemainsVisibleAndCanRetry() async throws {
        enum Failure: Error { case expected }
        let gate = AppRestartGate()
        var attempts = 0, quits = 0, failurePresentations = 0
        let language = AppRelaunchCoordinator(gate: gate, cleanup: { true }, launchHelper: {
            attempts += 1
            if attempts == 1 { throw Failure.expected }
        }, terminate: { quits += 1 }, showFailure: { failurePresentations += 1 })
        try language.relaunch()
        await language.waitForRelaunch()
        #expect(language.failure != nil && gate.lease == nil && !language.helperScheduled && quits == 0)
        #expect(failurePresentations == 1)
        try language.relaunch()
        await language.waitForRelaunch()
        #expect(attempts == 2 && quits == 1)
    }

    @Test func stoppedRuntimeCanReopenFailureWithoutReinitializingBusiness() async {
        _ = NSApplication.shared
        var constructions = 0, sceneOpens = 0
        let startup = AppStartupCoordinator(store: nil, factory: { _ in
            constructions += 1
            throw NSError(domain: "unused", code: 1)
        }, cleanup: { _ in })
        #expect(await startup.terminate().value)
        let windows = NetVplayerWindowCoordinator(startup: startup, canPresentStopped: { true })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        windows.registerMainWindow(window) { sceneOpens += 1; window.makeKeyAndOrderFront(nil) }
        windows.showMainWindow()
        window.close()
        windows.showMainWindow()
        #expect(sceneOpens == 2 && constructions == 0 && startup.phase == .stopped)
    }

    @Test func automaticRemindersRequireEverySafeCondition() {
        let ready = AppUpdatePresentationContext(startupReady: true, playbackActive: false,
            applicationActive: true, visibleWindow: true, fullScreen: false, modal: false)
        #expect(ready.permitsAutomaticReminder)
        for flag in 0..<6 {
            var blocked = ready
            switch flag {
            case 0: blocked.startupReady = false
            case 1: blocked.playbackActive = true
            case 2: blocked.applicationActive = false
            case 3: blocked.visibleWindow = false
            case 4: blocked.fullScreen = true
            default: blocked.modal = true
            }
            #expect(!blocked.permitsAutomaticReminder)
        }
    }
}

@MainActor private final class RestartTestLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
