import Foundation
import Testing
import Models
import Storage
import ApplicationCore
@testable import SearchEngine
@testable import NetVplayerApp

@Suite(.serialized)
struct SearchScrollContinuationTests {
    @MainActor
    private func isolatedState() -> (AppState, URL, UserDefaults, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "search-scroll-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore()),
            providerRuntimeBootstrap: nil)
        return (state, directory, defaults, suite)
    }

    @MainActor
    private func waitForPages(_ state: AppState) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while state.contentSearchState.cursors.values.contains(where: { $0.status == .loading }), .now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(!state.contentSearchState.cursors.values.contains(where: { $0.status == .loading }))
        await Task.yield() // Let the owned task remove its entry after publishing the cursor.
    }

    @MainActor
    @Test func allSourcesAreAttemptedAndOneScrollReplaysOnlyABoundedWave() async throws {
        let (state, directory, defaults, suite) = isolatedState()
        defer { state.resetSearchState(); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let probe = SearchScrollCalls()
        state.sites = (0..<12).map { Site(key: "s\($0)", name: "Source \($0)", type: 1, api: "https://example.test/\($0)", searchable: 1) }
        state.activeSite = state.sites[0]
        state.searchEngine = SearchEngine { site, query, _, page in
            await probe.record(site.key + ":" + page)
            try await Task.sleep(for: .milliseconds(15))
            return Result(list: (0..<100).map { Vod(vodId: "\($0)", vodName: query, siteKey: site.key) }, page: Int(page)!, pagecount: 2)
        }
        let start = ContinuousClock.now
        let task = Task { await state.search(keyword: "Film") }
        var firstUseful: Double?, firstTwelve: Double?
        let deadline = start.advanced(by: .seconds(5))
        while .now < deadline {
            let count = state.searchResults.reduce(0) { $0 + $1.vods.count }
            let elapsed = milliseconds(start.duration(to: .now))
            if count > 0 && firstUseful == nil { firstUseful = elapsed }
            if count >= 12 && firstTwelve == nil { firstTwelve = elapsed }
            if !state.isSearching && count > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await task.value
        try #require(firstUseful != nil && firstTwelve != nil)
        let complete = milliseconds(start.duration(to: .now))
        #expect(await probe.calls.count == 12)
        #expect(state.contentSearchState.cursors.count == 12)
        #expect(state.searchResults.reduce(0) { $0 + $1.vods.count } == 60)
        #expect(state.searchResults.allSatisfy { $0.vods.count <= 12 })
        #expect(SearchResultPresentationSnapshot(results: state.searchResults, keyword: "Film").sourceOptions.count == 12)
        let generation = state.contentSearchState.generation
        let before = state.contentSearchState.resultBudget
        try await Task.sleep(for: .milliseconds(60)) // A trailing snapshot/layout cannot append.
        #expect(state.contentSearchState.resultBudget == before)
        #expect(await probe.calls.count == 12)
        state.appendSearchResultsAfterScroll(siteKey: nil, generation: generation)
        #expect(state.contentSearchState.cursors.values.filter { $0.status == .loading }.count == 6)
        let admitted = state.contentSearchState.resultBudget
        state.appendSearchResultsAfterScroll(siteKey: nil, generation: generation)
        #expect(state.contentSearchState.resultBudget == admitted)
        try await waitForPages(state)
        #expect(await probe.calls.count == 12) // The complete first pages were cached.
        #expect(state.searchResults.reduce(0) { $0 + $1.vods.count } == 120)
        #expect(state.contentSearchState.cursors.values.allSatisfy { $0.nextPage == 1 })
        let count = state.searchResults.reduce(0) { $0 + $1.vods.count }
        try await Task.sleep(for: .milliseconds(60))
        #expect(state.searchResults.reduce(0) { $0 + $1.vods.count } == count)
        print("OV91_05_SAMPLE firstUsefulMs=\(firstUseful ?? -1) first12AdmittedMs=\(firstTwelve ?? -1) allSourcesMs=\(complete) coverage=12/12 initial=60 afterScroll=120 cachedReplayRequests=0")
    }

    @MainActor
    @Test func selectedSourceFinalPageReplaysUntilCompleteAndOldGenerationCannotExpand() async throws {
        let (state, directory, defaults, suite) = isolatedState()
        defer { state.resetSearchState(); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let probe = SearchScrollCalls()
        state.sites = ["a", "b"].map { Site(key: $0, type: 1, api: "https://example.test/\($0)", searchable: 1) }
        state.searchEngine = SearchEngine { site, query, _, page in
            await probe.record(site.key + ":" + page)
            return Result(list: (0..<30).map { Vod(vodId: String($0), vodName: query) }, page: 1, pagecount: 1)
        }
        await state.search(keyword: "Film")
        let generation = state.contentSearchState.generation
        for expected in [24, 30] {
            state.appendSearchResultsAfterScroll(siteKey: "b", generation: generation)
            try await waitForPages(state)
            #expect(state.searchResults.first { $0.siteKey == "b" }?.vods.count == expected)
            #expect(state.searchResults.first { $0.siteKey == "a" }?.vods.count == 12)
        }
        #expect(state.contentSearchState.cursors["b"]?.status == .exhausted)
        #expect(await probe.calls.count == 2)
        await state.search(keyword: "New")
        state.appendSearchResultsAfterScroll(siteKey: "a", generation: generation)
        #expect(state.contentSearchState.resultBudget == SearchResultBudget())
    }

    @MainActor
    @Test func pageCancellationIsExplicitlyRetryableAndResetOrScopeChangeRejectsLateWork() async throws {
        let (state, directory, defaults, suite) = isolatedState()
        defer { state.resetSearchState(); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        state.sites = [Site(key: "a", type: 1, api: "https://example.test/a", searchable: 1)]
        let probe = SearchScrollCalls()
        state.searchEngine = SearchEngine { _, query, _, page in
            await probe.record(query + ":" + page)
            if page == "2" { try? await Task.sleep(for: .milliseconds(150)) }
            return Result(list: [Vod(vodId: query + page, vodName: query)], page: Int(page)!, pagecount: 3)
        }
        await state.search(keyword: "Film")
        state.appendSearchResultsAfterScroll(siteKey: "a", generation: state.contentSearchState.generation)
        try await Task.sleep(for: .milliseconds(15))
        state.cancelSearchContinuation(siteKey: "a")
        try await waitForPages(state)
        #expect(state.contentSearchState.cursors["a"]?.status == .retryable)
        #expect(state.searchResults[0].vods.count == 1)
        let before = await probe.calls.count
        state.appendSearchResultsAfterScroll(siteKey: "a", generation: state.contentSearchState.generation)
        #expect(await probe.calls.count == before) // Scroll must never retry a failure/cancellation.
        state.loadMoreSearchResults(siteKey: "a")
        try await waitForPages(state)
        #expect(state.searchResults[0].vods.count == 2)
        state.appendSearchResultsAfterScroll(siteKey: "a", generation: state.contentSearchState.generation)
        state.resetSearchState()
        await state.search(keyword: "New")
        try await Task.sleep(for: .milliseconds(180))
        #expect(state.searchResults[0].vods.map(\.vodId) == ["New1"])
        let budget = state.contentSearchState.resultBudget
        state.sites[0].api = "https://changed.example.test/a"
        state.appendSearchResultsAfterScroll(siteKey: "a", generation: state.contentSearchState.generation)
        #expect(state.contentSearchState.resultBudget == budget)
        #expect(state.contentSearchState.cursors["a"]?.status == .ready)
    }

    private func milliseconds(_ value: Duration) -> Double {
        Double(value.components.seconds) * 1_000 + Double(value.components.attoseconds) / 1e15
    }

    @MainActor
    @Test func truncatedFallbackPageUsesOriginalCacheKeyAndLaterPagesUseEffectiveKeyword() async throws {
        let (state, directory, defaults, suite) = isolatedState()
        defer { state.resetSearchState(); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let probe = SearchScrollCalls()
        state.sites = [Site(key: "s", type: 1, api: "https://example.test/s", searchable: 1)]
        state.searchEngine = SearchEngine { _, query, _, page in
            await probe.record(query + ":" + page)
            if query == "电影·第二季" { return .empty }
            let ids = page == "1" ? 0..<20 : 20..<24
            return Result(list: ids.map { Vod(vodId: String($0), vodName: "电影第二季") }, page: Int(page)!, pagecount: 2)
        }
        await state.search(keyword: "电影·第二季")
        #expect(await probe.calls == ["电影·第二季:1", "电影第二季:1"])
        #expect(state.contentSearchState.cursors["s"]?.pageKeyword == "电影·第二季")
        state.appendSearchResultsAfterScroll(siteKey: "s", generation: state.contentSearchState.generation)
        try await waitForPages(state)
        #expect(await probe.calls.count == 2)
        #expect(state.searchResults[0].vods.count == 20)
        #expect(state.contentSearchState.cursors["s"]?.nextPage == 2)
        state.appendSearchResultsAfterScroll(siteKey: "s", generation: state.contentSearchState.generation)
        try await waitForPages(state)
        #expect(await probe.calls.last == "电影第二季:2")
        #expect(state.searchResults[0].vods.count == 24)
        #expect(state.contentSearchState.cursors["s"]?.status == .exhausted)
    }

    @MainActor
    @Test func strictSearchContinuationRetainsLiteralKeywordAndFirstPageCache() async throws {
        let (state, directory, defaults, suite) = isolatedState()
        defer { state.resetSearchState(); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let probe = SearchScrollCalls()
        state.sites = [Site(key: "s", type: 1, api: "https://example.test/s", searchable: 1)]
        state.allowsSearchFallbacks = false
        state.selectedSearchSiteKeys = ["s"]
        state.searchEngine = SearchEngine { _, query, _, page in
            await probe.record(query + ":" + page)
            if page != "1" { return .empty }
            return Result(list: (0..<20).map { Vod(vodId: String($0), vodName: query) }, page: 1, pagecount: 2)
        }
        await state.search(keyword: "电影·第二季")
        state.appendSearchResultsAfterScroll(siteKey: "s", generation: state.contentSearchState.generation)
        try await waitForPages(state)
        #expect(try #require(state.searchResults.first).vods.count == 20)
        #expect(await probe.calls == ["电影·第二季:1"])
        state.appendSearchResultsAfterScroll(siteKey: "s", generation: state.contentSearchState.generation)
        try await waitForPages(state)
        #expect(await probe.calls == ["电影·第二季:1", "电影·第二季:2"])
        #expect(state.contentSearchState.cursors["s"]?.status == .exhausted)
    }

    @MainActor
    @Test func configuredSourceSelectionRemainsTheSearchAndContinuationBoundary() async throws {
        let (state, directory, defaults, suite) = isolatedState()
        defer { state.resetSearchState(); try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let probe = SearchScrollCalls()
        state.sites = ["allowed", "excluded"].map { Site(key: $0, type: 1, api: "https://example.test/\($0)", searchable: 1) }
        state.selectedSearchSiteKeys = ["allowed"]
        state.searchEngine = SearchEngine { site, query, _, page in
            await probe.record(site.key + ":" + page)
            return Result(list: [Vod(vodId: page, vodName: query)], page: Int(page)!, pagecount: 2)
        }
        await state.search(keyword: "Film")
        state.appendSearchResultsAfterScroll(siteKey: "excluded", generation: state.contentSearchState.generation)
        state.appendSearchResultsAfterScroll(siteKey: nil, generation: state.contentSearchState.generation)
        try await waitForPages(state)
        #expect(await probe.calls == ["allowed:1", "allowed:2"])
        #expect(state.contentSearchState.cursors["excluded"] == nil)
        state.selectedSearchSiteKeys = ["excluded"]
        #expect(state.searchResults.isEmpty)
        #expect(state.contentSearchState.resultBudget == SearchResultBudget())
    }

    @MainActor
    @Test func sameSampleRecordsFirstUsefulFirstTwelveAndFullCoverageBeforeAndAfterBudget() async throws {
        let sources = (0..<12).map { Site(key: "s\($0)", name: "Sample \($0)", type: 1, searchable: 1) }
        for budgeted in [false, true] {
            let calls = SearchScrollCalls()
            let engine = SearchEngine { site, query, _, _ in
                await calls.record(site.key)
                try await Task.sleep(for: .milliseconds(15))
                return Result(list: (0..<100).map { Vod(vodId: String($0), vodName: query, siteKey: site.key) })
            }
            var working = ContentSearchCore.begin(.init(), keyword: "Film", siteOrder: sources.map(\.key))
            if !budgeted { working.resultBudget = SearchResultBudget(total: 30_000, perSite: 2_000) }
            let start = ContinuousClock.now
            var firstUseful: Double?, firstTwelve: Double?, peak = 0
            let publisher = SearchSnapshotPublisher { snapshot in
                let count = snapshot.results.reduce(0) { $0 + $1.vods.count }
                peak = max(peak, count)
                if count > 0 && firstUseful == nil { firstUseful = milliseconds(start.duration(to: .now)) }
                if count >= 12 && firstTwelve == nil { firstTwelve = milliseconds(start.duration(to: .now)) }
            }
            for await result in engine.search(keyword: "Film", sites: sources) {
                working = ContentSearchCore.ingest(working, generation: working.generation, result: result)
                publisher.submit(working)
            }
            publisher.submit(ContentSearchCore.finish(working, generation: working.generation))
            publisher.flush()
            try #require(firstUseful != nil && firstTwelve != nil)
            #expect(Set(await calls.calls).count == 12)
            #expect(peak == (budgeted ? 60 : 1_200))
            print("OV91_05_AB budgeted=\(budgeted) firstUsefulMs=\(firstUseful!) first12AdmittedMs=\(firstTwelve!) allSourcesMs=\(milliseconds(start.duration(to: .now))) coverage=12/12 admitted=\(peak)")
        }
    }
}

private actor SearchScrollCalls {
    private(set) var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}
