import ApplicationCore
import Models
import Testing

@Suite("Application core content browsing")
struct ContentBrowsingCoreTests {
    @Test func homeLifecycleResetsFiltersAndBuildsVisibleSnapshot() {
        let oldVod = Vod(vodId: "old", vodName: "Old")
        let current = ContentCatalogState(
            vods: [oldVod],
            categories: [VodClass(typeId: "old", typeName: "Old")],
            categoryFilters: [Filter(key: "genre", name: "类型")],
            selectedFilterValues: ["genre": "action"],
            filtersByCategoryID: ["old": [Filter(key: "genre", name: "类型")]],
            selectionsByCategoryID: ["old": ["genre": "action"]],
            currentPage: 3,
            pageCount: 5,
            isLoadingMore: true
        )

        let loading = ContentCatalogCore.beginHome(current)
        #expect(loading.generation == 1)
        #expect(loading.isLoading)
        #expect(!loading.isLoadingMore)
        #expect(loading.currentPage == 1)
        #expect(loading.pageCount == 1)
        #expect(loading.categoryFilters.isEmpty)
        #expect(loading.selectedFilterValues.isEmpty)
        #expect(loading.filtersByCategoryID.isEmpty)
        #expect(loading.selectionsByCategoryID.isEmpty)
        #expect(loading.vods.map(\.vodId) == ["old"])

        let movie = VodClass(typeId: "movie", typeName: "电影")
        let payload = ContentCatalogPayload(
            types: [
                VodClass(typeId: "recommend", typeName: "任意"),
                movie,
                VodClass(typeId: "MOVIE", typeName: "重复电影"),
                VodClass(typeId: "shows", typeName: "推荐"),
                VodClass(typeId: "series", typeName: "剧集")
            ],
            vods: [Vod(vodId: "new", vodName: "New")],
            filters: ["movie": [Filter(key: "genre", name: "类型")]],
            page: 2,
            pageCount: 4
        )
        let received = ContentCatalogCore.receiveHome(
            loading,
            generation: loading.generation,
            payload: payload
        )

        #expect(received.categories.map(\.typeId) == ["movie", "series"])
        #expect(received.vods.map(\.vodId) == ["new"])
        #expect(received.currentPage == 2)
        #expect(received.pageCount == 4)
        #expect(!received.isLoading)
    }

    @Test func staleHomeResponseAndFailureCannotReplaceNewerState() {
        let first = ContentCatalogCore.beginHome(ContentCatalogState())
        let second = ContentCatalogCore.beginHome(first)
        let stalePayload = ContentCatalogPayload(
            types: [VodClass(typeId: "stale", typeName: "Stale")],
            vods: [Vod(vodId: "stale", vodName: "Stale")]
        )

        let ignoredSuccess = ContentCatalogCore.receiveHome(
            second,
            generation: first.generation,
            payload: stalePayload
        )
        let ignoredFailure = ContentCatalogCore.failHome(
            second,
            generation: first.generation,
            clearContent: true
        )

        #expect(ignoredSuccess.generation == second.generation)
        #expect(ignoredSuccess.categories.isEmpty)
        #expect(ignoredFailure.isLoading)
    }

    @Test func requiredTextFilterWaitsThenProducesNormalizedRequest() {
        let category = VodClass(typeId: "catalog", typeName: "精选")
        let filters = [
            Filter(
                key: "genre",
                name: "类型",
                values: [
                    FilterValue(name: "全部", value: ""),
                    FilterValue(name: "动作", value: "action")
                ]
            ),
            Filter(key: "query", name: "关键词", inputKind: .text, isRequired: true)
        ]
        let state = ContentCatalogState(filtersByCategoryID: [category.typeId: filters])

        let waiting = ContentCatalogCore.beginCategory(state, category: category)
        #expect(waiting.request == nil)
        #expect(!waiting.state.isLoading)
        #expect(waiting.state.selectedFilterValues == ["genre": "", "query": ""])

        let drafted = ContentCatalogCore.updateTextDraft(
            waiting.state,
            filterKey: "query",
            value: "  Matrix  "
        )
        let applied = ContentCatalogCore.applyTextFilter(
            drafted.state,
            filterKey: "query"
        )

        #expect(applied.failure == nil)
        #expect(applied.request?.page == 1)
        #expect(applied.request?.selection == ["genre": "", "query": "Matrix"])
        #expect(applied.state.isLoading)
        #expect(applied.state.vods.isEmpty)
    }

