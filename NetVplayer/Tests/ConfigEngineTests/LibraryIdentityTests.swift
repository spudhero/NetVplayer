import Foundation
import Testing
import Models
import Storage
import ApplicationCore
@testable import NetVplayerApp

@Suite(.serialized)
@MainActor
struct LibraryIdentityTests {
    private let site = Site(key: "shared_site", name: "Source", type: 1, api: "https://source.invalid/api")

    @Test func configurationAndProviderChangesSeparateIdentityButRenamesDoNot() throws {
        let first = LibrarySourceIdentity.fingerprint(configurationURL: "https://one.invalid/config", site: site)
        let second = LibrarySourceIdentity.fingerprint(configurationURL: "https://two.invalid/config", site: site)
        var renamed = site
        renamed.name = "New display name"
        #expect(first != second)
        #expect(first == LibrarySourceIdentity.fingerprint(configurationURL: "https://one.invalid/config", site: renamed))
        renamed.api = "https://replacement.invalid/api"
        #expect(first != LibrarySourceIdentity.fingerprint(configurationURL: "https://one.invalid/config", site: renamed))
        let key = PlaybackLinkage.vodKey(siteKey: site.key, vodId: "season_1|episode_2", sourceFingerprint: first)
        #expect(PlaybackLinkage.vodIdentity(from: key).siteKey == site.key)
        #expect(PlaybackLinkage.vodIdentity(from: key).vodId == "season_1|episode_2")
    }

    @Test func migrationPreservesAmbiguousRecordsAndBindsOnlyKnownConfiguration() throws {
        let a = Config(id: 1, url: "https://a.invalid/config")
        let b = Config(id: 2, url: "https://b.invalid/config")
        let legacy = History(key: "shared_site_film", siteKey: site.key, vodId: "film", episodeName: "Episode 1", position: 500)
        let state = ApplicationLibraryState(configs: [a, b], history: [legacy], keeps: [Keep(key: legacy.key)])
        let ambiguous = LibraryIdentityMigration.migrate(state, configuration: a, sites: [site])
        #expect(ambiguous.history == state.history)
        #expect(ambiguous.keeps.first?.sourceFingerprint == "")
        let unique = LibraryIdentityMigration.migrate(.init(configs: [a], history: [legacy], keeps: state.keeps), configuration: a, sites: [site])
        #expect(unique.history.first?.configId == 1)
        #expect(unique.history.first?.sourceFingerprint.isEmpty == false)
        #expect(unique.keeps.first?.key == unique.history.first?.key)
        #expect(unique.history.first?.position == 500)
        let roundTrip = try JSONDecoder().decode(History.self, from: JSONEncoder().encode(unique.history[0]))
        #expect(roundTrip == unique.history[0])
        let oldJSON = Data(#"{"key":"old","siteKey":"s","vodId":"v"}"#.utf8)
        #expect(try JSONDecoder().decode(History.self, from: oldJSON).sourceFingerprint.isEmpty)
    }

    @Test func duplicateEpisodeNamesDoNotResumeAnArbitraryVersion() {
        let history = History(siteKey: "s", vodId: "v", episodeName: "Episode 1")
        let episodes = [Episode(name: "Episode 1", url: "cut-a"), Episode(name: "Episode 1", url: "cut-b")]
        #expect(PlaybackLinkage.preferredEpisode(from: history, episodes: episodes) == nil)
        let intent = ApplicationLibraryCore.historyPlaybackIntent(history: history, sites: [])
        #expect(intent.episode(from: episodes, history: history).url.isEmpty)
    }

    @Test func progressMergeCannotCrossConfigurationEvenWithSameEpisode() {
        let a = Config(id: 1, url: "https://a.invalid/config")
        let b = Config(id: 2, url: "https://b.invalid/config")
        let base = History(key: "old", siteKey: site.key, vodId: "v", episodeUrl: "episode", position: 100, createTime: Date(timeIntervalSince1970: 1))
        let first = LibraryIdentityMigration.bind(base, configuration: a, site: site)
        var second = LibraryIdentityMigration.bind(base, configuration: b, site: site)
        second.position = 900
        second.createTime = Date(timeIntervalSince1970: 2)
        let export = PlaybackProgressExport(records: [PlaybackProgressRecord(history: second)])
        #expect(PlaybackProgressRecord(history: first).progressKey != export.records[0].progressKey)
        #expect(PlaybackProgressSyncPolicy.merged(existing: [first], importing: export) == [first])
    }

    @Test func appWritesAndFindsHistoryAndFavoritesWithinConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = StorageManager(storageDirectory: directory)
        let app = AppState(loadDefaultConfig: false, startProxyServer: false, storageManager: storage, providerRuntimeBootstrap: nil)
        let a = Config(id: 1, url: "https://a.invalid/config")
        let b = Config(id: 2, url: "https://b.invalid/config")
        app.savedConfigs = [a, b]
        app.sites = [site]
        app.activeSite = site
        let vod = Vod(vodId: "v", vodName: "Same title", siteKey: site.key)
        app.detailVod = vod
        app.libraryConfigurationURL = a.url
        app.addHistory(vod: vod, flag: "line", episode: Episode(name: "1", url: "one"), position: 100, duration: 1000)
        app.toggleKeep(vod: vod)
        app.libraryConfigurationURL = b.url
        #expect(app.currentDetailHistory() == nil)
        #expect(!app.isKept(vodId: "v"))
        app.addHistory(vod: vod, flag: "line", episode: Episode(name: "1", url: "one"), position: 200, duration: 1000)
        app.toggleKeep(vod: vod)
        #expect(app.historyItems.count == 2)
        #expect(app.keepItems.count == 2)
        #expect(app.currentDetailHistory()?.position == 200)
        app.libraryConfigurationURL = a.url
        #expect(app.currentDetailHistory()?.position == 100)
        #expect(app.isKept(vodId: "v"))
        app.clearHistory()
    }
}
