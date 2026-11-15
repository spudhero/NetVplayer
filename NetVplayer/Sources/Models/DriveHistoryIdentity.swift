import Foundation

/// Source file identity for history matching, independent of expiring playback credentials
/// and of the personal-drive copy created while resolving a shared file.
struct DriveHistoryIdentity: Equatable {
    let provider: String
    let share: String
    let shareID: String
    let fileID: String

    init?(locator: String) {
        var value = locator
        if let separator = value.firstIndex(of: "$") {
            value = String(value[value.index(after: separator)...])
        }
        let sanitized = HistoryPersistencePolicy.sanitizedDriveReference(value)
        guard let components = URLComponents(string: sanitized), !sanitized.isEmpty else { return nil }
        if components.scheme?.lowercased() == "pikpak" {
            self.provider = "pikpak"
            self.share = ""
            self.shareID = ""
            self.fileID = String(components.path.dropFirst())
            return
        }
        guard components.path == "/file", let host = components.host else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            // Ambiguous identity parameters must not pick whichever value appeared first.
            guard query[name] == nil else { return nil }
            query[name] = item.value ?? ""
        }
        guard let fileID = query["fid"], !fileID.isEmpty else { return nil }
        var share = URLComponents(string: query["share"] ?? "") ?? URLComponents()
        share.scheme = share.scheme?.lowercased()
        share.host = share.host?.lowercased()
        share.fragment = nil
        share.queryItems = share.queryItems?.sorted {
            $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name
        }
        self.provider = host.lowercased()
        self.share = share.string ?? ""
        self.shareID = query["pwd_id"] ?? ""
        self.fileID = fileID
    }

    static func from(_ history: History) -> Self? {
        Self(locator: history.episodeUrl) ?? Self(locator: history.driveReferenceURL)
    }
}