    @Test func optionsAndTextFiltersRejectUndeclaredValues() {
        let category = VodClass(typeId: "catalog", typeName: "精选")
        let filters = [
            Filter(
                key: "genre",
                name: "类型",
                values: [FilterValue(name: "动作", value: "action")]
            ),
            Filter(key: "query", name: "关键词", inputKind: .text)
        ]
        let selected = ContentCatalogCore.beginCategory(
            ContentCatalogState(filtersByCategoryID: [category.typeId: filters]),
            category: category
        )

        let invalidOption = ContentCatalogCore.selectOption(
            selected.state,
            filterKey: "genre",
            value: "comedy"
        )
        #expect(invalidOption.failure == .invalidOption)
        #expect(invalidOption.request == nil)

        let invalidFilter = ContentCatalogCore.updateTextDraft(
            selected.state,
            filterKey: "missing",
            value: "value"
        )
        #expect(invalidFilter.failure == .invalidFilter)

        let invalidTextDraft = ContentCatalogCore.updateTextDraft(
            selected.state,
            filterKey: "query",
            value: "\u{0000}"
        )
        let invalidText = ContentCatalogCore.applyTextFilter(
            invalidTextDraft.state,
            filterKey: "query"
        )
        #expect(invalidText.failure == .invalidTextFilter(name: "关键词"))

        let validOption = ContentCatalogCore.selectOption(
            selected.state,
            filterKey: "genre",
            value: "action"
        )
        #expect(validOption.failure == nil)
        #expect(validOption.request?.selection["genre"] == "action")
    }

    @Test func categoryResponseUpdatesFiltersAndRejectsStaleGeneration() {
        let category = VodClass(typeId: "catalog", typeName: "精选")
        let initialFilter = Filter(
            key: "genre",
            name: "类型",
            values: [FilterValue(name: "动作", value: "action")]
        )
        let started = ContentCatalogCore.beginCategory(
            ContentCatalogState(filtersByCategoryID: [category.typeId: [initialFilter]]),
            category: category
        )
        let request = started.request!
        let returnedFilter = Filter(
            key: "genre",
            name: "类型",
            values: [FilterValue(name: "剧情", value: "drama")]
        )
        let received = ContentCatalogCore.receiveCategory(
            started.state,
            request: request,
            payload: ContentCatalogPayload(
                vods: [Vod(vodId: "movie", vodName: "Movie")],
                filters: [category.typeId: [returnedFilter]],
                page: 2,
                pageCount: 3
            )
        )

        #expect(received.vods.map(\.vodId) == ["movie"])
        #expect(received.categoryFilters.first?.values.first?.value == "drama")
        #expect(received.selectedFilterValues["genre"] == "drama")
        #expect(received.currentPage == 2)
        #expect(received.pageCount == 3)

        let newer = ContentCatalogCore.beginCategory(received, category: category)
        let ignored = ContentCatalogCore.receiveCategory(
            newer.state,
            request: request,
            payload: ContentCatalogPayload(vods: [Vod(vodId: "stale", vodName: "Stale")])
        )
        #expect(ignored.vods.isEmpty)
        #expect(ignored.generation == newer.state.generation)
    }

