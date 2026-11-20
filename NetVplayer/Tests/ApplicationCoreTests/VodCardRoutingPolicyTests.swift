import ApplicationCore
import Models
import Testing

@Suite("Provider card routing")
struct VodCardRoutingPolicyTests {
    @Test func resourceFolderStaysInItsProvider() {
        let site = Site(key: "catalog", type: 3, api: "provider.example")
        let card = Vod(vodId: "/movies/12/@folder", vodName: "Resources", siteKey: "catalog")
        #expect(VodCardRoutingPolicy.providerFolderCategory(site: site, vod: card)?.typeId == card.vodId)
        #expect(!VodCardRoutingPolicy.shouldRouteToGlobalSearch(site: site, vod: card))
        #expect(VodCardRoutingPolicy.providerFolderCategory(site: Site(key: "other", type: 3), vod: card) == nil)
        #expect(VodCardRoutingPolicy.providerFolderCategory(site: Site(key: "catalog", type: 1), vod: card) == nil)
    }

    @Test func searchCardsAndPlayableCardsKeepTheirRoutes() {
        let site = Site(key: "catalog", type: 3, api: "provider.example")
        let playable = Vod(vodId: "episode-12", vodName: "Episode")
        #expect(VodCardRoutingPolicy.providerFolderCategory(site: site, vod: playable) == nil)
        #expect(!VodCardRoutingPolicy.shouldRouteToGlobalSearch(site: site, vod: playable))
        #expect(VodCardRoutingPolicy.shouldRouteToGlobalSearch(site: site, vod: Vod(vodId: "msearch:title")))
        #expect(VodCardRoutingPolicy.shouldRouteToGlobalSearch(site: Site(api: "csp_douban"), vod: playable))
    }
}
