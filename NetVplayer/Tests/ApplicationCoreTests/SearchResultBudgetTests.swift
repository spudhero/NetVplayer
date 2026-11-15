import Testing
import Models
@testable import ApplicationCore

struct SearchResultBudgetTests {
    private func page(_ key: String = "s", range: Range<Int> = 0..<40, number: Int = 1, more: Bool = true) -> SearchResult {
        SearchResult(siteName: key, siteKey: key, vods: range.map { Vod(vodId: String($0), vodName: "Film") },
                     page: number, hasMore: more, effectiveKeyword: "normalized")
    }

    @Test func firstBatchBoundsTotalAndEachSourceWithoutDroppingSourceCursors() {
        var state = ContentSearchCore.begin(.init(), keyword: "Film")
        for key in (0..<20).map(String.init) {
            state = ContentSearchCore.ingest(state, generation: state.generation, result: page(key))
        }
        #expect(state.results.reduce(0) { $0 + $1.vods.count } == 60)
        #expect(state.results.allSatisfy { $0.vods.count <= 12 })
        #expect(state.cursors.count == 20)
        #expect(state.cursors.values.allSatisfy { $0.status == .budgeted && $0.nextPage == 1 })
        #expect(state.results.allSatisfy { $0.hasMore })
    }

    @Test func replaysTruncatedFinalPageAndDeduplicatesBeforeAdvancingCursor() {
        var state = ContentSearchCore.begin(.init(), keyword: "Film")
        let final = page(range: 0..<30, more: false)
        state = ContentSearchCore.ingest(state, generation: state.generation, result: final)
        state = ContentSearchCore.finish(state, generation: state.generation)
        #expect(state.results[0].vods.count == 12)
        #expect(state.cursors["s"]?.nextPage == 1)
        #expect(state.results[0].hasMore)
        for expected in [24, 30] {
            state = ContentSearchCore.expandContinuationBudget(state, siteKey: "s")
            state = ContentSearchCore.beginContinuation(state, siteKey: "s")
            state = ContentSearchCore.receivePage(state, generation: state.generation, requestedPage: 1, result: final)
            #expect(state.results[0].vods.count == expected)
        }
        #expect(Set(state.results[0].vods.map(\.vodId)).count == 30)
        #expect(state.cursors["s"]?.nextPage == 2)
        #expect(state.cursors["s"]?.status == .exhausted)
        #expect(!state.results[0].hasMore)
        #expect(state.cursors["s"]?.keyword == "normalized")
    }

    @Test func expandsOnlySelectedSourceAndPrioritizesSparseSourcesWhenReturningToAll() {
        var state = ContentSearchCore.begin(.init(), keyword: "Film", siteOrder: (0..<8).map(String.init))
        for key in state.siteOrder {
            state = ContentSearchCore.ingest(state, generation: state.generation, result: page(key))
        }
        state = ContentSearchCore.finish(state, generation: state.generation)
        state = ContentSearchCore.expandContinuationBudget(state, siteKey: "7")
        #expect(ContentSearchCore.automaticContinuationSites(state, siteKey: "7") == ["7"])
        #expect(state.resultBudget.limit(for: "7") == 24)
        #expect(state.resultBudget.limit(for: "0") == 12)
        state = ContentSearchCore.expandContinuationBudget(state)
        #expect(Array(ContentSearchCore.automaticContinuationSites(state).prefix(3)) == ["5", "6", "7"])
    }

    @Test func retryAndAbnormalPagesNeverSpendBudgetOrSkipAPage() {
        var state = ContentSearchCore.begin(.init(), keyword: "Film")
        state = ContentSearchCore.ingest(state, generation: state.generation, result: page(range: 0..<4))
        state = ContentSearchCore.finish(state, generation: state.generation)
        for bad in [page(range: 4..<6), page(range: 0..<4, number: 2), SearchResult(siteKey: "s", error: "failure", page: 2)] {
            let total = state.resultBudget
            state = ContentSearchCore.beginContinuation(state, siteKey: "s")
            state = ContentSearchCore.receivePage(state, generation: state.generation, requestedPage: 2, result: bad)
            #expect(state.cursors["s"]?.status == .retryable)
            #expect(state.cursors["s"]?.nextPage == 2)
            #expect(state.results[0].vods.count == 4)
            #expect(state.resultBudget == total)
            #expect(ContentSearchCore.automaticContinuationSites(state).isEmpty)
        }
        state.cursors["s"]?.nextPage = .max
        state = ContentSearchCore.receivePage(state, generation: state.generation, requestedPage: .max,
            result: page(number: .max))
        #expect(state.cursors["s"]?.status == .retryable)
    }

    @Test func newGenerationResetsExpandedBudgetsAndRejectsLatePages() {
        var state = ContentSearchCore.begin(.init(), keyword: "Film", sourceScope: "a")
        state = ContentSearchCore.ingest(state, generation: state.generation, result: page())
        state = ContentSearchCore.finish(state, generation: state.generation)
        state = ContentSearchCore.expandContinuationBudget(state)
        let old = state.generation
        state = ContentSearchCore.begin(state, keyword: "Other", sourceScope: "b")
        state = ContentSearchCore.receivePage(state, generation: old, requestedPage: 1, result: page())
        #expect(state.resultBudget == SearchResultBudget())
        #expect(state.cursors.isEmpty && state.results.isEmpty)
        #expect(ContentSearchCore.automaticContinuationSites(state).isEmpty)
        state = ContentSearchCore.reset(state)
        #expect(state.resultBudget == SearchResultBudget())
    }

    @Test func firstBatchRetainsUsefulTailHitsUsingTheExistingPresentationRanking() {
        var state = ContentSearchCore.begin(.init(), keyword: "Film")
        let related = (0..<30).map { Vod(vodId: "other\($0)", vodName: "Unrelated") }
        let result = SearchResult(siteKey: "s", vods: related + [
            Vod(vodId: "exact", vodName: "Film"), Vod(vodId: "prefix", vodName: "Film Part 2")
        ])
        state = ContentSearchCore.ingest(state, generation: state.generation, result: result)
        #expect(state.results[0].vods.count == 12)
        #expect(Array(state.results[0].vods.prefix(2)).map(\.vodId) == ["exact", "prefix"])
        #expect(state.cursors["s"]?.nextPage == 1)
    }
}