    @Test func paginationRequiresLastCardAndDeduplicatesStableIDs() {
        let category = VodClass(typeId: "catalog", typeName: "精选")
        let state = ContentCatalogState(
            vods: [
                Vod(vodId: "a", vodName: "A"),
                Vod(vodId: "b", vodName: "B")
            ],
            selectedCategory: category,
            currentPage: 1,
            pageCount: 3
        )

        #expect(ContentCatalogCore.beginNextPage(state, triggerVodID: "a").request == nil)
        let loading = ContentCatalogCore.beginNextPage(state, triggerVodID: "b")
        #expect(loading.request?.page == 2)
        #expect(loading.state.isLoadingMore)

        let received = ContentCatalogCore.receiveCategory(
            loading.state,
            request: loading.request!,
            payload: ContentCatalogPayload(
                vods: [
                    Vod(vodId: "b", vodName: "Duplicate"),
                    Vod(vodId: "c", vodName: "C")
                ],
                page: 2,
                pageCount: 3
            )
        )
        #expect(received.vods.map(\.vodId) == ["a", "b", "c"])
        #expect(received.currentPage == 2)
        #expect(!received.isLoadingMore)
    }

    @Test func categoryDeduplicatesEquivalentPlaybackAcrossPages() {
        let category = VodClass(typeId: "56", typeName: "港台三级")
        let started = ContentCatalogCore.beginCategory(ContentCatalogState(), category: category)
        let firstPage = ContentCatalogCore.receiveCategory(
            started.state,
            request: started.request!,
            payload: ContentCatalogPayload(
                vods: [
                    Vod(
                        vodId: "original",
                        vodName: "喜爱夜蒲",
                        vodPic: "original.jpg",
                        vodPlayFrom: "wsym3u8",
                        vodPlayUrl: "HD$https://media.example.test/one.m3u8"
                    ),
                    Vod(
                        vodId: "duplicate",
                        vodName: " 喜爱夜蒲 ",
                        vodPic: "duplicate.jpg",
                        vodPlayFrom: "wsym3u8",
                        vodPlayUrl: "HD$https://media.example.test/one.m3u8"
                    ),
                    Vod(
                        vodId: "alternate",
                        vodName: "喜爱夜蒲",
                        vodPlayFrom: "backup",
                        vodPlayUrl: "HD$https://media.example.test/alternate.m3u8"
                    ),
                    Vod(vodId: "summary-a", vodName: "喜爱夜蒲"),
                    Vod(vodId: "summary-b", vodName: "喜爱夜蒲")
                ],
                page: 1,
                pageCount: 3
            )
        )

        #expect(firstPage.vods.map(\.vodId) == ["original", "alternate", "summary-a", "summary-b"])
        #expect(firstPage.vods.first?.vodPic == "original.jpg")

        let loading = ContentCatalogCore.beginNextPage(firstPage, triggerVodID: "summary-b")
        let secondPage = ContentCatalogCore.receiveCategory(
            loading.state,
            request: loading.request!,
            payload: ContentCatalogPayload(
                vods: [
                    Vod(
                        vodId: "later-duplicate",
                        vodName: "喜爱夜蒲",
                        vodPlayFrom: "wsym3u8",
                        vodPlayUrl: "HD$https://media.example.test/one.m3u8"
                    ),
                    Vod(
                        vodId: "new-content",
                        vodName: "喜爱夜蒲2",
                        vodPlayFrom: "wsym3u8",
                        vodPlayUrl: "HD$https://media.example.test/two.m3u8"
                    )
                ],
                page: 2,
                pageCount: 3
            )
        )

        #expect(secondPage.vods.map(\.vodId) == ["original", "alternate", "summary-a", "summary-b", "new-content"])
        #expect(secondPage.currentPage == 2)
    }

