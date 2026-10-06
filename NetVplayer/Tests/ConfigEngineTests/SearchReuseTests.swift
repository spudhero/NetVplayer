import Foundation
import Testing
import Models
import Storage
import ApplicationCore
@testable import SearchEngine
@testable import NetVplayerApp

@Suite(.serialized)
struct SearchReuseTests {
    private let site = Site(key: "reuse", name: "Reuse", type: 1, api: "https://example.test/api", searchable: 1)

    private func key(_ query: String, scope: String = "account-a") -> SearchResponseCacheKey {
        SearchResponseCacheKey(scope: scope, site: site, keyword: query, page: "1", quick: false)
    }

    @Test func cacheEvictsAndRejectsUnsuccessfulOrOversizedPages() async {
        let cache = SearchResponseCache(maxEntries: 3, maxItems: 4, maxBytes: 4_096)
        for index in 0..<10 {
            let k = key(String(index)), ticket = await cache.lookup(key(String(index)), bypass: false)
            let result = SearchResult(vods: [Vod(vodId: "a"), Vod(vodId: "b")])
            await cache.insert(result, for: k, revision: ticket.revision, writer: ticket.writer)
        }
        #expect(await cache.entryCount == 2)
        #expect(await cache.itemCount == 4)
        #expect(await cache.byteCount <= 4_096)
        for result in [SearchResult(), SearchResult(error: "failed"),
                       SearchResult(vods: (0..<201).map { Vod(vodId: String($0)) }),
                       SearchResult(vods: [Vod(vodId: "large", vodContent: String(repeating: "x", count: 600_000))])] {
            let ticket = await cache.lookup(key("invalid"), bypass: false)
            await cache.insert(result, for: key("invalid"), revision: ticket.revision, writer: ticket.writer)
            #expect(await cache.lookup(key("invalid"), bypass: false).result == nil)
        }
        let bytesOnly = SearchResponseCache(maxBytes: 1)
        let ticket = await bytesOnly.lookup(key("bytes"), bypass: false)
        await bytesOnly.insert(SearchResult(vods: [Vod(vodId: "bytes")]), for: key("bytes"), revision: ticket.revision, writer: ticket.writer)
        #expect(await bytesOnly.entryCount == 0)
    }

    @Test func refreshAndClearRejectLateWritersAndTTLExpires() async throws {
        let cache = SearchResponseCache(ttl: .milliseconds(20))
        let k = key("film"), result = SearchResult(vods: [Vod(vodId: "old")])
        let old = await cache.lookup(k, bypass: false)
        let newer = await cache.lookup(k, bypass: true)
        await cache.insert(result, for: k, revision: old.revision, writer: old.writer)
        #expect(await cache.entryCount == 0)
        await cache.insert(SearchResult(vods: [Vod(vodId: "new")]), for: k, revision: newer.revision, writer: newer.writer)
        let hit = await cache.lookup(k, bypass: false)
        #expect(hit.result?.isCached == true)
        #expect(hit.result?.vods.first?.vodId == "new")
        #expect(await cache.lookup(key("film", scope: "account-b"), bypass: false).result == nil)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await cache.lookup(k, bypass: false).result == nil)
        let pending = await cache.lookup(k, bypass: true)
        await cache.clear()
        await cache.insert(result, for: k, revision: pending.revision, writer: pending.writer)
        #expect(await cache.entryCount == 0)
    }

    @Test func engineCachePreservesFallbackPaginationAndExplicitRefresh() async throws {
        let calls = SearchReuseProbe()
        let engine = SearchEngine { _, query, _, page in
            await calls.record(query + ":" + page)
            if query == "电影·第二季" { return .empty }
            return Result(list: [Vod(vodId: "film", vodName: "电影第二季")], page: Int(page)!, pagecount: 3)
        }
        var first: SearchResult?
        for await result in engine.search(keyword: "电影·第二季", sites: [site], cacheScope: "a") { first = result }
        #expect(first?.effectiveKeyword == "电影第二季")
        for await result in engine.search(keyword: "电影·第二季", sites: [site], cacheScope: "a") {
            #expect(result.isCached)
            #expect(result.hasMore)
            #expect(result.effectiveKeyword == first?.effectiveKeyword)
        }
        #expect(await calls.values.count == 2)
        for await result in engine.search(keyword: first!.effectiveKeyword, sites: [site], page: "2", cacheScope: "a") {
            #expect(result.page == 2)
            #expect(!result.isCached)
        }
        for await _ in engine.search(keyword: "电影·第二季", sites: [site], cacheScope: "a", bypassCache: true) {}
        #expect(await calls.values.count == 5)
        var changed = site; changed.jar = "new-runtime.jar"
        for await result in engine.search(keyword: "电影·第二季", sites: [changed], cacheScope: "a") { #expect(!result.isCached) }
        #expect(await calls.values.count == 7)
    }

    @MainActor
    @Test func publisherFlushesTrailingResultWithoutAnotherNetworkEventAndCancelsOldTimer() async throws {
        var counts: [Int] = []
        let publisher = SearchSnapshotPublisher(interval: .milliseconds(20)) { counts.append($0.results.count) }
        var state = ContentSearchState(isLoading: true)
        state.results = [SearchResult(vods: [Vod(vodId: "first")])]
        publisher.submit(state)
        #expect(counts == [1])
        state.results.append(SearchResult(siteKey: "second"))
        publisher.submit(state)
        #expect(counts == [1])
        try await Task.sleep(for: .milliseconds(50))
        #expect(counts == [1, 2])
        state.results.append(SearchResult(siteKey: "third"))
        publisher.submit(state)
        publisher.cancel()
        try await Task.sleep(for: .milliseconds(40))
        #expect(counts == [1, 2])
    }

    @MainActor
    @Test func appReusesActiveSearchAndSeparatesRefreshSourceAndCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "search-reuse-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory), userPreferences: preferences,
            providerRuntimeBootstrap: nil)
        let calls = SearchReuseProbe()
        state.searchEngine = SearchEngine { site, query, _, _ in
            await calls.record(query)
            // Deliberately ignores cancellation; stale publication still must be rejected.
            try? await Task.sleep(for: .milliseconds(80))
            return Result(list: [Vod(vodId: query, vodName: query, siteKey: site.key)])
        }
        state.sites = [site]; state.activeSite = site
        let first = Task { await state.search(keyword: "film") }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel() // A cancelled view waiter must not cancel the owned search.
        await state.search(keyword: "film")
        await first.value
        #expect(await calls.values == ["film"])
        #expect(!state.isSearching)
        await state.search(keyword: "film")
        #expect(await calls.values.count == 1)
        #expect(state.searchResults.first?.isCached == true)
        await state.search(keyword: "film", forceRefresh: true)
        #expect(await calls.values.count == 2)
        try await Task.detached {
            try preferences.saveCredential("new-account", for: "quarkCookie")
        }.value
        await Task.yield()
        await state.search(keyword: "film")
        #expect(await calls.values.count == 3)
        var changed = site; changed.api = "https://other.example.test/api"
        let old = Task { await state.search(keyword: "old") }
        try await Task.sleep(for: .milliseconds(10))
        state.sites = [changed]; state.activeSite = changed
        await state.search(keyword: "new")
        await old.value
        #expect(state.searchKeyword == "new")
        #expect(state.searchResults.flatMap(\.vods).map(\.vodId) == ["new"])
        #expect(!state.isSearching)
    }
}

private actor SearchReuseProbe {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
