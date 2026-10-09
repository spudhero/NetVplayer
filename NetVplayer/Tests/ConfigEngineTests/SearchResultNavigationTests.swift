import Combine
import ConfigEngine
import DriveEngine
import Foundation
import Models
import Networking
import SpiderEngine
import Storage
import Testing
import WebHomeEngine
@testable import NetVplayerApp
@testable import SearchEngine

@MainActor
@Suite(.serialized)
struct SearchResultNavigationTests {
    @Test(arguments: [false, true])
    func detailRoundTripPreservesResultsAndPagination(switchesSource: Bool) async throws {
        let fixture = try await SearchNavigationFixture()
        defer { fixture.removeStorage() }
        let state = fixture.state
        state.searchEngine = SearchEngine { site, keyword, _, page in
            Self.page(site: site, keyword: keyword, page: page)
        }
        await state.search(keyword: "影片")
        let generation = state.contentSearchState.generation
        let scope = state.contentSearchState.sourceScope
        let siteOrder = state.contentSearchState.siteOrder
        let destination = switchesSource ? fixture.destination : fixture.home
        let vod = try #require(state.searchResults.first { $0.siteKey == destination.key }?.vods.first)
        let originalIDs = state.searchResults.flatMap(\.vods).map(\.vodId)

        await state.openSearchResultVod(vod, from: destination)
        #expect(state.isDetailPresented)
        #expect(state.detailVod?.siteKey == destination.key)
        state.isDetailPresented = false

        #expect(state.selectedTab == .search)
        #expect(state.searchKeyword == "影片")
        #expect(state.searchResults.flatMap(\.vods).map(\.vodId) == originalIDs)
        #expect(state.contentSearchState.generation == generation)
        #expect(state.contentSearchState.sourceScope == scope)
        #expect(state.contentSearchState.siteOrder == siteOrder)
        #expect(state.contentSearchState.cursors[destination.key]?.nextPage == 2)

        state.loadMoreSearchResults(siteKey: destination.key)
        for await snapshot in state.$contentSearchState.values {
            if snapshot.cursors[destination.key]?.status != .loading { break }
        }
        #expect(state.searchResults.first { $0.siteKey == destination.key }?.vods.map(\.vodId)
            == [destination.key + "-1", destination.key + "-2"])
        #expect(state.contentSearchState.cursors[destination.key]?.nextPage == 3)
        #expect(state.contentSearchState.generation == generation)
    }

    @Test(arguments: [false, true])
    func openingAnotherSourceKeepsStreamingSearchAlive(opensLocalShare: Bool) async throws {
        let fixture = try await SearchNavigationFixture(driveShareExpander: DriveShareExpander(expanders: [NavigationShareExpander()]))
        defer { fixture.removeStorage() }
        let state = fixture.state
        let gate = SearchNavigationGate()
        let home = fixture.home
        state.searchEngine = SearchEngine { site, keyword, _, page in
            if site.key == home.key { await gate.wait() }
            return Self.page(site: site, keyword: keyword, page: page)
        }
        let waiter = Task { await state.search(keyword: "影片") }
        await gate.waitUntilStarted()
        for await snapshot in state.$contentSearchState.values {
            if snapshot.results.contains(where: { !$0.vods.isEmpty }) { break }
        }
        let generation = state.contentSearchState.generation
        let vod = try #require(state.searchResults.first { $0.siteKey == fixture.destination.key }?.vods.first)

        if opensLocalShare {
            await state.openImportedDriveShare(Vod(vodId: "https://pan.quark.cn/s/navigation-fixture", vodName: "分享"))
        } else {
            await state.openSearchResultVod(vod, from: fixture.destination)
        }
        state.isDetailPresented = false
        #expect(state.isSearching)
        #expect(state.searchKeyword == "影片")
        #expect(state.searchResults.flatMap(\.vods).map(\.vodId) == [vod.vodId])
        #expect(state.contentSearchState.generation == generation)

        await gate.release()
        await waiter.value
        #expect(!state.isSearching)
        #expect(state.searchResults.count == 2)
        #expect(Set(state.searchResults.flatMap(\.vods).map(\.vodId))
            == [home.key + "-1", fixture.destination.key + "-1"])
        #expect(state.contentSearchState.generation == generation)
    }

    @Test(arguments: [SidebarTab.search, .history, .favorites, .vodHome])
    func playbackRoundTripUsesOriginRoute(origin: SidebarTab) async throws {
        let fixture = try await SearchNavigationFixture()
        defer { fixture.removeStorage() }
        let state = fixture.state
        state.searchEngine = SearchEngine { site, keyword, _, page in
            Self.page(site: site, keyword: keyword, page: page)
        }
        await state.search(keyword: "影片")
        let vod = try #require(state.searchResults.first { $0.siteKey == fixture.destination.key }?.vods.first)
        state.selectedTab = origin
        let generation = state.contentSearchState.generation
        let originalIDs = state.searchResults.flatMap(\.vods).map(\.vodId)
        let expectedKeyword = origin == .search ? "影片" : ""
        await state.openSearchResultVod(vod, from: fixture.destination)
        let episode = try #require(state.episodes.first)
        var specs: [PlaySpec] = []
        state.playSpecHandler = { specs.append($0) }

        await state.playEpisode(episode)
        #expect(specs.count == 1)
        #expect(state.isPlayerPresented)
        #expect(state.selectedTab == origin)
        #expect(state.searchKeyword == expectedKeyword)
        #expect(state.searchResults.flatMap(\.vods).map(\.vodId) == originalIDs)
        #expect(state.contentSearchState.generation == generation)

        state.beginPlayerDismissalReturningToDetail()
        state.completePlayerDismissalPresentation()
        #expect(!state.isPlayerPresented)
        #expect(state.isDetailPresented)
        state.isDetailPresented = false
        state.restoreVodHomeSiteIfNeeded()
        #expect(state.selectedTab == origin)
        #expect(state.searchKeyword == expectedKeyword)
        #expect(state.searchResults.flatMap(\.vods).map(\.vodId) == originalIDs)
        #expect(state.contentSearchState.cursors[fixture.destination.key]?.nextPage == (origin == .search ? 2 : nil))
        #expect(state.contentSearchState.generation == generation)
    }

    @Test(arguments: [SidebarTab.history, .favorites], [false, true])
    func libraryEntryPlaybackReturnsToItsPage(origin: SidebarTab, switchesConfiguration: Bool) async throws {
        let fixture = try await SearchNavigationFixture()
        defer { fixture.removeStorage() }
        let state = fixture.state
        let current = Config(id: 1, url: "https://configuration.test/" + fixture.home.key)
        let destination = Config(id: 2, url: "https://configuration.test/" + fixture.destination.key)
        state.savedConfigs = [current, destination]
        state.libraryConfigurationURL = current.url
        let configuration = switchesConfiguration ? destination : current
        let fingerprint = LibrarySourceIdentity.fingerprint(configurationURL: configuration.url, site: fixture.destination)
        let key = PlaybackLinkage.vodKey(siteKey: fixture.destination.key, vodId: "saved-film", sourceFingerprint: fingerprint)
        let history = History(
            key: key, siteKey: fixture.destination.key, vodId: "saved-film", vodName: "影片",
            vodFlag: "测试线路", episodeUrl: "https://example.test/film.mp4", episodeName: "测试集",
            position: 42_000, duration: 600_000, configId: configuration.id, sourceFingerprint: fingerprint
        )
        let favorite = Keep(
            key: key, vodName: "影片", type: .vod,
            configId: configuration.id, sourceFingerprint: fingerprint
        )
        state.historyItems = [history]
        state.keepItems = [favorite]
        state.selectedTab = origin
        var specs: [PlaySpec] = []
        state.playSpecHandler = { specs.append($0) }

        if origin == .history {
            await state.playHistory(history)
        } else {
            await state.openKeep(favorite)
            #expect(state.selectedTab == .favorites)
            #expect(state.isDetailPresented)
            await state.playEpisode(try #require(state.episodes.first))
        }

        #expect(specs.count == 1)
        #expect(state.isPlayerPresented)
        #expect(state.selectedTab == origin)
        #expect(state.activeSite?.key == fixture.destination.key)
        #expect(state.libraryConfigurationURL == configuration.url)
        if origin == .history { #expect(specs.first?.initialStartPositionSeconds == 42) }
        state.beginPlayerDismissalReturningToDetail()
        state.completePlayerDismissalPresentation()
        #expect(state.isDetailPresented)
        #expect(!state.isPlayerPresented)
        state.isDetailPresented = false
        state.restoreVodHomeSiteIfNeeded()
        #expect(state.selectedTab == origin)
        #expect(state.historyItems.contains { $0.key == key })
        #expect(state.keepItems.contains { $0.key == key })
    }

    @Test
    func importedShareDetailsPreserveSearchResults() async throws {
        let fixture = try await SearchNavigationFixture(driveShareExpander: DriveShareExpander(expanders: [NavigationShareExpander()]))
        defer { fixture.removeStorage() }
        let state = fixture.state
        await state.search(keyword: "https://pan.quark.cn/s/navigation-fixture")
        let vod = try #require(state.searchResults.first?.vods.first)
        let results = state.searchResults.flatMap(\.vods).map(\.vodId)
        let generation = state.contentSearchState.generation
        let keyword = state.searchKeyword

        await state.openImportedDriveShare(vod)
        #expect(state.isDetailPresented)
        #expect(state.episodes.count == 1)
        state.isDetailPresented = false
        state.restoreVodHomeSiteIfNeeded()
        #expect(state.selectedTab == .search)
        #expect(state.searchKeyword == keyword)
        #expect(state.searchResults.flatMap(\.vods).map(\.vodId) == results)
        #expect(state.contentSearchState.generation == generation)
    }

    @Test
    func webHomeDirectPlaybackReturnsWithoutAnUnrelatedDetail() async throws {
        let fixture = try await SearchNavigationFixture()
        defer { fixture.removeStorage() }
        let state = fixture.state
        state.selectedTab = .webHome
        state.detailVod = Vod(vodId: "previous-film", vodName: "之前关闭的详情")
        var specs: [PlaySpec] = []
        state.playSpecHandler = { specs.append($0) }
        let reply = await state.makeWebHomeBridgeDispatcher().dispatch(WebHomeBridgeMessage(
            id: "navigation-play", method: "play",
            params: ["url": .string("https://example.test/film.mp4"), "title": .string("网页播放")]
        ))
        #expect(reply.ok)
        #expect(specs.count == 1)
        #expect(state.isPlayerPresented)
        state.beginPlayerDismissalReturningToDetail()
        state.completePlayerDismissalPresentation()
        #expect(!state.isPlayerPresented)
        #expect(!state.isDetailPresented)
        #expect(state.selectedTab == .webHome)
    }

    @Test
    func leavingSearchCancelsOperationAndRejectsLateResults() async throws {
        let fixture = try await SearchNavigationFixture()
        defer { fixture.removeStorage() }
        let state = fixture.state
        let gate = SearchNavigationGate()
        state.selectedSearchSiteKeys = [fixture.home.key]
        state.searchEngine = SearchEngine { site, keyword, _, page in
            await gate.wait()
            return Self.page(site: site, keyword: keyword, page: page)
        }
        let waiter = Task { await state.search(keyword: "影片") }
        await gate.waitUntilStarted()
        let generation = state.contentSearchState.generation

        state.selectedTab = .history
        #expect(state.searchKeyword.isEmpty)
        #expect(state.searchResults.isEmpty)
        #expect(!state.isSearching)
        #expect(state.contentSearchState.generation != generation)
        await gate.release()
        await waiter.value
        #expect(state.searchKeyword.isEmpty)
        #expect(state.searchResults.isEmpty)
        #expect(!state.isSearching)
    }

    nonisolated private static func page(site: Site, keyword: String, page: String) -> Result {
        Result(
            list: [Vod(vodId: site.key + "-" + page, vodName: keyword, siteKey: site.key)],
            page: Int(page) ?? 1,
            pagecount: 2
        )
    }
}

@MainActor
private struct SearchNavigationFixture {
    let state: AppState
    let home: Site
    let destination: Site
    private let directory: URL
    private let suite: String
    private let defaults: UserDefaults

    init(driveShareExpander: DriveShareExpander = .shared) async throws {
        let id = UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-navigation-" + id)
        suite = "search-navigation-" + id
        defaults = try #require(UserDefaults(suiteName: suite))
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        home = Site(key: "search-home-" + id, name: "首页来源", type: 3, api: "csp_SearchNavigationFixture", searchable: 1)
        destination = Site(key: "search-destination-" + id, name: "另一来源", type: 3, api: "csp_SearchNavigationFixture", searchable: 1)
        for site in [home, destination] {
            await SpiderReplacementRegistry.shared.register(
                originalKey: site.key,
                originalAPI: site.api,
                provider: SearchNavigationProvider()
            )
        }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [NavigationConfigurationURLProtocol.self]
        state = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            driveShareExpander: driveShareExpander,
            configResolver: ConfigResolver(
                httpClient: HTTPClient(session: URLSession(configuration: sessionConfiguration)),
                preferences: preferences, allowsProxyFallback: false
            ),
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeBootstrap: nil,
            providerRuntimeRegistrationOverride: { true }
        )
        state.sites = [home, destination]
        state.activeSite = home
        state.selectedTab = .search
    }

    func removeStorage() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class NavigationConfigurationURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "configuration.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let body = try! JSONSerialization.data(withJSONObject: ["sites": [[
            "key": url.lastPathComponent, "name": "另一来源", "type": 3,
            "api": "csp_SearchNavigationFixture", "searchable": 1
        ]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct NavigationShareExpander: DriveShareExpanding {
    func canExpand(url: String) -> Bool { url == "https://pan.quark.cn/s/navigation-fixture" }
    func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        [Episode(name: "测试集", url: "https://example.test/film.mp4")]
    }
}

private struct SearchNavigationProvider: SiteContentProvider {
    func homeContent(site: Site) async throws -> Result { .empty }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result { .empty }
    func detailContent(site: Site, id: String) async throws -> Result {
        Result(list: [Vod(vodId: id, vodName: "影片", vodPlayFrom: "测试线路", vodPlayUrl: "测试集$https://example.test/film.mp4", siteKey: site.key)])
    }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        Result(url: id, flag: flag, key: site.key)
    }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}

private actor SearchNavigationGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
