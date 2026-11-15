import Foundation
import Testing
import SwiftUI
import Models
import Storage
import MediaLibraryEngine
import SpiderEngine
@testable import NetVplayerApp

@Suite("OV91-09 online detail", .serialized, .timeLimit(.minutes(2))) @MainActor
struct OnlineVodDetailTests {
    @Test func automaticUniqueMatchPreservesSourceAndImmediateOriginalSelection() async throws {
        let provider = OnlineDetailProvider()
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        let vod = source()
        model.receive(input(vod)); model.resume(); model.showEnhanced()
        try await eventually { model.metadata?.detailVersion == 2 }
        #expect(model.binding?.metadata.tmdbID == "12")
        #expect(model.displayedMetadata?.title == "TMDB title")
        model.showOriginal()
        #expect(model.displayedMetadata == nil)
        var completed = vod
        completed.vodName = "Provider corrected title"; completed.vodYear = "2025"
        completed.vodPlayUrl += "#Second$https://example.test/second.mp4"
        model.receive(input(completed))
        #expect(model.binding?.metadata.tmdbID == "12")
        #expect(!model.wantsEnhanced)
        model.showEnhanced()
        #expect(model.displayedMetadata?.title == "TMDB title")
        #expect(await provider.searchCalls == 1)
        #expect(await provider.detailCalls == 1)
        model.suspend(); model.resume()
        #expect(model.binding?.metadata.tmdbID == "12")
        #expect(vod.vodId == "source-film" && vod.parseFlags().first?.episodes.first?.url == "https://example.test/first.mp4")
        model.suspend()
    }

    @Test(arguments: ["remake", "cross-kind", "partial", "cross-kind-many"])
    func ambiguityAndPartialCoverageRequireConfirmation(mode: String) async throws {
        let provider = OnlineDetailProvider(mode: mode)
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        var vod = source(); vod.typeName = ""; vod.vodYear = ""
        model.receive(input(vod)); model.resume(); model.showEnhanced()
        try await eventually { model.hasSearched && !model.isLoading }
        #expect(model.binding == nil && model.metadata == nil)
        #expect(await provider.detailCalls == 0)
        #expect(!model.candidates.isEmpty)
        let candidate = try #require(model.candidates.last)
        model.confirm(candidate)
        // Confirmation is retained even if the provider completes original details during the request.
        vod.vodName = "Completed title"; vod.typeName = "电视剧"
        model.receive(input(vod))
        try await eventually { model.metadata?.detailVersion == 2 }
        #expect(model.metadata?.tmdbID == candidate.metadata.tmdbID)
        #expect(model.metadata?.kind == candidate.metadata.kind)
        model.suspend()
    }

