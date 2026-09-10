import Foundation
import Testing
import ApplicationCore
import Models
import Storage
@testable import NetVplayerApp

@Suite("AppState library item removal", .serialized)
struct AppStateLibraryRemovalTests {
    @MainActor
    @Test func removingSavedConfigUpdatesMemoryDiskAndCurrentPreference() throws {
        let (storage, directory) = makeTemporaryStorage()
        let previousPreference = UserPreferences.shared.currentVodConfigUrl
        defer {
            UserPreferences.shared.currentVodConfigUrl = previousPreference
            try? FileManager.default.removeItem(at: directory)
        }

        let removed = Config(
            id: 3,
            type: .vod,
            url: "https://config.example.test/removed.json",
            name: "待删除配置"
        )
        let remaining = Config(
            id: 4,
            type: .vod,
            url: "https://config.example.test/remaining.json",
            name: "保留配置"
        )
        try storage.saveConfigs([removed, remaining])
        UserPreferences.shared.currentVodConfigUrl = removed.url

        let appState = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            storageManager: storage
        )

        #expect(appState.deleteSavedConfig(removed))
        #expect(appState.savedConfigs.map(\.id) == [remaining.id])
        #expect(storage.loadConfigs().map(\.id) == [remaining.id])
        #expect(UserPreferences.shared.currentVodConfigUrl.isEmpty)
    }

    @MainActor
    @Test func removingInactiveSavedConfigKeepsCurrentPreference() throws {
        let (storage, directory) = makeTemporaryStorage()
        let previousPreference = UserPreferences.shared.currentVodConfigUrl
        defer {
            UserPreferences.shared.currentVodConfigUrl = previousPreference
            try? FileManager.default.removeItem(at: directory)
        }

        let removed = Config(
            id: 5,
            type: .vod,
            url: "https://config.example.test/inactive.json"
        )
        try storage.saveConfigs([removed])
        UserPreferences.shared.currentVodConfigUrl = "https://config.example.test/current.json"

        let appState = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            storageManager: storage
        )

        #expect(appState.deleteSavedConfig(removed))
        #expect(appState.savedConfigs.isEmpty)
        #expect(storage.loadConfigs().isEmpty)
        #expect(
            UserPreferences.shared.currentVodConfigUrl
                == "https://config.example.test/current.json"
        )
    }

    @MainActor
    @Test func removingOneHistoryItemUpdatesMemoryAndDisk() throws {
        let (storage, directory) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: directory) }

        let removed = History(
            key: "site_removed",
            siteKey: "site",
            vodId: "removed",
            vodName: "待删除影片"
        )
        let remaining = History(
            key: "site_remaining",
            siteKey: "site",
            vodId: "remaining",
            vodName: "保留影片"
        )
        try storage.saveHistory([removed, remaining])

        let appState = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            storageManager: storage
        )
        appState.removeHistory(removed)

        #expect(appState.historyItems.map(\.id) == [remaining.id])
        #expect(storage.loadHistory().map(\.id) == [remaining.id])
    }

    @MainActor
    @Test func removingHistoryCancelsPendingSnapshotSave() async throws {
        let (storage, directory) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: directory) }

        let appState = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            storageManager: storage
        )
        appState.addHistory(
            vod: Vod(vodId: "pending", vodName: "防抖影片", siteKey: "site"),
            flag: "线路一",
            episode: Episode(name: "第1集", url: "https://media.example.test/pending.m3u8"),
            position: 12_000,
            duration: 120_000
        )

        let item = try #require(appState.historyItems.first)
        appState.removeHistory(item)
        try await Task.sleep(nanoseconds: 450_000_000)

        #expect(appState.historyItems.isEmpty)
        #expect(storage.loadHistory().isEmpty)
    }

    @MainActor
    @Test func removingKeepMatchesBothStableIDAndType() throws {
        let (storage, directory) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: directory) }

        let vodKeep = Keep(key: "shared-key", vodName: "点播收藏", type: .vod)
        let liveKeep = Keep(key: "shared-key", vodName: "直播收藏", type: .live)
        try storage.saveKeeps([vodKeep, liveKeep])

        let appState = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            storageManager: storage
        )
        appState.removeKeep(vodKeep)

        #expect(appState.keepItems.count == 1)
        #expect(appState.keepItems.first?.type == .live)
        #expect(storage.loadKeeps().map(\.type) == [.live])

        appState.removeKeep(liveKeep)

        #expect(appState.keepItems.isEmpty)
        #expect(storage.loadKeeps().isEmpty)
    }

    @MainActor
    @Test func failedPersistenceDoesNotReplaceLibraryState() {
        let previousPreference = UserPreferences.shared.currentVodConfigUrl
        defer { UserPreferences.shared.currentVodConfigUrl = previousPreference }

        let history = History(key: "history", siteKey: "site", vodId: "vod")
        let keep = Keep(key: "keep", vodName: "Keep", type: .vod)
        let config = Config(id: 3, type: .vod, url: "https://config.example.test")
        UserPreferences.shared.currentVodConfigUrl = config.url
        let persistence = FailingLibraryPersistence(
            configs: [config],
            history: [history],
            keeps: [keep]
        )
        let appState = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            applicationLibraryPersistence: persistence
        )

        #expect(!appState.deleteSavedConfig(config))
        appState.removeHistory(history)
        appState.removeKeep(keep)
        appState.toggleKeep(vod: Vod(vodId: "new", vodName: "New", siteKey: "site"))

        #expect(appState.savedConfigs.map(\.id) == [3])
        #expect(UserPreferences.shared.currentVodConfigUrl == config.url)
        #expect(appState.historyItems.map(\.key) == ["history"])
        #expect(appState.keepItems.map(\.key) == ["keep"])
    }

    private func makeTemporaryStorage() -> (StorageManager, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netvplayer-library-removal-\(UUID().uuidString)", isDirectory: true)
        return (StorageManager(storageDirectory: directory), directory)
    }
}

private final class FailingLibraryPersistence: ApplicationLibraryPersistence, @unchecked Sendable {
    private let configs: [Config]
    private let history: [History]
    private let keeps: [Keep]

    init(configs: [Config], history: [History], keeps: [Keep]) {
        self.configs = configs
        self.history = history
        self.keeps = keeps
    }

    func loadConfigs() -> [Config] { configs }
    func loadHistory() -> [History] { history }
    func loadKeeps() -> [Keep] { keeps }
    func saveConfigs(_ configs: [Config]) throws { throw Failure.write }
    func saveHistory(_ items: [History]) throws { throw Failure.write }
    func clearHistoryRecords() throws { throw Failure.write }
    func saveKeeps(_ items: [Keep]) throws { throw Failure.write }

    private enum Failure: Error {
        case write
    }
}
