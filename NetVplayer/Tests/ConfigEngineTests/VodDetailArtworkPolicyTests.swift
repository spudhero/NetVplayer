import Testing
import Models
import ApplicationCore

struct VodDetailArtworkPolicyTests {
    @Test func omittedPosterKeepsCatalogueArtworkAndOriginalPlayback() {
        let card = Vod(vodId: "opaque?id=1", vodPic: "https://art.example/card.jpg", siteKey: "source")
        let detail = Vod(vodId: card.vodId, vodName: "Detail", vodPic: " \n",
                         vodPlayFrom: "original", vodPlayUrl: "Episode$opaque-play-id", siteKey: "source")
        let result = VodDetailArtworkPolicy.preservingPoster(in: detail, from: card, siteKey: "source")
        #expect(result.vodPic == card.vodPic)
        #expect(result.vodName == detail.vodName)
        #expect(result.vodPlayFrom == detail.vodPlayFrom)
        #expect(result.vodPlayUrl == detail.vodPlayUrl)
        #expect(result.vodId == detail.vodId)
    }

    @Test func explicitDetailArtworkWins() {
        let card = Vod(vodId: "1", vodPic: "https://art.example/card.jpg")
        let detail = Vod(vodId: "1", vodPic: "provider-artwork")
        #expect(VodDetailArtworkPolicy.preservingPoster(in: detail, from: card, siteKey: "source").vodPic == detail.vodPic)
    }

    @Test func neverBorrowsAcrossContentSourcesOrFolders() {
        let detail = Vod(vodId: "1", siteKey: "source")
        let unrelated = [
            Vod(vodId: "2", vodPic: "other-content"),
            Vod(vodId: "1", vodPic: "other-source", siteKey: "other"),
            Vod(vodId: "1", vodPic: "folder-art", isFolder: true),
        ]
        for card in unrelated {
            #expect(VodDetailArtworkPolicy.preservingPoster(in: detail, from: card, siteKey: "source").vodPic.isEmpty)
        }
        let card = Vod(vodId: "1", vodPic: "art", siteKey: "source")
        #expect(VodDetailArtworkPolicy.preservingPoster(in: detail, from: card, siteKey: "other").vodPic.isEmpty)
        #expect(VodDetailArtworkPolicy.preservingPoster(in: Vod(), from: Vod(vodPic: "art"), siteKey: "source").vodPic.isEmpty)
    }

    @Test func progressiveDetailsKeepArtworkWithoutInventingMissingArtwork() {
        let card = Vod(vodId: "1", vodPic: "original-art")
        let initial = VodDetailArtworkPolicy.preservingPoster(in: Vod(vodId: "1"), from: card, siteKey: "source")
        let expanded = VodDetailArtworkPolicy.preservingPoster(in: Vod(vodId: "1", vodPlayUrl: "new-episodes"), from: initial, siteKey: "source")
        #expect(expanded.vodPic == card.vodPic)
        #expect(VodDetailArtworkPolicy.preservingPoster(in: Vod(vodId: "1"), from: nil, siteKey: "source").vodPic.isEmpty)
    }
}
