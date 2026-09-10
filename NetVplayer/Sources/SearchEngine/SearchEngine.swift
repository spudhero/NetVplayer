// SearchEngine/SearchEngine.swift
// 多站并发搜索引擎

import Foundation
import Models
import ApplicationCore
import SpiderEngine

struct SearchQueryPlan: Equatable, Sendable {
    let original: String
    let fallback: String?

    init(_ keyword: String) {
        original = keyword
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        fallback = SearchTitleNormalizer.fallbackQuery(for: original)
    }
}

enum SearchTitleNormalizer {
    static func comparisonKey(_ value: String) -> String {
        transform(folded(value), replacingSeparatorsWithSpaces: false)
    }

    static func fallbackQuery(for value: String) -> String? {
        let value = value
            .folding(options: [.widthInsensitive], locale: .current)
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(value)
        guard characters.indices.contains(where: { index in
            isRemovableSeparator(characters[index], at: index, in: characters)
        }) else { return nil }
        let fallback = transform(
            value,
            replacingSeparatorsWithSpaces: !containsCJK(value)
        )
        return fallback.isEmpty || fallback == value ? nil : fallback
    }

    static func hasMeaningfulMatch(_ items: [Vod], keyword: String) -> Bool {
        let query = comparisonKey(keyword)
        guard !query.isEmpty else { return !items.isEmpty }
        return items.contains { item in
            let title = comparisonKey(item.vodName)
            return !title.isEmpty && (title.contains(query) || query.contains(title))
        }
    }

