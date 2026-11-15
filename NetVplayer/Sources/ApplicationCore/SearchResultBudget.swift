/// Admission budgets bound the published list without excluding any source's first request.
/// Complete pages remain in SearchEngine's existing bounded cache, never in a second page store.
public struct SearchResultBudget: Sendable, Equatable {
    public static let batchTotal = 60
    public static let batchPerSite = 12
    public private(set) var total: Int
    public private(set) var perSite: [String: Int] = [:]
    private let initialPerSite: Int

    public init(total: Int = batchTotal, perSite: Int = batchPerSite) {
        self.total = max(0, total)
        self.initialPerSite = max(0, min(perSite, ContentSearchCore.maximumResultsPerSite))
    }

    public func limit(for siteKey: String) -> Int { perSite[siteKey] ?? initialPerSite }

    public mutating func expand(siteKeys: [String]) {
        guard !siteKeys.isEmpty else { return }
        total = total > Int.max - Self.batchTotal ? Int.max : total + Self.batchTotal
        for key in siteKeys {
            perSite[key] = min(ContentSearchCore.maximumResultsPerSite, limit(for: key) + Self.batchPerSite)
        }
    }
}

public extension ContentSearchCore {
    static func remainingBudget(_ state: ContentSearchState, siteKey: String) -> Int {
        let count = state.results.first { $0.siteKey == siteKey }?.vods.count ?? 0
        let total = state.results.reduce(0) { $0 + $1.vods.count }
        return max(0, min(state.resultBudget.total - total,
                          state.resultBudget.limit(for: siteKey) - count,
                          maximumResultsPerSite - count))
    }

    /// One user action admits one bounded wave. Sparse/unseen sources get their turn first.
    static func expandContinuationBudget(_ current: ContentSearchState, siteKey: String? = nil) -> ContentSearchState {
        guard !current.isLoading else { return current }
        let keys = current.cursors.keys.filter { key in
            (siteKey == nil || key == siteKey) && current.cursors[key]?.status != .limited
                && current.cursors[key]?.status != .exhausted
        }
        var state = current
        state.resultBudget.expand(siteKeys: keys)
        for key in keys where state.cursors[key]?.status == .budgeted && remainingBudget(state, siteKey: key) > 0 {
            state.cursors[key]?.status = .ready
        }
        return state
    }

    static func automaticContinuationSites(_ state: ContentSearchState, siteKey: String? = nil) -> [String] {
        guard !state.isLoading else { return [] }
        let counts = Dictionary(state.results.map { ($0.siteKey, $0.vods.count) }, uniquingKeysWith: max)
        let order = Dictionary(state.siteOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return state.cursors.keys.filter { key in
            (siteKey == nil || siteKey == key) && state.cursors[key]?.status == .ready
                && remainingBudget(state, siteKey: key) > 0
        }.sorted {
            if counts[$0, default: 0] != counts[$1, default: 0] { return counts[$0, default: 0] < counts[$1, default: 0] }
            if order[$0, default: .max] != order[$1, default: .max] { return order[$0, default: .max] < order[$1, default: .max] }
            return $0 < $1
        }
    }
}
