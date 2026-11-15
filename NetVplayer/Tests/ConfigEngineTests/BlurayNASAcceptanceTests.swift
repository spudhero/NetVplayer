import AppKit
import CryptoKit
import Foundation
import Testing
import Models
import Storage
import FileServiceEngine
@testable import PlayerEngine
import ProxyServer

/// Opt-in only: existing user credentials stay in their store. ISO candidates
/// are not assumed to be Blu-ray discs. No URLs, paths or credentials in reports.
@MainActor
@Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_BLURAY_NAS_CANDIDATES"] == nil))
func configuredNASBlurayCandidatesWhenEnabled() async throws {
    let env = ProcessInfo.processInfo.environment
    let input = URL(fileURLWithPath: try #require(env["NETVPLAYER_BLURAY_NAS_CANDIDATES"]))
    let output = URL(fileURLWithPath: try #require(env["NETVPLAYER_BLURAY_NAS_REPORT"]))
    let candidates = try JSONDecoder().decode([FileResourceReference].self, from: Data(contentsOf: input))
    let defaults = try #require(UserDefaults(suiteName: UserPreferences.stableBundleIdentifier))
    let store = FileServiceStore(preferences: UserPreferences(defaults: defaults, credentialStore: LocalCredentialStore()))
    let runtime = FileServiceRuntime(store: store)
    _ = NSApplication.shared
    let server = ProxyServer.shared; try server.start(); defer { server.stop() }
    var reports: [[String: Any]] = []
    for reference in candidates.prefix(4) {
        let client = try await runtime.client(for: reference.serviceID)
        let reader = BlurayDiscReader(reference: reference, client: client)
        var record: [String: Any] = ["scope": "configured-real-SMB-ISO", "passed": false,
            "pathSHA256": SHA256.hash(data: Data(reference.path.utf8)).map { String(format: "%02x", $0) }.joined()]
        let began = Date()
        do {
            let catalog = try await reader.scan()
            record["scanSeconds"] = Date().timeIntervalSince(began)
            let playlist = try #require(catalog.suggestedPlaylist)
            let disc = try await reader.playback(selection: .init(reference: reference, playlist: playlist))
            defer { disc.segmentURLs.forEach { server.unregisterSeekableResource(url: $0) } }
            record["playlistCount"] = catalog.titles.count; record["playlist"] = playlist
            record["clipCount"] = disc.title.clips.count; record["chapterCount"] = disc.title.chapters.count
            record["duration"] = disc.title.duration
            let prefsID = "bluray-NAS-\(UUID())"
            let prefs = try #require(UserDefaults(suiteName: prefsID))
            defer { prefs.removePersistentDomain(forName: prefsID) }
            let audio = PlaybackAudioPreferenceStore(defaults: prefs); audio.setMuted(true)
            let engine = MPVPlayerEngine(videoSurface: .vod, stopResourcePolicy: .fullDestroy, audioPreferences: audio)
            engine.performanceDiagnosticsHandler = { _, _ in }
            let state = PlayerState(); engine.playerState = state
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0.01
            let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
            view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
            engine.attach(to: view, surface: .vod)
            defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
            var spec = PlaySpec(url: disc.edl(), disc: disc)
            spec.mpvOptions["cache-secs"] = "30"
            await engine.play(spec: spec)
            try #require(await nasDiscWait { state.errorMessage != nil || (!state.isMediaLoading && state.position > 0.2) })
            try #require(state.errorMessage == nil)
            #expect(engine.performanceFrameSnapshot.freshFrames > 0)
            let target = min(max(2, disc.title.duration / 2), max(2, disc.title.duration - 30))
            engine.seek(to: Int64(target * 1000))
            try #require(await nasDiscWait { state.errorMessage != nil || (!state.isSeeking && state.position >= target && state.position < target + 3) })
            try #require(state.errorMessage == nil)
            record["seekTarget"] = target; record["seekPosition"] = state.position
            let start = state.position, clock = Date(), frames = engine.performanceFrameSnapshot.freshFrames
            try await Task.sleep(for: .seconds(15))
            let elapsed = Date().timeIntervalSince(clock), advanced = state.position - start
            record["elapsed"] = elapsed; record["advanced"] = advanced
            record["freshFrames"] = engine.performanceFrameSnapshot.freshFrames - frames
            record["passed"] = state.errorMessage == nil && advanced >= elapsed * 0.98
            record["status"] = "short-native-playback-observation"
            #expect(state.errorMessage == nil && advanced >= elapsed * 0.98)
            engine.pause()
            let preview = await PlayerChapterThumbnailDecoder.shared.imageData(spec: state.currentSpec ?? spec, seconds: target) != nil
            record["previewDecoded"] = preview
            record["passed"] = (record["passed"] as? Bool == true) && preview
            #expect(preview)
        } catch let error as DiscReadError {
            switch error {
            case .invalidDisc: record["status"] = "candidate-is-not-a-readable-bluray"
            case .protectedDisc: record["status"] = "protected-disc-unsupported"
            case .runtime: record["status"] = "runtime-unavailable"
            default: record["status"] = "disc-read-failed"
            }
        } catch { record["status"] = "native-check-failed" }
        record["totalSeconds"] = Date().timeIntervalSince(began)
        reports.append(record)
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
    for id in Set(candidates.map(\.serviceID)) { await runtime.invalidate(serviceID: id) }
}

@MainActor private func nasDiscWait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<600 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
    return false
}
