import Foundation
import Models
import ConfigEngine
import Storage
@testable import SpiderEngine
import Testing
@testable import NetVplayerApp

@Suite(.serialized)
struct CatalogCacheLifecycleTests {
    @MainActor
    @Test func staleHomeAndCategoryRefreshOnceWithoutClearingCachedContent() async throws {
        for kind in [CatalogCacheBaseKey.Kind.home, .category("movie")] {
            let clock = CatalogLifecycleClock()
            let repository = CatalogRepository(now: clock.now)
            let provider = CatalogLifecycleProvider()
            let (state, site) = await makeState(repository: repository, provider: provider)
            let key = CatalogCacheBaseKey(revision: 0, siteKey: site.key, kind: kind)
            _ = try await repository.result(for: key, page: 1) { catalogLifecycleResult("cached") }
            clock.advance(301)
            await provider.holdRequests()

            switch kind {
            case .home: await state.loadHomeContent()
            case .category: await state.selectCategory(VodClass(typeId: "movie"))
            }
            #expect(state.vods.first?.vodId == "cached")
            #expect(!state.isLoadingVod)
            try await waitUntil { await provider.callCount() == 1 }
            #expect(state.isCatalogRefreshing)
            await provider.releaseRequests()
            try await waitUntil { !state.isCatalogRefreshing }
            #expect(state.vods.first?.vodId != "cached")
            #expect(await provider.callCount() == 1)
            #expect((await repository.lookup(key)).freshness == .fresh)
        }
    }

    @MainActor
    @Test func repeatedCategoryClickDoesNotRetireActiveManualRefresh() async throws {
        let repository = CatalogRepository()
        let provider = CatalogLifecycleProvider()
        let (state, _) = await makeState(repository: repository, provider: provider)
        let category = VodClass(typeId: "movie")
        await state.selectCategory(category)
        let original = state.vods.first?.vodId
        await provider.holdRequests()
        let refresh = Task { await state.refreshCurrentCatalog() }
        try await waitUntil { await provider.callCount() == 2 }
        await state.selectCategory(category)
        #expect(state.isCatalogRefreshing)
        #expect(state.vods.first?.vodId == original)
        await provider.releaseRequests()
        await refresh.value
        #expect(!state.isCatalogRefreshing)
        #expect(!state.isLoadingVod)
        #expect(state.vods.first?.vodId != original)
        #expect(await provider.callCount() == 2)
    }

    @MainActor
    @Test func categoryFilterRoundTripRestoresAllPagesAndStaleRefreshesInPlace() async throws {
        let clock = CatalogLifecycleClock()
        let repository = CatalogRepository(now: clock.now)
        let provider = CatalogLifecycleProvider()
        let (state, _) = await makeState(repository: repository, provider: provider)
        await state.loadHomeContent()
        await state.selectCategory(VodClass(typeId: "movie"))
        let filter = try #require(state.categoryFilters.first)
          // Optional filters have no implicit first-value selection.
          await state.selectCategoryFilter(filter, value: FilterValue(name: "国内", value: "domestic"))
        let firstPage = try #require(state.vods.last)
        await state.loadMoreCategoryContentIfNeeded(currentVod: firstPage)
        let domesticIDs = state.vods.map(\.vodId)
        #expect(domesticIDs.count == 2)
        #expect(state.contentCatalogState.currentPage == 2)

        await state.selectCategoryFilter(filter, value: FilterValue(name: "海外", value: "overseas"))
        let callsAfterForeign = await provider.callCount()
        await state.selectCategoryFilter(filter, value: FilterValue(name: "国内", value: "domestic"))
        #expect(await provider.callCount() == callsAfterForeign)
        #expect(state.vods.map(\.vodId) == domesticIDs)
        #expect(state.selectedCategoryFilterValues["area"] == "domestic")
        #expect(state.contentCatalogState.currentPage == 2)

        clock.advance(301)
        await provider.holdRequests()
        await state.selectCategoryFilter(filter, value: FilterValue(name: "海外", value: "overseas"))
        #expect(state.vods.first?.vodId.contains("overseas") == true)
        #expect(!state.isLoadingVod)
        try await waitUntil { await provider.callCount() == callsAfterForeign + 1 }
        await provider.releaseRequests()
        try await waitUntil { !state.isCatalogRefreshing }
        #expect(state.selectedCategoryFilterValues["area"] == "overseas")
        #expect(await provider.callCount() == callsAfterForeign + 1)
    }

