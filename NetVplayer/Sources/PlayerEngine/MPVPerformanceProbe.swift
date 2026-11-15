#if DEBUG
import AppKit
import CoreFoundation
import Darwin
import Foundation
import IOKit
import Models
import Storage

// Opt-in acceptance instrumentation. The shipping playback path does not
// create a recorder, perform extra property reads, or retain frame history.
struct MPVPerformanceFrames: Codable, Sendable {
    var loadUptime: Double = 0
    var firstFrameUptime: Double?
    var lastFrameUptime: Double?
    var freshFrames = 0
    var redraws = 0
    var unavailable = 0
    var width = 0
    var height = 0
    var cachePauseCount = 0
    var cachePauseSeconds = 0.0
    private var cachePauseStart: Double?
    var pauseRequests = 0
    var seekRequests = 0
    var speedChanges = 0

    init(loadUptime: Double = 0) { self.loadUptime = loadUptime }

    mutating func cache(paused: Bool, now: Double) {
        if paused, cachePauseStart == nil {
            cachePauseStart = now; cachePauseCount += 1
        } else if !paused, let start = cachePauseStart {
            cachePauseSeconds += max(0, now - start); cachePauseStart = nil
        }
    }

    func snapshot(now: Double) -> Self {
        var copy = self
        if let start = cachePauseStart { copy.cachePauseSeconds += max(0, now - start) }
        return copy
    }

    mutating func record(flags: Int64, width: Int, height: Int, now: Double) {
        self.width = width; self.height = height
        guard flags >= 0 else { unavailable += 1; return }
        guard flags & 1 != 0 else { return }
        if flags & 6 != 0 { redraws += 1; return }
        freshFrames += 1
        if firstFrameUptime == nil { firstFrameUptime = now }
        lastFrameUptime = now
    }
}

struct MPVPerformanceReading: Codable, Sendable {
    static let properties = ["time-pos", "pause", "paused-for-cache", "speed",
                             "demuxer-cache-duration", "video-bitrate", "vo-passes"]
    let uptime: Double
    let position: Double?
    let paused: Bool?
    let pausedForCache: Bool?
    let speed: Double?
    let cacheSeconds: Double?
    let videoBitsPerSecond: Double?
    /// Sum of libmpv fresh-pass moving averages, not total device utilization.
    let gpuPassAverageMilliseconds: Double?
    let diagnostics: PlaybackDiagnostics

    init(info: PlaybackDiagnostics, properties: [String: Data], now: Double) {
        func value(_ key: String) -> Any? {
            guard let data = properties[key] else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
        func number(_ raw: Any?) -> Double? {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func flag(_ key: String) -> Bool? {
            guard let n = value(key) as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        }
        uptime = now
        position = number(value("time-pos"))
        paused = flag("pause"); pausedForCache = flag("paused-for-cache")
        speed = number(value("speed")); cacheSeconds = number(value("demuxer-cache-duration"))
        videoBitsPerSecond = number(value("video-bitrate"))
        let passes = (value("vo-passes") as? [String: Any])?["fresh"] as? [[String: Any]]
        let times = passes?.compactMap { number($0["avg"]) }.filter { $0 >= 0 }
        if let passes, !passes.isEmpty, let times, times.count == passes.count, times.contains(where: { $0 > 0 }) {
            gpuPassAverageMilliseconds = times.reduce(0, +) / 1e6
        } else {
            gpuPassAverageMilliseconds = nil
        }
        var redacted = info
        redacted.display.name = nil
        redacted.audio.deviceName = nil
        redacted.audio.systemDefaultDeviceName = nil
        diagnostics = redacted
    }
}

private struct MPVPerformanceResources: Codable, Sendable {
    let uptime: Double
    let cpuSeconds: Double
    let residentBytes: UInt64?
    let footprintBytes: UInt64?
    let billedEnergyCounter: UInt64?
    let systemGPUDeviceUtilizationPercent: Double?
    let thermalState: Int

    static func read() -> Self {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return Self(uptime: ProcessInfo.processInfo.systemUptime,
                    cpuSeconds: Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6,
                    residentBytes: result == 0 ? info.ri_resident_size : nil,
                    footprintBytes: result == 0 ? info.ri_phys_footprint : nil,
                    billedEnergyCounter: result == 0 && info.ri_billed_energy > 0 ? info.ri_billed_energy : nil,
                    systemGPUDeviceUtilizationPercent: gpuUtilization(),
                    thermalState: ProcessInfo.processInfo.thermalState.rawValue)
    }

    private static func gpuUtilization() -> Double? {
        // Optional, driver-specific whole-system gauge. Never equate it with
        // per-process GPU time or calibrated power, and reject multi-GPU ambiguity.
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var services = 0
        var result: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            services += 1
            defer { IOObjectRelease(service) }
            let raw = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            if let facts = raw as? [String: Any], let value = facts["Device Utilization %"] as? NSNumber,
               CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
               (0...100).contains(value.doubleValue) { result = value.doubleValue }
        }
        return services == 1 ? result : nil
    }
}

private actor MPVPerformanceWriter {
    let file: FileHandle
    init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteFileExists)
        }
        file = try FileHandle(forWritingTo: url)
    }
    func append<T: Encodable & Sendable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 65_536 else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try file.write(contentsOf: data + Data([10]))
    }
    func close() throws { try file.synchronize(); try file.close() }
}

