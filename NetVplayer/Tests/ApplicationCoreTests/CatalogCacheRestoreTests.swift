import ApplicationCore
import Models
import Testing

@Test func cachedCategoryRestoreRebuildsConsecutivePages() {
    let category = VodClass(typeId: "movie", typeName: "电影")
    var state = ContentCatalogState(
        categories: [category],
        filtersByCategoryID: ["movie": []]
    )
    state.selectionsByCategoryID["movie"] = ["area": "cn"]
    let first = ContentCatalogPayload(
        vods: [Vod(vodId: "1", vodName: "One")],
        page: 1,
        pageCount: 2
    )
    let second = ContentCatalogPayload(
        vods: [Vod(vodId: "2", vodName: "Two")],
        page: 2,
        pageCount: 2
    )

    let restored = ContentCatalogCore.restoreCategory(
        state,
        category: category,
        payloads: [first, second]
    )

    #expect(restored.selectedCategory == category)
    #expect(restored.vods.map(\.vodId) == ["1", "2"])
    #expect(restored.currentPage == 2)
    #expect(restored.pageCount == 2)
    #expect(!restored.isLoading)
    #expect(!restored.isLoadingMore)
}

@Test func cachedHomeRestoreClearsCategorySelection() {
    let category = VodClass(typeId: "movie", typeName: "电影")
    let state = ContentCatalogState(
        vods: [Vod(vodId: "old", vodName: "Old")],
        categories: [category],
        selectedCategory: category,
        isLoading: true
    )
    let payload = ContentCatalogPayload(
        types: [category],
        vods: [Vod(vodId: "home", vodName: "Home")],
        page: 1,
        pageCount: 1
    )

    let restored = ContentCatalogCore.restoreHome(state, payload: payload)

    #expect(restored.selectedCategory == nil)
    #expect(restored.vods.map(\.vodId) == ["home"])
    #expect(!restored.isLoading)
}
