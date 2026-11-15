import Models

enum MediaServerVersionSelection {
    static func files(_ files: [MediaServerFileDetail], for episodeURL: String?) -> [MediaServerFileDetail] {
        guard let episodeURL, let reference = MediaServerReference(locator: episodeURL) else { return [] }
        return files.filter { reference.matchesItem($0.episodeURL) }
    }

    static func preferredSourceID(explicit: String?, historyURL: String?, episodeURL: String?) -> String? {
        let requested: String?
        if let explicit { requested = explicit.isEmpty ? nil : explicit }
        else if let historyURL, let history = MediaServerReference(locator: historyURL),
                let episodeURL, history.matchesItem(episodeURL) { requested = history.sourceID }
        else { requested = nil }
        // Keep a vanished choice explicit; resolution must fail rather than play another cut.
        return requested.flatMap { MediaServerReference.validID($0) ? $0 : nil }
    }

    static func episode(_ episode: Episode, sourceID: String?) -> Episode {
        guard let sourceID, let reference = MediaServerReference(locator: episode.url),
              let selected = try? MediaServerReference(accountID: reference.accountID, itemID: reference.itemID, sourceID: sourceID)
        else { return episode }
        var copy = episode
        copy.url = selected.locator
        return copy
    }
}
