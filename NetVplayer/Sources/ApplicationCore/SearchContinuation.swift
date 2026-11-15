import Models

public struct SearchPageCursor: Sendable, Equatable {
    public enum Status: Sendable { case ready, loading, exhausted, retryable, budgeted, limited }
    public var keyword: String
    /// The exact cache/request keyword for an incompletely admitted page.
    public var pageKeyword: String?
    public var nextPage: Int = 1
    public var status: Status = .ready
    public var message: String?

    public init(keyword: String) { self.keyword = keyword }
    public var canRequest: Bool { status == .ready || status == .retryable }
}

public extension ContentSearchCore {
    static let maximumResultsPerSite = 2_000

    static func beginContinuation(_ current: ContentSearchState, siteKey: String) -> ContentSearchState {
        guard var cursor = current.cursors[siteKey], cursor.canRequest,
              remainingBudget(current, siteKey: siteKey) > 0 else { return current }
        var state = current
        cursor.status = .loading
        cursor.message = nil
        state.cursors[siteKey] = cursor
        return state
    }

    static func receivePage(_ current: ContentSearchState, generation: UInt64, requestedPage: Int, result: SearchResult) -> ContentSearchState {
        guard current.generation == generation else { return current }
        var state = current
        var cursor = state.cursors[result.siteKey] ?? SearchPageCursor(keyword: state.keyword)
        guard cursor.nextPage == requestedPage else { return current }
        let index = state.results.firstIndex { $0.siteKey == result.siteKey }
        var combined = index.map { state.results[$0] } ?? SearchResult(siteName: result.siteName, siteKey: result.siteKey)
        combined.isCached = (index == nil || combined.isCached) && result.isCached
        var failure = result.error
        if failure == nil, result.page != requestedPage || requestedPage < 1 || requestedPage == Int.max {
            failure = L10n.text("站点返回了错误页码，可重试本页。")
        }
        var seen = Set(combined.vods.map(searchIdentity))
        let normalized = result.vods.map { vod in
            var vod = vod
            if vod.siteKey.isEmpty { vod.siteKey = result.siteKey }
            return vod
        }
        let additions = normalized.filter { seen.insert(searchIdentity($0)).inserted }
        if failure == nil, additions.isEmpty, result.hasMore {
            failure = L10n.text("站点未返回新内容，可重试本页。")
        }
        if let failure {
            cursor.status = .retryable
            cursor.message = failure
            combined.error = failure
            combined.errorCategory = result.errorCategory
        } else {
            let remaining = remainingBudget(state, siteKey: result.siteKey)
            let truncated = additions.count > remaining
            // The presentation already ranks exact/prefix/title matches first. Apply that
            // same policy before a cut so a useful hit at the tail is not hidden by budget.
            let admitted = truncated && remaining > 0
                ? SearchResultPresentationPolicy.ordered(Array(additions.enumerated()), keyword: state.keyword,
                    vod: { $0.element }, sourceOrder: { _ in 0 }, sourceItemOrder: { $0.offset }).map(\.element)
                : additions
            combined.vods.append(contentsOf: admitted.prefix(remaining))
            combined.error = nil
            combined.errorCategory = nil
            combined.page = requestedPage
            combined.hasMore = result.hasMore || truncated
            combined.durationMs = result.durationMs
            combined.pageCountIsKnown = result.pageCountIsKnown
            cursor.pageKeyword = truncated ? (cursor.pageKeyword ?? (requestedPage == 1 ? state.keyword : cursor.keyword)) : nil
            cursor.keyword = result.effectiveKeyword.isEmpty ? cursor.keyword : result.effectiveKeyword
            combined.effectiveKeyword = cursor.keyword
            // A truncated page is replayed through the cache and the same identity dedupe.
            cursor.nextPage = truncated ? requestedPage : requestedPage + 1
            cursor.status = combined.hasMore ? .ready : .exhausted
            if combined.hasMore && (truncated || combined.vods.count >= state.resultBudget.limit(for: result.siteKey)
                || state.results.reduce(0, { $0 + $1.vods.count }) + min(additions.count, remaining) >= state.resultBudget.total) {
                cursor.status = .budgeted
            }
            if combined.vods.count == maximumResultsPerSite && combined.hasMore {
                cursor.status = .limited
                cursor.message = L10n.text("已达到此来源的结果上限，请缩小关键词范围。")
            }
            cursor.message = cursor.status == .limited ? cursor.message : nil
        }
        if let index { state.results[index] = combined } else { state.results.append(combined) }
        state.cursors[result.siteKey] = cursor
        state.results = orderedResults(state.results, siteOrder: state.siteOrder)
        return state
    }

    static func cancelContinuation(_ current: ContentSearchState, generation: UInt64, siteKey: String) -> ContentSearchState {
        guard current.generation == generation, var cursor = current.cursors[siteKey], cursor.status == .loading else { return current }
        var state = current
        cursor.status = .retryable
        state.cursors[siteKey] = cursor
        return state
    }

    private static func searchIdentity(_ vod: Vod) -> String {
        vod.vodId.isEmpty ? "\(vod.siteKey)\u{0}\(vod.vodName)\u{0}\(vod.vodPic)" : "\(vod.siteKey)\u{0}\(vod.vodId)"
    }
}
