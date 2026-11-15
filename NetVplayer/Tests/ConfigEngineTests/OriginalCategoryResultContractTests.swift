import Foundation
import Models
import Storage
import Testing
@testable import SpiderEngine
@testable import NetVplayerApp

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_CATEGORY_RUNTIME_FIXTURE"] != nil))
@MainActor
struct OriginalCategoryResultContractTests {
    @Test func emptyOriginalCategoryEndsInEmptyUI() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "empty", typeName: "Offline category"), forceRefresh: true)
        #expect(fixture.state.vodError == nil)
        #expect(fixture.state.vods.isEmpty)
        #expect(!fixture.state.isLoadingVod && !fixture.state.contentCatalogState.isLoadingMore)
        #expect(fixture.state.selectedCategory?.typeId == "empty")
        #expect(status(fixture, "empty") == "catalog_empty")
        #expect(fixture.state.developmentAndroidCategoryObservation?.androidCategoryPayload == .emptyText)
        try fixture.save("empty")
        await fixture.close()
    }

    @Test func malformedOriginalCategoryEndsInEmptyUI() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "malformed"), forceRefresh: true)
        #expect(fixture.state.vodError == nil)
        #expect(fixture.state.vods.isEmpty)
        #expect(!fixture.state.isLoadingVod)
        #expect(status(fixture, "malformed") == "catalog_empty")
        #expect(fixture.state.developmentAndroidCategoryObservation?.androidCategoryPayload == .invalidJSON)
        try fixture.save("malformed")
        await fixture.close()
    }

    @Test func emptyRefreshClearsPreviouslyDisplayedCards() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        let category = VodClass(typeId: "refresh-empty")
        await fixture.state.selectCategory(category)
        #expect(fixture.state.vods.first?.vodId == "local-card")
        await fixture.state.selectCategory(category, forceRefresh: true)
        #expect(fixture.state.vods.isEmpty)
        #expect(fixture.state.vodError == nil)
        #expect(!fixture.state.isCatalogRefreshing && !fixture.state.isLoadingVod)
        #expect(status(fixture, category.typeId) == "catalog_empty")
        try fixture.save("refresh-empty")
        await fixture.close()
    }

    @Test func categoryPayloadsMatchFrozenOriginalResultOracle() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        do {
            let cases: [(String, Result.AndroidCategoryPayload)] = [
                ("empty", .emptyText), ("whitespace", .emptyText), ("malformed", .invalidJSON),
                ("array", .invalidJSON), ("scalar", .invalidJSON), ("null", .nullValue),
                ("json-null", .nullValue), ("empty-object", .object), ("empty-list", .object), ("bad-list", .invalidObject)
            ]
            for (mode, shape) in cases {
                let result = try await fixture.provider.categoryContent(site: fixture.site, tid: mode, page: "1", filter: true, extend: [:])
                #expect(result.list.isEmpty && result.msg.isEmpty)
                #expect(result.pagecount <= 1 && !result.pageCountIsKnown)
                #expect(result.androidCategoryPayload == shape)
                #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("androidCategoryPayload"))
            }
            let cards = try await fixture.provider.categoryContent(site: fixture.site, tid: "cards", page: "1", filter: true, extend: [:])
            #expect(cards.list.first?.vodId == "local-card" && cards.pagecount == 2)
            #expect(cards.androidCategoryPayload == .object)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test func originalExceptionsRemainErrorsAndDoNotExposeRawText() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "throw"), forceRefresh: true)
        #expect(fixture.state.vodError != nil)
        #expect(fixture.state.vods.isEmpty)
        #expect(status(fixture, "throw") == "catalog_error")
        let encoded = String(decoding: try JSONEncoder().encode(fixture.state.developmentAndroidCategoryObservation), as: UTF8.self)
        #expect(!encoded.contains("secret-fixture-marker"))
        #expect(fixture.state.developmentAndroidCategoryObservation?.failure != nil)
        try fixture.save("exception")
        await fixture.close()
    }

    @Test func failedRefreshCannotUseRetainedCardsAsAuditSuccess() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        let category = VodClass(typeId: "refresh-throw")
        await fixture.state.selectCategory(category)
        #expect(status(fixture, category.typeId) == "catalog_observed")
        await fixture.state.selectCategory(category, forceRefresh: true)
        #expect(fixture.state.vodError == nil && fixture.state.vods.first?.vodId == "local-card")
        #expect(status(fixture, category.typeId) == "catalog_error")
        #expect(fixture.state.developmentAndroidCategoryObservation?.outcome == "error_retained_content")
        try fixture.save("failed-refresh")
        await fixture.close()
    }

    @Test func emptyCacheRestoresWithoutAnotherOriginalRequest() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "empty"))
        await fixture.state.selectCategory(VodClass(typeId: "cards"))
        await fixture.state.selectCategory(VodClass(typeId: "empty"))
        #expect(fixture.state.vodError == nil && fixture.state.vods.isEmpty)
        #expect(status(fixture, "empty") == "catalog_empty")
        #expect(fixture.state.developmentAndroidCategoryObservation?.outcome == "cache_fresh")
        #expect(try fixture.calls().filter { $0 == "category:empty:1" }.count == 1)
        try fixture.save("cached-empty")
        await fixture.close()
    }

    @Test func emptyFirstPageRefreshCannotResurrectCachedLaterPages() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        let category = VodClass(typeId: "paged-empty")
        await fixture.state.selectCategory(category)
        await fixture.state.loadMoreCategoryContentIfNeeded(currentVod: try #require(fixture.state.vods.last))
        #expect(fixture.state.vods.map(\.vodId) == ["local-card", "second-card"])
        // Background stale refresh uses this path and retains cached pages until the response.
        await fixture.state.selectCategory(category, forceRefresh: true, invalidateCache: false)
        #expect(fixture.state.vods.isEmpty)
        #expect(status(fixture, category.typeId) == "catalog_empty")
        try fixture.save("empty-first-page-refresh")
        await fixture.close()
    }

    @Test func emptyLaterPageRetainsTheLastSuccessfulPageAndRetriesTheSameOriginalPage() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "page-two-empty"))
        let first = try #require(fixture.state.vods.last)
        await fixture.state.loadMoreCategoryContentIfNeeded(currentVod: first)
        #expect(fixture.state.vods.map(\.vodId) == ["local-card"])
        #expect(!fixture.state.contentCatalogState.isLoadingMore)
        #expect(fixture.state.contentCatalogState.currentPage == 1)
        await fixture.state.loadMoreCategoryContentIfNeeded(currentVod: first)
        #expect(try fixture.calls().filter { $0.hasPrefix("category:page-two-empty:") } == [
            "category:page-two-empty:1", "category:page-two-empty:2", "category:page-two-empty:2"])
        try fixture.save("empty-later-page")
        await fixture.close()
    }

    @Test func lateEmptyCategoryCannotReplaceNewSelectionOrItsAuditStatus() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        let old = Task { await fixture.state.selectCategory(VodClass(typeId: "slow-empty"), forceRefresh: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(try fixture.calls().contains("category:slow-empty:1")), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try fixture.calls().contains("category:slow-empty:1"))
        await fixture.state.selectCategory(VodClass(typeId: "cards"), forceRefresh: true)
        await old.value
        #expect(fixture.state.selectedCategory?.typeId == "cards")
        #expect(fixture.state.vods.first?.vodId == "local-card")
        #expect(status(fixture, "cards") == "catalog_observed")
        #expect(status(fixture, "slow-empty") == "catalog_incomplete")
        try fixture.save("late-empty")
        await fixture.close()
    }

    @Test func clearedCachesRetireThePreviousCategoryAuditObservation() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "cards"))
        #expect(status(fixture, "cards") == "catalog_observed")
        fixture.state.didClearPerformanceCaches()
        #expect(fixture.state.developmentAndroidCategoryObservation == nil)
        #expect(status(fixture, "cards") == "catalog_incomplete")
        await fixture.close()
    }

    @Test func auditEmptyFailureStageAndProvenanceCannotBeForgedByProviderJSON() throws {
        #expect(DevelopmentAndroidAuditContract.requestedCategoryFailure(advertised: true, status: "catalog_empty") == "requested_category_empty")
        #expect(DevelopmentAndroidAuditContract.requestedCategoryFailure(advertised: true, status: "catalog_error") == "requested_category_unavailable")
        #expect(DevelopmentAndroidAuditContract.requestedCategoryFailure(advertised: false, status: "catalog_empty") == "requested_category_not_advertised")
        #expect(DevelopmentAndroidAuditContract.requestedCategoryFailure(advertised: true, status: "catalog_incomplete") == "requested_category_incomplete")
        let result = try JSONDecoder().decode(Result.self, from: Data(#"{"androidCategoryPayload":"emptyText","list":[]}"#.utf8))
        #expect(result.androidCategoryPayload == nil)
    }

    private func status(_ fixture: CategoryStateFixture, _ id: String) -> String {
        DevelopmentAndroidAuditContract.categoryStatus(state: fixture.state, id: id, completed: true)
    }
}

@MainActor
func makeOriginalCategoryStateFixture(repository: CatalogRepository = CatalogRepository()) async throws -> CategoryStateFixture {
    let root = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_CATEGORY_RUNTIME_FIXTURE"])
    let site = Site(key: "CategoryResultFixture-" + UUID().uuidString, name: "Offline fixture", type: 3, api: "csp_CategoryResultContractGuard")
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: URL(fileURLWithPath: root)).selectingOriginalBindings(sites: [site])
    let evidence = ProcessInfo.processInfo.environment["NETVPLAYER_CATEGORY_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory
    let directory = evidence.appendingPathComponent("category-state-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: directory)
    await SpiderReplacementRegistry.shared.register(originalKey: site.key, originalAPI: site.api, provider: provider)
    let defaults = try #require(UserDefaults(suiteName: site.key))
    let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
    preferences.providerExecutionPreference = .androidPreferred
    let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
        userPreferences: preferences, providerRuntimeBootstrap: nil, catalogRepository: repository)
    state.sites = [site]
    state.activeSite = site
    state.isConfigLoaded = true
    state.categories = [VodClass(typeId: "empty", typeName: "Offline category")]
    return CategoryStateFixture(state: state, site: site, provider: provider, directory: directory, defaults: defaults, repository: repository)
}

@MainActor
struct CategoryStateFixture {
    let state: AppState
    let site: Site
    let provider: DevelopmentAndroidSiteProvider
    let directory: URL
    let defaults: UserDefaults
    let repository: CatalogRepository
    func calls() throws -> [String] {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "category-calls.log" }
        return try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init) }
    }
    func save(_ name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["case": name, "items": state.vods.count,
            "error": state.vodError != nil, "loading": state.isLoadingVod, "refreshing": state.isCatalogRefreshing,
            "page": state.contentCatalogState.currentPage, "pages": state.contentCatalogState.pageCount,
            "ids": state.vods.map(\.vodId), "selection": state.selectedCategoryFilterValues,
            "status": DevelopmentAndroidAuditContract.categoryStatus(state: state, id: state.selectedCategory?.typeId ?? "", completed: true),
            "outcome": state.developmentAndroidCategoryObservation?.outcome ?? "none"], options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent(name + ".safe.json"))
    }
    func close() async {
        await state.cancelLoading()
        await provider.shutdown()
        defaults.removePersistentDomain(forName: site.key)
    }
}
