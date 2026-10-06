import Foundation
import Testing
import Models
import PlayerEngine
import SpiderEngine
@testable import NetVplayerApp

@MainActor
@Test func playbackPreparationFailurePreservesActiveRoutesAndIgnoresOldCallbacks() async throws {
    let (state, provider, oldSpec) = await playbackPreparationFixture()
    var submissions = 0
    state.playSpecHandler = { _ in submissions += 1 }
    let task = Task { await state.playEpisode(Episode(name: "Next", url: "next")) }
    await provider.waitUntilRequested()

    #expect(state.isPlayerLoading)
    #expect(state.preparingEpisode?.url == "next")
    #expect(state.preparingPlaybackTitle == "Next")
    #expect(state.drivePlaybackRoutes.map(\.id) == ["original"])
    state.handleMPVPlaybackStarted(spec: oldSpec)
    #expect(state.isPlayerLoading)
    state.handleMPVPlaybackFailure(spec: oldSpec, message: "stale failure")
    #expect(state.playerState.errorMessage == nil)

    await provider.complete(url: "netvplayer-unavailable://episode?reason=unavailable")
    await task.value

    #expect(submissions == 0)
    #expect(state.playerState.currentSpec?.url == oldSpec.url)
    #expect(state.playerState.isPlaying)
    #expect(state.drivePlaybackRoutes.map(\.id) == ["original"])
    #expect(state.selectedDrivePlaybackRouteID == "original")
    #expect(!state.isPlayerLoading)
    #expect(state.preparingEpisode == nil)
    #expect(state.preparingPlaybackTitle == nil)
}

@MainActor
@Test(arguments: [false, true])
func playbackPreparationCancellationPreservesActiveVideo(cancelTask: Bool) async throws {
    let (state, provider, oldSpec) = await playbackPreparationFixture()
    var submissions = 0
    state.playSpecHandler = { _ in submissions += 1 }
    let task = Task { await state.playEpisode(Episode(name: "Next", url: "next")) }
    await provider.waitUntilRequested()
    if cancelTask {
        task.cancel()
    } else {
        await state.cancelLoading()
    }
    // The Provider deliberately ignores cancellation and returns a valid URL late.
    await provider.complete(url: "https://media.example.test/next.mp4")
    await task.value

    #expect(submissions == 0)
    #expect(state.playerState.currentSpec?.url == oldSpec.url)
    #expect(state.playerState.isPlaying)
    #expect(state.drivePlaybackRoutes.map(\.id) == ["original"])
    #expect(!state.isPlaybackErrorPresented)
    #expect(!state.isPlayerLoading)
    #expect(state.preparingEpisode == nil)
}

@MainActor
@Test(arguments: ["complete", "cancel", "close"])
func manualEpisodeSwitchShowsTargetWhileWaitingForPreload(action: String) async throws {
    let (state, provider, oldSpec) = await playbackPreparationFixture()
    let next = Episode(name: "Next", url: "next")
    state.episodes = [Episode(name: "Current", url: oldSpec.url), next]
    state.isPlayerPresented = true
    var submissions: [PlaySpec] = []
    state.playSpecHandler = { spec in
        await Task.yield()
        state.playerState.currentSpec = spec
        submissions.append(spec)
    }
    state.playerState.duration = 600
    state.playerState.position = 590
    state.evaluateNextEpisodePreload(spec: oldSpec, positionSeconds: 590)
    await provider.waitUntilRequested()
    #expect(!state.isPreparingVodPlayback)

    let task = Task { await state.playRelativeEpisode(offset: 1) }
    for _ in 0..<200 where state.preparingEpisode == nil { await Task.yield() }
    #expect(state.isPreparingVodPlayback)
    #expect(state.preparingEpisode?.id == next.id)
    #expect(state.preparingPlaybackTitle == "Next")
    #expect(state.playerState.currentSpec?.url == oldSpec.url)
    #expect(submissions.isEmpty)

    if action == "cancel" { await state.cancelLoading() }
    if action == "close" { state.isPlayerPresented = false }
    if action != "complete" {
        #expect(state.preparingEpisode == nil)
        #expect(!state.isPreparingVodPlayback)
    }
    await provider.complete(url: "https://media.example.test/next.mp4")
    await task.value

    #expect(state.preparingEpisode == nil)
    #expect(!state.isPreparingVodPlayback)
    #expect(submissions.count == (action == "complete" ? 1 : 0))
    if action == "complete" {
        #expect(submissions.first?.metadata["vod.episodeURL"] == next.url)
    } else {
        #expect(state.playerState.currentSpec?.url == oldSpec.url)
        #expect(state.playerState.isPlaying)
    }
    if action == "close" { #expect(!state.isPlayerPresented) }
}

@MainActor
private func playbackPreparationFixture() async -> (AppState, DeferredPlaybackProvider, PlaySpec) {
    let provider = DeferredPlaybackProvider()
    let uniqueID = UUID().uuidString
    let site = Site(key: uniqueID, name: "Playback test", type: 3, api: "csp_PlaybackTest_\(uniqueID)")
    await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: provider)
    let state = AppState(
        loadDefaultConfig: false,
        startProxyServer: false,
        providerRuntimeRegistrationOverride: { true },
        providerRuntimeStartupOverride: { true }
    )
    state.sites = [site]
    state.activeSite = site
    var oldSpec = PlaySpec(url: "https://media.example.test/old.mp4", siteKey: site.key)
    oldSpec.drivePlaybackPlan = DrivePlaybackPlan(
        provider: .quark,
        asset: DrivePlaybackAssetIdentity(provider: .quark, sourceFileID: "old"),
        candidates: [DrivePlaybackCandidate(
            id: "original", providerRoute: "original-download", kind: .original,
            transport: .direct, url: oldSpec.url
        )]
    )
    oldSpec = state.configureDrivePlaybackRoutes(for: oldSpec)
    state.playerState.currentSpec = oldSpec
    state.playerState.isPlaying = true
    return (state, provider, oldSpec)
}