@MainActor
public enum MPVPerformanceProbe {
    private struct Configuration: Decodable {
        let outputDirectory: String
        let cases: [Case]
    }
    private struct Case: Codable, Sendable {
        let id: String
        let url: String
        let warmupSeconds: Double
        let measurementSeconds: Double
        let purpose: String
        let software: Bool?
        let renderAt4K: Bool?
        let hdrPresentation: Bool?
        /// Optional explicit policy for display-mode acceptance runs. Existing
        /// performance configurations retain their SDR/EDR selection semantics.
        let videoOutput: PlaybackVideoOutputMode?
    }
    private struct Record: Codable, Sendable {
        let phase: String
        let reading: MPVPerformanceReading
        let render: MPVPerformanceFrames
        let resources: MPVPerformanceResources
        let hdrSurface: [String: Double]?
    }
    private struct CaseResult: Codable {
        let id: String
        let purpose: String
        let warmupSeconds: Double
        let measurementSeconds: Double
        var completed = false
        var error: String?
        var diagnostics: PlaybackDiagnostics?
        var frames: MPVPerformanceFrames?
        var viewport: [String: [Double]]?
        var hdrPresentationRequested: Bool?
        var videoOutputRequested: PlaybackVideoOutputMode?
    }
    private struct Failure: Error { let message: String }

