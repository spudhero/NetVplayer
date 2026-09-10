import Foundation
import Models
import Testing
@testable import SearchEngine

private actor SearchConcurrencyProbe {
    private var active = 0
    private var peak = 0

    func search(site: Site) async throws -> Result {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(30))
        return Result(
            list: [Vod(vodId: site.key, vodName: site.name, siteKey: site.key)],
            page: 1,
            pagecount: 1
        )
    }

    func peakConcurrency() -> Int { peak }
}

private actor SearchKeywordProbe {
    private var keywords: [String] = []

    func record(_ keyword: String) {
        keywords.append(keyword)
    }

    func recordedKeywords() -> [String] { keywords }
}

private struct ExpectedSearchFailure: Error {}

@Test func searchEngineUsesBoundedMovingConcurrencyWindow() async {
    let probe = SearchConcurrencyProbe()
    let engine = SearchEngine(maxConcurrentSites: 2) { site, _, _, _ in
        try await probe.search(site: site)
    }
    let sites = (0..<7).map { index in
        Site(
            key: "site-\(index)",
            name: "Site \(index)",
            type: 1,
            api: "https://site-\(index).example.test/api",
            timeout: 2,
            searchable: 1
        )
    }

    var results: [SearchResult] = []
    for await result in engine.search(keyword: "swift", sites: sites) {
        results.append(result)
    }

    #expect(results.count == sites.count)
    #expect(Set(results.map(\.siteKey)) == Set(sites.map(\.key)))
    #expect(await probe.peakConcurrency() == 2)
}

@Test func searchEngineClampsConcurrencyWindowToAtLeastOne() {
    let engine = SearchEngine(maxConcurrentSites: 0) { _, _, _, _ in .empty }
    #expect(engine.maxConcurrentSites == 1)
}

@Test func searchQueryPlanBuildsConservativePunctuationFallbacks() {
    #expect(SearchQueryPlan("庆余年·第二季").fallback == "庆余年第二季")
    #expect(SearchQueryPlan("Movie: The Return").fallback == "Movie The Return")
    #expect(SearchQueryPlan("Spider-Man").fallback == nil)
    #expect(SearchQueryPlan("C++").fallback == nil)
    #expect(SearchQueryPlan("C#").fallback == nil)
    #expect(SearchQueryPlan("Version 1.5").fallback == nil)
}

@Test func searchEngineRetriesPunctuationOnlyWhenOriginalHasNoMeaningfulMatch() async throws {
    let probe = SearchKeywordProbe()
    let engine = SearchEngine(maxConcurrentSites: 1) { _, keyword, _, _ in
        await probe.record(keyword)
        if keyword == "庆余年第二季" {
            return Result(list: [Vod(vodId: "fallback", vodName: "庆余年 第二季")])
        }
        return .empty
    }
    let site = Site(
        key: "site",
        name: "Site",
        type: 1,
        api: "https://site.example.test/api",
        timeout: 2,
        searchable: 1
    )

    var results: [SearchResult] = []
    for await result in engine.search(keyword: "庆余年·第二季", sites: [site]) {
        results.append(result)
    }

    #expect(await probe.recordedKeywords() == ["庆余年·第二季", "庆余年第二季"])
    #expect(results.first?.vods.map(\.vodId) == ["fallback"])
}

@Test func searchEngineKeepsMeaningfulOriginalAndSkipsFallback() async {
    let probe = SearchKeywordProbe()
    let engine = SearchEngine(maxConcurrentSites: 1) { _, keyword, _, _ in
        await probe.record(keyword)
        return Result(list: [Vod(vodId: "original", vodName: "庆余年 第二季")])
    }
    let site = Site(
        key: "site",
        name: "Site",
        type: 1,
        api: "https://site.example.test/api",
        timeout: 2,
        searchable: 1
    )

    for await _ in engine.search(keyword: "庆余年·第二季", sites: [site]) {}
    #expect(await probe.recordedKeywords() == ["庆余年·第二季"])
}