    @MainActor
    @Test func expiredCategoryKeepsOldPagesUntilColdRequestFinishes() async throws {
        let clock = CatalogLifecycleClock()
        let repository = CatalogRepository(now: clock.now)
        let provider = CatalogLifecycleProvider()
        let (state, site) = await makeState(repository: repository, provider: provider)
        let key = CatalogCacheBaseKey(revision: 0, siteKey: site.key, kind: .category("movie"))
        _ = try await repository.result(for: key, page: 1) { catalogLifecycleResult("expired") }
        clock.advance(1_801)
        await provider.holdRequests()
        let load = Task { await state.selectCategory(VodClass(typeId: "movie")) }
        try await waitUntil { await provider.callCount() == 1 }
        #expect(state.vods.first?.vodId == "expired")
        #expect(!state.isLoadingVod)
        await provider.releaseRequests()
        await load.value
        #expect(state.vods.first?.vodId != "expired")
    }

    @MainActor
    @Test func retiredRefreshCannotClearNewRefreshFlagOrReplaceSelection() async throws {
        let clock = CatalogLifecycleClock()
        let repository = CatalogRepository(now: clock.now)
        let provider = CatalogLifecycleProvider()
        let (state, site) = await makeState(repository: repository, provider: provider)
        for id in ["a", "b"] {
            let key = CatalogCacheBaseKey(revision: 0, siteKey: site.key, kind: .category(id))
            _ = try await repository.result(for: key, page: 1) { catalogLifecycleResult("cached-\(id)") }
        }
        clock.advance(301)
        await provider.holdRequests()
        await state.selectCategory(VodClass(typeId: "a"))
        try await waitUntil { await provider.callCount() == 1 }
        await state.selectCategory(VodClass(typeId: "b"))
        try await waitUntil { await provider.callCount() == 2 }
        await provider.releaseRequest(id: "a")
        // A's provider deliberately ignores cancellation, then finishes while B is pending.
        try await Task.sleep(for: .milliseconds(20))
        #expect(state.isCatalogRefreshing)
        #expect(state.selectedCategory?.typeId == "b")
        #expect(state.vods.first?.vodId == "cached-b")
        await provider.releaseRequests()
        try await waitUntil { !state.isCatalogRefreshing }
        #expect(state.vods.first?.vodId.hasPrefix("b-") == true)
    }

