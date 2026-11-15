#if DEBUG
import AppKit
import Foundation
import Models
import Storage

/// Exercises the ordinary product output policy in an isolated preference
/// domain. The fixed-target AV-03 development experiment remains independent.
@MainActor
public enum MPVVideoOutputProbe {
    private struct Failure: Error { let message: String }
    private final class WindowEvents: NSObject, NSWindowDelegate {
        var entered = false
        var exited = false
        func windowDidEnterFullScreen(_ notification: Notification) { entered = true }
        func windowDidExitFullScreen(_ notification: Notification) { exited = true }
    }

    public static func scheduleIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--av04-output-probe"), args.count > i + 2 else { return false }
        let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let output = URL(fileURLWithPath: args[i + 2])
        Task { @MainActor in
            do { try await run(folder: folder, output: output) }
            catch { print("AV04 output probe failed: \(error)") }
            NSApp.terminate(nil)
        }
        return true
    }

    public static func run(folder: URL, output: URL, requireProductHDR: Bool = true) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let suite = "NetVplayer.AV04." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackColorPreferenceStore(defaults: defaults)
        let engine = MPVPlayerEngine(videoSurface: .vod, colorPreferences: preferences)
        let state = PlayerState()
        engine.playerState = state
        let (window, view) = try makeWindow(engine: engine, surface: .vod, x: 60)
        let windowEvents = WindowEvents()
        window.delegate = windowEvents
        defer {
            engine.stop(); view.deactivatePlaybackSurface(); window.orderOut(nil)
            Task { @MainActor in await engine.detachAndReleaseOpenGLResources(from: view) }
        }
        var report: [String: Any] = ["schema": 1, "passed": false, "physicalHDRVerified": false,
            "requiresProductHDR": requireProductHDR,
            "physicalDisplayTransitionsVerified": false,
            "screens": NSScreen.screens.map { ["currentHeadroom": Double($0.maximumExtendedDynamicRangeColorComponentValue),
                                               "potentialHeadroom": Double($0.maximumPotentialExtendedDynamicRangeColorComponentValue)] }]
        var snapshots: [[String: Any]] = []
        var activationTrace: [[String: Any]] = []
        defer {
            report["snapshots"] = snapshots
            report["activationTrace"] = activationTrace
            report["lastDiagnostics"] = state.playbackDiagnostics.flatMap { try? JSONSerialization.jsonObject(with: Data($0.redactedJSON().utf8)) }
            report["lastSurface"] = view.hdrPrototypeSurface?.facts
            report["lastNativeTransfer"] = engine.nativePropertyJSON("options/target-trc")
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
        await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("contract.mkv").absoluteString))
        try await wait("PQ tracks and chapters") {
            state.playbackDiagnostics?.display.videoOutput?.sourceSignal == .pq && state.position > 0.1
                && state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8"
                && state.audioTracks.count == 2 && state.subtitleTracks.count == 1 && state.chapters.count == 2
        }
        engine.selectAudioTrack(id: "2"); engine.selectSubtitleTrack(id: "1"); engine.seek(to: 5000)
        try await wait("seek and tracks") {
            state.position >= 4.9 && state.selectedAudioTrackID == "2" && state.selectedSubtitleTrackID == "1"
        }
        engine.pause()
        try await wait("paused") { !state.isPlaying }
        let owner = state.playbackDiagnostics!.mediaID
        report["runtime"] = ["mpv": engine.nativePropertyJSON("mpv-version") ?? "unknown",
            "ffmpeg": engine.nativePropertyJSON("ffmpeg-version") ?? "unknown"]
        let position = state.position
        let tracks = [engine.nativePropertyJSON("aid"), engine.nativePropertyJSON("sid")]
        let supportsEDR = (window.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1.01
        for mode in PlaybackVideoOutputMode.allCases {
            preferences.set(.init(videoOutput: mode))
            let expectsEDR = supportsEDR && mode == .hdrIfAvailable && requireProductHDR
            try await wait("policy \(mode.rawValue)") {
                if expectsEDR, activationTrace.count < 100 {
                    activationTrace.append(["uptime": ProcessInfo.processInfo.systemUptime,
                        "currentHeadroom": window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1,
                        "surface": view.hdrPrototypeSurface?.facts ?? [:],
                        "applicationActive": NSApp.isActive,
                        "windowVisible": window.isVisible])
                }
                return state.playbackDiagnostics?.display.videoOutput?.requestedMode == mode
                    && (expectsEDR ? state.playbackDiagnostics?.display.edrEnabled == true
                        : (state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" && view.hdrPrototypeSurface == nil)
                            || state.playbackDiagnostics?.display.edrEnabled == true)
            }
            let usedEDR = state.playbackDiagnostics?.display.edrEnabled == true
            let observed: [String: Any] = ["phase": mode.rawValue,
                "positionDelta": state.position - position, "isPlaying": state.isPlaying,
                "nativeTracks": [engine.nativePropertyJSON("aid") ?? "unknown", engine.nativePropertyJSON("sid") ?? "unknown"],
                "targetTransfer": engine.nativePropertyJSON("options/target-trc") ?? "unknown",
                "subtitleBlending": engine.nativePropertyJSON("options/blend-subtitles") ?? "unknown"]
            snapshots.append(observed)
            guard let info = state.playbackDiagnostics, info.mediaID == owner,
                  info.display.targetFormat == (usedEDR ? "GL_RGBA16F / rgba16Float" : "GL_RGBA8"), info.display.edrEnabled == usedEDR,
                  info.display.videoOutput?.hdrRestrictions.contains(.routeNotValidated) == true,
                  abs(state.position - position) < 0.15, !state.isPlaying,
                  tracks == [engine.nativePropertyJSON("aid"), engine.nativePropertyJSON("sid")],
                  state.chapters.count == 2,
                  engine.nativePropertyJSON("options/target-trc") == (usedEDR ? "\"linear\"" : "\"srgb\""),
                  engine.nativePropertyJSON("options/blend-subtitles") == "false" else {
                throw Failure(message: "Policy changed session or selected an unexpected output")
            }
            if usedEDR {
                report["productHDRValidated"] = true
                report["PQReference"] = try reference(view: view, info: info, folder: folder, sample: "pq.mkv")
                guard let surface = view.hdrPrototypeSurface,
                      let data = surface.copyPresentedHalfFloats(),
                      let width = (surface.facts["width"] as? NSNumber)?.intValue,
                      let height = (surface.facts["height"] as? NSNumber)?.intValue else { throw Failure(message: "Missing PGS FP16 pixels") }
                let white = pixel(data, x: 42*width/640, y: 40*height/360, width: width)
                let grey = pixel(data, x: 106*width/640, y: 40*height/360, width: width)
                guard white.allSatisfy({ abs($0-1) <= 0.035 }), grey.allSatisfy({ abs($0-0.21586) <= 0.035 }) else {
                    throw Failure(message: "Product PGS white/grey changed in EDR")
                }
                report["PGSLinearWhite"] = white; report["PGSLinearGrey"] = grey
                report["productSurface"] = surface.facts
                report["activeDisplay"] = ["name": window.screen?.localizedName ?? "unknown",
                    "currentHeadroom": Double(window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1),
                    "potentialHeadroom": Double(window.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1),
                    "windowNumber": window.windowNumber, "backingScale": window.backingScaleFactor,
                    "viewBackingPixels": [view.convertToBacking(view.bounds).width, view.convertToBacking(view.bounds).height]]
                if requireProductHDR {
                    window.setContentSize(NSSize(width: 720, height: 405))
                    view.displayOpenGL()
                    try await wait("resized EDR") {
                        (view.hdrPrototypeSurface?.facts["width"] as? Int) == Int(view.convertToBacking(view.bounds).width)
                            && state.playbackDiagnostics?.display.edrEnabled == true
                    }
                    report["resizedPQReference"] = try reference(view: view, info: state.playbackDiagnostics!, folder: folder, sample: "pq.mkv")
                    window.collectionBehavior.insert(.fullScreenPrimary)
                    window.toggleFullScreen(nil)
                    try await wait("product full screen") { windowEvents.entered && window.styleMask.contains(.fullScreen) && view.bounds.width >= 1000 }
                    view.displayOpenGL()
                    try await wait("full screen FP16") { (view.hdrPrototypeSurface?.facts["width"] as? Int) == Int(view.convertToBacking(view.bounds).width) }
                    report["fullScreenSurface"] = view.hdrPrototypeSurface?.facts
                    report["fullScreenPQReference"] = try reference(view: view, info: state.playbackDiagnostics!, folder: folder, sample: "pq.mkv")
                    window.toggleFullScreen(nil)
                    try await wait("product full screen exit") { windowEvents.exited && !window.styleMask.contains(.fullScreen) && view.bounds.width < 1000 }
                    engine.detach(from: view)
                    guard view.hdrPrototypeSurface == nil, state.playbackDiagnostics?.display.targetFormat == nil else {
                        throw Failure(message: "Detached product retained a submitted HDR surface")
                    }
                    engine.attach(to: view, surface: .vod)
                    try await wait("HDR surface reopened") { state.playbackDiagnostics?.display.edrEnabled == true }
                    guard state.playbackDiagnostics?.mediaID == owner, !state.isPlaying,
                          abs(state.position-position) < 0.15,
                          tracks == [engine.nativePropertyJSON("aid"), engine.nativePropertyJSON("sid")] else {
                        throw Failure(message: "Product lifecycle changed paused session")
                    }
                    report["productResizeFullScreenDetachReattachSameSession"] = true
                }
                guard let reopened = view.hdrPrototypeSurface,
                      !reopened.prepareWidth(16384, height: 16384) else { throw Failure(message: "Unbounded product allocation") }
                engine.fallbackFromHDRPrototype(in: view)
                try await wait("allocation-failure SDR fallback") { state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" }
                try await Task.sleep(for: .milliseconds(1100))
                guard view.hdrPrototypeSurface == nil, state.playbackDiagnostics?.mediaID == owner,
                      engine.nativePropertyJSON("options/target-trc") == "\"srgb\"",
                      state.playbackDiagnostics?.display.iccSubmission == .display else { throw Failure(message: "Failure retried or failed ICC restoration") }
                report["allocationFailureSameSessionSDRFallback"] = true
            }
            snapshots.append(try snapshot(info, phase: mode.rawValue))
        }
        preferences.set(.init(videoOutput: .sdr))
        try await wait("explicit SDR restore") { state.playbackDiagnostics?.display.videoOutput?.requestedMode == .sdr && state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" }
        report["sameSessionProgressTracksChapters"] = true
        // Exercise actual observers, while explicitly retaining the physical
        // sleep/hotplug/cross-display acceptance gates as unverified.
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeScreenProfileNotification,
                     NSWindow.didChangeBackingPropertiesNotification, NSApplication.didChangeScreenParametersNotification] {
            NotificationCenter.default.post(name: name, object: name == NSApplication.didChangeScreenParametersNotification ? nil : window)
        }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        guard state.playbackDiagnostics?.display.targetFormat == nil,
              state.playbackDiagnostics?.display.currentEDRHeadroom == nil,
              state.playbackDiagnostics?.display.videoOutput?.disposition == .awaitingRender else {
            throw Failure(message: "Sleep observer retained stale display output")
        }
        window.contentView = nil
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        guard state.playbackDiagnostics?.display.targetFormat == nil else {
            throw Failure(message: "System wake incorrectly implied screen wake")
        }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        guard state.playbackDiagnostics?.display.videoOutput?.disposition == .awaitingRender else {
            throw Failure(message: "Detached window retained stale output")
        }
        window.contentView = view
        try await wait("reattachment") { state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" }
        report["syntheticDisplayNotificationsAndViewReattachment"] = true
        let live = MPVPlayerEngine(videoSurface: .live, colorPreferences: preferences)
        live.subtitleSettingsProvider = { SubtitleRenderSettings(overrideSourceStyle: false) }
        let liveState = PlayerState(); live.playerState = liveState
        let (liveWindow, liveView) = try makeWindow(engine: live, surface: .live, x: 730)
        defer {
            live.stop(); liveView.deactivatePlaybackSurface(); liveWindow.orderOut(nil)
            Task { @MainActor in await live.detachAndReleaseOpenGLResources(from: liveView) }
        }
        await live.play(spec: PlaySpec(url: folder.appendingPathComponent("hlg.mkv").absoluteString,
                                      metadata: ["playback.kind": "live"]))
        try await wait("second window HLG") {
            liveState.playbackDiagnostics?.display.videoOutput?.sourceSignal == .hlg && liveState.position > 0.1
                && liveState.playbackDiagnostics?.display.targetFormat == "GL_RGBA8"
        }
        if supportsEDR && requireProductHDR {
            preferences.set(.init(videoOutput: .hdrIfAvailable))
            try await wait("dual EDR") { state.playbackDiagnostics?.display.edrEnabled == true && liveState.playbackDiagnostics?.display.edrEnabled == true }
            report["HLGReference"] = try reference(view: liveView, info: liveState.playbackDiagnostics!, folder: folder, sample: "hlg.mkv")
            live.pause()
            live.loadExternalSubtitle(Sub(name: "Original linear overlay contract", url: folder.appendingPathComponent("color-overlay.ass").path, format: "ass"))
            try await wait("ASS selected in EDR") { liveState.selectedSubtitleTrackID == "1" }
            try await Task.sleep(for: .milliseconds(150))
            liveView.displayOpenGL()
            guard let overlay = liveView.hdrPrototypeSurface, let bytes = overlay.copyPresentedHalfFloats(),
                  let width = overlay.facts["width"] as? Int,
                  let height = overlay.facts["height"] as? Int else { throw Failure(message: "Missing ASS FP16 readback") }
            let actual = (0..<4).map { pixel(bytes, x: (42+64*$0)*width/640, y: 40*height/360, width: width) }
            let expected: [[Double]] = [[1,1,1], [0.21586,0.21586,0.21586], [1,0,0], [0,1,0]]
            let error = zip(actual, expected).flatMap { zip($0,$1).map { abs($0-$1) } }.max() ?? .infinity
            guard error <= 0.035 else { throw Failure(message: "ASS white/grey/color EDR mismatch: \(error); pixels=\(actual); sid=\(live.nativePropertyJSON("sid") ?? "unknown")") }
            report["ASSLinearOverlay"] = ["pixels": actual, "maximumAbsoluteLinearError": error, "tolerance": 0.035,
                "sourceStyle": live.nativePropertyJSON("options/sub-ass-override") ?? "unknown"]
            report["twoIndependentEDRWindows"] = true
            snapshots.append(try snapshot(liveState.playbackDiagnostics!, phase: "local-live-surface-hlg-edr"))
        }
        preferences.set(.init(videoOutput: .sdr))
        try await wait("shared preference") {
            state.playbackDiagnostics?.display.videoOutput?.requestedMode == .sdr
                && liveState.playbackDiagnostics?.display.videoOutput?.requestedMode == .sdr
                && liveState.playbackDiagnostics?.display.targetFormat == "GL_RGBA8"
        }
        guard liveState.playbackDiagnostics?.display.edrEnabled == false,
              liveState.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" else {
            throw Failure(message: "Second window escaped SDR route")
        }
        snapshots.append(try snapshot(liveState.playbackDiagnostics!, phase: "local-live-surface-hlg"))
        report["twoIndependentWindowsSharedPreference"] = true
        preferences.set(.init(videoOutput: .hdrIfAvailable))
        await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("sdr-limited.mkv").absoluteString))
        try await wait("new SDR media") {
            state.playbackDiagnostics?.mediaID != owner
                && state.playbackDiagnostics?.display.videoOutput?.disposition == .sdrContent && state.position > 0.1
        }
        guard state.playbackDiagnostics?.display.videoOutput?.sourceSignal == .sdr,
              state.playbackDiagnostics?.display.referencePeakNits == 203,
              state.playbackDiagnostics?.display.toneMapping == "bt.2390" else {
            throw Failure(message: "New SDR media retained previous HDR/policy state")
        }
        guard view.hdrPrototypeSurface == nil, state.playbackDiagnostics?.display.iccSubmission == .display else { throw Failure(message: "SDR content retained EDR surface") }
        snapshots.append(try snapshot(state.playbackDiagnostics!, phase: "next-sdr-media"))
        engine.stop()
        try await wait("stop cleanup") { state.playbackDiagnostics == nil }
        report["nextMediaAndStopClearedState"] = true
        report["passed"] = true
    }

    private static func makeWindow(engine: MPVPlayerEngine, surface: MPVVideoSurface, x: CGFloat) throws -> (NSWindow, MPVOpenGLVideoView) {
        let window = NSWindow(contentRect: NSRect(x: x, y: 80, width: 640, height: 360),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "AV-04 · product output · optical calibration pending"
        guard let view = MPVOpenGLVideoView(engine: engine, surface: surface) else { throw Failure(message: "OpenGL unavailable") }
        view.frame = window.contentView!.bounds
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        engine.attach(to: view, surface: surface)
        return (window, view)
    }

    private static func snapshot(_ info: PlaybackDiagnostics, phase: String) throws -> [String: Any] {
        ["phase": phase, "diagnostics": try JSONSerialization.jsonObject(with: Data(info.redactedJSON().utf8))]
    }

    private struct Reference: Decodable {
        struct Sample: Decodable {
            struct Patch: Decodable { let x: Int; let y: Int }
            let patches: [Patch]
            let referencesByPeak: [String: [[Double]]]
        }
        let tolerance: Double
        let samples: [String: Sample]
    }

    private static func reference(view: MPVOpenGLVideoView, info: PlaybackDiagnostics, folder: URL, sample: String) throws -> [String: Any] {
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: folder.appendingPathComponent("hdr-product-reference.json")))
        guard let surface = view.hdrPrototypeSurface, let data = surface.copyPresentedHalfFloats(),
              let width = (surface.facts["width"] as? NSNumber)?.intValue,
              let height = (surface.facts["height"] as? NSNumber)?.intValue,
              let hdr = info.display.hdrPresentation, let input = reference.samples[sample],
              let expected = input.referencesByPeak[String(hdr.targetPeakSignalNits)] else { throw Failure(message: "Missing independent product reference") }
        let pixels = input.patches.map { pixel(data, x: $0.x*width/640, y: $0.y*height/360, width: width) }
        let maximum = zip(pixels, expected).flatMap { zip($0, $1).map { abs($0-$1) } }.max() ?? .infinity
        guard maximum.isFinite, maximum <= reference.tolerance,
              pixels.flatMap({ $0 }).allSatisfy({ $0.isFinite && $0 <= hdr.maximumLinearComponent + 0.005 }),
              (surface.facts["surfaceCount"] as? Int) == 2,
              (surface.facts["surfaceBytes"] as? Int ?? .max) <= 128*1024*1024,
              (surface.facts["maximumObservedInFlightFrames"] as? Int ?? .max) <= 2 else {
            throw Failure(message: "Product reference mismatch \(sample) peak \(hdr.targetPeakSignalNits): \(maximum); pixels=\(pixels)")
        }
        return ["maximumAbsoluteLinearError": maximum, "tolerance": reference.tolerance,
                "peakSignalNits": hdr.targetPeakSignalNits, "pixels": pixels, "expected": expected]
    }

    private static func pixel(_ data: Data, x: Int, y: Int, width: Int) -> [Double] {
        data.withUnsafeBytes { raw in
            (0..<3).map { Double(Float16(bitPattern: raw.loadUnaligned(fromByteOffset: (y*width+x)*8+$0*2, as: UInt16.self))) }
        }
    }

    private static func wait(_ label: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        guard predicate() else { throw Failure(message: "Timed out: \(label)") }
    }
}
#endif
