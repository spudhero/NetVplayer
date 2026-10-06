import Foundation
import Testing
import Models
import Storage
import SpiderEngine
@testable import NetVplayerApp

@Suite(.serialized)
struct PlaybackEndedTests {
    @MainActor
    @Test func replayResolvesAgainWithNewGenerationAndNoOpeningSkip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, provider, site) = await fixture(directory)
        let first = Episode(name: "第1集", url: "first")
        state.detailVod = Vod(vodId: "film", siteKey: site.key)
        state.episodes = [first]
        state.selectedPlayFlag = "line"
        let identity = try #require(VodSkipSettingsIdentity(siteKey: site.key, vodID: "film"))
        VodSkipSettingsStore.shared.save(openingSeconds: 60, endingSeconds: 0, for: identity)
        defer { VodSkipSettingsStore.shared.save(openingSeconds: 0, endingSeconds: 0, for: identity) }
        var submissions: [PlaySpec] = []
        state.playSpecHandler = { spec in
            await Task.yield()
            state.playerState.currentSpec = spec
            submissions.append(spec)
        }
        await state.playEpisode(first, resumePosition: 90_000, resumeDuration: 600_000)
        #expect(submissions.first?.initialStartPositionSeconds == 90)
        state.playerState.endDisposition = .natural
        await state.toggleVodPlayback()
        #expect(submissions.count == 2)
        #expect(submissions.last?.initialStartPositionSeconds == nil)
        #expect(submissions.first?.metadata["playback.sessionGeneration"] != submissions.last?.metadata["playback.sessionGeneration"])
        #expect(await provider.playerCalls == ["first", "first"])
        #expect(!state.playerState.hasEnded)
        state.isPlayerPresented = false
        await state.replayCurrentEpisode()
        #expect(submissions.count == 2)
    }

    @MainActor
    @Test(arguments: ["player", "source", "film", "close", "timeout"])
    func progressiveListOwnsCompletionAndDefersEOF(change: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, provider, site) = await fixture(directory)
        let normalRefreshTimeout = state.episodeListRefreshTimeout
        if change == "timeout" { state.episodeListRefreshTimeout = .milliseconds(350) }
        var submissions: [PlaySpec] = []
        state.playSpecHandler = { spec in
            await Task.yield()
            state.playerState.currentSpec = spec
            submissions.append(spec)
        }
        let load = Task { await state.selectVod(Vod(vodId: "film", siteKey: site.key)) }
        let loadingDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while state.episodeListState != .loading, ContinuousClock.now < loadingDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(state.episodeListState == .loading)
        await state.playEpisode(Episode(name: "第1集", url: "first"))
        let spec = try #require(state.playerState.currentSpec)
        state.playerState.endDisposition = .natural
        state.handleMPVPlaybackEnded(spec: spec)
        #expect(submissions.count == 1)
        await provider.waitForRefresh()
        switch change {
        case "source": state.activeSite = Site(key: site.key, name: "Changed", type: 3, api: "csp_Changed")
        case "film": state.detailVod = Vod(vodId: "other")
        case "close": state.isPlayerPresented = false
        case "timeout":
            let timeoutDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while state.episodeListState == .loading, ContinuousClock.now < timeoutDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(state.episodeListState == .incomplete)
            #expect(!state.isDetailLoading)
        default: break
        }
        await provider.finishRefresh()
        await load.value
        try await Task.sleep(for: .milliseconds(40))
        if change == "player" { try await waitForPreparedPlayback(state) }
        #expect(submissions.count == (change == "player" ? 2 : 1))
        if change == "player" {
            #expect(state.episodeListState == .ready)
            #expect(submissions.last?.metadata["vod.episodeURL"] == "second")
        } else if change == "timeout" {
            #expect(state.episodeListState == .incomplete)
            // Only the blocked request uses a short budget; retry gets the production budget.
            state.episodeListRefreshTimeout = normalRefreshTimeout
            await state.retryEpisodeList()
            try await waitForPreparedPlayback(state)
            #expect(state.episodeListState == .ready)
            #expect(submissions.count == 2)
        }
    }

    @MainActor
    @Test func biliPartsWithMixedFilenameLabelsKeepSourceOrderAndAdvancePastSecondPart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, provider, site) = await fixture(directory)
        let parts = [
            Episode(name: "第1集.自动门和旋转门.flv", url: "part-1"),
            Episode(name: "第2集.我和动物.flv", url: "part-2"),
            Episode(name: "第3集.电梯安全", url: "part-3")
        ]
        state.detailVod = Vod(vodId: "safety", siteKey: site.key)
        state.episodes = parts
        state.selectedPlayFlag = "B站"
        var submissions: [PlaySpec] = []
        state.playSpecHandler = { spec in
            state.playerState.currentSpec = spec
            submissions.append(spec)
        }

        await state.playEpisode(parts[1])
        #expect(state.displayedPlaybackEpisodes.map(\.id) == parts.map(\.id))
        #expect(state.playbackEpisodeContext().total == 3)
        #expect(state.playbackEpisodeContext().nextEpisode?.id == parts[2].id)
        let spec = try #require(state.playerState.currentSpec)
        state.playerState.endDisposition = .natural
        state.handleMPVPlaybackEnded(spec: spec)
        try await waitForPreparedPlayback(state)
        #expect(submissions.count == 2)
        #expect(submissions.last?.metadata["vod.episodeURL"] == parts[2].url)
        #expect(await provider.playerCalls == ["part-2", "part-3"])
    }

    @MainActor
    @Test func baiduFilenameSeriesSkipsEndingDespiteMovieShelfAndDuplicateUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, provider, site) = await fixture(directory)
        let first = Episode(name: "[2.81GB]S01E01 4K.mp4", url: "first")
        let second = Episode(name: "[2.64GB]S01E02 4K.mp4", url: "second")
        state.detailVod = Vod(vodId: "film", typeName: "玩偶电影", siteKey: site.key)
        state.episodes = [first, second,
            Episode(name: "[2.70GB]S01E07 4K.mp4", url: "seventh"),
            Episode(name: "[2.70GB]S01E07 4K(1).mp4", url: "copy")]
        state.selectedPlayFlag = "百度网盘"
        let identity = try #require(VodSkipSettingsIdentity(siteKey: site.key, vodID: "film"))
        VodSkipSettingsStore.shared.save(openingSeconds: 105, endingSeconds: 144, for: identity)
        defer { VodSkipSettingsStore.shared.save(openingSeconds: 0, endingSeconds: 0, for: identity) }
        var submissions: [PlaySpec] = []
        state.playSpecHandler = { spec in
            await Task.yield()
            state.playerState.currentSpec = spec
            submissions.append(spec)
        }
        await state.playEpisode(first)
        let spec = try #require(state.playerState.currentSpec)
        state.playerState.duration = 2_715
        state.playerState.position = 2_604
        #expect(state.playbackEpisodeContext().nextEpisode?.id == second.id)
        state.handleMPVPlaybackPosition(spec: spec, positionSeconds: 2_604)
        // Repeated position and EOF callbacks must share one automatic transition.
        state.handleMPVPlaybackPosition(spec: spec, positionSeconds: 2_605)
        state.handleMPVPlaybackEnded(spec: spec)
        for _ in 0..<200 where state.isPreparingVodPlayback {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(submissions.count == 2)
        #expect(submissions.last?.metadata["vod.episodeURL"] == second.url)
        #expect(submissions.last?.initialStartPositionSeconds == 105)
        #expect(await provider.playerCalls == ["first", "second"])
    }

    @MainActor
    @Test(arguments: ["complete", "cancel", "close"])
    func naturalEndWaitsForPreloadWithoutShowingEndedPanel(action: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, provider, site) = await fixture(directory)
        let first = Episode(name: "第1集", url: "first")
        let second = Episode(name: "第2集", url: "second")
        state.detailVod = Vod(vodId: "film", siteKey: site.key)
        state.episodes = [first, second]
        state.selectedPlayFlag = "line"
        var submissions: [PlaySpec] = []
        state.playSpecHandler = { spec in
            await Task.yield()
            state.playerState.currentSpec = spec
            submissions.append(spec)
        }
        await state.playEpisode(first)
        let spec = try #require(state.playerState.currentSpec)
        await provider.blockPlayback(id: second.url)
        state.playerState.duration = 600
        state.playerState.position = 590
        state.evaluateNextEpisodePreload(spec: spec, positionSeconds: 590)
        for _ in 0..<200 {
            if await provider.isPlaybackBlocked { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await provider.isPlaybackBlocked)
        #expect(!state.isPreparingVodPlayback)
        state.playerState.endDisposition = .natural
        state.handleMPVPlaybackEnded(spec: spec)
        #expect(state.isPreparingVodPlayback)
        #expect(!state.shouldShowPlaybackEndedPanel)
        await Task.yield()
        #expect(state.playerState.hasEnded)
        #expect(!state.shouldShowPlaybackEndedPanel)
        state.handleMPVPlaybackEnded(spec: spec)
        if action == "cancel" { await state.cancelLoading() }
        if action == "close" { state.isPlayerPresented = false }
        if action != "complete" { #expect(!state.isPreparingVodPlayback) }
        await provider.finishBlockedPlayback()
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(5))
            if !state.isPreparingVodPlayback { break }
        }
        #expect(!state.isPreparingVodPlayback)
        #expect(submissions.count == (action == "complete" ? 2 : 1))
        #expect(await provider.playerCalls == ["first", "second"])
        if action == "complete" {
            #expect(submissions.last?.metadata["vod.episodeURL"] == second.url)
            #expect(!state.playerState.hasEnded)
            #expect(!state.shouldShowPlaybackEndedPanel)
            state.playerState.endDisposition = .natural
            state.handleMPVPlaybackEnded(spec: state.playerState.currentSpec)
            #expect(state.shouldShowPlaybackEndedPanel)
        }
    }

    @MainActor
    @Test(arguments: [false, true], [false, true])
    func sortOrderControlsManualNavigationAutoAdvanceAndBoundaries(descending: Bool, audio: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, _, site) = await fixture(directory)
        let names = audio ? ["片头曲.flac", "未编号歌曲", "01.wav"]
            : ["[4.60GB]S01E03 4KHQHDR60FPS.mp4", "第4集(1).mkv", "花絮.mp4"]
        let items = names.enumerated().map { Episode(name: $0.element, url: "episode-\($0.offset + 1)") }
        state.detailVod = Vod(vodId: "film", siteKey: site.key)
        state.episodes = items
        state.selectedPlayFlag = "line"
        var submissions: [PlaySpec] = []
        state.playSpecHandler = { spec in
            await Task.yield()
            state.playerState.currentSpec = spec
            submissions.append(spec)
        }
        await state.playEpisode(items[1])
        let originalSpec = try #require(state.playerState.currentSpec)
        state.playerState.position = 90
        state.episodeSortOrder = descending ? .descending : .ascending
        let previous = items[descending ? 2 : 0]
        let next = items[descending ? 0 : 2]
        #expect(state.playbackEpisodeContext().previousEpisode?.id == previous.id)
        #expect(state.playbackEpisodeContext().nextEpisode?.id == next.id)
        #expect(state.playerState.position == 90)
        #expect(state.playerState.currentSpec?.metadata == originalSpec.metadata)
        #expect(submissions.count == 1)

        #expect(await state.playRelativeEpisode(offset: -1)?.id == previous.id)
        #expect(!state.playbackEpisodeContext().hasPrevious)
        #expect(await state.playRelativeEpisode(offset: -1) == nil)
        #expect(await state.playRelativeEpisode(offset: 1)?.id == items[1].id)
        state.playerState.endDisposition = .natural
        state.handleMPVPlaybackEnded(spec: state.playerState.currentSpec)
        for _ in 0..<200 where state.isPreparingVodPlayback {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(submissions.count == 4)
        #expect(submissions.last?.metadata["vod.episodeURL"] == next.url)
        #expect(!state.playbackEpisodeContext().hasNext)
        #expect(await state.playRelativeEpisode(offset: 1) == nil)
        state.playerState.endDisposition = .natural
        state.handleMPVPlaybackEnded(spec: state.playerState.currentSpec)
        #expect(state.shouldShowPlaybackEndedPanel)
        #expect(!state.isPreparingVodPlayback)

        state.episodeSortOrder = state.episodeSortOrder.next
        #expect(!state.playbackEpisodeContext().hasPrevious)
        #expect(state.playbackEpisodeContext().nextEpisode?.id == items[1].id)
        #expect(state.episodes.map(\.id) == items.map(\.id))
    }

    @MainActor
    @Test func changingSortCancelsPreloadEvenWhenToggledBackBeforeTheNextPositionUpdate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (state, provider, site) = await fixture(directory)
        let items = ["S01E03 4KHQHDR60FPS.mp4", "未编号文件", "试音.wav"].enumerated()
            .map { Episode(name: $0.element, url: "episode-\($0.offset + 1)") }
        state.detailVod = Vod(vodId: "film", siteKey: site.key)
        state.episodes = items
        state.selectedPlayFlag = "line"
        state.playSpecHandler = { spec in
            await Task.yield()
            state.playerState.currentSpec = spec
        }
        await state.playEpisode(items[1])
        let spec = try #require(state.playerState.currentSpec)
        await provider.blockPlayback(id: items[2].url)
        state.playerState.duration = 600
        state.playerState.position = 590
        state.evaluateNextEpisodePreload(spec: spec, positionSeconds: 590)
        for _ in 0..<200 {
            if await provider.isPlaybackBlocked { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await provider.isPlaybackBlocked)

        state.episodeSortOrder = .descending
        await provider.finishBlockedPlayback()
        state.episodeSortOrder = .ascending
        state.evaluateNextEpisodePreload(spec: spec, positionSeconds: 590)
        for _ in 0..<200 {
            if await provider.playerCalls.count == 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await provider.playerCalls == ["episode-2", "episode-3", "episode-3"])

        state.episodeSortOrder = .descending
        state.evaluateNextEpisodePreload(spec: spec, positionSeconds: 590)
        #expect(await state.playRelativeEpisode(offset: 1)?.id == items[0].id)
        #expect(await provider.playerCalls == ["episode-2", "episode-3", "episode-3", "episode-1"])
    }

    @MainActor
    private func waitForPreparedPlayback(_ state: AppState) async throws {
        // Resolution may include an asynchronous transport probe; 40ms is not a completion signal.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        await Task.yield()
        while state.isPreparingVodPlayback, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!state.isPreparingVodPlayback)
    }

    @MainActor
    private func fixture(_ directory: URL) async -> (AppState, EndedPlaybackProvider, Site) {
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
        let site = Site(key: UUID().uuidString, name: "Ended", type: 3, api: "csp_Ended_\(UUID().uuidString)")
        let provider = EndedPlaybackProvider()
        await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: provider)
        state.sites = [site]; state.activeSite = site
        return (state, provider, site)
    }
}

