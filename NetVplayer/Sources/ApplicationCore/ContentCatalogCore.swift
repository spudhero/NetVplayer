import Foundation
import Models

public struct ContentCatalogState: Sendable {
    public var generation: UInt64
    public var vods: [Vod]
    public var categories: [VodClass]
    public var selectedCategory: VodClass?
    public var categoryFilters: [Filter]
    public var selectedFilterValues: [String: String]
    public var filtersByCategoryID: [String: [Filter]]
    public var selectionsByCategoryID: [String: [String: String]]
    public var currentPage: Int
    public var pageCount: Int
    public var isLoading: Bool
    public var isLoadingMore: Bool

    public init(
        generation: UInt64 = 0,
        vods: [Vod] = [],
        categories: [VodClass] = [],
        selectedCategory: VodClass? = nil,
        categoryFilters: [Filter] = [],
        selectedFilterValues: [String: String] = [:],
        filtersByCategoryID: [String: [Filter]] = [:],
        selectionsByCategoryID: [String: [String: String]] = [:],
        currentPage: Int = 1,
        pageCount: Int = 1,
        isLoading: Bool = false,
        isLoadingMore: Bool = false
    ) {
        self.generation = generation
        self.vods = vods
        self.categories = categories
        self.selectedCategory = selectedCategory
        self.categoryFilters = categoryFilters
        self.selectedFilterValues = selectedFilterValues
        self.filtersByCategoryID = filtersByCategoryID
        self.selectionsByCategoryID = selectionsByCategoryID
        self.currentPage = max(currentPage, 1)
        self.pageCount = max(pageCount, 1)
        self.isLoading = isLoading
        self.isLoadingMore = isLoadingMore
    }
}

public struct ContentCatalogPayload: Sendable {
    public var types: [VodClass]
    public var vods: [Vod]
    public var filters: [String: [Filter]]
    public var page: Int
    public var pageCount: Int

    public init(
        types: [VodClass] = [],
        vods: [Vod] = [],
        filters: [String: [Filter]] = [:],
        page: Int = 1,
        pageCount: Int = 1
    ) {
        self.types = types
        self.vods = vods
        self.filters = filters
        self.page = page
        self.pageCount = pageCount
    }
}

public struct ContentCatalogRequest: Equatable, Sendable {
    public var generation: UInt64
    public var categoryID: String
    public var page: Int
    public var selection: [String: String]

    public init(
        generation: UInt64,
        categoryID: String,
        page: Int,
        selection: [String: String]
    ) {
        self.generation = generation
        self.categoryID = categoryID
        self.page = max(page, 1)
        self.selection = selection
    }
}

public enum ContentCatalogFailure: Equatable, Sendable, Error {
    case invalidFilter
    case invalidOption
    case invalidTextFilter(name: String)
}

public struct ContentCatalogTransition: Sendable {
    public var state: ContentCatalogState
    public var request: ContentCatalogRequest?
    public var failure: ContentCatalogFailure?

    public init(
        state: ContentCatalogState,
        request: ContentCatalogRequest? = nil,
        failure: ContentCatalogFailure? = nil
    ) {
        self.state = state
        self.request = request
        self.failure = failure
    }
}

public enum ContentCatalogCore {
    public static func beginHome(_ current: ContentCatalogState) -> ContentCatalogState {
        var state = resetFilters(current, clearDefinitions: true)
        state.generation &+= 1
        state.currentPage = 1
        state.pageCount = 1
        state.isLoading = true
        state.isLoadingMore = false
        return state
    }

    public static func receiveHome(
        _ current: ContentCatalogState,
        generation: UInt64,
        payload: ContentCatalogPayload
    ) -> ContentCatalogState {
        guard current.generation == generation else { return current }
        var state = current
        state.categories = visibleCategories(from: payload.types)
        state.vods = payload.vods
        state.filtersByCategoryID = payload.filters
        state.currentPage = max(payload.page, 1)
        state.pageCount = max(payload.pageCount, 1)
        state.isLoading = false
        return state
    }

