import Foundation

public struct VodSkipSettingsIdentity: Codable, Hashable, Sendable {
    public let siteKey: String
    public let vodID: String

    public init?(siteKey: String, vodID: String) {
        let normalizedSiteKey = siteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVodID = vodID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSiteKey.isEmpty, !normalizedVodID.isEmpty else { return nil }
        self.siteKey = normalizedSiteKey
        self.vodID = normalizedVodID
    }

    public init?(playbackMetadata: [String: String]) {
        self.init(
            siteKey: playbackMetadata["vod.siteKey"] ?? "",
            vodID: playbackMetadata["vod.id"] ?? ""
        )
    }
}

public struct VodSkipSettings: Codable, Equatable, Sendable {
    public static let empty = VodSkipSettings(openingSeconds: 0, endingSeconds: 0)

    public let openingSeconds: Int
    public let endingSeconds: Int

    public init(openingSeconds: Int, endingSeconds: Int) {
        self.openingSeconds = min(600, max(0, openingSeconds))
        self.endingSeconds = min(600, max(0, endingSeconds))
    }
}

public final class VodSkipSettingsStore: @unchecked Sendable {
    public static let shared = VodSkipSettingsStore()

    private struct Record: Codable {
        let identity: VodSkipSettingsIdentity
        let settings: VodSkipSettings
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "netvplayer.vodSkipSettings.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func settings(for identity: VodSkipSettingsIdentity?) -> VodSkipSettings {
        guard let identity else { return .empty }
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked().last { $0.identity == identity }?.settings ?? .empty
    }

    public func settings(for playbackMetadata: [String: String]) -> VodSkipSettings {
        settings(for: VodSkipSettingsIdentity(playbackMetadata: playbackMetadata))
    }

    @discardableResult
    public func save(
        openingSeconds: Int,
        endingSeconds: Int,
        for identity: VodSkipSettingsIdentity
    ) -> VodSkipSettings {
        let settings = VodSkipSettings(
            openingSeconds: openingSeconds,
            endingSeconds: endingSeconds
        )

        lock.lock()
        defer { lock.unlock() }

        var records = loadUnlocked()
        records.removeAll { $0.identity == identity }
        if settings != .empty {
            records.append(Record(identity: identity, settings: settings))
        }
        saveUnlocked(records)
        return settings
    }

    private func loadUnlocked() -> [Record] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        return records
    }

    private func saveUnlocked(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
