import Foundation
import ApplicationCore
import Models
import SpiderEngine
import Storage
import Testing
@testable import NetVplayerApp

@Suite("History file recovery", .serialized)
@MainActor
struct HistoryFileRecoveryTests {
    @Test(arguments: [false, true])
    func missingOriginalFileRequiresSelectionAndKeepsItsProgress(emptyDetail: Bool) async throws {
        let fixture = await fixture(episodes: emptyDetail ? [] : [Episode(name: "第1集", url: locator("new-file"))])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let task = Task { await fixture.state.playHistory(fixture.history) }
        defer { task.cancel() }
        for _ in 0..<300 where AppDialogCenter.shared.request == nil { try await Task.sleep(for: .milliseconds(10)) }
        let request = try #require(AppDialogCenter.shared.request)
        #expect(request.title == L10n.text("无法确认上次播放的文件"))
        #expect(await fixture.provider.playerCallCount() == 0)
        #expect(fixture.state.isDetailPresented)
        #expect(fixture.state.historyItems.first?.position == 42_000)
        AppDialogCenter.shared.complete(id: request.id, selection: 0)
        await task.value

        if let replacement = fixture.state.episodes.first {
            await fixture.state.playEpisode(replacement)
            #expect(await fixture.provider.playerCallCount() == 1)
            #expect(fixture.state.playbackSessionState.intent?.resumePosition == nil)
            #expect(fixture.state.playbackSessionState.intent?.resumeDuration == nil)
        }
    }

    @Test func refreshedSameFileUsesCurrentLocatorAndOriginalProgress() async {
        let refreshed = locator("original-file", token: "new")
        let fixture = await fixture(episodes: [Episode(name: "第1集", url: refreshed)])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.state.playHistory(fixture.history)
        #expect(await fixture.provider.playerCallCount() == 1)
        #expect(fixture.state.playbackSessionState.intent?.episode.url == refreshed)
        #expect(fixture.state.playbackSessionState.intent?.resumePosition == 42_000)
        #expect(fixture.state.playbackSessionState.intent?.resumeDuration == 600_000)
        #expect(AppDialogCenter.shared.request == nil)
    }

    @Test(arguments: ["cancel", "close", "source", "same-vod"])
    func lateDetailCannotResumeAfterItsOwnerChanges(action: String) async throws {
        let fixture = await fixture(episodes: [Episode(name: "第1集", url: locator("original-file", token: "new"))], holdDetail: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let task = Task { await fixture.state.playHistory(fixture.history) }
        await fixture.provider.waitForDetail()
        var navigation: Task<Void, Never>?
        switch action {
        case "cancel": task.cancel()
        case "close": fixture.state.isDetailPresented = false
        case "source": fixture.state.activeSite = Site(key: "replacement", type: 3, api: "csp_Other")
        default:
            navigation = Task { await fixture.state.selectVod(Vod(vodId: fixture.history.vodId, siteKey: fixture.history.siteKey)) }
            // selectVod publishes its new owner before waiting for the shared detail fetch.
            for _ in 0..<300 where fixture.state.detailVod?.vodName == fixture.history.vodName { try await Task.sleep(for: .milliseconds(10)) }
        }
        await fixture.provider.releaseDetail()
        await task.value
        await navigation?.value
        #expect(await fixture.provider.playerCallCount() == 0)
        #expect(AppDialogCenter.shared.request == nil)
        #expect(fixture.state.historyItems.first?.position == 42_000)
    }

    private func locator(_ fileID: String, token: String = "old") -> String {
        "netvplayer-drive://quark/file?share=https://pan.quark.cn/s/share&pwd_id=share&fid=\(fileID)&fid_token=\(token)&file_name=episode.mp4"
    }

    private func fixture(episodes: [Episode], holdDetail: Bool = false) async -> (state: AppState, provider: HistoryRecoveryProvider, history: History, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryRecovery-\(UUID().uuidString)")
        let storage = StorageManager(storageDirectory: directory)
        let unique = UUID().uuidString
        let site = Site(key: unique, type: 3, api: "csp_HistoryRecovery_\(unique)")
        let provider = HistoryRecoveryProvider(episodes: episodes, holdDetail: holdDetail)
        await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: provider)
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, storageManager: storage,
                             providerRuntimeRegistrationOverride: { true }, providerRuntimeStartupOverride: { true })
        let config = Config(id: 1, url: "https://history.example.invalid/\(unique)")
        state.savedConfigs = [config]
        state.libraryConfigurationURL = config.url
        state.sites = [site]
        state.activeSite = site
        state.isConfigLoaded = true
        let history = LibraryIdentityMigration.bind(History(siteKey: site.key, vodId: unique, vodName: "History title", vodFlag: "line",
                                                            episodeUrl: locator("original-file"), episodeName: "第1集", position: 42_000, duration: 600_000),
                                                   configuration: config, site: site)
        state.historyItems = [history]
        return (state, provider, history, directory)
    }
}

private actor HistoryRecoveryProvider: SiteContentProvider {
    private let episodes: [Episode]
    private let held: Bool
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    private var playerCalls = 0

    init(episodes: [Episode], holdDetail: Bool) { self.episodes = episodes; self.held = holdDetail }
    func playerCallCount() -> Int { playerCalls }
    func waitForDetail() async {
        if !started { await withCheckedContinuation { observer = $0 } }
    }
    func releaseDetail() { pending?.resume(); pending = nil }
    func detailContent(site: Site, id: String) async throws -> Result {
        started = true
        observer?.resume(); observer = nil
        if held { await withCheckedContinuation { pending = $0 } }
        return Result(list: [Vod(vodId: id, vodName: "Current title", vodPlayFrom: "line",
                                 vodPlayUrl: episodes.map { "\($0.name)$\($0.url)" }.joined(separator: "#"), siteKey: site.key)])
    }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        playerCalls += 1
        // A deterministic provider failure verifies selection and resume intent without real media or mpv side effects.
        return Result(url: "netvplayer-unavailable://episode?reason=unavailable")
    }
    func homeContent(site: Site) async throws -> Result { .empty }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}
