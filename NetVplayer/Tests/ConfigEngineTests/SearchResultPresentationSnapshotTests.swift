import ApplicationCore
import Models
import Testing
@testable import NetVplayerApp

@Suite("Search result presentation snapshot")
struct SearchResultPresentationSnapshotTests {
    @Test
    func precomputesSectionsAndSourceCounts() {
        let snapshot = SearchResultPresentationSnapshot(
            results: [
                SearchResult(
                    siteName: "来源 A",
                    siteKey: "a",
                    vods: [
                        Vod(vodId: "a-exact", vodName: "仙逆", siteKey: "a"),
                        Vod(vodId: "a-related", vodName: "仙逆 年番", siteKey: "a")
                    ]
                ),
                SearchResult(
                    siteName: "来源 B",
                    siteKey: "b",
                    vods: [Vod(vodId: "b-exact", vodName: "仙逆", siteKey: "b")]
                ),
                SearchResult(siteName: "来源 C", siteKey: "c", error: "请求失败")
            ],
            keyword: "仙逆"
        )

        #expect(snapshot.successfulResults.map(\.siteKey) == ["a", "b"])
        #expect(snapshot.secondaryResults.map(\.siteKey) == ["c"])
        #expect(snapshot.exactItems.map { $0.vod.vodId } == ["a-exact", "b-exact"])
        #expect(snapshot.relatedItems.map { $0.vod.vodId } == ["a-related"])
        #expect(snapshot.exactItems(sourceKey: "a").map { $0.vod.vodId } == ["a-exact"])
        #expect(snapshot.relatedItems(sourceKey: "b").isEmpty)
        #expect(snapshot.itemCount(sourceKey: nil) == 3)
        #expect(snapshot.itemCount(sourceKey: "a") == 2)
        #expect(snapshot.sourceOptions.map(\.siteKey) == ["a", "b"])
        #expect(snapshot.sourceOptions.map(\.count) == [2, 1])
    }

    @Test
    func revisionDetectsStreamedReplacementWithoutChangingSourceCount() {
        let first = ContentSearchState(
            generation: 7,
            results: [SearchResult(siteKey: "a", vods: [Vod(vodId: "1", vodName: "旧结果")], durationMs: 10)],
            isLoading: true
        )
        let replacement = ContentSearchState(
            generation: 7,
            results: [SearchResult(siteKey: "a", vods: [Vod(vodId: "1", vodName: "新结果")], durationMs: 10)],
            isLoading: true
        )

        #expect(SearchResultPresentationRevision(state: first) != SearchResultPresentationRevision(state: replacement))
    }

}
