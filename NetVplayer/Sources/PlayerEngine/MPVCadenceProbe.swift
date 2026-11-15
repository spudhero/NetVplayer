#if DEBUG
import AppKit
import CoreVideo
import Foundation
import Models
import Storage

/// Explicit development instrumentation; no file I/O or property query in draw.
final class MPVCadenceRecorder: @unchecked Sendable {
    struct Frame: Codable { let uptime: Double; let flags: Int64 }
    struct Tick: Codable {
        let hostSeconds: Double
        let videoTime: Int64
        let videoTimeScale: Int32
        let refreshPeriod: Int64
        let flags: UInt64
    }
    struct Snapshot: Codable {
        let frames: [Frame]
        let ticks: [Tick]
        let overflow: Int
    }
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var ticks: [Tick] = []
    private var overflow = 0
    static let capacity = 16_384

    func record(flags: Int64, now: Double) {
        lock.withLock {
            if frames.count < Self.capacity { frames.append(Frame(uptime: now, flags: flags)) }
            else { overflow += 1 }
        }
    }
    func tick(_ timestamp: CVTimeStamp) {
        lock.withLock {
            if ticks.count < Self.capacity {
                ticks.append(Tick(hostSeconds: Double(timestamp.hostTime) / CVGetHostClockFrequency(),
                    videoTime: timestamp.videoTime, videoTimeScale: timestamp.videoTimeScale,
                    refreshPeriod: timestamp.videoRefreshPeriod, flags: timestamp.flags))
            } else { overflow += 1 }
        }
    }
    func snapshot() -> Snapshot { lock.withLock { Snapshot(frames: frames, ticks: ticks, overflow: overflow) } }
}

@MainActor
public enum MPVCadenceProbe {
    private struct Configuration: Decodable { let outputDirectory: String; let cases: [Case] }
    private struct Case: Codable {
        let id: String
        let url: String
        let warmupSeconds: Double
        let measurementSeconds: Double
    }
    private struct Sample: Codable {
        let reading: MPVPerformanceReading
        let frames: MPVPerformanceFrames
    }
    private struct Mode: Codable, Equatable {
        let widthPoints: Int
        let heightPoints: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let configuredRefreshHz: Double
        init?(_ id: CGDirectDisplayID) {
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            widthPoints = mode.width; heightPoints = mode.height
            pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
            configuredRefreshHz = mode.refreshRate
        }
    }
    private struct Report: Encodable {
        let schema = 1
        let id: String
        let scope = "Host flush-completion timestamps and CVDisplayLink output clock; not compositor scanout, physical pixels, blackout duration or QMS"
        let modeWrites = 0
        let before: Mode?
        var after: Mode?
        var actualDisplayLinkPeriodSeconds: Double?
        var startUptime: Double?
        var endUptime: Double?
        var completed = false
        var error: String?
        var samples: [Sample] = []
        var trace: MPVCadenceRecorder.Snapshot?
    }
    private struct Failure: Error { let message: String }