private actor EndedPlaybackProvider: SiteContentProvider {
    private var detailCalls = 0
    private var refreshing = false
    private var refreshWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private var blockedPlayerID: String?
    private var playbackCompletion: CheckedContinuation<Void, Never>?
    private(set) var playerCalls: [String] = []
    var isPlaybackBlocked: Bool { playbackCompletion != nil }
    func blockPlayback(id: String) { blockedPlayerID = id }
    func finishBlockedPlayback() {
        blockedPlayerID = nil
        playbackCompletion?.resume()
        playbackCompletion = nil
    }
    func detailContent(site: Site, id: String) async throws -> Result {
        detailCalls += 1
        if detailCalls == 2 {
            await withCheckedContinuation {
                completion = $0; refreshing = true
                refreshWaiter?.resume(); refreshWaiter = nil
            }
        }
        return Result(list: [Vod(vodId: id, vodPlayFrom: "line",
            vodPlayUrl: detailCalls == 1 ? "第1集$first#加载中$netvplayer-pending:list" : "第1集$first#第2集$second", siteKey: site.key)])
    }
    func waitForRefresh() async {
        if refreshing { return }
        await withCheckedContinuation { refreshWaiter = $0 }
    }
    func finishRefresh() { completion?.resume(); completion = nil }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        playerCalls.append(id)
        if blockedPlayerID == id {
            await withCheckedContinuation {
                playbackCompletion = $0
            }
        }
        return Result(url: "https://media.example.test/\(id).mp4", format: "mp4")
    }
    func homeContent(site: Site) async throws -> Result { .empty }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}