    @MainActor
    @Test func manualRefreshInvalidatesEveryPageOfOnlyCurrentCombination() async throws {
        let repository = CatalogRepository()
        let provider = CatalogLifecycleProvider()
        let (state, _) = await makeState(repository: repository, provider: provider)
        await state.loadHomeContent()
        await state.selectCategory(VodClass(typeId: "movie"))
        let filter = try #require(state.categoryFilters.first)
        await state.loadMoreCategoryContentIfNeeded(currentVod: try #require(state.vods.last))
        await state.selectCategoryFilter(filter, value: FilterValue(value: "overseas"))
        let overseasID = state.vods.first?.vodId
        await state.selectCategoryFilter(filter, value: FilterValue(value: "domestic"))
        await state.refreshCurrentCatalog()
        #expect(state.contentCatalogState.currentPage == 1)
        #expect(state.vods.count == 1)
        let calls = await provider.callCount()
        await state.selectCategoryFilter(filter, value: FilterValue(value: "overseas"))
        #expect(state.vods.first?.vodId == overseasID)
        #expect(await provider.callCount() == calls)
    }

    @MainActor
    @Test func clearingCachesRetiresPaginationWithoutClearingVisibleContentOrRefillingCache() async throws {
        let repository = CatalogRepository()
        let provider = CatalogLifecycleProvider()
        let (state, _) = await makeState(repository: repository, provider: provider)
        await state.selectCategory(VodClass(typeId: "movie"))
        let visibleIDs = state.vods.map(\.vodId)
        let last = try #require(state.vods.last)
        await provider.holdRequests()
        let pagination = Task { await state.loadMoreCategoryContentIfNeeded(currentVod: last) }
        try await waitUntil { await provider.callCount() == 2 }
        #expect(state.isLoadingMoreVods)
        state.didClearPerformanceCaches()
        await repository.clear()
        await provider.releaseRequests()
        await pagination.value
        #expect(state.vods.map(\.vodId) == visibleIDs)
        #expect(!state.isLoadingMoreVods)
        #expect(!state.isLoadingVod)
        #expect((await repository.stats()).pageCount == 0)
        await state.loadMoreCategoryContentIfNeeded(currentVod: last)
        #expect(await provider.callCount() == 2)
        #expect((await repository.stats()).pageCount == 0)
    }

    #if DEBUG
    @MainActor
    @Test func originalEmptyHomeRequestsTheExactFirstCategoryAndKeepsExplicitSelection() async throws {
        let provider = OriginalHomeCatalogProvider(home: originalHomeCatalog())
        let (state, _) = try await makeOriginalHomeState(provider: provider)
        await state.loadHomeContent()

        #expect(!state.showsHomeRecommendation)
        #expect(state.selectedCategory?.typeId == originalHomeFirstCategoryID)
        #expect(state.vods.first?.vodId == "category-" + originalHomeFirstCategoryID)
        #expect(await provider.categoryRequests() == [OriginalHomeCategoryRequest(
            id: originalHomeFirstCategoryID, page: "1", filter: true, selection: [:]
        )])
        #expect(await provider.homeCallCount() == 1)

        await state.selectCategory(VodClass(typeId: "second"))
        await state.refreshCurrentCatalog()
        #expect(state.selectedCategory?.typeId == "second")
        #expect(state.vods.first?.vodId == "category-second")
        #expect(!state.showsHomeRecommendation)
        #expect(await provider.categoryRequests().map(\.id) == [originalHomeFirstCategoryID, "second", "second"])
        #expect(await provider.homeCallCount() == 1)
    }

    @MainActor
    @Test(arguments: [false, true])
    func originalNonemptyMergedHomeRetainsRecommendationAcrossEmptyCategories(inHomeVideo: Bool) async throws {
        let recommendation = Vod(vodId: "recommendation", vodName: "Recommendation")
        let provider = OriginalHomeCatalogProvider(
            home: originalHomeCatalog(list: inHomeVideo ? [] : [recommendation]),
            homeVideo: Result(list: inHomeVideo ? [recommendation] : []),
            emptyCategories: true
        )
        let (state, _) = try await makeOriginalHomeState(provider: provider)
        await state.loadHomeContent()
        #expect(state.showsHomeRecommendation)
        #expect(state.selectedCategory == nil)
        #expect(state.vods.map(\.vodId) == ["recommendation"])
        #expect(await provider.categoryRequests().isEmpty)

        await state.selectCategory(VodClass(typeId: "second"))
        #expect(state.vods.isEmpty)
        #expect(state.showsHomeRecommendation)
        await state.loadHomeContent()
        #expect(state.selectedCategory == nil)
        #expect(state.vods.map(\.vodId) == ["recommendation"])
        #expect(await provider.homeCallCount() == 1)
        state.didClearPerformanceCaches()
        #expect(state.showsHomeRecommendation)
        #expect(state.vods.map(\.vodId) == ["recommendation"])
    }

    @MainActor
    @Test(arguments: [0.0, 301.0, 1_801.0])
    func originalEmptyCachedHomeLoadsFirstCategoryAndRestoresItsCache(age: TimeInterval) async throws {
        let clock = CatalogLifecycleClock()
        let repository = CatalogRepository(now: clock.now)
        let provider = OriginalHomeCatalogProvider(home: originalHomeCatalog())
        let (state, site) = try await makeOriginalHomeState(provider: provider, repository: repository)
        let key = CatalogCacheBaseKey(revision: 1, siteKey: site.key, kind: .home)
        _ = try await repository.result(for: key, page: 1) { originalHomeCatalog() }
        clock.advance(age)
        await state.loadHomeContent()
        #expect(!state.showsHomeRecommendation)
        #expect(state.selectedCategory?.typeId == originalHomeFirstCategoryID)
        #expect(state.vods.first?.vodId == "category-" + originalHomeFirstCategoryID)
        #expect(await provider.categoryRequests().map(\.id) == [originalHomeFirstCategoryID])
        if age > 0 {
            try await waitUntil { (await repository.lookup(key)).freshness == .fresh }
        }
        #expect(await provider.homeCallCount() == (age == 0 ? 0 : 1))

        await state.selectCategory(VodClass(typeId: "second"))
        await state.loadHomeContent()
        #expect(state.selectedCategory?.typeId == originalHomeFirstCategoryID)
        #expect(state.vods.first?.vodId == "category-" + originalHomeFirstCategoryID)
        #expect(await provider.categoryRequests().map(\.id) == [originalHomeFirstCategoryID, "second"])
    }

    @MainActor
    @Test(arguments: [false, true])
    func originalStaleHomeRefreshPreservesTheExplicitCategory(failingRefresh: Bool) async throws {
        let clock = CatalogLifecycleClock()
        let repository = CatalogRepository(now: clock.now)
        let provider = OriginalHomeCatalogProvider(
            home: originalHomeCatalog(list: [Vod(vodId: "new-recommendation")]),
            holdHome: true,
            failHome: failingRefresh
        )
        let (state, site) = try await makeOriginalHomeState(provider: provider, repository: repository)
        let key = CatalogCacheBaseKey(revision: 1, siteKey: site.key, kind: .home)
        _ = try await repository.result(for: key, page: 1) { originalHomeCatalog() }
        clock.advance(301)
        await state.loadHomeContent()
        #expect(state.selectedCategory?.typeId == originalHomeFirstCategoryID)
        #expect(!state.showsHomeRecommendation)
        try await waitUntil { await provider.homeCallCount() == 1 }
        await state.selectCategory(VodClass(typeId: "second"))
        await provider.releaseHome()
        try await waitUntil { await provider.completedHomeCallCount() == 1 }
        if !failingRefresh {
            try await waitUntil { state.showsHomeRecommendation }
        }
        #expect(state.selectedCategory?.typeId == "second")
        #expect(state.vods.map(\.vodId) == ["category-second"])
        #expect(state.vodError == nil)
        #expect(!state.isLoadingVod)
        #expect(!state.isCatalogRefreshing)
        #expect(state.showsHomeRecommendation == !failingRefresh)
        #expect(await provider.categoryRequests().map(\.id) == [originalHomeFirstCategoryID, "second"])
    }

    @MainActor
    @Test func originalFailedHomeDoesNotTurnAnErrorIntoAFirstCategoryRequest() async throws {
        let provider = OriginalHomeCatalogProvider(home: originalHomeCatalog(), failHome: true)
        let (state, _) = try await makeOriginalHomeState(provider: provider)
        state.categories = originalHomeCatalog().types
        await state.loadHomeContent()
        #expect(state.vodError != nil)
        #expect(!state.isLoadingVod)
        #expect(await provider.categoryRequests().isEmpty)
    }

    @MainActor
    @Test func explicitCategoryRetiresAPendingOriginalHomeDefault() async throws {
        let provider = OriginalHomeCatalogProvider(home: originalHomeCatalog(), holdHome: true)
        let (state, _) = try await makeOriginalHomeState(provider: provider)
        let home = Task { await state.loadHomeContent() }
        try await waitUntil { await provider.homeCallCount() == 1 }
        await state.selectCategory(VodClass(typeId: "second"))
        await provider.releaseHome()
        await home.value
        #expect(state.selectedCategory?.typeId == "second")
        #expect(state.vods.map(\.vodId) == ["category-second"])
        #expect(await provider.categoryRequests().map(\.id) == ["second"])
    }

    @MainActor
    @Test func nativeEmptyHomeKeepsItsExistingNavigationPolicy() async throws {
        let provider = OriginalHomeCatalogProvider(home: originalHomeCatalog())
        let (state, site) = try await makeOriginalHomeState(provider: provider, backend: .macNative)
        await state.loadHomeContent()
        #expect(state.showsHomeRecommendation == site.showsSyntheticRecommendation)
        #expect(state.selectedCategory == nil)
        #expect(state.vods.isEmpty)
        #expect(await provider.categoryRequests().isEmpty)
    }

    @MainActor
    @Test func originalEmptyHomeWithoutCategoriesRemainsAnEmptySuccess() async throws {
        let provider = OriginalHomeCatalogProvider(home: .empty)
        let (state, _) = try await makeOriginalHomeState(provider: provider)
        await state.loadHomeContent()
        #expect(!state.showsHomeRecommendation)
        #expect(state.selectedCategory == nil)
        #expect(state.vods.isEmpty)
        #expect(state.vodError == nil)
        #expect(await provider.categoryRequests().isEmpty)
    }

    @MainActor
    private func makeOriginalHomeState(
        provider: OriginalHomeCatalogProvider,
        repository: CatalogRepository = CatalogRepository(),
        backend: ProviderExecutionBackend = .androidOriginal
    ) async throws -> (AppState, Site) {
        let site = Site(key: UUID().uuidString, type: 3, api: "csp_HomeCatalog_\(UUID().uuidString)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-home-catalog-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        preferences.providerExecutionPreference = .automatic
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        if backend == .androidOriginal {
            let binding = DevelopmentAndroidRuntimeManifest.Binding(key: site.key, api: site.api, className: "fixture.NoExecution")
            let manifest = DevelopmentAndroidRuntimeManifest(schema: 1, providerID: "test.home-navigation", backend: nil,
                providerSHA256: String(repeating: "0", count: 64), hostSHA256: String(repeating: "0", count: 64),
                bindings: [binding], bootstrapClass: nil, package: nil)
            let layout = DevelopmentAndroidRuntimeLayout(root: directory, manifest: manifest, classPath: [])
            let original = DevelopmentAndroidSiteProvider(runtime: layout, binding: binding, stateDirectory: directory)
            await SpiderReplacementRegistry.shared.register(originalKey: site.key, originalAPI: site.api, provider: original)
        } else {
            await SpiderReplacementRegistry.shared.register(originalKey: site.key, originalAPI: site.api, provider: provider)
        }
        let state = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeBootstrap: nil,
            providerRuntimeRegistrationOverride: { true },
            providerRuntimeStartupOverride: { true },
            // The providers above are the fixture. Do not select the machine's
            // installed component or require a signed application test bundle.
            androidProviderRegistrationOverride: { _ in },
            catalogRepository: repository
        )
        let json = try JSONSerialization.data(withJSONObject: ["sites": [
            ["key": site.key, "type": 3, "api": site.api]
        ]])
        let url = directory.appendingPathComponent("config.json").absoluteString
        // Use the existing config path to capture the real backend. An already-resolved
        // initial payload prevents any helper or content request during setup.
        await state.loadConfig(url: url, persistUserConfig: false, waitForProviderRuntime: false,
            refreshCachedConfiguration: false, preparedInput: ResolvedVodInput(
                json: String(decoding: json, as: UTF8.self), config: Config(url: url),
                kind: .configuration, canonicalURL: url, initialResult: .empty, usesCachedConfiguration: true
            ))
        #expect(state.configError == nil)
        #expect(state.providerExecutionBackends[site.key] == backend)
        #expect(state.activeSite?.key == site.key)
        // Only subsequent content calls are handled by the in-memory request recorder.
        await SpiderReplacementRegistry.shared.register(originalKey: site.key, originalAPI: site.api, provider: provider)
        return (state, site)
    }

    #endif

    @MainActor
    private func makeState(
        repository: CatalogRepository,
        provider: CatalogLifecycleProvider
    ) async -> (AppState, Site) {
        let site = Site(key: UUID().uuidString, type: 3, api: "csp_CatalogLifecycle_\(UUID().uuidString)")
        await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: provider)
        let state = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            providerRuntimeRegistrationOverride: { true },
            providerRuntimeStartupOverride: { true },
            catalogRepository: repository
        )
        state.sites = [site]
        state.activeSite = site
        state.isConfigLoaded = true
        return (state, site)
    }

    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}

