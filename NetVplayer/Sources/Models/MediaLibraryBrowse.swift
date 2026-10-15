import Foundation

public enum MediaLibraryIdentity {
    public static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    /// Strip explicit season suffixes only; similar or deliberately altered names remain distinct.
    public static func showTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "(?i)[ ._\\-]*(?:第[一二三四五六七八九十百零〇0-9]+季|season[ ._\\-]*[0-9]{1,2}|S[0-9]{1,2}(?:[ ._]*-[ ._]*S?[0-9]{1,2})?)[ ._\\-]*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func collectionKey(_ collection: MediaCollection) -> String {
        if let id = collection.tmdbID, !id.isEmpty { return "tmdb:" + id }
        return "name:" + normalized(collection.name)
    }
    public static func actorKey(_ actor: MediaCastMember) -> String {
        if let id = actor.tmdbID, !id.isEmpty { return "tmdb:" + id }
        return "name:" + normalized(actorName(actor.name))
    }
    public static func actorName(_ name: String) -> String {
        personName(name)
    }
    public static func personName(_ name: String) -> String {
        // Douban/NFO can put the Chinese name and its Latin spelling in one field.
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = name.range(of: "^[\\p{Han}·・]+(?=\\s+[A-Za-z])", options: .regularExpression) else { return name }
        return String(name[range])
    }
    public static func directorKey(_ name: String) -> String {
        "name:" + normalized(personName(name))
    }
}

public struct MediaLibraryFilter: Equatable, Hashable, Sendable {
    public var collection: String?
    public var actor: String?
    public var director: String?
    public var isEmpty: Bool { collection == nil && actor == nil && director == nil }
    public init(collection: String? = nil, actor: String? = nil, director: String? = nil) {
        self.collection = collection; self.actor = actor; self.director = director
    }
}

public struct MediaLibraryFacet: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var count: Int
    public init(id: String, name: String, count: Int) { self.id = id; self.name = name; self.count = count }
}

public struct MediaLibraryFacets: Equatable, Sendable {
    public var collections: [MediaLibraryFacet]
    public var actors: [MediaLibraryFacet]
    public var directors: [MediaLibraryFacet]
    public init(collections: [MediaLibraryFacet] = [], actors: [MediaLibraryFacet] = [], directors: [MediaLibraryFacet] = []) {
        self.collections = collections; self.actors = actors; self.directors = directors
    }
}
