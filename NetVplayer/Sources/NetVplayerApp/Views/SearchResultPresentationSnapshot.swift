// NetVplayerApp/Views/SearchResultPresentationSnapshot.swift
// Stable, precomputed presentation data for streamed search results.

import ApplicationCore
import DriveEngine
import Models

struct SearchDisplayItem: Identifiable, Sendable {
    let id: String
    let result: SearchResult
    let vod: Vod
    let badge: String
    let isDrive: Bool
    let matchKind: SearchResultPresentationPolicy.MatchKind
    let sourceOrder: Int
    let sourceItemOrder: Int
}

struct SearchSourceOption: Identifiable, Sendable {
    let siteKey: String
    let siteName: String
    let count: Int
    let isDriveOnly: Bool

    var id: String { siteKey }
}

struct SearchResultPresentationRevision: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let id: String
        let name: String
        let picture: String
        let year: String
        let area: String
        let content: String
        let actor: String
        let director: String
        let remarks: String
        let typeName: String

        init(vod: Vod) {
            id = vod.vodId
            name = vod.vodName
            picture = vod.vodPic
            year = vod.vodYear
            area = vod.vodArea
            content = vod.vodContent
            actor = vod.vodActor
            director = vod.vodDirector
            remarks = vod.vodRemarks
            typeName = vod.typeName
        }
    }

    struct Source: Equatable, Sendable {
        let siteKey: String
        let siteName: String
        let items: [Item]
        let error: String?
        let durationMs: Int
    }

    let generation: UInt64
    let isLoading: Bool
    let sources: [Source]

    init(state: ContentSearchState) {
        generation = state.generation
        isLoading = state.isLoading
        sources = state.results.map {
            Source(
                siteKey: $0.siteKey,
                siteName: $0.siteName,
                items: $0.vods.map(Item.init(vod:)),
                error: $0.error,
                durationMs: $0.durationMs
            )
        }
    }
}

struct SearchResultPresentationSnapshot: Sendable {
    static let empty = SearchResultPresentationSnapshot(results: [], keyword: "")

    let successfulResults: [SearchResult]
    let secondaryResults: [SearchResult]
    let sourceOptions: [SearchSourceOption]
    let exactItems: [SearchDisplayItem]
    let relatedItems: [SearchDisplayItem]

    private let exactItemsBySource: [String: [SearchDisplayItem]]
    private let relatedItemsBySource: [String: [SearchDisplayItem]]

    init(results: [SearchResult], keyword: String) {
        successfulResults = results.filter { !$0.vods.isEmpty }
        secondaryResults = results.filter(\.vods.isEmpty)

        var candidates: [SearchDisplayItem] = []
        var options: [SearchSourceOption] = []

        for (sourceOrder, result) in results.enumerated() {
            var sourceItems: [SearchDisplayItem] = []

            if !result.vods.isEmpty {
                let groups = DriveSearchGroupingPolicy.groups(for: result.vods, sourceName: result.siteName)
                var sourceItemOrder = 0

                for (groupOrder, group) in groups.enumerated() {
                    for (vodOrder, vod) in group.vods.enumerated() {
                        let isDrive = group.provider != .unknown
                        let badge = isDrive ? "\(result.siteName) · \(group.title)" : result.siteName
                        sourceItems.append(SearchDisplayItem(
                            id: "\(result.siteKey)|\(group.id)|\(vod.vodId)|\(groupOrder)|\(vodOrder)",
                            result: result,
                            vod: vod,
                            badge: badge,
                            isDrive: isDrive,
                            matchKind: SearchResultPresentationPolicy.matchKind(of: vod, keyword: keyword),
                            sourceOrder: sourceOrder,
                            sourceItemOrder: sourceItemOrder
                        ))
                        sourceItemOrder += 1
                    }
                }
            }

            candidates.append(contentsOf: sourceItems)
            if !sourceItems.isEmpty {
                options.append(SearchSourceOption(
                    siteKey: result.siteKey,
                    siteName: result.siteName,
                    count: sourceItems.count,
                    isDriveOnly: sourceItems.allSatisfy(\.isDrive)
                ))
            }
        }

        let orderedItems = SearchResultPresentationPolicy.ordered(
            candidates,
            keyword: keyword,
            vod: \.vod,
            sourceOrder: \.sourceOrder,
            sourceItemOrder: \.sourceItemOrder
        )
        let exactItems = orderedItems.filter { $0.matchKind == .exact }
        let relatedItems = orderedItems.filter { $0.matchKind != .exact }

        self.sourceOptions = options
        self.exactItems = exactItems
        self.relatedItems = relatedItems
        exactItemsBySource = Dictionary(grouping: exactItems) { $0.result.siteKey }
        relatedItemsBySource = Dictionary(grouping: relatedItems) { $0.result.siteKey }
    }

    func exactItems(sourceKey: String?) -> [SearchDisplayItem] {
        guard let sourceKey else { return exactItems }
        return exactItemsBySource[sourceKey] ?? []
    }

    func relatedItems(sourceKey: String?) -> [SearchDisplayItem] {
        guard let sourceKey else { return relatedItems }
        return relatedItemsBySource[sourceKey] ?? []
    }

    func itemCount(sourceKey: String?) -> Int {
        exactItems(sourceKey: sourceKey).count + relatedItems(sourceKey: sourceKey).count
    }
}
