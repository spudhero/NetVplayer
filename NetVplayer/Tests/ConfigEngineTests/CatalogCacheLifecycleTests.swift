import Foundation
import Models
import SpiderEngine
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
