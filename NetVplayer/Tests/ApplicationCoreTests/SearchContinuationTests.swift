import Testing
import Models
@testable import ApplicationCore

struct SearchContinuationTests {
    private func page(_ ids: [String], number: Int = 1, more: Bool = true, keyword: String = "query", error: String? = nil) -> SearchResult {
        SearchResult(siteName: "Site", siteKey: "s", vods: ids.map { Vod(vodId: $0, siteKey: "s") }, error: error,
                     page: number, hasMore: more, effectiveKeyword: keyword)
    }

    @Test func appendsOnlyNewItemsAndRetainsEffectiveKeyword() {
        var state = ContentSearchCore.begin(.init(), keyword: "query: original", sourceScope: "config-a")
        state = ContentSearchCore.ingest(state, generation: state.generation, result: page(["a", "a", "b"], keyword: "query original"))
        state = ContentSearchCore.finish(state, generation: state.generation)
        #expect(state.cursors["s"]?.keyword == "query original")
        #expect(state.cursors["s"]?.nextPage == 2)
        state = ContentSearchCore.beginContinuation(state, siteKey: "s")
        state = ContentSearchCore.receivePage(state, generation: state.generation, requestedPage: 2, result: page(["b", "c"], number: 2, more: false, keyword: "query original"))
        #expect(state.results[0].vods.map(\.vodId) == ["a", "b", "c"])
        #expect(state.cursors["s"]?.status == .exhausted)
    }

    @Test func wrongRepeatedAndFailedPagesRetainCursorAndExistingResults() {
        for result in [page(["b"], number: 1), page(["a"], number: 2), page([], number: 2, error: "timeout")] {
            var state = ContentSearchCore.begin(.init(), keyword: "query")
            state = ContentSearchCore.ingest(state, generation: state.generation, result: page(["a"]))
            state = ContentSearchCore.receivePage(state, generation: state.generation, requestedPage: 2, result: result)
            #expect(state.results[0].vods.map(\.vodId) == ["a"])
            #expect(state.cursors["s"]?.nextPage == 2)
            #expect(state.cursors["s"]?.status == .retryable)
            state = ContentSearchCore.receivePage(state, generation: state.generation, requestedPage: 2, result: page(["b"], number: 2))
            #expect(state.results[0].vods.map(\.vodId) == ["a", "b"])
            #expect(state.cursors["s"]?.nextPage == 3)
        }
    }

    @Test func resetRejectsOldWindowAndCancellationRemainsRetryable() {
        var state = ContentSearchCore.begin(.init(), keyword: "query", sourceScope: "a")
        state = ContentSearchCore.ingest(state, generation: state.generation, result: page(["a"]))
        let oldGeneration = state.generation
        state = ContentSearchCore.beginContinuation(state, siteKey: "s")
        state = ContentSearchCore.cancelContinuation(state, generation: oldGeneration, siteKey: "s")
        #expect(state.cursors["s"]?.canRequest == true)
        state = ContentSearchCore.begin(state, keyword: "other", sourceScope: "b")
        state = ContentSearchCore.receivePage(state, generation: oldGeneration, requestedPage: 2, result: page(["b"], number: 2))
        #expect(state.results.isEmpty)
        #expect(state.cursors.isEmpty)
    }

    @Test func resultBudgetDoesNotPretendToBeEndOfSource() {
        var state = ContentSearchCore.begin(.init(), keyword: "query")
        state = ContentSearchCore.ingest(state, generation: state.generation, result: page((0...2_000).map(String.init)))
        #expect(state.results[0].vods.count == 2_000)
        #expect(state.cursors["s"]?.status == .limited)
        #expect(state.results[0].hasMore)
    }
}
