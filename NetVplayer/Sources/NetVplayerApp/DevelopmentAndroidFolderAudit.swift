import Models

/// Finds a content card without treating CatVod folder results as playback.
/// Folder IDs are opaque, including JSON text consumed by the original spider.
@MainActor
enum DevelopmentAndroidFolderAudit {
    struct Listing {
        var items: [Vod]
        var error: String? = nil
    }

    struct Visit {
        let id: String
        let depth: Int
        let items: Int
        let folders: Int
        let error: String?
    }

    struct Resolution {
        var leaf: Vod?
        var leafDepth = 0
        var visits: [Visit] = []
        var failure: String?
    }

    static func resolve(
        _ root: Vod,
        maximumDepth: Int = 3,
        maximumFolderVisits: Int = 6,
        allowEmptyRootID: Bool = false,
        isFolder: (Vod) -> Bool,
        load: (Vod) async -> Listing
    ) async -> Resolution {
        var resolution = Resolution()
        var pending = [(root, 0)]
        var visited = Set<String>()
        var depthLimited = false
        var repeatedFolder = false
        var listingFailed = false
        while !pending.isEmpty {
            guard !Task.isCancelled else {
                resolution.failure = "folder_cancelled"
                return resolution
            }
            let (card, depth) = pending.removeFirst()
            let folder = isFolder(card)
            // Some original providers use the empty string as an explicit
            // category root. Only the diagnostic's root can opt in; empty
            // child folders and ordinary cards must never become requests.
            guard !card.vodId.isEmpty || (allowEmptyRootID && depth == 0 && folder) else { continue }
            guard folder else {
                resolution.leaf = card
                resolution.leafDepth = depth
                return resolution
            }
            guard !visited.contains(card.vodId) else {
                repeatedFolder = true
                continue
            }
            guard depth < max(0, maximumDepth) else {
                depthLimited = true
                continue
            }
            guard resolution.visits.count < max(0, maximumFolderVisits) else {
                resolution.failure = "folder_visit_limit"
                return resolution
            }
            visited.insert(card.vodId)
            let listing = await load(card)
            let error = listing.error.flatMap { $0.isEmpty ? nil : $0 }
            resolution.visits.append(Visit(id: card.vodId, depth: depth + 1,
                items: listing.items.count, folders: listing.items.filter(isFolder).count, error: error))
            guard error == nil else {
                // A failed category request can leave old AppState cards behind.
                listingFailed = true
                continue
            }
            // Prefer an actual leaf, then descend in provider order. An empty
            // branch can fall back to its siblings within the same request cap.
            let leaves = listing.items.filter { !isFolder($0) }
            let folders = listing.items.filter(isFolder)
            pending.insert(contentsOf: (leaves + folders).map { ($0, depth + 1) }, at: 0)
        }
        resolution.failure = listingFailed ? "folder_category_error"
            : depthLimited ? "folder_depth_limit"
            : repeatedFolder ? "folder_cycle" : "folder_empty"
        return resolution
    }
}
