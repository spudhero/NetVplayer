import Foundation
import Models
import PlayerEngine
import Storage
import Testing
@testable import NetVplayerApp

@Suite("Media server version and episode linkage", .serialized) @MainActor
struct MediaServerVersionSelectionTests {
    @Test func versionChoicesStayWithinTheCurrentEpisodeAndAccount() throws {
        let account = UUID()
        let one = try MediaServerReference(accountID: account, itemID: "one")
        let two = try MediaServerReference(accountID: account, itemID: "two")
        let other = try MediaServerReference(accountID: UUID(), itemID: "one")
        let files = [one, two, other].map { MediaServerFileDetail(id: $0.locator, episodeURL: $0.locator, name: "Version", sourceID: "source-a") }
        #expect(MediaServerVersionSelection.files(files, for: one.locator).map(\.episodeURL) == [one.locator])
        let selected = try MediaServerReference(accountID: account, itemID: "one", sourceID: "source-b")
        #expect(MediaServerVersionSelection.preferredSourceID(explicit: nil, historyURL: selected.locator, episodeURL: one.locator) == "source-b")
        #expect(MediaServerVersionSelection.preferredSourceID(explicit: "", historyURL: selected.locator, episodeURL: one.locator) == nil)
        #expect(MediaServerVersionSelection.preferredSourceID(explicit: nil, historyURL: selected.locator, episodeURL: two.locator) == nil)
        #expect(MediaServerVersionSelection.preferredSourceID(explicit: "source-removed", historyURL: nil, episodeURL: one.locator) == "source-removed")
        let episode = Episode(name: "Episode", url: one.locator, overview: "Original overview", season: 1, number: 2)
        let version = MediaServerVersionSelection.episode(episode, sourceID: "source-b")
        #expect(version.url == selected.locator && version.overview == episode.overview && version.number == episode.number)
        #expect(MediaServerVersionSelection.episode(episode, sourceID: nil).url == episode.url)
    }

    @Test func historyAndCurrentPlaybackLocateTheCanonicalEpisodeWithoutQueuingOtherCuts() throws {
        let one = try MediaServerReference(accountID: UUID(), itemID: "one")
        let two = try MediaServerReference(accountID: one.accountID, itemID: "two")
        let selected = try MediaServerReference(accountID: one.accountID, itemID: "two", sourceID: "source-b")
        let episodes = [Episode(name: "One", url: one.locator), Episode(name: "Two", url: two.locator)]
        let history = History(episodeUrl: selected.locator, position: 30_000)
        #expect(PlaybackLinkage.preferredEpisode(from: history, episodes: episodes)?.url == two.locator)
        #expect(NASMediaDetailPresentation.primaryEpisode(episodes: episodes, history: history)?.url == two.locator)
        let domain = "ServerVersionSelection." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let app = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: .init(storageDirectory: directory),
            userPreferences: .init(defaults: defaults, credentialStore: MemoryCredentialStore()), providerRuntimeBootstrap: nil)
        var spec = PlaySpec(url: "http://127.0.0.1/stream")
        spec.metadata["vod.episodeURL"] = selected.locator
        app.playerState.currentSpec = spec
        #expect(app.episodeForCurrentPlayback(in: episodes)?.url == two.locator)
        #expect(app.playbackEpisodeContext(in: episodes).total == 2)
        #expect(app.playbackEpisodeContext(in: episodes).hasNext == false)
    }
}
