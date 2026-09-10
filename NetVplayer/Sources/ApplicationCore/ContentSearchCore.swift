import Models

public struct ContentSearchState: Sendable {
    public var generation: UInt64
    public var keyword: String
    public var siteOrder: [String]
    public var results: [SearchResult]
    public var isLoading: Bool

    public init(
        generation: UInt64 = 0,
        keyword: String = "",
        siteOrder: [String] = [],
        results: [SearchResult] = [],
        isLoading: Bool = false
    ) {
        self.generation = generation
        self.keyword = keyword
        self.siteOrder = siteOrder
        self.results = results
        self.isLoading = isLoading
    }
}

public struct ContentSearchSummary: Equatable, Sendable {
    public var totalResults: Int
    public var errorCount: Int

    public init(totalResults: Int, errorCount: Int) {
        self.totalResults = totalResults
        self.errorCount = errorCount
    }
}

public enum ContentSearchCore {
    public static func begin(
        _ current: ContentSearchState,
        keyword: String,
        siteOrder: [String] = []
    ) -> ContentSearchState {
        var state = current
        state.generation &+= 1
        state.keyword = keyword
        state.siteOrder = siteOrder
        state.results = []
        state.isLoading = true
        return state
    }

    public static func updateSiteOrder(
        _ current: ContentSearchState,
        generation: UInt64,
        siteOrder: [String]
    ) -> ContentSearchState {
        guard current.generation == generation else { return current }
        var state = current
        state.siteOrder = siteOrder
        state.results = orderedResults(state.results, siteOrder: siteOrder)
        return state
    }

    public static func ingest(
        _ current: ContentSearchState,
        generation: UInt64,
        result: SearchResult
    ) -> ContentSearchState {
        guard current.generation == generation, current.isLoading else { return current }
        var state = current
        if let index = state.results.firstIndex(where: { $0.siteKey == result.siteKey }) {
            state.results[index] = result
        } else {
            state.results.append(result)
        }
        state.results = orderedResults(state.results, siteOrder: state.siteOrder)
        return state
    }

    public static func finish(
        _ current: ContentSearchState,
        generation: UInt64
    ) -> ContentSearchState {
        guard current.generation == generation else { return current }
        var state = current
        state.isLoading = false
        return state
    }

    public static func reset(_ current: ContentSearchState) -> ContentSearchState {
        var state = current
        state.generation &+= 1
        state.keyword = ""
        state.siteOrder = []
        state.results = []
        state.isLoading = false
        return state
    }

    public static func resolved(
        _ current: ContentSearchState,
        keyword: String,
        results: [SearchResult]
    ) -> ContentSearchState {
        var state = current
        state.generation &+= 1
        state.keyword = keyword
        state.siteOrder = results.map(\.siteKey)
        state.results = results
        state.isLoading = false
        return state
    }

    public static func summary(
        _ state: ContentSearchState,
        generation: UInt64
    ) -> ContentSearchSummary? {
        guard state.generation == generation else { return nil }
        return ContentSearchSummary(
            totalResults: state.results.reduce(0) { $0 + $1.vods.count },
            errorCount: state.results.filter { $0.error != nil }.count
        )
    }

    public static func orderedResults(
        _ results: [SearchResult],
        siteOrder: [String]
    ) -> [SearchResult] {
        var order: [String: Int] = [:]
        for (index, key) in siteOrder.enumerated() where order[key] == nil {
            order[key] = index
        }
        return results.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = resultRank(lhs.element)
                let rhsRank = resultRank(rhs.element)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                let lhsOrder = order[lhs.element.siteKey] ?? Int.max
                let rhsOrder = order[rhs.element.siteKey] ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func resultRank(_ result: SearchResult) -> Int {
        if !result.vods.isEmpty { return 0 }
        if result.error == nil { return 1 }
        return 2
    }
}