    private static func transform(
        _ value: String,
        replacingSeparatorsWithSpaces: Bool
    ) -> String {
        let characters = Array(value)
        var result = ""
        var pendingSpace = false

        for index in characters.indices {
            let character = characters[index]
            if character.isLetter || character.isNumber
                || isSemanticSymbol(character, at: index, in: characters) {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(character)
            } else if replacingSeparatorsWithSpaces {
                pendingSpace = !result.isEmpty
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func folded(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isRemovableSeparator(
        _ character: Character,
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        !character.isWhitespace
            && !character.isLetter
            && !character.isNumber
            && !isSemanticSymbol(character, at: index, in: characters)
    }

    private static func isSemanticSymbol(
        _ character: Character,
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        switch character {
        case "+", "#", "/":
            return true
        case "-", "‐", "‑":
            return hasASCIIAlphaNumericNeighbors(at: index, in: characters)
        case ".":
            return neighbor(at: index - 1, in: characters)?.isNumber == true
                && neighbor(at: index + 1, in: characters)?.isNumber == true
        case "'", "’":
            return hasASCIILetterNeighbors(at: index, in: characters)
        case "!", "?":
            return neighbor(at: index - 1, in: characters).map(isASCIIAlphaNumeric) == true
        default:
            return false
        }
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x2FFF, 0x3040...0x30FF, 0x31F0...0x31FF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
                 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func hasASCIIAlphaNumericNeighbors(
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        guard let previous = neighbor(at: index - 1, in: characters),
              let next = neighbor(at: index + 1, in: characters) else { return false }
        return isASCIIAlphaNumeric(previous) && isASCIIAlphaNumeric(next)
    }

    private static func hasASCIILetterNeighbors(
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        guard let previous = neighbor(at: index - 1, in: characters),
              let next = neighbor(at: index + 1, in: characters) else { return false }
        return isASCIILetter(previous) && isASCIILetter(next)
    }

    private static func neighbor(at index: Int, in characters: [Character]) -> Character? {
        characters.indices.contains(index) ? characters[index] : nil
    }

    private static func isASCIIAlphaNumeric(_ character: Character) -> Bool {
        isASCIILetter(character) || isASCIIDigit(character)
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return (0x30...0x39).contains(value)
    }
}

public enum SearchSitePlanner {
    public static let builtInCMSKey = BuiltInVodSourceCatalog.speedDirectKey

    public static func orderedSearchSites(
        sites: [Site],
        activeSiteKey: String?,
        selectedKeys: [String],
        replacementSiteKeys: Set<String> = [],
        healthSummaries: [String: SiteHealthSummary] = [:],
        healthSortingEnabled: Bool = false
    ) -> [Site] {
        let searchable = sites.filter { site in
            site.isSearchable && (!site.isAndroidCrawlerSource || replacementSiteKeys.contains(site.key))
        }
        let selected = Set(selectedKeys)
        let scoped = selected.isEmpty ? searchable : searchable.filter { selected.contains($0.key) }
        let candidates = scoped.isEmpty ? searchable : scoped
        let indexed = candidates.enumerated().map { (index: $0.offset, site: $0.element) }

        return indexed
            .sorted { lhs, rhs in
                let lhsRank = rank(site: lhs.site, activeSiteKey: activeSiteKey, replacementSiteKeys: replacementSiteKeys)
                let rhsRank = rank(site: rhs.site, activeSiteKey: activeSiteKey, replacementSiteKeys: replacementSiteKeys)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if healthSortingEnabled {
                    let lhsScore = healthSummaries[lhs.site.key]?.score ?? 0.5
                    let rhsScore = healthSummaries[rhs.site.key]?.score ?? 0.5
                    if lhsScore != rhsScore { return lhsScore > rhsScore }
                }
                return lhs.index < rhs.index
            }
            .map(\.site)
    }

    public static func orderedResults(_ results: [SearchResult], siteOrder: [String]) -> [SearchResult] {
        ContentSearchCore.orderedResults(results, siteOrder: siteOrder)
    }

    private static func rank(site: Site, activeSiteKey: String?, replacementSiteKeys: Set<String>) -> Int {
        if site.key == activeSiteKey { return 0 }
        if site.key == builtInCMSKey { return 1 }
        if replacementSiteKeys.contains(site.key) { return 2 }
        return 3
    }

}

/// 搜索引擎 — 多站点并发搜索
public final class SearchEngine: @unchecked Sendable {

    public static let shared = SearchEngine()

    public let maxConcurrentSites: Int
    private let searchContent: @Sendable (Site, String, Bool, String) async throws -> Result

    public init(siteApi: SiteApi = .shared, maxConcurrentSites: Int = 6) {
        self.maxConcurrentSites = max(1, maxConcurrentSites)
        self.searchContent = { site, keyword, quick, page in
            try await siteApi.searchContent(site: site, keyword: keyword, quick: quick, page: page)
        }
    }

    init(
        maxConcurrentSites: Int = 6,
        searchContent: @escaping @Sendable (Site, String, Bool, String) async throws -> Result
    ) {
        self.maxConcurrentSites = max(1, maxConcurrentSites)
        self.searchContent = searchContent
    }

    /// 多站点并发搜索，返回 AsyncStream 渐进式渲染
    public func search(keyword: String, sites: [Site], page: String = "1", quick: Bool = false) -> AsyncStream<SearchResult> {
        AsyncStream { continuation in
            let producer = Task {
                let searchableSites = sites.filter { $0.isSearchable && (!quick || $0.isQuickSearch) }
                DiagnosticLog.write("[SEARCH_START] keyword=\(keyword) siteCount=\(searchableSites.count) concurrency=\(maxConcurrentSites) quick=\(quick) page=\(page)")
                await withTaskGroup(of: SearchResult.self) { group in
                    var nextSiteIndex = 0
                    let initialCount = min(maxConcurrentSites, searchableSites.count)
                    for site in searchableSites.prefix(initialCount) {
                        group.addTask { [searchContent] in
                            await Self.searchSite(
                                site,
                                keyword: keyword,
                                page: page,
                                quick: quick,
                                searchContent: searchContent
                            )
                        }
                        nextSiteIndex += 1
                    }

                    var totalResults = 0
                    var errorCount = 0
                    while let result = await group.next() {
                        totalResults += result.vods.count
                        if result.error != nil { errorCount += 1 }
                        continuation.yield(result)
                        if nextSiteIndex < searchableSites.count, !Task.isCancelled {
                            let site = searchableSites[nextSiteIndex]
                            nextSiteIndex += 1
                            group.addTask { [searchContent] in
                                await Self.searchSite(
                                    site,
                                    keyword: keyword,
                                    page: page,
                                    quick: quick,
                                    searchContent: searchContent
                                )
                            }
                        }
                    }
                    DiagnosticLog.write("[SEARCH_FINISH] keyword=\(keyword) totalResults=\(totalResults) errorCount=\(errorCount)")
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    private static func searchSite(
        _ site: Site,
        keyword: String,
        page: String,
        quick: Bool,
        searchContent: @escaping @Sendable (Site, String, Bool, String) async throws -> Result
    ) async -> SearchResult {
        let startedAt = ContinuousClock.now
        func durationMs() -> Int {
            let components = startedAt.duration(to: .now).components
            return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
        }
        func elapsedSeconds() -> TimeInterval {
            let components = startedAt.duration(to: .now).components
            return TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        }
        let requestedPage = Int(page) ?? 1
        do {
            let plan = SearchQueryPlan(keyword)
            let timeout = TimeInterval(max(site.timeout, 1))
            let original = try await resultWithTimeout(
                site: site,
                keyword: plan.original,
                page: page,
                quick: quick,
                timeout: timeout,
                searchContent: searchContent
            )
            var result = original
            if requestedPage == 1,
               let fallback = plan.fallback,
               !SearchTitleNormalizer.hasMeaningfulMatch(original.list, keyword: plan.original) {
                let remaining = timeout - elapsedSeconds()
                if remaining > 0, !Task.isCancelled {
                    do {
                        let fallbackResult = try await resultWithTimeout(
                            site: site,
                            keyword: fallback,
                            page: page,
                            quick: quick,
                            timeout: remaining,
                            searchContent: searchContent
                        )
                        result = merged(original: original, fallback: fallbackResult, siteKey: site.key)
                        DiagnosticLog.write(
                            "[SEARCH_SITE_FALLBACK] site=\(site.name) key=\(site.key) original=\(plan.original) fallback=\(fallback) list=\(fallbackResult.list.count)"
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        DiagnosticLog.write(
                            "[SEARCH_SITE_FALLBACK_FAILED] site=\(site.name) key=\(site.key) error=\(error.localizedDescription)"
                        )
                    }
                }
            }
            let resultPage = result.page > 0 ? result.page : requestedPage
            let searchResult = SearchResult(
                siteName: site.name,
                siteKey: site.key,
                vods: result.list,
                page: resultPage,
                hasMore: result.pagecount > resultPage,
                durationMs: durationMs()
            )
            DiagnosticLog.write("[SEARCH_SITE_RESULT] site=\(site.name) key=\(site.key) list=\(result.list.count) page=\(resultPage)")
            return searchResult
        } catch {
            let searchResult = SearchResult(
                siteName: site.name,
                siteKey: site.key,
                error: error.localizedDescription,
                errorCategory: Self.category(for: error),
                page: requestedPage,
                durationMs: durationMs()
            )
            DiagnosticLog.write("[SEARCH_SITE_RESULT] site=\(site.name) key=\(site.key) list=0 error=\(error.localizedDescription)")
            return searchResult
        }
    }

    private static func resultWithTimeout(
        site: Site,
        keyword: String,
        page: String,
        quick: Bool,
        timeout: TimeInterval,
        searchContent: @escaping @Sendable (Site, String, Bool, String) async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { inner in
            inner.addTask {
                try await Task.sleep(for: .seconds(max(0.001, timeout)))
                throw SearchEngineError.timeout(site.name)
            }
            inner.addTask {
                try await searchContent(site, keyword, quick, page)
            }
            guard let first = try await inner.next() else { throw CancellationError() }
            inner.cancelAll()
            return first
        }
    }

    private static func merged(original: Result, fallback: Result, siteKey: String) -> Result {
        var result = original
        var seen = Set<String>()
        result.list = (original.list + fallback.list).filter { vod in
            let source = vod.siteKey.isEmpty ? siteKey : vod.siteKey
            let identity = vod.vodId.isEmpty
                ? "\(source)|\(vod.vodName)|\(vod.vodPic)"
                : "\(source)|\(vod.vodId)"
            return seen.insert(identity).inserted
        }
        result.page = max(original.page, fallback.page)
        result.pagecount = max(original.pagecount, fallback.pagecount)
        result.total = max(result.list.count, max(original.total, fallback.total))
        return result
    }

    private static func category(for error: Error) -> AppFailureCategory {
        if error is SearchEngineError {
            return .spider
        }
        if let spiderError = error as? SpiderEngineError {
            switch spiderError {
            case .unsupportedAndroidCrawler:
                return .spider
            default:
                return .spider
            }
        }
        let text = error.localizedDescription.lowercased()
        if text.contains("timed out") || text.contains("timeout") || text.contains("cancel") {
            return .spider
        }
        if text.contains("parse") || text.contains("json") {
            return .source
        }
        return .source
    }
}

public enum SearchEngineError: LocalizedError, Sendable {
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let siteName):
            return "搜索站点超时: \(siteName)"
        }
    }
}
