import AppKit
import Foundation
import SwiftUI
import Models
import Storage
import Testing
@testable import PlayerEngine
@testable import NetVplayerApp

/// Uses a real local HTTP service and the shipped libmpv, never a protocol stub.
@Suite(.serialized) @MainActor
struct LiveCatchupNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_CATCHUP_NATIVE_ROOT"] != nil))
    func loopbackArchiveSeeksStopsReplaysAndReturnsToLive() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_CATCHUP_NATIVE_ROOT"]))
        let server = try JSONDecoder().decode(Server.self, from: Data(contentsOf: root.appendingPathComponent("server.json")))
        try #require(URL(string: server.baseURL)?.host == "127.0.0.1")
        let suite = "catchup-native-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: root.appendingPathComponent("library")),
            userPreferences: UserPreferences(defaults: defaults), providerRuntimeBootstrap: nil)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OV87-03 local catch-up acceptance"
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        let engine = MPVPlayerEngine.live
        let video = try #require(MPVOpenGLVideoView(engine: engine, surface: .live))
        video.frame = content.bounds
        video.autoresizingMask = [.width, .height]
        content.addSubview(video)
        let host = NSHostingView(rootView: NativeCatchupPanel(state: state, player: state.livePlayerState))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        window.orderFrontRegardless()
        engine.attach(to: video, surface: .live)
        defer { state.dismissLivePlayer(); engine.stop(); engine.detach(from: video); window.orderOut(nil) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let programme = EpgItem(title: "Local synthetic programme", start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(-1_800))
        let channel = Channel(name: "Loopback HLS", number: "1", urls: [server.baseURL + "/live.m3u8"],
            catchup: .init(source: "?utc={utc}&duration={duration}", type: "append", days: 1))
        await state.changeLive(.init(name: "Local fixture", url: server.baseURL + "/list"),
            initialGroups: [.init(name: "Fixture", channels: [channel])])
        state.presentLivePlayer()
        await state.playLiveCatchup(channel: channel, programme: programme)
        print("[CATCHUP_NATIVE_STATE] phase=\(state.liveCatchupPhase) status=\(engine.status) error=\(state.livePlayerState.errorMessage ?? "none")")
        try await wait { state.liveCatchupPhase == .playing && state.liveCatchupPosition > 0.2 }
        let first = try #require(state.livePlayerState.currentSpec?.liveCatchup)
        let firstSeekable = state.livePlayerState.isSeekable
        let firstDuration = state.livePlayerState.duration
        let videoWidth = MPVPlayerEngine.live.nativePropertyJSON("video-params/w")
        try #require(videoWidth == "640")
        let action = await state.seekLiveCatchup(to: 1_795)
        try #require(action == .request(programmePosition: 1_795))
        try await wait { state.liveCatchupPhase == .playing && state.liveCatchupPosition > 1_795.2 }
        let second = try #require(state.livePlayerState.currentSpec?.liveCatchup)
        try #require(second.programme == first.programme && second.requestID != first.requestID)
        try await capture(host, root: root, name: "native-request-seek.png")
        try await wait { state.liveCatchupPhase == .ended && !state.livePlayerState.isPlaying }
        try #require(state.liveCatchupPosition == 1_800)
        await state.retryLiveCatchup(fromBeginning: true)
        try await wait { state.liveCatchupPhase == .playing && state.liveCatchupPosition > 0.2 && state.liveCatchupPosition < 10 }
        await state.returnToLiveFromCatchup()
        try await wait { state.liveCatchupContext == nil && state.livePlayerState.currentSpec?.liveCatchup == nil && state.livePlayerState.isPlaying }
        // A fixed archive requires the demuxer's real seekable flag; it is a distinct path.
        state.dismissLivePlayer()
        var fixed = channel
        fixed.name = "Loopback native seek"
        fixed.catchup = .init(source: server.baseURL + "/fixture.mp4", type: "default", days: 1)
        await state.changeLive(.init(name: "Fixed fixture", url: server.baseURL + "/list"),
            initialGroups: [.init(name: "Fixture", channels: [fixed])])
        state.presentLivePlayer()
        let short = EpgItem(title: "Ten-second programme in a longer file", start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(-3_590))
        await state.playLiveCatchup(channel: fixed, programme: short)
        try await wait { state.liveCatchupPhase == .playing && state.livePlayerState.isSeekable == true && state.livePlayerState.duration > 20 }
        let nativeID = state.liveCatchupContext?.requestID
        try #require(await state.seekLiveCatchup(to: 6) == .native(mediaPosition: 6))
        try await wait { state.liveCatchupPosition >= 6 && !state.livePlayerState.isSeeking }
        try #require(state.liveCatchupContext?.requestID == nativeID)
        try await capture(host, root: root, name: "native-fixed-seek.png")
        try await wait { state.liveCatchupPhase == .ended }
        try #require(state.liveCatchupPosition == 10)
        let record: [String: Any] = ["service": "synthetic-loopback", "kernel": "real-libmpv", "videoWidth": videoWidth ?? "unknown",
            "hlsSeekable": firstSeekable as Any? ?? NSNull(), "hlsMediaDuration": firstDuration,
            "requestSeek": true, "programmeTimesPreserved": first.programme == second.programme,
            "requestIdentityRotated": first.requestID != second.requestID, "programmeEndStops": true,
            "replay": true, "returnToLive": true, "nativeSeek": true, "nativeEndInLongerFile": true,
            "realRemoteArchiveVerified": false]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("native-result.json"))
    }

    private struct Server: Decodable { let baseURL: String }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(condition(), "Local native catch-up condition timed out")
    }
    private func capture(_ host: NSView, root: URL, name: String) async throws {
        // AppKit's slider thumb animates after the binding changes; capture its settled layout.
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name))
    }
}

private struct NativeCatchupPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var player: PlayerState
    var body: some View {
        VStack {
            Spacer()
            if let context = state.liveCatchupContext {
                LiveCatchupControls(context: context, phase: state.liveCatchupPhase,
                    position: state.liveCatchupPosition, canSeek: state.liveCatchupCanSeek,
                    message: state.liveError ?? state.liveCatchupSeekMessage,
                    onSeek: { value in Task { await state.seekLiveCatchup(to: value) } },
                    onRetry: { Task { await state.retryLiveCatchup() } },
                    onReplay: { Task { await state.retryLiveCatchup(fromBeginning: true) } },
                    onReturnToLive: { Task { await state.returnToLiveFromCatchup() } })
            }
        }.padding(22)
    }
}
