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
