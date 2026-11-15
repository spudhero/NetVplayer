import Foundation
import Testing
import Diagnostics
import Storage
import Models
@testable import NetVplayerApp

@Suite(.serialized) @MainActor
struct StartupCoordinatorTests {
    private enum Failure: Error { case expected }

    private func store() -> StartupSessionStore {
        StartupSessionStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("ov87-unit-\(UUID())/session.json"))
    }

    @Test func interruptedFactoryIsDetectedBeforeAnyBusinessConstruction() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try store.write(.starting, recoveryPending: false)
        var constructions = 0
        let startup = StartupCoordinator<Int>(store: store, factory: { _ in constructions += 1; return 1 }, cleanup: { _ in })
        startup.prepare()
        startup.startIfNeeded()
        startup.prepare() // App + delegate + each reopened root may repeat this.
        #expect(startup.phase == .recovery)
        #expect(startup.runtime == nil)
        #expect(constructions == 0)
        #expect(!startup.diagnostics.crashedLastRun)
        #expect(await startup.terminate().value)
        #expect(try store.needsRecovery()) // Quitting does not silently accept recovery.
    }

    @Test func confirmedSDKCrashAlsoRecoversAfterACleanMarker() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try store.write(.clean, recoveryPending: false)
        let startup = StartupCoordinator<Int>(store: store,
            startDiagnostics: { .init(state: .active, crashedLastRun: true) },
            factory: { _ in Issue.record("must not initialize"); return 0 }, cleanup: { _ in })
        startup.prepare()
        #expect(startup.phase == .recovery)
        #expect(startup.diagnostics.crashedLastRun)
    }

    @Test func repeatedChoicesCreateOnceAndCleanExitResolvesRecovery() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try store.write(.ready, recoveryPending: false)
        var choices: [StartupRestorationChoice] = []
        var stops = 0, synchronousSnapshots = 0
        let startup = StartupCoordinator<Int>(store: store, factory: { choices.append($0); return 42 },
            cleanup: { _ in #expect(synchronousSnapshots == 1); stops += 1 },
            onTerminationRequested: { _ in synchronousSnapshots += 1 })
        startup.start(.deferRestoration)
        startup.start(.restore)
        startup.startIfNeeded()
        await startup.waitForStartup()
        #expect(choices == [.deferRestoration])
        #expect(startup.runtime == 42 && startup.phase == .ready)
        let first = startup.terminate(), repeated = startup.terminate()
        #expect(synchronousSnapshots == 1) // Before SwiftUI observes terminating/removes playback.
        #expect(await first.value)
        #expect(await repeated.value)
        #expect(stops == 1 && startup.phase == .stopped)
        #expect(try !store.needsRecovery())
    }

    @Test func freshRunRestoresAndFactoryFailureNeverBecomesReady() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var readyCalls = 0
        let startup = StartupCoordinator<Int>(store: store, factory: { choice in
            #expect(choice == .restore)
            throw Failure.expected
        }, cleanup: { _ in Issue.record("no runtime exists") }, onReady: { _ in readyCalls += 1 })
        startup.startIfNeeded()
        await startup.waitForStartup()
        #expect(startup.phase == .failed && startup.failure != nil && startup.runtime == nil)
        #expect(readyCalls == 0)
        #expect(await startup.terminate().value)
        #expect(try store.needsRecovery())
    }

    @Test func validationFailureRetainsRuntimeForCleanup() async {
        var stops = 0
        let startup = StartupCoordinator<Int>(store: nil, factory: { _ in 9 },
            validate: { _ in throw Failure.expected }, cleanup: { _ in stops += 1 })
        startup.startIfNeeded()
        await startup.waitForStartup()
        #expect(startup.phase == .failed && startup.runtime == 9)
        #expect(await startup.terminate().value)
        #expect(stops == 1)
    }

    @Test func lateFactoryResultDuringQuitIsCleanedWithoutBecomingReady() async {
        let gate = StartupTestGate()
        var stops = 0, readyCalls = 0
        let startup = StartupCoordinator<Int>(store: nil, factory: { _ in await gate.wait(); return 7 },
            cleanup: { value in #expect(value == 7); stops += 1 }, onReady: { _ in readyCalls += 1 })
        startup.startIfNeeded()
        while !gate.isWaiting { await Task.yield() }
        let quit = startup.terminate()
        #expect(startup.phase == .terminating)
        startup.start(.restore)
        gate.release()
        #expect(await quit.value)
        #expect(readyCalls == 0 && stops == 1 && startup.runtime == nil)
    }

    @Test func quitBeforeFactoryBeginsDoesNotConstructRuntime() async {
        var constructions = 0
        let startup = StartupCoordinator<Int>(store: nil, factory: { _ in constructions += 1; return 0 }, cleanup: { _ in })
        startup.startIfNeeded()
        #expect(await startup.terminate().value)
        #expect(constructions == 0)
    }

    @Test func cleanupWaitsForCompletionAndFailureRemainsVisibleUntilRetry() async {
        let gate = StartupTestGate()
        var attempts = 0
        let startup = StartupCoordinator<Int>(store: nil, factory: { _ in 1 }, cleanup: { _ in
            attempts += 1
            if attempts == 1 { await gate.wait(); throw Failure.expected }
        })
        startup.startIfNeeded()
        await startup.waitForStartup()
        let quit = startup.terminate()
        while !gate.isWaiting { await Task.yield() }
        #expect(startup.phase == .terminating && startup.runtime != nil)
        gate.release()
        #expect(await !quit.value)
        #expect(startup.phase == .terminationFailed && startup.failure != nil)
        #expect(await startup.terminate().value)
        #expect(attempts == 2 && startup.phase == .stopped)
    }

    @Test func boundedFileQueueDeduplicatesAndCannotBeConsumedBeforeReady() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try store.write(.starting, recoveryPending: false)
        let startup = StartupCoordinator<Int>(store: store, factory: { _ in 1 }, cleanup: { _ in })
        let files = (0..<12).map { URL(fileURLWithPath: "/tmp/fixture-\($0).mkv") }
        startup.enqueue([files[0], files[0], URL(string: "https://example.test/media")!])
        startup.prepare()
        startup.enqueue(files)
        #expect(startup.pendingFiles == Array(files.prefix(8)))
        #expect(startup.rejectedFileCount == 5)
        #expect(startup.takeFile(files[0]) == nil)
        startup.start(.deferRestoration)
        await startup.waitForStartup()
        #expect(startup.takeFile(files[0]) == files[0])
        #expect(startup.takeFile(files[0]) == nil)
        startup.discardFiles()
        #expect(startup.pendingFiles.isEmpty)
        #expect(await startup.terminate().value)
        startup.enqueue(files)
        #expect(startup.pendingFiles.isEmpty)
    }

    @Test func malformedMarkerAndStorageFailureDoNotBypassRecovery() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try store.write(.clean, recoveryPending: false)
        try Data("not-json".utf8).write(to: store.url)
        #expect(try store.needsRecovery())
        let invalidStore = StartupSessionStore(url: store.url.appendingPathComponent("child.json"))
        let startup = StartupCoordinator<Int>(store: invalidStore, factory: { _ in Issue.record("unsafe start"); return 0 }, cleanup: { _ in })
        startup.startIfNeeded()
        #expect(startup.phase == .failed)
        #expect(await startup.terminate().value) // Disk failure must not make quitting impossible.
    }

    @Test func deferredAppStateDoesNotScheduleProviderOrConfigAndPreservesPreferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ov87-state-\(UUID())")
        let suite = "ov87-state-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let prefs = UserPreferences(defaults: defaults)
        prefs.currentVodConfigUrl = "https://saved.example.test/config.json"
        var registrations = 0, synchronizations = 0
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            startProviderRuntime: false, deferStartupRestoration: true,
            storageManager: StorageManager(storageDirectory: directory), userPreferences: prefs,
            providerRuntimeBootstrap: nil,
            providerRuntimeRegistrationOverride: { registrations += 1; return false },
            providerRuntimeStartupOverride: { synchronizations += 1; return false })
        await Task.yield()
        #expect(state.initialConfigTask == nil && state.providerRuntimeStartupTask == nil)
        #expect(registrations == 0 && synchronizations == 0 && state.sites.isEmpty)
        #expect(prefs.currentVodConfigUrl == "https://saved.example.test/config.json")
        state.restoreDeferredStartup()
        state.restoreDeferredStartup()
        await state.initialConfigTask?.value
        #expect(registrations == 1 && synchronizations == 1)
        #expect(!state.startupRestorationDeferred)
        try await state.prepareForApplicationTermination()
    }
}

@MainActor private final class StartupTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