    @Test func originalChoiceDuringSlowSearchIsNotOverriddenByCompletion() async throws {
        let gate = OnlineDetailGate()
        let provider = OnlineDetailProvider(gate: gate)
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        model.receive(input(source())); model.resume(); model.showEnhanced()
        try await eventually { await gate.entered }
        model.showOriginal()
        #expect(model.displayedMetadata == nil)
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.binding == nil && model.metadata == nil && !model.isLoading)
        #expect(await provider.detailCalls == 0)
        #expect(model.displayedMetadata == nil && !model.wantsEnhanced)
        model.suspend()
    }

    @Test func retiringViewCannotSuspendTheNewVisibleOwner() async throws {
        let provider = OnlineDetailProvider()
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        let old = UUID(), current = UUID()
        model.receive(input(source())); model.resume(owner: old); model.showEnhanced()
        try await eventually { model.metadata?.detailVersion == 2 }
        model.resume(owner: current); model.suspend(owner: old)
        await provider.setMode("detail-failure")
        model.retry()
        try await eventually { model.issue != nil }
        #expect(model.binding?.metadata.tmdbID == "12")
        model.suspend(owner: current)
    }

    @Test(arguments: ["source", "site", "film", "close"])
    func cancelledLateRequestsCannotBindAnotherEntry(change: String) async throws {
        let gate = OnlineDetailGate()
        let provider = OnlineDetailProvider(gate: gate)
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        model.receive(input(source())); model.resume(); model.showEnhanced()
        try await eventually { await gate.entered }
        if change == "close" { model.suspend() }
        else {
            var vod = source(); if change == "film" { vod.vodId = "other" }
            if change == "site" { vod.siteKey = "other" }
            model.receive(input(vod, fingerprint: change == "source" ? "other-config" : "config"))
            model.suspend()
        }
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.binding == nil && model.metadata == nil && !model.isLoading)
    }

    @Test func detailFailureRetainsConfirmedCandidateAndRetryWorks() async throws {
        let provider = OnlineDetailProvider(mode: "detail-failure")
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        model.receive(input(source())); model.resume(); model.showEnhanced()
        try await eventually { model.issue != nil && !model.isLoading }
        #expect(model.binding?.metadata.tmdbID == "12")
        model.showOriginal(); #expect(model.displayedMetadata == nil)
        await provider.setMode("normal")
        model.showEnhanced()
        try await eventually { model.metadata?.detailVersion == 2 }
        #expect(model.wantsEnhanced && model.issue == nil)
        #expect(await provider.detailCalls == 2)
        model.suspend()
    }

    @Test func searchFailureAndMissingCredentialsRemainRetryable() async throws {
        let provider = OnlineDetailProvider(mode: "failure")
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        model.receive(input(source())); model.resume(); model.showEnhanced()
        try await eventually { model.issue != nil && !model.isLoading }
        #expect(model.binding == nil)
        await provider.setMode("normal"); model.retry()
        try await eventually { model.metadata?.detailVersion == 2 }
        model.suspend()
        let missing = OnlineVodDetailModel(matcher: MetadataMatcher(providers: []))
        missing.receive(input(source())); missing.resume(); missing.showEnhanced()
        try await eventually { missing.issue != nil }
        #expect(missing.displayedMetadata == nil && !missing.isLoading)
        missing.suspend()
    }

    @Test func manualTitleSearchAndKnownYearDisambiguate() async throws {
        let provider = OnlineDetailProvider(mode: "remake")
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        var vod = source(); vod.vodYear = "2024"
        model.receive(input(vod)); model.resume(); model.showEnhanced()
        try await eventually { model.metadata?.detailVersion == 2 }
        #expect(model.binding?.metadata.year == 2024)
        model.search(title: "Other title")
        try await eventually { !model.isLoading }
        #expect(model.binding?.metadata.title == "Other title")
        model.suspend()
    }

    @Test func manualSearchSurvivesOriginalCompletionBeforeConfirmation() async throws {
        let provider = OnlineDetailProvider(mode: "remake")
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        var vod = source(); vod.vodYear = ""
        model.receive(input(vod)); model.resume(); model.showEnhanced()
        try await eventually { !model.isLoading }
        model.search(title: "User corrected title")
        vod.vodName = "Provider completed title"
        model.receive(input(vod))
        try await eventually { !model.isLoading }
        #expect(model.binding == nil)
        #expect(model.candidates.allSatisfy { $0.metadata.title == "User corrected title" })
        model.suspend()
    }

    @Test func mismatchedDetailIdentityCannotReplaceTheConfirmedWork() async throws {
        let provider = OnlineDetailProvider(mode: "wrong-id")
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        model.receive(input(source())); model.resume(); model.showEnhanced()
        try await eventually { model.issue != nil && !model.isLoading }
        #expect(model.binding?.metadata.tmdbID == "12" && model.metadata?.tmdbID == "12")
        #expect(model.metadata?.detailVersion == nil)
        model.suspend()
    }

    @Test func appStateCompletionAndConfigurationIdentityDoNotChangePlaybackContract() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = OnlineDetailProvider(mode: "failure")
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: directory), userPreferences: preferences,
            onlineDetailMetadata: model, providerRuntimeBootstrap: nil)
        let site = Site(key: "site", name: "Source", type: 3, api: "csp_OnlineDetail_" + UUID().uuidString)
        state.sites = [site]; state.activeSite = site; state.libraryConfigurationURL = "https://example.test/config"
        state.detailVod = source(); state.applyPlaybackAvailability(for: source())
        state.isDetailPresented = true
        model.resume(); model.showEnhanced()
        try await eventually { model.issue != nil }
        await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: OnlinePlaybackProvider())
        var captured: PlaySpec?
        state.playSpecHandler = { captured = $0 }
        let episode = try #require(state.episodes.first)
        await state.playEpisode(episode)
        let spec = try #require(captured)
        #expect(spec.url == episode.url)
        #expect(state.detailVod?.vodId == "source-film")
        let line = state.selectedPlayFlag
        let originalSummary = state.playbackSummaryIdentity(vodID: "source-film", line: line, episodeURL: episode.url)
        await provider.setMode("normal"); model.retry()
        try await eventually { model.metadata?.detailVersion == 2 }
        state.detailVod?.vodActor = "Completed actor"
        state.detailVod?.vodName = "Completed source name"
        #expect(model.binding?.metadata.tmdbID == "12")
        #expect(state.selectedPlayFlag == line && state.episodes.first?.url == episode.url)
        #expect(state.playbackSummaryIdentity(vodID: "source-film", line: line, episodeURL: episode.url) == originalSummary)
        state.libraryConfigurationURL = "https://example.test/other-config"
        #expect(model.binding == nil && model.metadata == nil)
        model.suspend()
    }

    @Test func sourceRoutingAndLinksRejectUntrustedIDs() throws {
        var vod = source(); vod.vodId = try FileResourceReference(serviceID: UUID(), path: "/movie.mkv").locator
        #expect(input(vod) == nil)
        vod = source(); vod.typeName = "动漫"
        #expect(input(vod)?.kind == nil)
        #expect(OnlineVodInformationPane<EmptyView>.tmdbURL(type: "person", id: "12")?.host == "www.themoviedb.org")
        for id in ["", "../evil", "1?redirect=evil", "１２", "1234567890123"] {
            #expect(OnlineVodInformationPane<EmptyView>.tmdbURL(type: "person", id: id) == nil)
        }
    }

    @Test func openingAndSourceCompletionDoNotRequestMetadataUntilExplicitSelection() async throws {
        let provider = OnlineDetailProvider()
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        var vod = source()
        model.receive(input(vod)); model.resume()
        vod.vodActor = "Provider completed actor"
        model.receive(input(vod)); model.resume(); model.retry()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!model.wantsEnhanced && !model.isLoading && model.displayedMetadata == nil)
        #expect(await provider.searchCalls == 0)
        #expect(await provider.detailCalls == 0)
        model.showEnhanced()
        try await eventually { model.metadata?.detailVersion == 2 }
        #expect(await provider.searchCalls == 1)
        model.suspend()
    }

    @Test func anotherFilmDefaultsToOriginalAndDoesNotReuseThePreviousSelection() async throws {
        let provider = OnlineDetailProvider()
        let model = OnlineVodDetailModel(matcher: MetadataMatcher(providers: [provider]))
        var vod = source()
        model.receive(input(vod)); model.resume(); model.showEnhanced()
        try await eventually { model.metadata?.detailVersion == 2 }
        vod.vodId = "another-film"; vod.vodName = "Another movie"
        model.receive(input(vod)); model.resume()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!model.wantsEnhanced && model.binding == nil && model.metadata == nil && !model.isLoading)
        #expect(await provider.searchCalls == 1)
        model.showEnhanced()
        try await eventually { model.metadata?.detailVersion == 2 }
        #expect(await provider.searchCalls == 2)
        model.suspend()
    }

    private func source() -> Vod {
        Vod(vodId: "source-film", vodName: "Movie", vodYear: "2024", vodContent: "Original plot", typeName: "电影",
            vodPlayFrom: "line", vodPlayUrl: "First$https://example.test/first.mp4", siteKey: "site")
    }
    private func input(_ vod: Vod, fingerprint: String = "config") -> OnlineVodDetailInput? {
        .init(vod: vod, sourceFingerprint: fingerprint, siteKey: vod.siteKey)
    }
    private func eventually(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !predicate() {
            try #require(ContinuousClock.now < deadline, "Online metadata fixture timed out")
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor OnlineDetailGate {
    var entered = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered = true; await withCheckedContinuation { waiters.append($0) } }
    func release() { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
private actor OnlineDetailProvider: MetadataProvider {
    nonisolated let source = MetadataSource.tmdb
    var mode: String
    var searchCalls = 0, detailCalls = 0
    let gate: OnlineDetailGate?
    init(mode: String = "normal", gate: OnlineDetailGate? = nil) { self.mode = mode; self.gate = gate }
    func setMode(_ value: String) { mode = value }
    func search(title: String, year: Int?, kind: MediaLibraryKind) async throws -> [MetadataCandidate] {
        try await searchResult(title: title, year: year, kind: kind).candidates
    }
    func searchResult(title: String, year: Int?, kind: MediaLibraryKind) async throws -> MetadataSearchResult {
        searchCalls += 1
        if searchCalls == 1 { await gate?.wait() }
        if mode == "failure" { throw URLError(.timedOut) }
        if mode == "partial", kind == .television { throw URLError(.timedOut) }
        if kind == .television, !mode.hasPrefix("cross-kind") { return .init(candidates: []) }
        var items = [MetadataCandidate(source: .tmdb, metadata: .init(title: title, year: 2024, kind: kind, tmdbID: "12"))]
        if mode == "remake" || (mode == "cross-kind-many" && kind == .television) {
            items.append(.init(source: .tmdb, metadata: .init(title: title, year: 1994, kind: kind, tmdbID: "13")))
        }
        return .init(candidates: items)
    }
    func details(id: String, kind: MediaLibraryKind) async throws -> MediaMetadata {
        detailCalls += 1
        if mode == "detail-failure" { throw URLError(.timedOut) }
        return .init(title: "TMDB title", kind: kind, plot: "Metadata plot", tmdbID: mode == "wrong-id" ? "999" : id, tmdbRating: 8.5, detailVersion: 2)
    }
}
private struct OnlinePlaybackProvider: SiteContentProvider {
    func playerContent(site: Site, flag: String, id: String) async throws -> Models.Result { .init(url: id, parse: 0) }
    func homeContent(site: Site) async throws -> Models.Result { .empty }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Models.Result { .empty }
    func detailContent(site: Site, id: String) async throws -> Models.Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Models.Result { .empty }
}
