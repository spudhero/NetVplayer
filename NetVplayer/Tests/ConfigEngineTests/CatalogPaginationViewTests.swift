import AppKit
import Models
import SpiderEngine
import SwiftUI
import Testing
@testable import NetVplayerApp

@Suite(.serialized)
struct CatalogPaginationViewTests {
    @MainActor
    @Test(arguments: [1, 2])
    func manualRefreshRechecksPaginationForReusedPosterCards(pageCount: Int) async throws {
        let provider = StablePosterPageProvider(pageCount: pageCount)
        let site = Site(key: UUID().uuidString, type: 3, api: "csp_PaginationView_\(UUID().uuidString)")
        await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: provider)
        let state = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            providerRuntimeRegistrationOverride: { true },
            providerRuntimeStartupOverride: { true },
            catalogRepository: CatalogRepository()
        )
        state.sites = [site]
        state.activeSite = site
        state.isConfigLoaded = true
        let category = VodClass(typeId: "books", typeName: "图书")
        await state.loadHomeContent()
        await state.selectCategory(category)

        // Ten posters fit in the viewport. Refresh must reuse those same IDs,
        // as real sources do, without requiring a scroll or a second onAppear.
        let size = CGSize(width: 1_500, height: 1_000)
        let hostingView = NSHostingView(rootView: VodHomeView().environmentObject(state))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.frame = CGRect(origin: .zero, size: size)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try await waitForPages(pageCount, state: state, hostingView: hostingView)
        let originalIDs = state.vods.map(\.vodId)

        for _ in 0..<2 {
            await state.refreshCurrentCatalog()
            #expect(!state.isCatalogRefreshing)
            try await waitForPages(pageCount, state: state, hostingView: hostingView)
            #expect(state.vods.map(\.vodId) == originalIDs)
            #expect(!state.isLoadingMoreVods)
        }

        // Exactly one request per available page on initial load and each refresh.
        #expect(await provider.requestedPages() == Array(repeating: Array(1...pageCount), count: 3).flatMap { $0 })
    }

    @MainActor
    private func waitForPages(
        _ pageCount: Int,
        state: AppState,
        hostingView: NSView
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            hostingView.layoutSubtreeIfNeeded()
            hostingView.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        } while state.contentCatalogState.currentPage < pageCount && ContinuousClock.now < deadline
        try #require(state.contentCatalogState.currentPage == pageCount)
        #expect(state.vods.count == pageCount * 10)
    }
}

private actor StablePosterPageProvider: SiteContentProvider {
    private let pageCount: Int
    private var pages: [Int] = []

    init(pageCount: Int) { self.pageCount = pageCount }

    func requestedPages() -> [Int] { pages }

    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        let pageNumber = Int(page) ?? 1
        pages.append(pageNumber)
        return Result(
            list: (0..<10).map { index in
                let id = "\(tid)-\(pageNumber)-\(index)"
                return Vod(vodId: id, vodName: id)
            },
            page: pageNumber,
            pagecount: pageCount
        )
    }

    func homeContent(site: Site) async throws -> Result {
        Result(types: [VodClass(typeId: "books", typeName: "图书")])
    }
    func detailContent(site: Site, id: String) async throws -> Result { .empty }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}