    public static func scheduleIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--av11-cadence-probe"), args.count > i + 1 else { return false }
        Task { @MainActor in
            do { try await run(configuration: URL(fileURLWithPath: args[i + 1])) }
            catch { print("AV11 cadence probe failed: \(error)") }
            NSApp.terminate(nil)
        }
        return true
    }

    public static func run(configuration: URL) async throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configuration))
        guard !config.cases.isEmpty, config.cases.count <= 12,
              Set(config.cases.map(\.id)).count == config.cases.count else { throw Failure(message: "Invalid cases") }
        for item in config.cases {
            guard item.id.range(of: #"^[a-z0-9][a-z0-9_-]{0,80}$"#, options: .regularExpression) != nil,
                  item.warmupSeconds.isFinite, (0...30).contains(item.warmupSeconds),
                  item.measurementSeconds.isFinite, item.measurementSeconds > 0, item.measurementSeconds <= 120,
                  let url = URL(string: item.url), url.isFileURL else { throw Failure(message: "Invalid local cadence case") }
        }
        let output = URL(fileURLWithPath: config.outputDirectory, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path), let screen = NSScreen.main,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { throw Failure(message: "Use a new output directory and an attached display") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for item in config.cases {
            let report = await runCase(item, screen: screen, displayID: id)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(report).write(to: output.appendingPathComponent(item.id + ".json"), options: .withoutOverwriting)
            print("AV11 \(item.id): collected=\(report.completed); offline validation required")
        }
    }

    private static func runCase(_ item: Case, screen: NSScreen, displayID: CGDirectDisplayID) async -> Report {
        var report = Report(id: item.id, before: Mode(displayID))
        let suite = "NetVplayer.AV11." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = MPVPlayerEngine(videoSurface: .vod,
            audioPreferences: PlaybackAudioPreferenceStore(defaults: defaults),
            audioOutputPreferences: PlaybackAudioOutputPreferenceStore(defaults: defaults),
            dialoguePreferences: PlaybackDialoguePreferenceStore(defaults: defaults),
            colorPreferences: PlaybackColorPreferenceStore(defaults: defaults))
        let state = PlayerState(); engine.playerState = state
        let recorder = MPVCadenceRecorder()
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &link) == kCVReturnSuccess, let link else {
            report.error = "Display clock unavailable"; return report
        }
        let callbackStatus = CVDisplayLinkSetOutputCallback(link, { _, _, outputTime, _, _, context in
            guard let context else { return kCVReturnError }
            Unmanaged<MPVCadenceRecorder>.fromOpaque(context).takeUnretainedValue().tick(outputTime.pointee)
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(recorder).toOpaque())
        guard callbackStatus == kCVReturnSuccess else { report.error = "Display callback unavailable"; return report }
        let window = NSWindow(contentRect: NSRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80,
            width: 960, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "AV-11 · " + item.id
        guard let view = MPVOpenGLVideoView(engine: engine, surface: .vod) else { report.error = "OpenGL unavailable"; return report }
        window.contentView = view; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        engine.attach(to: view, surface: .vod)
        var latest: MPVPerformanceReading?
        engine.performanceDiagnosticsHandler = { info, properties in
            latest = MPVPerformanceReading(info: info, properties: properties, now: ProcessInfo.processInfo.systemUptime)
        }
        engine.cadenceRecorder = recorder
        do {
            guard CVDisplayLinkStart(link) == kCVReturnSuccess else { throw Failure(message: "Display clock start failed") }
            await engine.play(spec: PlaySpec(url: item.url))
            engine.setVolume(0); engine.setMuted(true)
            let deadline = ProcessInfo.processInfo.systemUptime + item.warmupSeconds + item.measurementSeconds + 20
            var prior = -1.0
            while ProcessInfo.processInfo.systemUptime < deadline {
                if state.errorMessage != nil { throw Failure(message: "Playback error") }
                if let reading = latest, reading.uptime != prior {
                    prior = reading.uptime
                    let frames = engine.performanceFrameSnapshot
                    report.samples.append(Sample(reading: reading, frames: frames))
                    if let first = frames.firstFrameUptime, reading.uptime - first >= item.warmupSeconds,
                       report.startUptime == nil { report.startUptime = reading.uptime }
                    if let start = report.startUptime, reading.uptime - start >= item.measurementSeconds {
                        report.endUptime = reading.uptime; report.completed = true; break
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            if !report.completed { throw Failure(message: "Required continuous duration not collected") }
        } catch { report.error = String(describing: error) }
        report.actualDisplayLinkPeriodSeconds = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
        CVDisplayLinkStop(link)
        engine.cadenceRecorder = nil; engine.performanceDiagnosticsHandler = nil
        report.trace = recorder.snapshot(); report.after = Mode(displayID)
        engine.stop(); view.deactivatePlaybackSurface(); window.orderOut(nil)
        await engine.detachAndReleaseOpenGLResources(from: view)
        return report
    }
}
#endif
