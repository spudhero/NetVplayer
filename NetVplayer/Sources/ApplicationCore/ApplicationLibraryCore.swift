import Foundation
import Models

public struct ApplicationLibraryState: Sendable {
    public var configs: [Config]
    public var history: [History]
    public var keeps: [Keep]

    public init(
        configs: [Config] = [],
        history: [History] = [],
        keeps: [Keep] = []
    ) {
        self.configs = configs
        self.history = history
        self.keeps = keeps
    }
}

public struct ApplicationLibraryTransition: Sendable {
    public var state: ApplicationLibraryState
    public var changed: Bool

    public init(state: ApplicationLibraryState, changed: Bool) {
        self.state = state
        self.changed = changed
    }
}

public protocol ApplicationLibraryPersistence: Sendable {
    func loadConfigs() -> [Config]
    func saveConfigs(_ configs: [Config]) throws
    func loadHistory() -> [History]
    func saveHistory(_ items: [History]) throws
    func clearHistoryRecords() throws
    func loadKeeps() -> [Keep]
    func saveKeeps(_ items: [Keep]) throws
}

public extension ApplicationLibraryPersistence {
    func loadApplicationLibrary() -> ApplicationLibraryState {
        ApplicationLibraryState(
            configs: loadConfigs(),
            history: loadHistory(),
            keeps: loadKeeps()
        )
    }
}

public struct ContentSourceSelection: Sendable {
    public var site: Site?
    public var displayName: String

    public init(site: Site?, displayName: String) {
        self.site = site
        self.displayName = displayName
    }
}

public struct HistoryPlaybackIntent: Sendable {
    public var site: Site?
    public var vod: Vod
    public var preferredFlag: String?
    public var fallbackEpisode: Episode
    public var resumePosition: Int64?
    public var resumeDuration: Int64?

    public init(
        site: Site?,
        vod: Vod,
        preferredFlag: String?,
        fallbackEpisode: Episode,
        resumePosition: Int64?,
        resumeDuration: Int64?
    ) {
        self.site = site
        self.vod = vod
        self.preferredFlag = preferredFlag
        self.fallbackEpisode = fallbackEpisode
        self.resumePosition = resumePosition
        self.resumeDuration = resumeDuration
    }

    public func episode(from episodes: [Episode], history: History) -> Episode {
        PlaybackLinkage.preferredEpisode(from: history, episodes: episodes) ?? fallbackEpisode
    }
}

public enum ApplicationLibraryCore {
    public static func sourceSelection(
        sites: [Site],
        configuredHome: Site?,
        preferredSiteKey: String? = nil
    ) -> ContentSourceSelection {
        let selected: Site?
        if let preferredSiteKey,
           let preferredSite = sites.first(where: { $0.key == preferredSiteKey }) {
            selected = preferredSite
        } else if let configuredHome {
            selected = sites.first { $0.key == configuredHome.key } ?? configuredHome
        } else {
            selected = sites.first
        }
        return ContentSourceSelection(site: selected, displayName: selected?.name ?? "默认")
    }

    public static func sourceSelection(site: Site) -> ContentSourceSelection {
        ContentSourceSelection(site: site, displayName: site.name)
    }

    public static func registerConfig(
        _ state: ApplicationLibraryState,
        loadedConfig: Config?,
        canonicalURL: String,
        fallbackName: String
    ) -> ApplicationLibraryTransition {
        var next = state
        var loaded = loadedConfig ?? Config.vod(url: canonicalURL)
        loaded.type = .vod
        loaded.url = loaded.url.isEmpty ? canonicalURL : loaded.url
        if loaded.name.isEmpty {
            loaded.name = fallbackName
        }

        if let index = next.configs.firstIndex(where: {
            $0.type == loaded.type && $0.url == loaded.url
        }) {
            loaded.id = next.configs[index].id
            next.configs[index] = loaded
        } else {
            loaded.id = (next.configs.map(\.id).max() ?? 0) + 1
            next.configs.insert(loaded, at: 0)
        }
        return ApplicationLibraryTransition(state: next, changed: true)
    }

    public static func removeConfig(
        _ state: ApplicationLibraryState,
        config: Config
    ) -> ApplicationLibraryTransition {
        var next = state
        let originalCount = next.configs.count
        next.configs.removeAll {
            $0.id == config.id || ($0.type == config.type && $0.url == config.url)
        }
        return ApplicationLibraryTransition(
            state: next,
            changed: next.configs.count != originalCount
        )
    }

    public static func replacingConfigs(
        _ state: ApplicationLibraryState,
        with configs: [Config]
    ) -> ApplicationLibraryState {
        var next = state
        next.configs = configs
        return next
    }

