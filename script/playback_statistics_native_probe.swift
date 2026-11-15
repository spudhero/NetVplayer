import AppKit
import SwiftUI
import Foundation
import Storage
import Models
@testable import PlayerEngine
@testable import NetVplayerApp

@main
struct StatisticsNativeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = StatisticsNativeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        _ = delegate
    }
}

@MainActor
final class StatisticsNativeDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var engine: MPVPlayerEngine?
    var output = URL(fileURLWithPath: CommandLine.arguments[1])
    var batches: [(UUID, [String])] = []
    var checks: [String: Bool] = [:]
    var fields: [String: String] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do { try await verify(); finish(status: "passed") }
            catch { finish(status: "failed", error: String(describing: error)) }
        }
    }
    func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw NSError(domain: "StatisticsNativeProbe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: name]) }
        checks[name] = true
    }
    func wait(_ predicate: () -> Bool, seconds: Double = 12) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else { throw NSError(domain: "StatisticsNativeProbe", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "wait timed out"]) }
    }
    func window(_ title: String, size: NSSize, content: NSView, x: Double) -> NSWindow {
        let w = NSWindow(contentRect: .init(x: x, y: 180, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title; w.isReleasedWhenClosed = false; w.contentView = content
        windows.append(w); w.makeKeyAndOrderFront(nil)
        return w
    }
    func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "capture", code: 1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
    func verify() async throws {
        let suite = "com.netvplayer.statistics-native." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let audio = PlaybackAudioPreferenceStore(defaults: defaults); audio.setMuted(true)
        let e = MPVPlayerEngine(videoSurface: .vod, audioPreferences: audio,
            audioOutputPreferences: .init(defaults: defaults), dialoguePreferences: .init(defaults: defaults),
            colorPreferences: .init(defaults: defaults))
        engine = e
        let state = PlayerState(); e.playerState = state
        e.statisticsSamplingObserver = { [weak self] owner, names in self?.batches.append((owner, names)) }
        guard let video = MPVOpenGLVideoView(engine: e, surface: .vod) else { throw NSError(domain: "video", code: 1) }
        _ = window("OV87-07 isolated engine", size: .init(width: 640, height: 360), content: video, x: 80)
        let keyA = PlaybackSummaryIdentity(scope: "fixture-r1-accountA", site: "site", vod: "same-title", line: "line", episode: "fileA")
        let keyB = PlaybackSummaryIdentity(scope: "fixture-r1-accountA", site: "site", vod: "same-title", line: "line", episode: "fileB")
        let file = output.appendingPathComponent("fixture.mp4")
        var spec = PlaySpec(url: file.absoluteString, title: "Same title")
        spec.userOpenedLocalFile = file; spec.playbackSummaryIdentity = keyA
        await e.play(spec: spec)
        try await wait { state.position > 0.3 && state.playbackDiagnostics != nil && !self.batches.isEmpty }
        try require(state.playbackStatistics == nil && !state.statisticsVisibility.isVisible, "hidden panel has no presentation sample")
        try require(!batches.last!.1.contains("estimated-vf-fps"), "hidden batch excludes presentation properties")
        try require(batches.last!.1.contains("audio-out-params") && batches.last!.1.contains("video-dec-params"), "hidden batch retains audio and video control properties")
        try require(state.playbackSummaries.summary(for: keyA)?.width == 640, "static specs arrive without panel")
        let localBytes = Int64((try Data(contentsOf: file)).count)
        try require(state.playbackDiagnostics?.localInputBytes == localBytes, "user opened local input byte count confirmed")
        let panelView = NSHostingView(rootView: ScrollView {
            PlaybackInformationView(playerState: state).padding(18)
        }.frame(width: 390, height: 680)
            .environment(\.appThemePalette, AppThemeCatalog.palette(for: .legacyDeepSpace))
            .preferredColorScheme(.dark).background(Color.black))
        let panel = window("OV87-07 Playback Information", size: .init(width: 390, height: 680), content: panelView, x: 730)
        try await wait { state.statisticsVisibility.isVisible && state.playbackStatistics?.estimatedOutputFPS != nil }
        for name in ["container-fps", "estimated-vf-fps", "video-bitrate", "audio-bitrate", "cache-speed", "file-size", "current-ao", "audio-out-params", "mpv-version"] {
            fields[name] = e.nativePropertyJSON(name) ?? "unknown"
        }
        try require(state.playbackDiagnostics?.video.framesPerSecond == 24, "nominal frame rate from actual engine")
        try require(abs((state.playbackStatistics?.estimatedOutputFPS ?? 0) - 24) < 0.1, "estimated frame rate from actual engine")
        try require((state.playbackStatistics?.videoBitsPerSecond ?? 0) > 0, "packet bitrate from actual engine")
        try capture(panelView, name: "native-information.png")
        let revision = state.playbackSummaries.revision
        e.pause(); try await wait { !state.isPlaying }
        try await Task.sleep(for: .milliseconds(250))
        try capture(panelView, name: "native-paused.png")
        e.seek(to: 5000); e.resume()
        try await wait { state.position >= 5 && !state.isSeeking }
        try require(state.playbackSummaries.revision == revision, "pause and seek do not publish dynamic data to static store")
        panel.miniaturize(nil)
        try await wait { !state.statisticsVisibility.isVisible }
        try await Task.sleep(for: .milliseconds(1300))
        try require(!batches.last!.1.contains("estimated-vf-fps"), "minimized panel stops presentation queries")
        panel.deminiaturize(nil); panel.makeKeyAndOrderFront(nil)
        try await wait { state.statisticsVisibility.isVisible && state.playbackStatistics != nil }
        panel.orderOut(nil)
        try await wait { !state.statisticsVisibility.isVisible }
        let hiddenCount = batches.count
        try await wait { self.batches.count > hiddenCount }
        try require(!batches.last!.1.contains("estimated-vf-fps"), "ordered out panel stops presentation queries")
        try require(batches.last!.1.contains("current-ao"), "audio control continues while panel hidden")
        panel.makeKeyAndOrderFront(nil)
        try await wait { state.statisticsVisibility.isVisible }
        panel.close()
        try await wait { !state.statisticsVisibility.isVisible && state.playbackStatistics == nil }
        var next = PlaySpec(url: output.appendingPathComponent("other.mp4").absoluteString, title: "Same title")
        next.playbackSummaryIdentity = keyB
        await e.play(spec: next)
        try await wait { state.playbackSummaries.summary(for: keyB)?.width == 854 }
        try require(state.playbackSummaries.summary(for: keyA)?.width == 640, "same title distinct media preserve distinct summaries")
        let base = CommandLine.arguments[2]
        var remote = PlaySpec(url: base + "/fixture.mp4", contentLength: 12345, title: "HTTP resource")
        await e.play(spec: remote)
        try await wait { state.position > 0.3 && state.playbackDiagnostics != nil }
        try require(state.playbackDiagnostics?.localInputBytes == nil, "HTTP length never presented as complete file size")
        remote.url = base + "/live.m3u8"; remote.metadata["playback.kind"] = "live"
        await e.play(spec: remote)
        try await wait { state.position > 0.3 && state.playbackDiagnostics != nil }
        try require(state.playbackDiagnostics?.localInputBytes == nil, "live HLS segment size remains unknown")
        e.stop()
        try await wait { state.currentSpec == nil && state.playbackDiagnostics == nil }
        let stoppedCount = batches.count
        try await Task.sleep(for: .milliseconds(1300))
        try require(batches.count == stoppedCount, "closed player stops all diagnostics queries")
        let summaryView = NSHostingView(rootView: PlaybackSummaryView(store: state.playbackSummaries, identity: keyA,
            episodeName: "Same title / file A").padding().frame(width: 390, height: 160)
            .environment(\.appThemePalette, AppThemeCatalog.palette(for: .legacyDeepSpace))
            .preferredColorScheme(.dark).background(Color.black))
        _ = window("OV87-07 session summary", size: .init(width: 390, height: 160), content: summaryView, x: 730)
        try await Task.sleep(for: .milliseconds(300))
        try capture(summaryView, name: "native-summary.png")
        try require(state.playbackSummaries.summary(for: keyA) != nil, "static summary remains available after player closes")
    }
    func finish(status: String, error: String? = nil) {
        engine?.stop()
        let record: [String: Any] = ["status": status, "error": error as Any? ?? NSNull(), "checks": checks,
            "engineFields": fields, "batches": batches.map { ["mediaID": $0.0.uuidString, "properties": $0.1] },
            "backingScale": windows.first?.backingScaleFactor ?? 0,
            "scope": "isolated AppKit app, synthetic local/loopback media, real product views and engine; no AppState"]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-validation.json"))
        windows.forEach { $0.orderOut(nil) }
        NSApp.terminate(nil)
    }
}
