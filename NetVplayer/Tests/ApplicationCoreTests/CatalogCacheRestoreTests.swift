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

@Test func originalFolderCategoryInheritsTheExactFilterSelection() throws {
    let values = ["area": "A+%2F 中", "opaque": " {\"a\":1} "]
    let state = ContentCatalogState(selectedFilterValues: values)
    let folder = VodClass(typeId: " {\"id\":\"/%2F+\"} ", typeName: "Folder", typeFlag: "1")
    let transition = ContentCatalogCore.beginCategory(state, category: folder, preservingFilterSelection: true)
    let request = try #require(transition.request)
    #expect(request.categoryID == folder.typeId)
    #expect(request.selection == values)
    #expect(transition.state.selectedFilterValues == values)
    let restored = ContentCatalogCore.restoreCategory(
        transition.state, category: folder,
        payloads: [ContentCatalogPayload(vods: [Vod(vodId: "last")], filters: [folder.typeId: []], pageCount: 2)]
    )
    #expect(restored.selectedFilterValues == values)
    let nextPage = try #require(ContentCatalogCore.beginNextPage(restored, triggerVodID: "last").request)
    #expect(nextPage.selection == values)
    let refreshed = ContentCatalogCore.beginCategory(restored, category: folder)
    #expect(refreshed.request?.selection == values)
    let nested = VodClass(typeId: "nested", typeName: "Nested", typeFlag: "1")
    let nestedRequest = ContentCatalogCore.beginCategory(restored, category: nested, preservingFilterSelection: true)
    #expect(nestedRequest.request?.selection == values)
    // Selecting a top-level category with the same ID must leave folder mode.
    let topLevel = VodClass(typeId: folder.typeId, typeName: folder.typeName)
    let returned = ContentCatalogCore.beginCategory(restored, category: topLevel)
    #expect(returned.state.selectedFilterValues.isEmpty)
    let home = ContentCatalogCore.restoreHome(restored, payload: ContentCatalogPayload())
    #expect(ContentCatalogCore.beginCategory(home, category: folder).state.selectedFilterValues.isEmpty)
    // Ordinary top-level categories still use their own filter configuration.
    let ordinary = ContentCatalogCore.beginCategory(state, category: folder)
    #expect(ordinary.state.selectedFilterValues.isEmpty)
}
