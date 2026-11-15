import Foundation
import Models
import Testing
@testable import NetVplayerApp

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_CATEGORY_RUNTIME_FIXTURE"] != nil))
@MainActor
struct OriginalCategoryPaginationContractTests {
    @Test(arguments: ["paging-missing", "paging-zero", "paging-null", "paging-string-zero"])
    func unknownPageCountRequestsSecondOriginalPage(_ mode: String) async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: mode))
        #expect(fixture.state.contentCatalogState.pageCount == 0)
        await more(fixture)
        #expect(fixture.state.contentCatalogState.currentPage == 2)
        #expect(fixture.state.vods.map(\.vodId) == ["original:\(mode):1", "original:\(mode):2"])
        #expect(try requests(fixture, mode) == ["category:\(mode):1", "category:\(mode):2"])
        try fixture.save(mode)
        await fixture.close()
    }

    @Test func rawCountAndOriginalGetterWinOverProviderKnownFlags() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        for (mode, count) in [("paging-missing", 0), ("paging-null", 0), ("paging-known", 2), ("paging-negative", -1)] {
            let result = try await fixture.provider.categoryContent(site: fixture.site, tid: mode, page: "1", filter: true, extend: [:])
            #expect(result.pagecount == count)
            #expect(result.pageCountIsKnown == (count > 0))
        }
        await fixture.close()
    }

    @Test func responsePageCannotSkipOriginalRequestPages() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "paging-stale-page"))
        #expect(fixture.state.contentCatalogState.currentPage == 1)
        await more(fixture)
        #expect(fixture.state.contentCatalogState.currentPage == 2)
        #expect(try requests(fixture, "paging-stale-page") == ["category:paging-stale-page:1", "category:paging-stale-page:2"])
        try fixture.save("response-page-ignored")
        await fixture.close()
    }

    @Test func latestKnownCountCanShrinkAndStopAtTheCurrentPage() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "paging-shrinking"))
        await more(fixture)
        #expect(fixture.state.contentCatalogState.currentPage == 2)
        #expect(fixture.state.contentCatalogState.pageCount == 2)
        await more(fixture)
        #expect(try requests(fixture, "paging-shrinking").count == 2)
        try fixture.save("shrinking-count")
        await fixture.close()
    }

    @Test func zeroCountAfterKnownPageReopensPaginationAndRetriesEmptyPage() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "paging-reopen"))
        await more(fixture)
        #expect(fixture.state.contentCatalogState.pageCount == 0)
        await more(fixture)
        await more(fixture)
        #expect(fixture.state.contentCatalogState.currentPage == 2)
        #expect(try requests(fixture, "paging-reopen") == ["category:paging-reopen:1", "category:paging-reopen:2", "category:paging-reopen:3", "category:paging-reopen:3"])
        try fixture.save("reopened-count")
        await fixture.close()
    }

    @Test func unknownCachedPagesRestoreRequestPositionWithoutCachingEmptyAttempt() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        let category = VodClass(typeId: "paging-missing")
        await fixture.state.selectCategory(category)
        await more(fixture)
        await more(fixture)
        await fixture.state.selectCategory(VodClass(typeId: "cards"))
        await fixture.state.selectCategory(category)
        #expect(fixture.state.contentCatalogState.currentPage == 2)
        #expect(fixture.state.contentCatalogState.pageCount == 0)
        #expect(fixture.state.vods.count == 2)
        await more(fixture)
        #expect(try requests(fixture, category.typeId) == ["category:paging-missing:1", "category:paging-missing:2", "category:paging-missing:3", "category:paging-missing:3"])
        try fixture.save("unknown-cache-restore")
        await fixture.close()
    }

    @Test func filterRoundTripRestoresOnlyItsPagesAndExactExtend() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        let id = "paging-zero"
        let filter = Filter(key: "area", values: [FilterValue(name: "A", value: "A"), FilterValue(name: "B", value: "B+/% 中文")])
        await fixture.state.loadHomeContent()
        await fixture.state.selectCategory(VodClass(typeId: id))
        await more(fixture)
        await fixture.state.selectCategoryFilter(filter, value: filter.values[1])
        #expect(fixture.state.contentCatalogState.currentPage == 1)
        await more(fixture)
        await fixture.state.selectCategoryFilter(filter, value: filter.values[0])
        #expect(fixture.state.contentCatalogState.currentPage == 2)
        #expect(fixture.state.selectedCategoryFilterValues == ["area": "A"])
        #expect(try requests(fixture, id).count == 4)
        #expect(try fixture.calls().filter { $0.hasPrefix("params:") } == [
            "params:paging-zero:1:true:{area=A}", "params:paging-zero:2:true:{area=A}",
            "params:paging-zero:1:true:{area=B+/% 中文}", "params:paging-zero:2:true:{area=B+/% 中文}"])
        try fixture.save("filter-round-trip")
        await fixture.close()
    }

    @Test func folderPaginationPreservesOpaqueSelectionAndIDs() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        let values = ["opaque": " {\"a\":1} ", "area": "A+%2F 中"]
        fixture.state.selectedCategoryFilterValues = values
        await fixture.state.selectCategory(VodClass(typeId: "paging-missing", typeFlag: "1"), preservingFilterSelection: true)
        await more(fixture)
        #expect(fixture.state.selectedCategoryFilterValues == values)
        #expect(try fixture.calls().contains("params:paging-missing:2:true:{area=A+%2F 中, opaque= {\"a\":1} }"))
        #expect(fixture.state.vods.last?.vodId == "original:paging-missing:2")
        try fixture.save("folder-extend")
        await fixture.close()
    }

    @Test func refreshedKnownEndCannotReplayObsoleteCachedLaterPage() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        let category = VodClass(typeId: "paging-refresh-stop")
        await fixture.state.selectCategory(category)
        await more(fixture)
        #expect(fixture.state.vods.count == 2)
        await fixture.state.selectCategory(category, forceRefresh: true, invalidateCache: false)
        #expect(fixture.state.contentCatalogState.currentPage == 1)
        #expect(fixture.state.contentCatalogState.pageCount == 1)
        #expect(fixture.state.vods.map(\.vodId) == ["original:paging-single:1"])
        await fixture.state.selectCategory(VodClass(typeId: "cards"))
        await fixture.state.selectCategory(category)
        #expect(fixture.state.vods.map(\.vodId) == ["original:paging-single:1"])
        await more(fixture)
        #expect(try requests(fixture, category.typeId).count == 3)
        try fixture.save("refresh-known-end")
        await fixture.close()
    }

    @Test func lateUnknownPageCannotReplaceNewCategory() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "paging-slow"))
        let task = Task { await more(fixture) }
        try await waitForSecond(fixture)
        await fixture.state.selectCategory(VodClass(typeId: "cards"))
        await task.value
        #expect(fixture.state.selectedCategory?.typeId == "cards")
        #expect(fixture.state.vods.map(\.vodId) == ["local-card"])
        #expect(!fixture.state.isLoadingMoreVods)
        try fixture.save("late-unknown-page")
        await fixture.close()
    }

    @Test func clearingCacheRetiresInFlightUnknownPage() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "paging-slow"))
        let ids = fixture.state.vods.map(\.vodId)
        let task = Task { await more(fixture) }
        try await waitForSecond(fixture)
        fixture.state.didClearPerformanceCaches()
        await fixture.repository.clear()
        await task.value
        #expect(fixture.state.vods.map(\.vodId) == ids)
        #expect(!fixture.state.isLoadingMoreVods)
        #expect((await fixture.repository.stats()).pageCount == 0)
        await more(fixture)
        #expect(try requests(fixture, "paging-slow").count == 2)
        try fixture.save("cleared-unknown-page")
        await fixture.close()
    }

    @Test func laterPageExceptionLeavesPageAndRetryUnchanged() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "paging-error"))
        await more(fixture)
        #expect(fixture.state.contentCatalogState.currentPage == 1)
        #expect(!fixture.state.isLoadingMoreVods && fixture.state.vodError == nil)
        await more(fixture)
        #expect(try requests(fixture, "paging-error") == ["category:paging-error:1", "category:paging-error:2", "category:paging-error:2"])
        try fixture.save("page-error-retry")
        await fixture.close()
    }

    @Test func overlappingUnknownNextPageTriggersIssueOnlyOneOriginalCall() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        await fixture.state.selectCategory(VodClass(typeId: "paging-slow"))
        let task = Task { await more(fixture) }
        try await waitForSecond(fixture)
        await more(fixture)
        await task.value
        #expect(try requests(fixture, "paging-slow").count == 2)
        #expect(fixture.state.contentCatalogState.currentPage == 2)
        await fixture.close()
    }

    @Test func explicitEndAndNegativeOriginalCountDoNotRequestAnotherPage() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        for id in ["paging-single", "paging-negative", "paging-known"] {
            await fixture.state.selectCategory(VodClass(typeId: id))
            await more(fixture)
            await more(fixture)
            #expect(try requests(fixture, id).count == (id == "paging-known" ? 2 : 1))
        }
        await fixture.close()
    }

    @Test func unknownFirstPageRefreshRetiresPreviousPagesBeforeTheyCanReplay() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        let category = VodClass(typeId: "paging-zero")
        await fixture.state.selectCategory(category)
        await more(fixture)
        await fixture.state.selectCategory(category, forceRefresh: true, invalidateCache: false)
        #expect(fixture.state.contentCatalogState.currentPage == 1)
        #expect(fixture.state.contentCatalogState.pageCount == 0)
        #expect(fixture.state.vods.map(\.vodId) == ["original:paging-zero:1"])
        await fixture.state.selectCategory(VodClass(typeId: "cards"))
        await fixture.state.selectCategory(category)
        #expect(fixture.state.contentCatalogState.currentPage == 1)
        await more(fixture)
        #expect(try requests(fixture, category.typeId) == ["category:paging-zero:1", "category:paging-zero:2", "category:paging-zero:1", "category:paging-zero:2"])
        try fixture.save("refresh-unknown-first")
        await fixture.close()
    }

    @Test func opaqueCategoryAndReturnedCardIDsRemainExact() async throws {
        let fixture = try await makeOriginalCategoryStateFixture()
        let id = "paging-zero /+%2F 中文"
        await fixture.state.selectCategory(VodClass(typeId: id))
        await more(fixture)
        #expect(fixture.state.selectedCategory?.typeId == id)
        #expect(fixture.state.vods.map(\.vodId) == ["original:" + id + ":1", "original:" + id + ":2"])
        #expect(try requests(fixture, id) == ["category:" + id + ":1", "category:" + id + ":2"])
        try fixture.save("opaque-original-ids")
        await fixture.close()
    }

    private func more(_ fixture: CategoryStateFixture) async {
        if let last = fixture.state.vods.last { await fixture.state.loadMoreCategoryContentIfNeeded(currentVod: last) }
    }
    private func requests(_ fixture: CategoryStateFixture, _ id: String) throws -> [String] {
        try fixture.calls().filter { $0.hasPrefix("category:" + id + ":") }
    }
    private func waitForSecond(_ fixture: CategoryStateFixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(try fixture.calls().contains("category:paging-slow:2")), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try fixture.calls().contains("category:paging-slow:2"))
    }
}