@MainActor
@Test(arguments: [false, true])
func nextEpisodePreloadDoesNotMutateCurrentPlaybackAndIsConsumedWithoutSecondProviderCall(quark: Bool) async throws {
    let provider = CountingPlaybackProvider()
    let uniqueID = UUID().uuidString
    let site = Site(key: uniqueID, name: "Preload test", type: 3, api: "csp_PreloadTest_\(uniqueID)")
    await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: provider)
    let state = AppState(
        loadDefaultConfig: false,
        startProxyServer: false,
        providerRuntimeRegistrationOverride: { true },
        providerRuntimeStartupOverride: { true }
    )
    state.sites = [site]
    state.activeSite = site
    state.selectedPlayFlag = "line"
    let first = Episode(name: "E1", url: "episode-1")
    let second = Episode(name: "E2", url: "episode-2")
    state.episodes = [first, second]
    var currentSpec = PlaySpec(url: "https://media.example.test/e1.mp4", flag: "line", siteKey: site.key)
    currentSpec.metadata["vod.siteKey"] = site.key
    currentSpec.metadata["vod.id"] = "vod-1"
    currentSpec.metadata["vod.episodeURL"] = first.url
    currentSpec.metadata["vod.episodeName"] = first.name
    if quark {
        currentSpec.metadata["drive.provider"] = "quark"
        currentSpec.metadata["drive.route"] = "original-download"
    }
    state.playerState.currentSpec = currentSpec
    state.playerState.position = 1_770
    state.playerState.duration = 1_800
    state.playerState.bufferedUntil = quark ? 1_785 : 1_800
    state.playerState.isPlaying = true

    var submissions: [PlaySpec] = []
    state.playSpecHandler = { spec in submissions.append(spec) }
    state.evaluateNextEpisodePreload(spec: currentSpec, positionSeconds: 1_770)
    await provider.waitUntilRequested()

    #expect(state.playerState.currentSpec?.url == currentSpec.url)
    #expect(state.playerState.isPlaying)
    #expect(!state.isPlayerLoading)
    #expect(!state.isPlayerPresented)
    #expect(submissions.isEmpty)

    await state.playEpisode(second, automaticSelection: true)

    #expect(await provider.requestCount() == 1)
    #expect(submissions.count == 1)
    #expect(submissions.first?.metadata["vod.episodeURL"] == second.url)
    #expect(state.isPlayerPresented)
}

@MainActor
@Test func earlyMediaPreloadSupportsQuarkAndUCOriginalWithProviderBudgets() {
    var ucOriginal = PlaySpec(url: "http://127.0.0.1:9978/stream?id=uc")
    ucOriginal.metadata["drive.provider"] = "uc"
    ucOriginal.metadata["drive.route"] = "uc-original-proxy"
    #expect(AppState.supportsEarlyMediaPreload(ucOriginal))
    #expect(LiveHLSRelayPolicy.playbackConcurrencyDuringPreload(for: ucOriginal, essentialsOnly: false) == 116)
    #expect(LiveHLSRelayPolicy.playbackConcurrencyDuringPreload(for: ucOriginal, essentialsOnly: true) == 136)

    var quarkOriginal = ucOriginal
    quarkOriginal.metadata["drive.provider"] = "quark"
    quarkOriginal.metadata["drive.route"] = "original-download"
    #expect(AppState.supportsEarlyMediaPreload(quarkOriginal))
    #expect(LiveHLSRelayPolicy.playbackConcurrencyDuringPreload(for: quarkOriginal, essentialsOnly: false) == 36)
    #expect(LiveHLSRelayPolicy.playbackConcurrencyDuringPreload(for: quarkOriginal, essentialsOnly: true) == 56)
    var quarkTranscode = quarkOriginal
    quarkTranscode.metadata["drive.route"] = "personal-transcode"
    #expect(!AppState.supportsEarlyMediaPreload(quarkTranscode))

    var ucTranscode = ucOriginal
    ucTranscode.metadata["drive.route"] = "personal-transcode"
    #expect(!AppState.supportsEarlyMediaPreload(ucTranscode))

    var p115Original = ucOriginal
    p115Original.metadata["drive.provider"] = "p115"
    p115Original.metadata["drive.route"] = "original-download"
    #expect(AppState.supportsEarlyMediaPreload(p115Original))
}

private actor DeferredPlaybackProvider: SiteContentProvider {
    private var continuation: CheckedContinuation<Result, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?

    func waitUntilRequested() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func complete(url: String) {
        continuation?.resume(returning: Result(url: url))
        continuation = nil
    }

    func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        await withCheckedContinuation {
            continuation = $0
            requestWaiter?.resume()
            requestWaiter = nil
        }
    }

    func homeContent(site: Site) async throws -> Result { .empty }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result { .empty }
    func detailContent(site: Site, id: String) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}

private actor CountingPlaybackProvider: SiteContentProvider {
    private var count = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func waitUntilRequested() async {
        guard count == 0 else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func requestCount() -> Int { count }

    func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        count += 1
        waiter?.resume()
        waiter = nil
        return Result(url: "https://media.example.test/e2.mp4", format: "mp4")
    }

    func homeContent(site: Site) async throws -> Result { .empty }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result { .empty }
    func detailContent(site: Site, id: String) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}