    @Test func searchRanksResultsAndReplacesDuplicateSites() {
        let started = ContentSearchCore.begin(
            ContentSearchState(),
            keyword: "Dune",
            siteOrder: ["a", "b", "c", "a"]
        )
        let generation = started.generation
        let withError = ContentSearchCore.ingest(
            started,
            generation: generation,
            result: SearchResult(siteName: "A", siteKey: "a", error: "failed")
        )
        let withEmpty = ContentSearchCore.ingest(
            withError,
            generation: generation,
            result: SearchResult(siteName: "B", siteKey: "b")
        )
        let withVod = ContentSearchCore.ingest(
            withEmpty,
            generation: generation,
            result: SearchResult(
                siteName: "C",
                siteKey: "c",
                vods: [Vod(vodId: "dune", vodName: "Dune")]
            )
        )

        #expect(withVod.results.map(\.siteKey) == ["c", "b", "a"])
        let replaced = ContentSearchCore.ingest(
            withVod,
            generation: generation,
            result: SearchResult(
                siteName: "A",
                siteKey: "a",
                vods: [Vod(vodId: "dune-2", vodName: "Dune 2")]
            )
        )
        #expect(replaced.results.map(\.siteKey) == ["a", "c", "b"])
        #expect(replaced.results.count == 3)
        #expect(ContentSearchCore.summary(replaced, generation: generation) == .init(
            totalResults: 2,
            errorCount: 0
        ))
    }

    @Test func searchPresentationPrioritizesTitleMatchesAndRotatesSources() {
        struct Placement {
            let vod: Vod
            let sourceOrder: Int
            let itemOrder: Int
        }

        let placements = [
            Placement(vod: Vod(vodId: "a0", vodName: "仙逆"), sourceOrder: 0, itemOrder: 0),
            Placement(vod: Vod(vodId: "a1", vodName: "仙逆"), sourceOrder: 0, itemOrder: 1),
            Placement(vod: Vod(vodId: "b0", vodName: "仙逆"), sourceOrder: 1, itemOrder: 0),
            Placement(vod: Vod(vodId: "b1", vodName: "仙逆 年番"), sourceOrder: 1, itemOrder: 1),
            Placement(vod: Vod(vodId: "c0", vodName: "仙逆"), sourceOrder: 2, itemOrder: 0),
            Placement(vod: Vod(vodId: "c1", vodName: "动画仙逆合集"), sourceOrder: 2, itemOrder: 1),
            Placement(
                vod: Vod(vodId: "c2", vodName: "年番动画", vodActor: "仙逆"),
                sourceOrder: 2,
                itemOrder: 2
            ),
            Placement(vod: Vod(vodId: "d0", vodName: "凡人修仙传"), sourceOrder: 3, itemOrder: 0)
        ]

        let ordered = SearchResultPresentationPolicy.ordered(
            placements,
            keyword: " 仙 逆 ",
            vod: \.vod,
            sourceOrder: \.sourceOrder,
            sourceItemOrder: \.itemOrder
        )

        #expect(ordered.map { $0.vod.vodId } == ["a0", "b0", "c0", "a1", "b1", "c1", "c2", "d0"])
        #expect(SearchResultPresentationPolicy.matchKind(of: placements[0].vod, keyword: " 仙 逆 ") == .exact)
        #expect(SearchResultPresentationPolicy.matchKind(of: placements[3].vod, keyword: "仙逆") == .prefix)
        #expect(SearchResultPresentationPolicy.matchKind(of: placements[5].vod, keyword: "仙逆") == .contains)
        #expect(SearchResultPresentationPolicy.matchKind(of: placements[6].vod, keyword: "仙逆") == .metadata)
        #expect(SearchResultPresentationPolicy.matchKind(of: placements[7].vod, keyword: "仙逆") == .other)
    }

    @Test func searchGenerationPreventsOldResultsAndCompletionFromMutatingNewState() {
        let first = ContentSearchCore.begin(ContentSearchState(), keyword: "first")
        let second = ContentSearchCore.begin(first, keyword: "second")
        let staleResult = ContentSearchCore.ingest(
            second,
            generation: first.generation,
            result: SearchResult(
                siteName: "Old",
                siteKey: "old",
                vods: [Vod(vodId: "old", vodName: "Old")]
            )
        )
        let staleFinish = ContentSearchCore.finish(
            staleResult,
            generation: first.generation
        )

        #expect(staleFinish.keyword == "second")
        #expect(staleFinish.results.isEmpty)
        #expect(staleFinish.isLoading)

        let reset = ContentSearchCore.reset(staleFinish)
        let afterReset = ContentSearchCore.ingest(
            reset,
            generation: second.generation,
            result: SearchResult(siteName: "Late", siteKey: "late")
        )
        #expect(afterReset.keyword.isEmpty)
        #expect(afterReset.results.isEmpty)
        #expect(!afterReset.isLoading)
    }
}