    public static func failHome(
        _ current: ContentCatalogState,
        generation: UInt64,
        clearContent: Bool = false
    ) -> ContentCatalogState {
        guard current.generation == generation else { return current }
        var state = current
        state.isLoading = false
        state.isLoadingMore = false
        if clearContent {
            state.categories = []
            state.vods = []
        }
        return state
    }

    public static func beginCategory(
        _ current: ContentCatalogState,
        category: VodClass
    ) -> ContentCatalogTransition {
        var state = current
        state.generation &+= 1
        state.selectedCategory = category
        state.vods = []
        state.currentPage = 1
        state.pageCount = 1
        state.isLoadingMore = false
        state = configureFilters(state, category: category)

        guard !CategoryFilterSelectionPolicy.hasMissingRequiredText(
            filters: state.categoryFilters,
            selection: state.selectedFilterValues
        ) else {
            state.isLoading = false
            return ContentCatalogTransition(state: state)
        }

        state.isLoading = true
        return ContentCatalogTransition(
            state: state,
            request: request(for: state, category: category, page: 1)
        )
    }

    public static func beginNextPage(
        _ current: ContentCatalogState,
        triggerVodID: String
    ) -> ContentCatalogTransition {
        guard let category = current.selectedCategory,
              current.vods.last?.vodId == triggerVodID,
              !current.isLoading,
              !current.isLoadingMore,
              current.currentPage < current.pageCount else {
            return ContentCatalogTransition(state: current)
        }
        var state = current
        state.isLoadingMore = true
        return ContentCatalogTransition(
            state: state,
            request: request(for: state, category: category, page: state.currentPage + 1)
        )
    }

    public static func receiveCategory(
        _ current: ContentCatalogState,
        request: ContentCatalogRequest,
        payload: ContentCatalogPayload
    ) -> ContentCatalogState {
        guard request.generation == current.generation,
              request.categoryID == current.selectedCategory?.typeId else {
            return current
        }
        var state = current
        if request.page == 1 {
            state.vods = appendDeduplicated(existing: [], additional: payload.vods)
            if let returnedFilters = payload.filters[request.categoryID] {
                state.filtersByCategoryID[request.categoryID] = returnedFilters
                if let category = state.selectedCategory {
                    state = configureFilters(state, category: category)
                }
            }
            state.currentPage = max(payload.page, 1)
            state.pageCount = max(payload.pageCount, 1)
            state.isLoading = false
        } else {
            state.vods = appendDeduplicated(existing: state.vods, additional: payload.vods)
            state.currentPage = max(payload.page, request.page)
            state.pageCount = max(payload.pageCount, state.pageCount)
            state.isLoadingMore = false
        }
        return state
    }

    public static func failCategory(
        _ current: ContentCatalogState,
        request: ContentCatalogRequest
    ) -> ContentCatalogState {
        guard request.generation == current.generation,
              request.categoryID == current.selectedCategory?.typeId else {
            return current
        }
        var state = current
        if request.page == 1 {
            state.isLoading = false
        } else {
            state.isLoadingMore = false
        }
        return state
    }

    public static func selectOption(
        _ current: ContentCatalogState,
        filterKey: String,
        value: String
    ) -> ContentCatalogTransition {
        guard let category = current.selectedCategory,
              let filter = current.categoryFilters.first(where: {
                  $0.key == filterKey && $0.inputKind == .options
              }) else {
            return ContentCatalogTransition(state: current, failure: .invalidFilter)
        }
        guard filter.values.contains(where: { $0.value == value }) else {
            return ContentCatalogTransition(state: current, failure: .invalidOption)
        }
        var state = current
        state.selectedFilterValues[filter.key] = value
        state.selectionsByCategoryID[category.typeId] = state.selectedFilterValues
        return beginCategory(state, category: category)
    }

    public static func updateTextDraft(
        _ current: ContentCatalogState,
        filterKey: String,
        value: String
    ) -> ContentCatalogTransition {
        guard let category = current.selectedCategory,
              current.categoryFilters.contains(where: {
                  $0.key == filterKey && $0.inputKind == .text
              }) else {
            return ContentCatalogTransition(state: current, failure: .invalidFilter)
        }
        var state = current
        state.selectedFilterValues[filterKey] = value
        state.selectionsByCategoryID[category.typeId] = state.selectedFilterValues
        return ContentCatalogTransition(state: state)
    }

