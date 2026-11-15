import AppKit
import Foundation
import Testing
import Models
import Storage
@testable import PlayerEngine
import ProxyServer

private struct RebufferAcceptanceInput: Decodable {
    let baseURL: String
    let size: Int64
    let output: String
    let repeats: Int
    let measurementSeconds: Double
}

private struct RebufferAcceptanceRecord: Codable {
    let experiment: Bool
    let scope: String
    let completed: Bool
    let measurementSeconds: Double
    let timelineSeconds: Double
    let sourceDurationSeconds: Double
    let quality: PlaybackQualitySnapshot
    let waitTargets: [Double]
    let receivedBytes: Int64
    let decoderDrops: Int?
    let rendererDrops: Int?
    let error: String?
}

@MainActor
private func rebufferAcceptanceWait(seconds: Double, _ predicate: () -> Bool) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return predicate()
}

/// Explicitly shaped loopback only. The same trace is replayed for every case;
/// synthetic network results never stand in for a real NAS or cloud long film.
@MainActor
@Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_REBUFFER_ACCEPTANCE"] != "1"))
func vodRebufferNativeComparisonWhenEnabled() async throws {
    let inputPath = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_REBUFFER_INPUT"])
    let permissions = try FileManager.default.attributesOfItem(atPath: inputPath)[.posixPermissions] as? NSNumber
    try #require((permissions?.intValue ?? 0) & 0o077 == 0)
    let input = try JSONDecoder().decode(RebufferAcceptanceInput.self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
    try #require((1...10).contains(input.repeats) && (20...180).contains(input.measurementSeconds))
    let base = try #require(URL(string: input.baseURL))
    try #require(base.host == "127.0.0.1" && input.size > 0)
    _ = NSApplication.shared
    let server = ProxyServer.shared
    if !server.isRunning { try server.start() }
    var records: [RebufferAcceptanceRecord] = []
    for enabled in [false, true] {
        let suite = "RebufferAcceptance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let audio = PlaybackAudioPreferenceStore(defaults: defaults); audio.setMuted(true)
        let engine = MPVPlayerEngine(videoSurface: .vod, stopResourcePolicy: .fullDestroy, audioPreferences: audio)
        engine.vodRebufferExperimentEnabled = enabled
        let state = PlayerState(); engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.02; window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }

        func spec(_ name: String) throws -> PlaySpec {
            let upstream = base.appendingPathComponent("media/" + name)
            let identity = PlaybackMediaIdentity(source: "controlled-fixture", account: "trace", item: "movie")
            let local = try server.registerSeekableResource(.init(size: input.size, contentType: "video/mp4",
                mediaIdentity: identity) { range in
                var request = URLRequest(url: upstream)
                request.timeoutInterval = 15
                request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
                let (data, response) = try await transport.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 206,
                      data.count == range.count else { throw URLError(.badServerResponse) }
                return data
            })
            // These are disclosed fixture constraints, not production defaults.
            return PlaySpec(url: local, mpvOptions: ["cache": "yes", "cache-secs": "3",
                "demuxer-max-bytes": "8388608", "demuxer-max-back-bytes": "0", "cache-pause-wait": "1"],
                mediaIdentity: identity, title: "Controlled VOD rebuffer")
        }
        let prefix = enabled ? "experiment" : "baseline"
        var failure: String?
        for index in 0..<input.repeats {
            let source = try spec("\(prefix)-repeat-\(index)")
            defer { engine.stop(); server.unregisterSeekableResource(url: source.url) }
            let starts = engine.qualityMetrics.snapshot().startupFirstFrame.count
            await engine.play(spec: source); engine.setMuted(true)
            guard await rebufferAcceptanceWait(seconds: 30, {
                state.errorMessage != nil || engine.qualityMetrics.snapshot().startupFirstFrame.count > starts
            }), state.errorMessage == nil else { failure = "startup-first-frame-timeout"; break }
            for target in [30.0, 2.0] {
                let seeks = engine.qualityMetrics.snapshot().seekFirstFrame.count
                engine.seek(to: Int64(target * 1000))
                guard await rebufferAcceptanceWait(seconds: 30, {
                    state.errorMessage != nil || engine.qualityMetrics.snapshot().seekFirstFrame.count > seeks
                }), state.errorMessage == nil else { failure = "seek-first-frame-timeout"; break }
            }
            if failure != nil { break }
        }
        let source = try spec("\(prefix)-continuous")
        let starts = engine.qualityMetrics.snapshot().startupFirstFrame.count
        await engine.play(spec: source); engine.setMuted(true)
        if !((await rebufferAcceptanceWait(seconds: 30, {
            state.errorMessage != nil || engine.qualityMetrics.snapshot().startupFirstFrame.count > starts
        })) && state.errorMessage == nil) { failure = "continuous-startup-timeout" }
        let began = ProcessInfo.processInfo.systemUptime
        let position = state.position
        var targets: [Double] = []
        while failure == nil, ProcessInfo.processInfo.systemUptime - began < input.measurementSeconds {
            if state.errorMessage != nil || state.hasEnded { failure = "continuous-playback-failed"; break }
            if let target = engine.nativePropertyJSON("options/cache-pause-wait").flatMap(Double.init), targets.last != target {
                targets.append(target)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let snapshot = await server.remoteStreamBufferSnapshot(forLocalURL: source.url)
        let result = RebufferAcceptanceRecord(experiment: enabled, scope: "controlled-loopback-http",
            completed: failure == nil, measurementSeconds: ProcessInfo.processInfo.systemUptime - began,
            timelineSeconds: state.position - position, sourceDurationSeconds: state.duration,
            quality: engine.qualityMetrics.snapshot(), waitTargets: targets,
            receivedBytes: snapshot?.receivedBytes ?? 0,
            decoderDrops: engine.nativePropertyJSON("decoder-frame-drop-count").flatMap(Int.init),
            rendererDrops: engine.nativePropertyJSON("frame-drop-count").flatMap(Int.init), error: failure)
        records.append(result)
        engine.stop(); server.unregisterSeekableResource(url: source.url)
        let output = URL(fileURLWithPath: input.output)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if records.count == 1 {
            try encoder.encode(records).write(to: output.deletingPathExtension().appendingPathExtension("baseline.json"), options: .withoutOverwriting)
        } else { try encoder.encode(records).write(to: output, options: .withoutOverwriting) }
        #expect(failure == nil, "Controlled rebuffer comparison failed: \(prefix)")
    }
}
