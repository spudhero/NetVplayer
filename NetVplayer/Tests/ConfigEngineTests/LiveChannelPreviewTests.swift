import AppKit
import LiveEngine
import Models
import Networking
import PlayerEngine
import SpiderEngine
import Storage
import Testing
@testable import NetVplayerApp

@MainActor struct LiveChannelPreviewTests {
    func channel(_ index: Int) -> Channel {
        Channel(name: "Channel \(index)", number: "\(index)", urls: ["https://preview.invalid/\(index).ts"])
    }
    func png(width: Int = 2, height: Int = 2) -> Data {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
    }
    func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "preview condition timed out")
    }

    @Test func manualRoundUsesVisibleOrderAndSharesOnePhysicalSlot() async throws {
        let probe = LivePreviewProbe(), budget = PlaybackBackgroundBudget()
        let store = LiveChannelPreviewStore(budget: budget, decode: probe.decode)
        let first = channel(1), next = channel(2), invisible = channel(3)
        store.setSource("source")
        store.setDemand(channel: first, owner: UUID(), priority: .init(tier: .visible, row: 9))
        store.setDemand(channel: next, owner: UUID(), priority: .init(tier: .visible, row: 1))
        store.setDemand(channel: invisible, owner: UUID(), priority: .nearby)
        #expect(probe.urls.isEmpty)
        store.refresh { PlaySpec(url: $0.currentUrl!) }
        try await wait { probe.urls.count == 1 }
        #expect(probe.urls == next.urls && store.activeCount == 1)
        let started = Date()
        probe.finish(png())
        try await wait { probe.urls.count == 2 }
        probe.finish(png())
        try await wait { !store.isRefreshing }
        let frame = try #require(store.frame(for: next))
        #expect(frame.capturedAt >= started && frame.capturedAt <= Date())
        #expect(probe.urls == [next.currentUrl!, first.currentUrl!] && store.cachedCount == 2)
        #expect(store.activeCount == 0)
    }

    @Test func sharedViewsWithdrawIndependentlyAndCancellationKeepsPhysicalSlot() async throws {
        let probe = LivePreviewProbe(), store = LiveChannelPreviewStore(budget: .init(), decode: { await probe.decode($0) })
        let a = channel(1), b = channel(2), owner = UUID(), other = UUID(), bOwner = UUID()
        store.setSource("A")
        store.setDemand(channel: a, owner: owner, priority: .visible)
        store.setDemand(channel: a, owner: other, priority: .visible)
        store.refresh { PlaySpec(url: $0.currentUrl!) }
        try await wait { probe.urls.count == 1 }
        store.setDemand(channel: a, owner: owner, priority: .inactive)
        probe.finish(png()); try await wait { !store.isRefreshing }
        #expect(store.frame(for: a) != nil)
        store.setDemand(channel: b, owner: bOwner, priority: .init(tier: .visible, row: -1))
        store.refresh { PlaySpec(url: $0.currentUrl!) }
        try await wait { probe.urls.count == 2 }
        store.setDemand(channel: b, owner: bOwner, priority: .inactive)
        #expect(store.activeCount == 1 && probe.urls.count == 2)
        probe.finish(png()); try await wait { probe.urls.count == 3 }
        #expect(store.frame(for: b) == nil)
        probe.finish(png()); try await wait { !store.isRefreshing }
        #expect(store.activeCount == 0)
    }

    @Test func sourceSwitchRejectsLateFramesAndOldFlightCannotReleaseNewSlot() async throws {
        let probe = LivePreviewProbe(), store = LiveChannelPreviewStore(budget: .init(), decode: probe.decode)
        let a = channel(1), b = channel(2)
        store.setSource("A"); store.setDemand(channel: a, owner: UUID(), priority: .visible)
        store.refresh { PlaySpec(url: $0.currentUrl!) }; try await wait { probe.urls.count == 1 }
        store.setSource("B"); store.setDemand(channel: b, owner: UUID(), priority: .visible)
        store.refresh { PlaySpec(url: $0.currentUrl!) }
        #expect(probe.urls.count == 1 && store.activeCount == 1)
        probe.finish(png()); await store.drain()
        #expect(store.cachedCount == 0 && store.activeCount == 0)
        store.refresh { PlaySpec(url: $0.currentUrl!) }; try await wait { probe.urls.count == 2 }
        probe.finish(png()); try await wait { !store.isRefreshing }
        #expect(store.frame(for: b) != nil && store.frame(for: a) == nil)
    }

    @Test func playbackWaitsForPhysicalRetirementAndBlocksNewRefreshes() async throws {
        let probe = LivePreviewProbe(), store = LiveChannelPreviewStore(budget: .init(), decode: probe.decode)
        let a = channel(1)
        store.setSource("A"); store.setDemand(channel: a, owner: UUID(), priority: .visible)
        store.refresh { PlaySpec(url: $0.currentUrl!) }; try await wait { probe.urls.count == 1 }
        let hold = store.beginPlayback()
        var playbackStarted = false
        let playback = Task { await store.drain(); playbackStarted = true }
        await Task.yield()
        store.refresh { PlaySpec(url: $0.currentUrl!) }
        #expect(!playbackStarted && store.activeCount == 1 && probe.urls.count == 1)
        probe.finish(png()); await playback.value
        #expect(playbackStarted && store.cachedCount == 0 && store.activeCount == 0)
        store.refresh { PlaySpec(url: $0.currentUrl!) }; #expect(!store.isRefreshing)
        store.endPlayback(hold)
        store.refresh { PlaySpec(url: $0.currentUrl!) }; try await wait { probe.urls.count == 2 }
        probe.finish(png()); await store.drain()
    }

    @Test func failuresKeepTimestampAndNeverExposeAuthenticatedTransportErrors() async throws {
        let data = png(), store = LiveChannelPreviewStore(budget: .init(), decode: { _ in data })
        let a = channel(1)
        store.setSource("A"); store.setDemand(channel: a, owner: UUID(), priority: .visible)
        store.refresh { PlaySpec(url: $0.currentUrl!) }; await store.drain()
        let before = try #require(store.frame(for: a))
        store.refresh { _ in throw NSError(domain: "https://user:secret@preview.invalid", code: 1) }; await store.drain()
        #expect(store.frame(for: a)?.capturedAt == before.capturedAt)
        #expect(store.error(for: a) == LivePreviewError.failed.errorDescription)
        #expect(store.message?.contains("secret") == false)
        store.refresh { PlaySpec(url: $0.currentUrl!) }; await store.drain()
        #expect(store.error(for: a) == nil)
    }

    @Test func windowAndPlaybackPressureCancelWithoutAutomaticNetworkRestart() async throws {
        let probe = LivePreviewProbe(), budget = PlaybackBackgroundBudget()
        let store = LiveChannelPreviewStore(budget: budget, decode: probe.decode), window = UUID()
        budget.updateWindow(window, visible: true)
        store.setSource("A"); store.setDemand(channel: channel(1), owner: UUID(), priority: .visible)
        store.refresh { PlaySpec(url: $0.currentUrl!) }; try await wait { probe.urls.count == 1 }
        budget.updateWindow(window, visible: false)
        try await wait { !store.isRefreshing }
        probe.finish(png()); await store.drain()
        budget.updateWindow(window, visible: true)
        await Task.yield(); #expect(probe.urls.count == 1 && store.cachedCount == 0)
        budget.update(session: "primary", bufferedAhead: 0, isLoading: true, isSeeking: false, isBuffering: false)
        store.refresh { PlaySpec(url: $0.currentUrl!) }
        #expect(!store.isRefreshing && probe.urls.count == 1 && store.message != nil)
        budget.remove(session: "primary")
    }

    @Test func boundedRoundAndLRUCacheRespectCountAndDecodedBytes() async throws {
        let data = png(), store = LiveChannelPreviewStore(budget: .init(), decode: { _ in data })
        store.setSource("A")
        for index in 0..<120 {
            store.setDemand(channel: channel(index), owner: UUID(), priority: .init(tier: .visible, row: index))
        }
        #expect(store.demandCount == 96)
        var calls = 0
        store.refresh { calls += 1; return PlaySpec(url: $0.currentUrl!) }
        try await wait { !store.isRefreshing }
        #expect(calls == 96 && store.cachedCount == 64 && store.cachedBytes <= LiveChannelPreviewStore.byteLimit)
        #expect(store.frame(for: channel(0)) == nil && store.frame(for: channel(95)) != nil)
        let large = png(width: 320, height: 180)
        let heavy = LiveChannelPreviewStore(budget: .init(), decode: { _ in large })
        heavy.setSource("B")
        for index in 0..<64 { heavy.setDemand(channel: channel(index), owner: UUID(), priority: .visible) }
        heavy.refresh { PlaySpec(url: $0.currentUrl!) }; try await wait { !heavy.isRefreshing }
        #expect(heavy.cachedCount < 64 && heavy.cachedBytes <= LiveChannelPreviewStore.byteLimit)
    }

    @Test func oversizedOrMalformedFramesFailWithoutReplacingCache() async throws {
        for data in [Data("bad".utf8), Data(repeating: 0, count: 2 * 1_024 * 1_024 + 1), png(width: 641)] {
            let store = LiveChannelPreviewStore(budget: .init(), decode: { _ in data })
            store.setSource("A"); store.setDemand(channel: channel(1), owner: UUID(), priority: .visible)
            store.refresh { PlaySpec(url: $0.currentUrl!) }; await store.drain()
            #expect(store.cachedCount == 0 && store.message == LivePreviewError.failed.errorDescription)
        }
    }

    @Test func sourceAndChannelFingerprintsIsolateHeadersAndCredentials() {
        var a = channel(1), b = a
        b.header = ["Authorization": "different-account"]
        #expect(LiveCatchupPolicy.channelFingerprint(a) != LiveCatchupPolicy.channelFingerprint(b))
        a.currentUrlIndex = 99
        #expect(LiveCatchupPolicy.channelFingerprint(a) == LiveCatchupPolicy.channelFingerprint(channel(1)))
        #expect(LiveCatchupPolicy.sourceFingerprint(Live(name: "A", url: "https://a.invalid")) !=
                LiveCatchupPolicy.sourceFingerprint(Live(name: "A", url: "https://b.invalid")))
    }

    @Test func appStatePlaybackDrainsPreviewBeforeSubmittingOriginalSpec() async throws {
        let probe = LivePreviewProbe(), store = LiveChannelPreviewStore(budget: .init(), decode: probe.decode)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-preview-state-\(UUID())")
        let suite = "live-preview-state-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: directory), userPreferences: UserPreferences(defaults: defaults),
            livePreviews: store, providerRuntimeBootstrap: nil)
        defer { state.beginApplicationTermination(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let a = channel(1)
        state.activeLive = Live(name: "fixture", url: "https://preview.invalid/list")
        state.channelGroups = [.init(name: "fixture", channels: [a])]
        store.setDemand(channel: a, owner: UUID(), priority: .visible)
        state.refreshLivePreviews(); try await wait { probe.urls.count == 1 }
        var submitted: [PlaySpec] = []
        state.playSpecHandler = { submitted.append($0) }
        let original = PlaySpec(url: "https://vod.invalid/original.mp4", headers: ["Authorization": "original"], title: "original")
        let play = Task { await state.play(spec: original) }
        await Task.yield(); #expect(submitted.isEmpty && store.activeCount == 1)
        probe.finish(png()); await play.value
        #expect(submitted.map(\.url) == [original.url] && submitted.first?.headers == original.headers)
        #expect(store.activeCount == 0 && store.cachedCount == 0)
    }

    @Test func appStateResolverPreservesHeadersAndSkipsBrowserAndDRMInputs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-preview-resolve-\(UUID())")
        let suite = "live-preview-resolve-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        var captured: [PlaySpec] = []
        let data = png(), store = LiveChannelPreviewStore(budget: .init(), decode: { captured.append($0); return data })
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: directory), userPreferences: UserPreferences(defaults: defaults),
            livePreviews: store, providerRuntimeBootstrap: nil)
        defer { state.beginApplicationTermination(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        var direct = channel(1); direct.header = ["Authorization": "fixture-only"]; direct.referer = "https://origin.invalid"
        var parsed = channel(2); parsed.parseFlag = 1
        var clicked = channel(3); clicked.clickScript = "fixture()"
        var foreign = channel(4); foreign.urls = ["file:///local.ts"]
        let channels = [direct, parsed, clicked, foreign]
        state.activeLive = Live(name: "fixture", url: "https://preview.invalid/list")
        state.channelGroups = [.init(name: "fixture", channels: channels)]
        for channel in channels { store.setDemand(channel: channel, owner: UUID(), priority: .visible) }
        state.refreshLivePreviews(); try await wait { !store.isRefreshing }
        #expect(captured.count == 1 && captured.first?.headers == direct.requestHeaders)
        #expect(store.error(for: parsed) == LivePreviewError.unsupported.errorDescription)
        state.livePlayerState.currentSpec = PlaySpec(url: "https://preview.invalid/primary.ts")
        state.refreshLivePreviews(); try await wait { !store.isRefreshing }
        #expect(captured.count == 1 && store.error(for: direct) == LivePreviewError.connectionLimit.errorDescription)
        state.livePlayerState.currentSpec = nil
        let before = state.livePreviewIdentity
        state.liveSourceRevision = UUID()
        #expect(state.livePreviewIdentity != before && store.cachedCount == 0 && store.demandCount == 0)
    }
}

@MainActor private final class LivePreviewProbe {
    var urls: [String] = []
    private var continuation: CheckedContinuation<Data?, Never>?
    func decode(_ spec: PlaySpec) async -> Data? {
        urls.append(spec.url)
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ data: Data?) { let pending = continuation; continuation = nil; pending?.resume(returning: data) }
}

struct XtreamPreviewQuotaTests {
    @Test(arguments: [("1", "0", false), ("2", "0", true), ("2", "1", false), ("3", "1", true),
                     ("3", "2", false), ("0", "0", false), ("", "0", false), ("3", "", false),
                     ("-1", "0", false), ("3", "-1", false), ("3.5", "0", false)])
    func reservesPrimaryConnection(maximum: String, active: String, allowed: Bool) {
        #expect(XtreamPreviewConnections(maximum: maximum, active: active).permitsPreview == allowed)
    }
}