    public static func scheduleIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--av05-performance-probe"), args.count > i + 1 else { return false }
        let config = URL(fileURLWithPath: args[i + 1])
        Task { @MainActor in
            do { try await run(configuration: config) }
            catch { print("AV05 performance probe failed: \(error)") }
            // AppKit waits in a nested run loop for the delegate's asynchronous
            // cleanup reply. Quit outside both the MainActor task and the main
            // dispatch queue, so that loop can service the cleanup task.
            RunLoop.main.perform {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
        return true
    }

    public static func run(configuration: URL) async throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configuration))
        guard !config.cases.isEmpty, config.cases.count <= 80,
              Set(config.cases.map(\.id)).count == config.cases.count else { throw Failure(message: "Invalid case count/duplicate IDs") }
        let output = URL(fileURLWithPath: config.outputDirectory, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.appendingPathComponent("environment.json").path) else {
            throw Failure(message: "Use a new output directory to preserve prior evidence")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let screen = NSScreen.main else { throw Failure(message: "No display") }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let mode = displayID.flatMap { CGDisplayCopyDisplayMode($0) }
        let environment: [String: Any] = ["schema": 1, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "pid": getpid(), "screenPixels": [mode?.pixelWidth ?? 0, mode?.pixelHeight ?? 0],
            "screenPoints": [screen.frame.width, screen.frame.height],
            "screenBackingScale": screen.backingScaleFactor,
            "displayModeSize": [mode?.width ?? 0, mode?.height ?? 0],
            "displayRefreshHz": mode?.refreshRate ?? 0,
            "edrHeadroom": screen.maximumExtendedDynamicRangeColorComponentValue,
            "audioAcceptance": "CoreAudio clock remains active; probe audio is muted only in its temporary preference domain; no acoustic latency claim",
            "energyCounterMeaning": "Darwin ri_billed_energy raw accounting units; not watts or calibrated joules",
            "gpuMeaning": "libmpv fresh-pass timer averages when available; not whole-device utilization",
            "systemGPUMeaning": "Optional AGXAccelerator PerformanceStatistics Device Utilization %; entire system, driver-specific, not app-attributed",
            "scope": "Ordinary engine with explicit per-case SDR or opt-in EDR policy in a DEBUG native acceptance window; product HUD is tested separately"]
        try JSONSerialization.data(withJSONObject: environment, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("environment.json"), options: .atomic)
        var results: [CaseResult] = []
        for item in config.cases {
            guard item.id.range(of: #"^[a-z0-9][a-z0-9-]{0,95}$"#, options: .regularExpression) != nil,
                  item.measurementSeconds.isFinite, item.measurementSeconds > 0, item.measurementSeconds <= 7200,
                  item.warmupSeconds.isFinite, item.warmupSeconds >= 0, item.warmupSeconds <= 300,
                  ["sustained", "compatibility", "transport"].contains(item.purpose),
                  let url = URL(string: item.url), ["file", "http", "https"].contains(url.scheme ?? ""),
                  item.purpose != "sustained" || (item.warmupSeconds >= 60 && item.measurementSeconds >= 1800)
            else { throw Failure(message: "Invalid acceptance configuration") }
            let result = await runCase(item, output: output, screen: screen)
            results.append(result)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: output.appendingPathComponent("cases.json"), options: .atomic)
        }
    }

    private static func runCase(_ item: Case, output: URL, screen: NSScreen) async -> CaseResult {
        var result = CaseResult(id: item.id, purpose: item.purpose, warmupSeconds: item.warmupSeconds,
                                measurementSeconds: item.measurementSeconds)
        let suite = "NetVplayer.AV05." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackColorPreferenceStore(defaults: defaults)
        let videoOutput = item.videoOutput ?? (item.hdrPresentation == true ? .hdrIfAvailable : .sdr)
        preferences.set(.init(videoOutput: videoOutput))
        result.hdrPresentationRequested = videoOutput == .hdrIfAvailable
        result.videoOutputRequested = videoOutput
        let audioPreferences = PlaybackAudioPreferenceStore(defaults: defaults)
        audioPreferences.setMuted(true)
        let engine = MPVPlayerEngine(videoSurface: .vod, audioPreferences: audioPreferences, colorPreferences: preferences)
        let state = PlayerState(); engine.playerState = state
        var latest: MPVPerformanceReading?
        engine.performanceDiagnosticsHandler = { info, properties in
            latest = MPVPerformanceReading(info: info, properties: properties, now: ProcessInfo.processInfo.systemUptime)
        }
        // A 4K backing target can exceed a smaller screen. Record both geometries:
        // this measures 4K render work, not full-panel 4K presentation.
        var targetFrame = screen.frame
        if item.renderAt4K == true {
            targetFrame.size = NSSize(width: 3840 / screen.backingScaleFactor, height: 2160 / screen.backingScaleFactor)
        }
        let window = NSWindow(contentRect: targetFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "AV-05 · " + item.id
        guard let view = MPVOpenGLVideoView(engine: engine, surface: .vod) else {
            result.error = "OpenGL unavailable"; return result
        }
        view.frame = NSRect(origin: .zero, size: targetFrame.size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        engine.attach(to: view, surface: .vod)
        var writer: MPVPerformanceWriter?
        do {
            let stream = try MPVPerformanceWriter(url: output.appendingPathComponent(item.id + ".jsonl"))
            writer = stream
            await engine.play(spec: PlaySpec(url: item.url, mpvOptions: item.software == true ? ["hwdec": "no"] : [:]))
            let started = ProcessInfo.processInfo.systemUptime
            let deadline = started + item.warmupSeconds + item.measurementSeconds + 45
            var previousUptime = -1.0
            var steadyStart: Double?
            while ProcessInfo.processInfo.systemUptime < deadline {
                if state.errorMessage != nil { throw Failure(message: "Playback reported an error; inspect redacted engine log") }
                if let reading = latest, reading.uptime != previousUptime {
                    previousUptime = reading.uptime
                    let frames = engine.performanceFrameSnapshot
                    if let first = frames.firstFrameUptime,
                       reading.uptime - first >= item.warmupSeconds, steadyStart == nil {
                        steadyStart = reading.uptime
                    }
                    let resources = await Task.detached(priority: .utility) { MPVPerformanceResources.read() }.value
                    try await stream.append(Record(phase: steadyStart == nil ? "warmup" : "measurement",
                                                   reading: reading, render: frames, resources: resources,
                                                   hdrSurface: view.hdrPrototypeSurface?.facts.compactMapValues { ($0 as? NSNumber)?.doubleValue }))
                    result.diagnostics = reading.diagnostics
                    result.frames = frames
                    result.viewport = ["windowPoints": [window.frame.width, window.frame.height],
                        "viewPoints": [view.bounds.width, view.bounds.height],
                        "viewBackingPixels": [view.convertToBacking(view.bounds).width, view.convertToBacking(view.bounds).height],
                        "windowBackingScale": [window.backingScaleFactor]]
                    if let steadyStart, reading.uptime - steadyStart >= item.measurementSeconds {
                        result.completed = true; break
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            if !result.completed { throw Failure(message: "Deadline reached before required measurement duration") }
        } catch {
            result.error = "\(error)"
        }
        do { try await writer?.close() } catch { result.completed = false; result.error = "Trace write failed" }
        engine.performanceDiagnosticsHandler = nil
        engine.stop()
        view.deactivatePlaybackSurface()
        window.orderOut(nil)
        await engine.detachAndReleaseOpenGLResources(from: view)
        print("AV05 case \(item.id): collection completed=\(result.completed); acceptance requires offline analysis")
        return result
    }
}
#endif