    public static func recordHistory(
        _ state: ApplicationLibraryState,
        record: History,
        preservingPlaybackPreferences: Bool
    ) -> ApplicationLibraryTransition {
        guard !record.key.isEmpty else {
            return ApplicationLibraryTransition(state: state, changed: false)
        }

        var next = state
        var updated = HistoryPersistencePolicy.sanitized(record)
        if preservingPlaybackPreferences,
           let existing = next.history.first(where: { $0.key == record.key }) {
            updated.revSort = existing.revSort
            updated.revPlay = existing.revPlay
            updated.opening = existing.opening
            updated.ending = existing.ending
            updated.speed = existing.speed
            updated.scale = existing.scale
            updated.configId = existing.configId
            let matchesExistingEpisode = !updated.episodeKey.isEmpty
                ? updated.episodeKey == existing.episodeKey
                : updated.episodeUrl == existing.episodeUrl
            if matchesExistingEpisode,
               updated.position == 0,
               updated.duration == 0,
               (existing.position > 0 || existing.duration > 0) {
                updated.position = existing.position
                updated.duration = existing.duration
            }
        }
        next.history.removeAll { $0.key == record.key }
        next.history.insert(updated, at: 0)
        return ApplicationLibraryTransition(state: next, changed: true)
    }

    public static func removeHistory(
        _ state: ApplicationLibraryState,
        id: String
    ) -> ApplicationLibraryTransition {
        var next = state
        let originalCount = next.history.count
        next.history.removeAll { $0.id == id }
        return ApplicationLibraryTransition(
            state: next,
            changed: next.history.count != originalCount
        )
    }

    public static func clearHistory(
        _ state: ApplicationLibraryState
    ) -> ApplicationLibraryTransition {
        guard !state.history.isEmpty else {
            return ApplicationLibraryTransition(state: state, changed: false)
        }
        var next = state
        next.history = []
        return ApplicationLibraryTransition(state: next, changed: true)
    }

    public static func replacingHistory(
        _ state: ApplicationLibraryState,
        with history: [History]
    ) -> ApplicationLibraryState {
        var next = state
        next.history = history
        return next
    }

    public static func toggleKeep(
        _ state: ApplicationLibraryState,
        candidate: Keep
    ) -> ApplicationLibraryTransition {
        guard !candidate.key.isEmpty else {
            return ApplicationLibraryTransition(state: state, changed: false)
        }
        var next = state
        if let index = next.keeps.firstIndex(where: {
            $0.key == candidate.key && $0.type == candidate.type
        }) {
            next.keeps.remove(at: index)
        } else {
            next.keeps.insert(candidate, at: 0)
        }
        return ApplicationLibraryTransition(state: next, changed: true)
    }

    public static func removeKeep(
        _ state: ApplicationLibraryState,
        id: String,
        type: KeepType
    ) -> ApplicationLibraryTransition {
        var next = state
        let originalCount = next.keeps.count
        next.keeps.removeAll { $0.id == id && $0.type == type }
        return ApplicationLibraryTransition(
            state: next,
            changed: next.keeps.count != originalCount
        )
    }

    public static func updateKeepRemarks(
        _ state: ApplicationLibraryState,
        key: String,
        currentRemarks: String,
        acknowledge: Bool
    ) -> ApplicationLibraryTransition {
        var next = state
        guard let index = next.keeps.firstIndex(where: {
            $0.key == key && $0.type == .vod
        }) else {
            return ApplicationLibraryTransition(state: state, changed: false)
        }
        let updated = PlaybackLinkage.updatedKeep(
            next.keeps[index],
            currentRemarks: currentRemarks,
            acknowledge: acknowledge
        )
        guard updated.vodRemarks != next.keeps[index].vodRemarks
            || updated.latestRemarks != next.keeps[index].latestRemarks else {
            return ApplicationLibraryTransition(state: state, changed: false)
        }
        next.keeps[index] = updated
        return ApplicationLibraryTransition(state: next, changed: true)
    }

    public static func containsKeep(
        _ state: ApplicationLibraryState,
        key: String,
        type: KeepType
    ) -> Bool {
        state.keeps.contains { $0.key == key && $0.type == type }
    }

    public static func historyPlaybackIntent(
        history: History,
        sites: [Site]
    ) -> HistoryPlaybackIntent {
        let site = sites.first { $0.key == history.siteKey }
        let vod = Vod(
            vodId: history.vodId,
            vodName: history.vodName,
            vodPic: history.vodPic,
            vodRemarks: history.vodRemarks,
            siteKey: history.siteKey
        )
        let fallbackName = history.episodeName.isEmpty
            ? (history.vodRemarks.isEmpty ? history.vodName : history.vodRemarks)
            : history.episodeName
        return HistoryPlaybackIntent(
            site: site,
            vod: vod,
            preferredFlag: history.vodFlag.isEmpty ? nil : history.vodFlag,
            fallbackEpisode: Episode(name: fallbackName, url: history.episodeUrl),
            resumePosition: history.position > 0 ? history.position : nil,
            resumeDuration: history.duration > 0 ? history.duration : nil
        )
    }
}
