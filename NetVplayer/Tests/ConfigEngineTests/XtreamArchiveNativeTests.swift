import AppKit
import SwiftUI
import Testing
import Foundation
import Models
import Storage
import LiveEngine
import SpiderEngine
@testable import NetVplayerApp
@testable import PlayerEngine

@Suite(.serialized) @MainActor
struct XtreamArchiveNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_XTREAM_NATIVE_ROOT"] != nil))
    func historyGuideRealDecodeCompensatedSeekEndReplayAndLive() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_XTREAM_NATIVE_ROOT"]))
        struct Server: Decodable { let baseURL: String; let programmeStart: Double }
        let server = try JSONDecoder().decode(Server.self, from: Data(contentsOf: root.appendingPathComponent("server.json")))
        try #require(URL(string: server.baseURL)?.host == "127.0.0.1")
        let suite = "xtream-native-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserPreferences(defaults: defaults)
        let account = try XtreamConfiguration(name: "Synthetic Xtream", server: server.baseURL, allowsHTTP: true)
        preferences.xtreamConfigurations = [account]
        try preferences.saveXtreamCredentials(.init(username: "fixture-user", password: "fixture-pass"), for: account.id, server: account.server)
        let provider = try XtreamSiteProvider(configuration: account, credentials: { try preferences.xtreamCredentials(for: account.id, server: account.server) })
        let site = try account.site()
        await SpiderReplacementRegistry.shared.register(originalKey: site.key, originalAPI: site.api, provider: provider)
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: root.appendingPathComponent("library")), userPreferences: preferences, providerRuntimeBootstrap: nil)
        state.liveEpgRepository = XMLTVRepository(directory: root.appendingPathComponent("epg-cache"))
        let groups = try await provider.liveGroups(), channel = try #require(groups.first?.channels.first)
        await state.changeLive(.init(name: "Synthetic Xtream", url: account.url), initialGroups: groups)
        let start = Date(timeIntervalSince1970: server.programmeStart)
        let model = EPGGuideModel(), loader = state.makeLiveEpgLoader()
        model.reset(window: DateInterval(start: start.addingTimeInterval(-60), duration: 6 * 3_600)) { ch, window, force in
            await loader.load(channel: ch, window: window, forceRefresh: force)
        }
        model.appear(id: "fixture", channel: channel, generation: model.generation)
        try await wait { model.rows["fixture"] != nil }
        let result = try #require(model.rows["fixture"]), programme = try #require(result.data.items.first)
        try #require(result.coverage == .xtreamHistory && result.data.items.count == 2)
        try #require(programme.start == start && programme.end == start.addingTimeInterval(3600))
        try #require(state.liveCatchupAvailability(channel: channel, programme: programme).isAvailable)
        try #require(!state.liveCatchupAvailability(channel: channel, programme: result.data.items[1]).isAvailable)
        _ = NSApplication.shared
        let panel = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 1080, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.title = "OV87-05 isolated Xtream archive"
        let guide = NSHostingView(rootView: EPGGuideView(initialDate: start).environmentObject(state))
        panel.contentView = guide; panel.orderFrontRegardless()
        defer { panel.orderOut(nil); model.stop(); state.dismissLivePlayer() }
        try await Task.sleep(for: .seconds(1))
        guide.layoutSubtreeIfNeeded(); guide.displayIfNeeded()
        let bitmap = try #require(guide.bitmapImageRepForCachingDisplay(in: guide.bounds))
        guide.cacheDisplay(in: guide.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("xtream-guide.png"))
        let engine = MPVPlayerEngine.live
        let video = try #require(MPVOpenGLVideoView(engine: engine, surface: .live))
        panel.contentView = video; engine.attach(to: video, surface: .live)
        defer { engine.stop(); engine.detach(from: video) }
        state.isLivePlayerPresented = true
        await state.playLiveCatchup(channel: channel, programme: programme, revision: state.liveSourceRevision)
        try await wait { state.liveCatchupPhase == .playing && state.liveCatchupPosition > 0.2 }
        let first = try #require(state.livePlayerState.currentSpec)
        try #require(engine.nativePropertyJSON("video-params/w") == "640")
        try #require(first.liveCatchup?.mediaStartOffset == -7 && first.initialStartPositionSeconds == 7)
        try #require(state.liveCatchupPosition < 5 && state.livePlayerState.position >= 7)
        try #require(await state.seekLiveCatchup(to: 3_595) == .request(programmePosition: 3_595))
        try await wait { state.liveCatchupPhase == .playing }
        let second = try #require(state.livePlayerState.currentSpec)
        try #require(second.liveCatchup?.programme == programme && second.liveCatchup?.mediaStartOffset == 3_593)
        try #require(second.initialStartPositionSeconds == 2)
        state.handleMPVPlaybackPosition(spec: first, positionSeconds: 3)
        try #require(state.liveCatchupPosition >= 3_595)
        try await wait { state.liveCatchupPhase == .ended }
        try #require(state.liveCatchupPosition == 3_600)
        await state.retryLiveCatchup(fromBeginning: true)
        try await wait { state.liveCatchupPhase == .playing }
        await state.returnToLiveFromCatchup()
        try await wait { state.livePlayerState.currentSpec?.liveCatchup == nil && state.livePlayerState.isPlaying }
        try #require(state.liveCatchupContext == nil)
        let record: [String: Any] = ["service": "synthetic-loopback", "serverTimeZone": "Asia/Kathmandu",
            "guideProgrammes": 2, "nonArchivedProgrammeDisabled": true, "programmeStart": server.programmeStart,
            "programmeEnd": server.programmeStart + 3_600, "initialCompensationSeconds": 7,
            "requestedSeekProgrammePosition": 3_595, "seekCompensationSeconds": 2,
            "programmeEndStopped": true, "replayAndReturnToLive": true, "oldCallbackRejected": true,
            "realLibmpvDecodedWidth": 640, "isolatedStorageDefaultsAndEPG": true, "realIPTVArchiveVerified": false]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("xtream-native-result.json"))
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(condition())
    }
}