private func catalogLifecycleResult(_ id: String, page: Int = 1) -> Result {
    Result(list: [Vod(vodId: id, vodName: id)], page: page, pagecount: 2)
}

private final class CatalogLifecycleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

private actor CatalogLifecycleProvider: SiteContentProvider {
    private var calls = 0
    private var held = false
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func callCount() -> Int { calls }
    func holdRequests() { held = true }
    func releaseRequest(id: String) { waiters.removeValue(forKey: id)?.resume() }
    func releaseRequests() {
        held = false
        for waiter in waiters.values { waiter.resume() }
        waiters.removeAll()
    }
    private func begin(_ id: String) async -> Int {
        calls += 1
        let serial = calls
        if held { await withCheckedContinuation { waiters[id] = $0 } }
        return serial
    }
    func homeContent(site: Site) async throws -> Result {
        let serial = await begin("home")
        let filter = Filter(key: "area", name: "地区", values: [
            FilterValue(name: "国内", value: "domestic"),
            FilterValue(name: "海外", value: "overseas")
        ])
        return Result(
            types: [VodClass(typeId: "movie")],
            list: [Vod(vodId: "home-\(serial)", vodName: "Home")],
            filters: ["movie": [filter]]
        )
    }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        let serial = await begin(tid)
        return catalogLifecycleResult("\(tid)-\(extend["area"] ?? "all")-\(page)-\(serial)", page: Int(page) ?? 1)
    }
    func detailContent(site: Site, id: String) async throws -> Result { .empty }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}

