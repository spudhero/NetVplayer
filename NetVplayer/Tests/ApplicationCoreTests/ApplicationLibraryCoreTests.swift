import ApplicationCore
import Foundation
import Models
import Testing

@Suite("Application core library and persistence")
struct ApplicationLibraryCoreTests {
    @Test func sourceSelectionUsesConfiguredHomeAndFallbacks() {
        let regular = Site(key: "regular", name: "Regular", type: 1, api: "https://cms.example.test")
        let configured = Site(key: "configured", name: "Configured", type: 1, api: "https://configured.example.test")
        let remoteHome = Site(key: "configured", name: "Remote", type: 1, api: "https://remote.example.test")

        let selection = ApplicationLibraryCore.sourceSelection(
            sites: [regular, configured],
            configuredHome: remoteHome
        )
        #expect(selection.site?.key == "configured")
        #expect(selection.displayName == "Configured")

        let preferred = ApplicationLibraryCore.sourceSelection(
            sites: [regular, configured],
            configuredHome: regular,
            preferredSiteKey: configured.key
        )
        #expect(preferred.site?.key == "configured")

        let stalePreference = ApplicationLibraryCore.sourceSelection(
            sites: [regular, configured],
            configuredHome: regular,
            preferredSiteKey: "removed"
        )
        #expect(stalePreference.site?.key == "regular")

        let missing = Site(key: "missing", name: "Missing", type: 1)
        let fallback = ApplicationLibraryCore.sourceSelection(
            sites: [regular],
            configuredHome: missing
        )
        #expect(fallback.site?.key == "missing")
        #expect(ApplicationLibraryCore.sourceSelection(sites: [], configuredHome: nil).displayName == "默认")
    }

    @Test func registeringNewConfigAssignsContinuousIDAndPrepends() {
        let initial = ApplicationLibraryState(configs: [
            Config(id: 4, type: .vod, url: "https://old.example.test/config.json", name: "Old")
        ])
        let transition = ApplicationLibraryCore.registerConfig(
            initial,
            loadedConfig: Config(type: .live, url: "", name: ""),
            canonicalURL: "https://new.example.test/config.json",
            fallbackName: "new.example.test/config.json"
        )

        #expect(transition.changed)
        #expect(transition.state.configs.map(\.id) == [5, 4])
        #expect(transition.state.configs.first?.type == .vod)
        #expect(transition.state.configs.first?.url == "https://new.example.test/config.json")
        #expect(transition.state.configs.first?.name == "new.example.test/config.json")
    }

    @Test func registeringExistingConfigPreservesIDAndPosition() {
        let initial = ApplicationLibraryState(configs: [
            Config(id: 8, type: .vod, url: "https://a.example.test/config.json", name: "A"),
            Config(id: 9, type: .vod, url: "https://b.example.test/config.json", name: "B")
        ])
        let transition = ApplicationLibraryCore.registerConfig(
            initial,
            loadedConfig: Config(type: .vod, url: "https://b.example.test/config.json", name: "Updated"),
            canonicalURL: "https://b.example.test/config.json",
            fallbackName: "Fallback"
        )

        #expect(transition.state.configs.map(\.id) == [8, 9])
        #expect(transition.state.configs[1].name == "Updated")
    }

    @Test func removingConfigUsesIDOrStableIdentity() {
        let initial = ApplicationLibraryState(configs: [
            Config(id: 1, type: .vod, url: "https://a.example.test"),
            Config(id: 2, type: .live, url: "https://b.example.test")
        ])
        let removed = ApplicationLibraryCore.removeConfig(
            initial,
            config: Config(id: 99, type: .vod, url: "https://a.example.test")
        )
        #expect(removed.changed)
        #expect(removed.state.configs.map(\.id) == [2])

        let unchanged = ApplicationLibraryCore.removeConfig(
            removed.state,
            config: Config(id: 100, type: .vod, url: "https://missing.example.test")
        )
        #expect(!unchanged.changed)
    }

