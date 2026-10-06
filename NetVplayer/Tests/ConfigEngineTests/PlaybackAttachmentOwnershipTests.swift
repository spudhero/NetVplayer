import Foundation
import Testing
import Models
import Storage
import DanmakuEngine
@testable import NetVplayerApp

@Suite(.serialized)
struct PlaybackAttachmentOwnershipTests {
    @MainActor
    @Test func danmakuResultCannotReplaceAnotherEpisodeOrClosedPlayer() async throws {
        let previous = UserPreferences.shared.danmakuEnabled
        UserPreferences.shared.danmakuEnabled = true
        defer { UserPreferences.shared.danmakuEnabled = previous }
        for closes in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let state = AppState(loadDefaultConfig: false, startProxyServer: false,
                                 storageManager: StorageManager(storageDirectory: directory),
                                 providerRuntimeBootstrap: nil)
            let gate = AttachmentSearchGate()
            state.danmakuSearchOperation = { _, _ in await gate.result() }
            state.isPlayerPresented = true
            state.playerState.currentSpec = PlaySpec(url: "https://example.test/old.mp4",
                metadata: ["playback.sessionGeneration": "1"], danmaku: "https://example.test/comments", title: "old")
            let search = Task { await state.manualSearchDanmakuForCurrentPlayback() }
            await gate.waitUntilStarted()
            state.playerState.currentSpec = PlaySpec(url: "https://example.test/new.mp4",
                metadata: ["playback.sessionGeneration": "2"], title: "new")
            state.playerState.danmakuStatus = "current session"
            if closes { state.isPlayerPresented = false }
            await gate.finish()
            await search.value
            #expect(state.playerState.currentSpec?.title == "new")
            #expect(state.playerState.currentSpec?.danmakuAttachment == nil)
            #expect(state.playerState.danmakuStatus == "current session")
            #expect(state.danmakuCandidates.isEmpty)
        }
    }

    @MainActor
    @Test func deletingCurrentHistorySuppressesFurtherProgressFromThatSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = StorageManager(storageDirectory: directory)
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
                             storageManager: storage, providerRuntimeBootstrap: nil)
        let vod = Vod(vodId: "film", vodName: "Film", siteKey: "source")
        state.detailVod = vod
        state.playerState.currentSpec = PlaySpec(url: "https://example.test/film.mp4", siteKey: "source")
        state.addHistory(vod: vod, flag: "line", episode: Episode(name: "1", url: "file-token"),
                         position: 10_000, duration: 30_000)
        state.removeHistory(try #require(state.historyItems.first))
        state.saveCurrentPlaybackProgress()
        #expect(state.historyItems.isEmpty)
        #expect(storage.loadHistory().isEmpty)
    }
}

private actor AttachmentSearchGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<[DanmakuMatch], Never>?
    func result() async -> [DanmakuMatch] {
        await withCheckedContinuation {
            resultWaiter = $0
            started = true
            startWaiter?.resume(); startWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish() {
        resultWaiter?.resume(returning: [DanmakuMatch(title: "old episode", track: DanmakuTrack(format: .xml, cacheKey: "old", sourceName: "old"))]); resultWaiter = nil
    }
}