#if DEBUG
private let originalHomeFirstCategoryID = "first +%2F category"

private func originalHomeCatalog(list: [Vod] = []) -> Result {
    Result(types: [
        VodClass(typeId: originalHomeFirstCategoryID, typeName: "First"),
        VodClass(typeId: "second", typeName: "Second")
    ], list: list)
}

private struct OriginalHomeCategoryRequest: Sendable, Equatable {
    let id: String
    let page: String
    let filter: Bool
    let selection: [String: String]
}

private actor OriginalHomeCatalogProvider: SiteContentProvider {
    private let home: Result
    private let homeVideo: Result?
    private let emptyCategories: Bool
    private var holdHome: Bool
    private let failHome: Bool
    private var homeCalls = 0
    private var completedHomeCalls = 0
    private var requests: [OriginalHomeCategoryRequest] = []
    private var homeWaiter: CheckedContinuation<Void, Never>?

    init(home: Result, homeVideo: Result? = .empty, emptyCategories: Bool = false,
         holdHome: Bool = false, failHome: Bool = false) {
        self.home = home
        self.homeVideo = homeVideo
        self.emptyCategories = emptyCategories
        self.holdHome = holdHome
        self.failHome = failHome
    }

    func homeCallCount() -> Int { homeCalls }
    func completedHomeCallCount() -> Int { completedHomeCalls }
    func categoryRequests() -> [OriginalHomeCategoryRequest] { requests }
    func releaseHome() {
        holdHome = false
        homeWaiter?.resume()
        homeWaiter = nil
    }
    func homeContent(site: Site) async throws -> Result {
        homeCalls += 1
        defer { completedHomeCalls += 1 }
        if holdHome { await withCheckedContinuation { homeWaiter = $0 } }
        if failHome { throw URLError(.notConnectedToInternet) }
        return home
    }
    func homeVideoContent(site: Site) async throws -> Result? { homeVideo }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        requests.append(OriginalHomeCategoryRequest(id: tid, page: page, filter: filter, selection: extend))
        return emptyCategories ? .empty : Result(list: [Vod(vodId: "category-" + tid)])
    }
    func detailContent(site: Site, id: String) async throws -> Result { .empty }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}

#endif