    @Test func playbackHistoryUpdatePreservesPreferencesAndMovesToFront() {
        let existing = History(
            key: "site-vod",
            siteKey: "site",
            vodId: "vod",
            revSort: true,
            revPlay: true,
            opening: 10_000,
            ending: 20_000,
            speed: 1.5,
            scale: 2,
            configId: 7
        )
        let other = History(key: "other", siteKey: "site", vodId: "other")
        let record = History(
            key: "site-vod",
            siteKey: "site",
            vodId: "vod",
            vodName: "Updated",
            episodeUrl: "episode-2",
            position: 42_000,
            duration: 120_000
        )
        let transition = ApplicationLibraryCore.recordHistory(
            ApplicationLibraryState(history: [other, existing]),
            record: record,
            preservingPlaybackPreferences: true
        )

        let updated = transition.state.history[0]
        #expect(transition.state.history.map(\.key) == ["site-vod", "other"])
        #expect(updated.vodName == "Updated")
        #expect(updated.revSort && updated.revPlay)
        #expect(updated.opening == 10_000)
        #expect(updated.ending == 20_000)
        #expect(updated.speed == 1.5)
        #expect(updated.scale == 2)
        #expect(updated.configId == 7)
    }

    @Test func explicitHistoryReplacementUsesRecordDefaults() {
        let existing = History(key: "same", opening: 9_000, speed: 2, configId: 3)
        let replacement = History(key: "same", vodName: "Replacement")
        let transition = ApplicationLibraryCore.recordHistory(
            ApplicationLibraryState(history: [existing]),
            record: replacement,
            preservingPlaybackPreferences: false
        )

        #expect(transition.state.history.first?.vodName == "Replacement")
        #expect(transition.state.history.first?.opening == 0)
        #expect(transition.state.history.first?.speed == 1)
        #expect(transition.state.history.first?.configId == 0)
        #expect(!ApplicationLibraryCore.recordHistory(
            transition.state,
            record: History(),
            preservingPlaybackPreferences: false
        ).changed)
    }

    @Test func playbackHistoryUpdateDoesNotEraseProgressAfterPlayerReset() {
        let existing = History(
            key: "site-vod",
            episodeUrl: "episode-1",
            position: 115_000,
            duration: 120_000
        )
        let resetSnapshot = History(
            key: "site-vod",
            episodeUrl: "episode-1",
            position: 0,
            duration: 0
        )

        let preserved = ApplicationLibraryCore.recordHistory(
            ApplicationLibraryState(history: [existing]),
            record: resetSnapshot,
            preservingPlaybackPreferences: true
        ).state.history[0]
        #expect(preserved.position == 115_000)
        #expect(preserved.duration == 120_000)

        let nextEpisode = History(key: "site-vod", episodeUrl: "episode-2")
        let replaced = ApplicationLibraryCore.recordHistory(
            ApplicationLibraryState(history: [existing]),
            record: nextEpisode,
            preservingPlaybackPreferences: true
        ).state.history[0]
        #expect(replaced.position == 0)
        #expect(replaced.duration == 0)
    }

    @Test func historyRemovalAndClearReportRealChanges() {
        let state = ApplicationLibraryState(history: [History(key: "one"), History(key: "two")])
        let removed = ApplicationLibraryCore.removeHistory(state, id: "one")
        #expect(removed.changed)
        #expect(removed.state.history.map(\.key) == ["two"])
        #expect(!ApplicationLibraryCore.removeHistory(removed.state, id: "missing").changed)

        let cleared = ApplicationLibraryCore.clearHistory(removed.state)
        #expect(cleared.changed)
        #expect(cleared.state.history.isEmpty)
        #expect(!ApplicationLibraryCore.clearHistory(cleared.state).changed)
    }

    @Test func keepIdentityIncludesMediaType() {
        let vod = Keep(key: "shared", vodName: "Vod", type: .vod)
        let live = Keep(key: "shared", vodName: "Live", type: .live)
        let withVod = ApplicationLibraryCore.toggleKeep(
            ApplicationLibraryState(keeps: [live]),
            candidate: vod
        ).state
        #expect(withVod.keeps.map(\.type) == [.vod, .live])
        #expect(ApplicationLibraryCore.containsKeep(withVod, key: "shared", type: .vod))
        #expect(ApplicationLibraryCore.containsKeep(withVod, key: "shared", type: .live))

        let withoutVod = ApplicationLibraryCore.toggleKeep(withVod, candidate: vod).state
        #expect(withoutVod.keeps.map(\.type) == [.live])
        let removedLive = ApplicationLibraryCore.removeKeep(
            withoutVod,
            id: live.id,
            type: .live
        )
        #expect(removedLive.changed)
        #expect(removedLive.state.keeps.isEmpty)
    }

    @Test func keepRemarksOnlyTransitionWhenValuesChange() {
        let keep = Keep(key: "site-vod", vodRemarks: "Episode 1", type: .vod)
        let initial = ApplicationLibraryState(keeps: [keep])
        let discovered = ApplicationLibraryCore.updateKeepRemarks(
            initial,
            key: keep.key,
            currentRemarks: "Episode 2",
            acknowledge: false
        )
        #expect(discovered.changed)
        #expect(discovered.state.keeps.first?.vodRemarks == "Episode 1")
        #expect(discovered.state.keeps.first?.latestRemarks == "Episode 2")

        let acknowledged = ApplicationLibraryCore.updateKeepRemarks(
            discovered.state,
            key: keep.key,
            currentRemarks: "Episode 2",
            acknowledge: true
        )
        #expect(acknowledged.state.keeps.first?.vodRemarks == "Episode 2")
        #expect(acknowledged.state.keeps.first?.latestRemarks.isEmpty == true)
        #expect(!ApplicationLibraryCore.updateKeepRemarks(
            acknowledged.state,
            key: keep.key,
            currentRemarks: "Episode 2",
            acknowledge: true
        ).changed)
    }

    @Test func historyPlaybackIntentKeepsSiteFlagEpisodeAndResume() {
        let site = Site(key: "site", name: "Site", type: 3)
        let history = History(
            key: "site-vod",
            siteKey: "site",
            vodId: "vod",
            vodPic: "poster",
            vodName: "Movie",
            vodFlag: "Line B",
            vodRemarks: "Episode 2",
            episodeUrl: "episode-2",
            position: 12_000,
            duration: 120_000
        )
        let intent = ApplicationLibraryCore.historyPlaybackIntent(
            history: history,
            sites: [site]
        )

        #expect(intent.site?.key == "site")
        #expect(intent.vod.vodId == "vod")
        #expect(intent.preferredFlag == "Line B")
        #expect(intent.resumePosition == 12_000)
        #expect(intent.resumeDuration == 120_000)
        #expect(intent.episode(
            from: [Episode(name: "Episode 2", url: "episode-2")],
            history: history
        ).url == "episode-2")
    }

    @Test func persistencePortBuildsOneLibrarySnapshot() {
        let persistence = FixturePersistence(
            configs: [Config(id: 1, url: "config")],
            history: [History(key: "history")],
            keeps: [Keep(key: "keep")]
        )
        let snapshot = persistence.loadApplicationLibrary()
        #expect(snapshot.configs.map(\.id) == [1])
        #expect(snapshot.history.map(\.key) == ["history"])
        #expect(snapshot.keeps.map(\.key) == ["keep"])
    }
}

private final class FixturePersistence: ApplicationLibraryPersistence, @unchecked Sendable {
    let configs: [Config]
    let history: [History]
    let keeps: [Keep]

    init(configs: [Config], history: [History], keeps: [Keep]) {
        self.configs = configs
        self.history = history
        self.keeps = keeps
    }

    func loadConfigs() -> [Config] { configs }
    func saveConfigs(_ configs: [Config]) throws {}
    func loadHistory() -> [History] { history }
    func saveHistory(_ items: [History]) throws {}
    func clearHistoryRecords() throws {}
    func loadKeeps() -> [Keep] { keeps }
    func saveKeeps(_ items: [Keep]) throws {}
}