@Test func searchEngineMergesFallbackResultsWithoutDuplicateVodIdentity() async {
    let engine = SearchEngine(maxConcurrentSites: 1) { _, keyword, _, _ in
        if keyword.contains("·") {
            return Result(list: [
                Vod(vodId: "same", vodName: "Unrelated"),
                Vod(vodId: "original", vodName: "Other")
            ])
        }
        return Result(list: [
            Vod(vodId: "same", vodName: "庆余年 第二季"),
            Vod(vodId: "fallback", vodName: "庆余年 第二季")
        ])
    }
    let site = Site(
        key: "site",
        name: "Site",
        type: 1,
        api: "https://site.example.test/api",
        timeout: 2,
        searchable: 1
    )

    var merged: SearchResult?
    for await result in engine.search(keyword: "庆余年·第二季", sites: [site]) {
        merged = result
    }
    #expect(merged?.vods.map(\.vodId) == ["same", "original", "fallback"])
}

@Test func searchEngineKeepsOriginalResultsWhenFallbackFails() async {
    let engine = SearchEngine(maxConcurrentSites: 1) { _, keyword, _, _ in
        if keyword.contains(":") {
            return Result(list: [Vod(vodId: "original", vodName: "Different Result")])
        }
        throw ExpectedSearchFailure()
    }
    let site = Site(
        key: "site",
        name: "Site",
        type: 1,
        api: "https://site.example.test/api",
        timeout: 2,
        searchable: 1
    )

    var result: SearchResult?
    for await item in engine.search(keyword: "Movie: Return", sites: [site]) {
        result = item
    }
    #expect(result?.vods.map(\.vodId) == ["original"])
    #expect(result?.error == nil)
}

@Test func searchEngineDoesNotRunFallbackForLaterPages() async {
    let probe = SearchKeywordProbe()
    let engine = SearchEngine(maxConcurrentSites: 1) { _, keyword, _, _ in
        await probe.record(keyword)
        return .empty
    }
    let site = Site(
        key: "site",
        name: "Site",
        type: 1,
        api: "https://site.example.test/api",
        timeout: 2,
        searchable: 1
    )

    for await _ in engine.search(keyword: "Movie: Return", sites: [site], page: "2") {}
    #expect(await probe.recordedKeywords() == ["Movie: Return"])
}

@Test func searchEngineDeduplicatesEmptyIDsAndMergesFallbackPagination() async {
    let engine = SearchEngine(maxConcurrentSites: 1) { _, keyword, _, _ in
        if keyword.contains(":") {
            return Result(
                list: [Vod(vodId: "", vodName: "Unrelated", vodPic: "poster")],
                page: 1,
                pagecount: 2,
                total: 10
            )
        }
        return Result(
            list: [
                Vod(vodId: "", vodName: "Unrelated", vodPic: "poster"),
                Vod(vodId: "", vodName: "Movie Return", vodPic: "other")
            ],
            page: 1,
            pagecount: 3,
            total: 12
        )
    }
    let site = Site(
        key: "site",
        name: "Site",
        type: 1,
        api: "https://site.example.test/api",
        timeout: 2,
        searchable: 1
    )

    var result: SearchResult?
    for await item in engine.search(keyword: "Movie: Return", sites: [site]) {
        result = item
    }
    #expect(result?.vods.count == 2)
    #expect(result?.page == 1)
    #expect(result?.hasMore == true)
}

@Test func searchEngineBoundsFallbackTimeoutByTheOriginalSiteBudget() async {
    let probe = SearchKeywordProbe()
    let engine = SearchEngine(maxConcurrentSites: 1) { _, keyword, _, _ in
        await probe.record(keyword)
        if keyword.contains(":") {
            try await Task.sleep(for: .milliseconds(700))
            return .empty
        }
        try await Task.sleep(for: .seconds(2))
        return Result(list: [Vod(vodId: "late", vodName: "Movie Return")])
    }
    let site = Site(
        key: "site",
        name: "Site",
        type: 1,
        api: "https://site.example.test/api",
        timeout: 1,
        searchable: 1
    )

    let startedAt = ContinuousClock.now
    var result: SearchResult?
    for await item in engine.search(keyword: "Movie: Return", sites: [site]) {
        result = item
    }
    let elapsed = startedAt.duration(to: .now)
    #expect(await probe.recordedKeywords() == ["Movie: Return", "Movie Return"])
    #expect(result?.vods.isEmpty == true)
    #expect(result?.error == nil)
    #expect(elapsed >= .milliseconds(900))
    #expect(elapsed < .seconds(1.3))
}
