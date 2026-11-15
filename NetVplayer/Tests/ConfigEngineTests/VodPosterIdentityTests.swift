import Foundation
import Models
import Testing
@testable import NetVplayerApp

@Test func vodPosterGridKeepsAllTwentyCardsWhenSourceOmitsIDs() throws {
    let raw = try JSONSerialization.data(withJSONObject: (0..<20).map {
        ["vod_name": "Movie \($0)", "vod_pic": "https://example.test/poster/\($0).jpg", "vod_remarks": ""]
    })
    let vods = try JSONDecoder().decode([Vod].self, from: raw)
    let rows = HomeVisualPolicy.posterRowStarts(itemCount: vods.count, columnCount: 9)
    let cards = rows.flatMap { row in
        vods[row..<min(row + 9, vods.count)].enumerated().map {
            VodPosterGridItem(vod: $0.element, index: row + $0.offset)
        }
    }
    #expect(cards.count == 20)
    #expect(Set(cards.map(\.id)).count == 20)
    #expect(cards.map { $0.vod.vodName } == vods.map(\.vodName))
    #expect(cards.allSatisfy { $0.vod.vodId.isEmpty })
    let original = Vod(vodId: "opaque/+%20=", vodName: "Original")
    #expect(VodPosterGridItem(vod: original, index: 0).id == VodPosterGridItem(vod: original, index: 12).id)
    #expect(VodPosterGridItem(vod: original, index: 0).vod.vodId == original.vodId)
}

@MainActor
@Test func vodPosterWithoutContentIDStillUsesDouDouSearchAction() async throws {
    let state = AppState(loadDefaultConfig: false, startProxyServer: false)
    let site = Site(key: "点我切源", name: "豆豆┃片单", type: 3, api: "csp_DouDouGuard", searchable: 0, quickSearch: 0)
    state.activeSite = site
    state.sites = [site]
    state.selectedTab = .vodHome
    await state.openVodCard(Vod(vodName: "Fixture movie", siteKey: site.key))
    #expect(state.selectedTab == .search)
    #expect(state.searchKeyword == "Fixture movie")
    #expect(!state.isDetailPresented)
}