    public static func applyTextFilter(
        _ current: ContentCatalogState,
        filterKey: String
    ) -> ContentCatalogTransition {
        guard let category = current.selectedCategory,
              let filter = current.categoryFilters.first(where: {
                  $0.key == filterKey && $0.inputKind == .text
              }) else {
            return ContentCatalogTransition(state: current, failure: .invalidFilter)
        }
        guard let value = current.selectedFilterValues[filter.key],
              let normalized = CategoryFilterTextPolicy.normalized(value) else {
            return ContentCatalogTransition(
                state: current,
                failure: .invalidTextFilter(name: filter.name)
            )
        }
        var state = current
        state.selectedFilterValues[filter.key] = normalized
        state.selectionsByCategoryID[category.typeId] = state.selectedFilterValues
        return beginCategory(state, category: category)
    }

    public static func selectedFilterName(
        in state: ContentCatalogState,
        filterKey: String
    ) -> String {
        guard let filter = state.categoryFilters.first(where: { $0.key == filterKey }) else {
            return ""
        }
        if filter.inputKind == .text {
            return state.selectedFilterValues[filter.key] ?? ""
        }
        let value = state.selectedFilterValues[filter.key]
        return filter.values.first(where: { $0.value == value })?.name
            ?? filter.values.first?.name
            ?? ""
    }

    public static func resetContent(_ current: ContentCatalogState) -> ContentCatalogState {
        var state = resetFilters(current, clearDefinitions: true)
        state.generation &+= 1
        state.vods = []
        state.categories = []
        state.selectedCategory = nil
        state.currentPage = 1
        state.pageCount = 1
        state.isLoading = false
        state.isLoadingMore = false
        return state
    }

    public static func resetFilters(
        _ current: ContentCatalogState,
        clearDefinitions: Bool
    ) -> ContentCatalogState {
        var state = current
        state.categoryFilters = []
        state.selectedFilterValues = [:]
        state.selectionsByCategoryID = [:]
        if clearDefinitions {
            state.filtersByCategoryID = [:]
        }
        return state
    }

    public static func visibleCategories(from types: [VodClass]) -> [VodClass] {
        var seen = Set<String>()
        return types.compactMap { category in
            let normalizedID = category.typeId
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let normalizedName = category.typeName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedID != "recommend", normalizedName != "推荐" else { return nil }
            let key = normalizedID.isEmpty ? normalizedName : normalizedID
            guard seen.insert(key).inserted else { return nil }
            return category
        }
    }

    private static func configureFilters(
        _ current: ContentCatalogState,
        category: VodClass
    ) -> ContentCatalogState {
        var state = current
        let filters = state.filtersByCategoryID[category.typeId] ?? []
        let existing = state.selectionsByCategoryID[category.typeId] ?? [:]
        let selection = CategoryFilterSelectionPolicy.normalized(filters: filters, existing: existing)
        state.categoryFilters = filters
        state.selectedFilterValues = selection
        state.selectionsByCategoryID[category.typeId] = selection
        return state
    }

    private static func request(
        for state: ContentCatalogState,
        category: VodClass,
        page: Int
    ) -> ContentCatalogRequest {
        ContentCatalogRequest(
            generation: state.generation,
            categoryID: category.typeId,
            page: page,
            selection: state.selectedFilterValues
        )
    }

    private static func appendDeduplicated(existing: [Vod], additional: [Vod]) -> [Vod] {
        var seenIDs = Set(existing.map(\.vodId))
        var seenContent = Set(existing.compactMap(contentDeduplicationKey))
        var result = existing
        for vod in additional {
            guard seenIDs.insert(vod.vodId).inserted else { continue }
            if let contentKey = contentDeduplicationKey(vod),
               !seenContent.insert(contentKey).inserted {
                continue
            }
            result.append(vod)
        }
        return result
    }

    private static func contentDeduplicationKey(_ vod: Vod) -> String? {
        let title = vod.vodName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        let playback = vod.vodPlayUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !playback.isEmpty else { return nil }
        return "\(title)\u{1F}\(playback)"
    }
}
