import Foundation
import Models

public enum SearchResultPresentationPolicy {
    public enum MatchKind: Int, Sendable {
        case exact
        case prefix
        case contains
        case metadata
        case other
    }

    public static func ordered<Element>(
        _ elements: [Element],
        keyword: String,
        vod: (Element) -> Vod,
        sourceOrder: (Element) -> Int,
        sourceItemOrder: (Element) -> Int
    ) -> [Element] {
        let normalizedKeyword = normalized(keyword)
        guard !normalizedKeyword.isEmpty else { return elements }

        let ranked = elements.enumerated().map { offset, element in
            (
                element: element,
                relevance: matchKind(of: vod(element), normalizedKeyword: normalizedKeyword).rawValue,
                sourceOrder: sourceOrder(element),
                sourceItemOrder: sourceItemOrder(element),
                offset: offset
            )
        }

        return ranked.sorted { lhs, rhs in
            if lhs.relevance != rhs.relevance { return lhs.relevance < rhs.relevance }
            if lhs.sourceItemOrder != rhs.sourceItemOrder {
                return lhs.sourceItemOrder < rhs.sourceItemOrder
            }
            if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    public static func matchKind(of vod: Vod, keyword: String) -> MatchKind {
        matchKind(of: vod, normalizedKeyword: normalized(keyword))
    }

    private static func matchKind(of vod: Vod, normalizedKeyword keyword: String) -> MatchKind {
        guard !keyword.isEmpty else { return .other }
        let title = normalized(vod.vodName)
        if title == keyword { return .exact }
        if title.hasPrefix(keyword) { return .prefix }
        if title.contains(keyword) { return .contains }

        let metadata = [
            vod.typeName,
            vod.vodActor,
            vod.vodDirector,
            vod.vodYear,
            vod.vodArea,
            vod.vodRemarks,
            vod.vodContent
        ]
        .map(normalized)
        .joined(separator: " ")
        if metadata.contains(keyword) { return .metadata }

        return .other
    }

    private static func normalized(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh_Hans_CN")
        )
        return folded.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }
}
