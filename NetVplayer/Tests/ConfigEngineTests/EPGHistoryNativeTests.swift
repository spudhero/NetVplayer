import AppKit
import Foundation
import SwiftUI
import Testing
import Models
import Storage
import LiveEngine
@testable import PlayerEngine
@testable import NetVplayerApp

@Suite(.serialized) @MainActor
struct EPGHistoryNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_EPG_NATIVE_ROOT"] != nil))
    func dateGuideToRealPlayerPreservesOriginalProgramme() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_EPG_NATIVE_ROOT"]))
        struct Server: Decodable { let baseURL: String }
        let server = try JSONDecoder().decode(Server.self, from: Data(contentsOf: root.appendingPathComponent("server.json")))
        try #require(URL(string: server.baseURL)?.host == "127.0.0.1")
        let suite = "epg-native-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: root.appendingPathComponent("epg-library")),
            userPreferences: UserPreferences(defaults: defaults), providerRuntimeBootstrap: nil)
        state.liveEpgRepository = XMLTVRepository(directory: root.appendingPathComponent("epg-cache"))
        let channel = Channel(name: "Synthetic date guide", number: "1", epg: server.baseURL + "/epg?date={date}", tvgId: "fixture",
            urls: [server.baseURL + "/live.m3u8"], catchup: .init(source: server.baseURL + "/fixture.mp4?utc={utc}&duration={duration}", type: "default", days: 7))
        await state.changeLive(.init(name: "Isolated EPG fixture", url: server.baseURL + "/list", timeZone: "UTC"),
            initialGroups: [.init(name: "Fixture", channels: [channel])])
        let date = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let window = DateInterval(start: date, duration: 6 * 3_600)
        let model = EPGGuideModel(), loader = state.makeLiveEpgLoader()
        model.reset(window: window) { ch, interval, force in await loader.load(channel: ch, window: interval, forceRefresh: force) }
        model.appear(id: "fixture", channel: channel, generation: model.generation)
        try await wait { model.rows["fixture"] != nil }
        let result = try #require(model.rows["fixture"])
        try #require(result.availability == .available && result.data.items.count >= 6)
        let programme = try #require(result.data.items.first)
        try #require(programme.start < window.start && programme.end > window.start)
        try #require(state.liveCatchupAvailability(channel: channel, programme: programme).isAvailable)
        _ = NSApplication.shared
        let panel = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 1080, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.title = "OV87-04 isolated native date guide"
        let guide = NSHostingView(rootView: EPGGuideView(initialDate: date).environmentObject(state))
        panel.contentView = guide; panel.orderFrontRegardless()
        defer { panel.orderOut(nil); model.stop(); state.dismissLivePlayer() }
        try await Task.sleep(for: .seconds(1))
        guide.layoutSubtreeIfNeeded(); guide.displayIfNeeded()
        let bitmap = try #require(guide.bitmapImageRepForCachingDisplay(in: guide.bounds))
        guide.cacheDisplay(in: guide.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("date-guide.png"))
        let engine = MPVPlayerEngine.live
        let video = try #require(MPVOpenGLVideoView(engine: engine, surface: .live))
        panel.contentView = video; engine.attach(to: video, surface: .live)
        defer { engine.stop(); engine.detach(from: video) }
        state.isLivePlayerPresented = true
        await state.playLiveCatchup(channel: channel, programme: programme, revision: state.liveSourceRevision)
        try await wait { state.liveCatchupPhase == .playing && state.liveCatchupPosition > 0.2 }
        let spec = try #require(state.livePlayerState.currentSpec)
        try #require(spec.liveCatchup?.programme == programme)
        try #require(engine.nativePropertyJSON("video-params/w") == "640")
        try #require(spec.url.contains("utc=\(Int(programme.start.timeIntervalSince1970))"))
        let record: [String: Any] = ["service": "synthetic-loopback", "sourceTimeZone": "UTC", "guideRows": result.data.items.count,
            "programmeStart": programme.start.timeIntervalSince1970, "programmeEnd": programme.end.timeIntervalSince1970,
            "originalProgrammePreserved": true, "guideDate": date.timeIntervalSince1970, "realLibmpvDecodedWidth": 640,
            "isolatedStorageAndDefaults": true, "realIPTVArchiveVerified": false]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("epg-native-result.json"))
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(condition())
    }
}
