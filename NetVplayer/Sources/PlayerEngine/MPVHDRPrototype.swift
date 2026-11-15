#if DEBUG
import AppKit
import AVFoundation
import Foundation
import Models
import MPVShim
import Storage

/// Explicit developer experiment, shared by native tests and the packaged app.
/// It never changes the user's playback preferences or selects a production route.
@MainActor
public enum MPVHDRPrototype {
    private final class WindowEvents: NSObject, NSWindowDelegate {
        var entered = false
        var exited = false
        func windowDidEnterFullScreen(_ notification: Notification) { entered = true }
        func windowDidExitFullScreen(_ notification: Notification) { exited = true }
    }
    private struct Manifest: Decodable {
        struct Sample: Decodable {
            struct Patch: Decodable { let x: Int; let y: Int; let linearRGB: [Double] }
            let file: String
            let patches: [Patch]
        }
        let width: Int; let height: Int; let tolerance: Double; let samples: [Sample]
    }
    private struct Failure: Error, CustomStringConvertible { let description: String }

    public static func scheduleIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--av03-hdr-probe"), args.count > i+2 else { return false }
        let folder = URL(fileURLWithPath: args[i+1], isDirectory: true)
        let output = URL(fileURLWithPath: args[i+2])
        Task { @MainActor in
            do { try await run(folder: folder, output: output) }
            catch { print("AV03 prototype failed: \(error)") }
            NSApp.terminate(nil)
        }
        return true
    }

    public static func run(folder: URL, output: URL) async throws {
        _ = NSApplication.shared
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("hdr-manifest.json")))
        let suite = "NetVplayer.AV03." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = MPVPlayerEngine(videoSurface: .vod, colorPreferences: PlaybackColorPreferenceStore(defaults: defaults))
        let state = PlayerState()
        engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 80,y: 80,width: manifest.width,height: manifest.height),
                              styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "AV-03 · FP16 prototype · optical HDR unverified"
        let windowEvents = WindowEvents()
        window.delegate = windowEvents
        guard let view = MPVOpenGLVideoView(engine: engine, surface: .vod) else { throw Failure(description: "OpenGL unavailable") }
        view.frame = window.contentView!.bounds
        guard view.enableHDRPrototype() else { throw Failure(description: "Metal unavailable") }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        engine.attach(to: view, surface: .vod)
        defer {
            engine.stop(); view.deactivatePlaybackSurface(); window.orderOut(nil)
            Task { @MainActor in await engine.detachAndReleaseOpenGLResources(from:view) }
        }
        var report: [String: Any] = ["schema":1,"opticalHDRVerified":false,
            "appBundle": Bundle.main.bundleIdentifier ?? "native-tests", "os":ProcessInfo.processInfo.operatingSystemVersionString,
            "currentHeadroom":window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0,
            "potentialHeadroom":window.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 0]
        var samples: [[String:Any]] = []
        var measurements: [[String:Any]] = []
        var phase = "initialization"
        defer {
            report["samples"] = samples; report["frameCosts"] = measurements; report["lastPhase"] = phase
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
        let cpuStart = getCPUTime()
        let wallStart = Date()
        let rssStart = residentBytes()
        for sample in manifest.samples {
            phase = sample.file
            window.title = "AV-03 · \(phase) · FP16 · optical HDR unverified"
            await engine.play(spec: PlaySpec(url: folder.appendingPathComponent(sample.file).absoluteString))
            try await wait("FP16 frame \(sample.file)") {
                state.playbackDiagnostics?.display.targetFormat == "GL_RGBA16F / rgba16Float" && state.position > 0.1
            }
            engine.pause()
            try await Task.sleep(for: .milliseconds(100))
            view.displayOpenGL()
            guard let surface = view.hdrPrototypeSurface, let bytes = surface.copyPresentedHalfFloats() else {
                throw Failure(description: "FP16 route fell back / drawable readback unavailable")
            }
            let facts = surface.facts
            let w = (facts["width"] as? NSNumber)?.intValue ?? 0
            let h = (facts["height"] as? NSNumber)?.intValue ?? 0
            var actual: [[Double]] = []
            var errors: [Double] = []
            for patch in sample.patches {
                let x = patch.x*w/manifest.width, y = patch.y*h/manifest.height
                let rgb: [Double] = bytes.withUnsafeBytes { raw in
                    (0..<3).map { Double(Float16(bitPattern: raw.loadUnaligned(fromByteOffset: (y*w+x)*8+$0*2, as: UInt16.self))) }
                }
                actual.append(rgb)
                errors += zip(rgb,patch.linearRGB).map { abs($0-$1) }
            }
            let maximum = errors.max() ?? .infinity
            samples.append(["file":sample.file,"facts":facts,"linearRGB":actual,"maximumError":maximum,
                            "mpv":engine.nativePropertyJSON("mpv-version") ?? "unknown",
                            "ffmpeg":engine.nativePropertyJSON("ffmpeg-version") ?? "unknown",
                            "hwdec":engine.nativePropertyJSON("hwdec-current") ?? "unknown",
                            "videoParams":engine.nativePropertyJSON("video-params") ?? "unknown",
                            "iccAuto":engine.nativePropertyJSON("options/icc-profile-auto") ?? "unknown"])
            guard errors.allSatisfy({ $0.isFinite && $0 <= manifest.tolerance }) else {
                throw Failure(description: "Linear reference mismatch \(sample.file): \(maximum)")
            }
            if sample.file == "pq.mkv", ProcessInfo.processInfo.arguments.contains("--av03-hdr-hold") {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for:.seconds(45))
            }
            for _ in 0..<30 {
                let start = Date()
                view.displayOpenGL()
                var values = surface.facts
                values["hostRenderWallMS"] = Date().timeIntervalSince(start)*1000
                measurements.append(values)
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        phase = "4K-output-allocation"
        window.title = "AV-03 · \(phase) · FP16 · optical HDR unverified"
        let oldBounds = view.bounds
        let scale = window.backingScaleFactor
        view.setBoundsSize(NSSize(width:3840/scale,height:2160/scale))
        var largeCosts: [[String:Any]] = []
        for _ in 0..<12 {
            let start = Date(); view.displayOpenGL()
            guard let surface = view.hdrPrototypeSurface else { throw Failure(description:"4K allocation failed") }
            var values = surface.facts
            values["hostRenderWallMS"] = Date().timeIntervalSince(start)*1000
            largeCosts.append(values)
            try await Task.sleep(for:.milliseconds(20))
        }
        report["fourKOutputCosts"] = largeCosts
        report["fourKDecodePerformanceVerified"] = false
        report["fourKReferenceError"] = try referenceError(view, sample:manifest.samples.last!, manifest:manifest)
        view.bounds = oldBounds
        view.displayOpenGL()
        report["resizeRestoreReferenceError"] = try referenceError(view, sample:manifest.samples.last!, manifest:manifest)
        phase = "contract"
        window.title = "AV-03 · \(phase) · FP16 · optical HDR unverified"
        await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("contract.mkv").absoluteString))
        try await wait("tracks and chapters") { state.audioTracks.count == 2 && state.subtitleTracks.count == 1 && state.chapters.count == 2 && state.position > 0.1 }
        engine.selectAudioTrack(id: "2")
        engine.selectSubtitleTrack(id: "1")
        engine.seek(to: 5000)
        try await wait("seek and selected tracks") { state.position >= 4.9 && state.selectedAudioTrackID == "2" && state.selectedSubtitleTrackID == "1" }
        engine.pause()
        try await Task.sleep(for: .milliseconds(120))
        view.displayOpenGL()
        guard let surface = view.hdrPrototypeSurface, let bytes = surface.copyPresentedHalfFloats(),
           let width = (surface.facts["width"] as? NSNumber)?.intValue,
           let height = (surface.facts["height"] as? NSNumber)?.intValue else {
            throw Failure(description:"PGS drawable readback unavailable")
        }
        let white = pixel(bytes, x:42*width/640, y:40*height/360, width:width)
        let grey = pixel(bytes, x:106*width/640, y:40*height/360, width:width)
        report["PGSLinearWhite"] = white; report["PGSLinearGrey"] = grey
        guard white.allSatisfy({ abs($0-1) < 0.035 }), grey.allSatisfy({ abs($0-0.21586) < 0.035 }) else {
            throw Failure(description:"PGS SDR reference-white mapping failed")
        }
        let before = state.playbackDiagnostics?.mediaID
        let position = state.position
        let nativeBefore = ["aid": engine.nativePropertyJSON("aid") ?? "unknown",
                            "sid": engine.nativePropertyJSON("sid") ?? "unknown"]
        // Actual allocation failure invokes the same path as device/drawable
        // failure. A zero-size or oversized allocation never reaches mpv.
        guard view.hdrPrototypeSurface?.prepareWidth(16384, height: 16384) == false else { throw Failure(description: "Unbounded surface allocation accepted") }
        engine.fallbackFromHDRPrototype(in: view)
        view.displayOpenGL()
        try await wait("SDR fallback") { state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" }
        let nativeAfter = ["aid": engine.nativePropertyJSON("aid") ?? "unknown",
                           "sid": engine.nativePropertyJSON("sid") ?? "unknown"]
        guard before == state.playbackDiagnostics?.mediaID, abs(state.position-position) < 0.15,
              nativeBefore == nativeAfter, state.chapters.count == 2,
              state.playbackDiagnostics?.display.toneMapping == "bt.2390",
              state.playbackDiagnostics?.display.iccSubmission == .display else { throw Failure(description: "Fallback changed session/position/tracks or failed SDR color restoration") }
        report["fallback"] = ["sameMediaID":true,"positionDelta":state.position-position,"nativeTracks":nativeAfter,
                              "chapters":state.chapters.count,"iccRestored":true,"SDRMappingRestored":true]
        var baseline: [Double] = []
        for _ in 0..<30 {
            let start = Date(); view.displayOpenGL()
            baseline.append(Date().timeIntervalSince(start)*1000)
            try await Task.sleep(for:.milliseconds(16))
        }
        report["SDRHostRenderWallMS"] = baseline
        phase = "reopen"
        window.title = "AV-03 · \(phase) · FP16 · optical HDR unverified"
        engine.stop()
        view.deactivatePlaybackSurface()
        await engine.detachAndReleaseOpenGLResources(from: view)
        window.orderOut(nil)
        guard view.activatePlaybackSurface() != nil, view.enableHDRPrototype() else { throw Failure(description: "Reopen failed") }
        window.makeKeyAndOrderFront(nil)
        engine.attach(to: view, surface: .vod)
        await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("hlg.mkv").absoluteString))
        try await wait("reopened FP16") { state.playbackDiagnostics?.display.targetFormat == "GL_RGBA16F / rgba16Float" && state.position > 0.1 }
        view.displayOpenGL()
        report["reopenReferenceError"] = try referenceError(view, sample:manifest.samples.first { $0.file == "hlg.mkv" }!, manifest:manifest)
        report["reopen"] = true
        phase = "dual-window-live-contract"
        let live = MPVPlayerEngine(videoSurface: .live, colorPreferences: PlaybackColorPreferenceStore(defaults: defaults))
        let liveState = PlayerState(); live.playerState = liveState
        let liveWindow = NSWindow(contentRect: NSRect(x:760,y:80,width:640,height:360),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        liveWindow.isReleasedWhenClosed = false
        guard let liveView = MPVOpenGLVideoView(engine: live,surface:.live), liveView.enableHDRPrototype() else { throw Failure(description:"Second surface unavailable") }
        liveView.frame = liveWindow.contentView!.bounds; liveWindow.contentView = liveView
        liveWindow.makeKeyAndOrderFront(nil); live.attach(to:liveView,surface:.live)
        defer {
            live.stop(); liveView.deactivatePlaybackSurface(); liveWindow.orderOut(nil)
            Task { @MainActor in await live.detachAndReleaseOpenGLResources(from:liveView) }
        }
        await live.play(spec: PlaySpec(url:folder.appendingPathComponent("pq.mkv").absoluteString,metadata:["playback.kind":"live"]))
        try await wait("dual surfaces") { liveState.playbackDiagnostics?.display.targetFormat == "GL_RGBA16F / rgba16Float" && state.position > 0.5 }
        view.displayOpenGL()
        report["dualVODReferenceError"] = try referenceError(view, sample:manifest.samples.first { $0.file == "hlg.mkv" }!, manifest:manifest)
        liveView.displayOpenGL()
        report["dualLiveReferenceError"] = try referenceError(liveView, sample:manifest.samples.first { $0.file == "pq.mkv" }!, manifest:manifest)
        report["dualWindowLocalLiveContract"] = true
        report["networkLiveVerified"] = false
        // Real AppKit fullscreen transition; record observed state both ways.
        phase = "fullscreen"
        if Bundle.main.bundleIdentifier == "com.netvplayer.app" {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.toggleFullScreen(nil)
            try await wait("fullscreen entry notification") { windowEvents.entered }
            view.displayOpenGL()
            guard let surface = view.hdrPrototypeSurface, let data = surface.copyPresentedHalfFloats() else { throw Failure(description:"Fullscreen fell back") }
            let peak: Double = data.withUnsafeBytes { raw in
                stride(from:0,to:raw.count,by:8).map { Double(Float16(bitPattern:raw.loadUnaligned(fromByteOffset:$0,as:UInt16.self))) }.max() ?? 0
            }
            report["fullscreenDrawablePeak"] = peak
            guard peak > 1 else { throw Failure(description:"Fullscreen drawable has no HDR signal") }
            window.toggleFullScreen(nil)
            try await wait("fullscreen exit notification") { windowEvents.exited }
            report["fullscreen"] = true
        } else { report["fullscreen"] = "requires packaged AppKit application lifecycle" }
        phase = "avfoundation"
        report["avfoundation"] = await systemCandidates(folder: folder)
        phase = "standalone-gpu-next"
        report["standaloneGPUCandidate"] = await gpuCandidate(folder: folder)
        report["cpuSeconds"] = getCPUTime()-cpuStart
        report["wallSeconds"] = Date().timeIntervalSince(wallStart)
        report["residentStartBytes"] = rssStart
        report["residentEndBytes"] = residentBytes()
        report["passed"] = true
        phase = "complete"
    }

    private static func wait(_ reason: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        if !predicate() { throw Failure(description: "Timed out: \(reason)") }
    }
    private static func referenceError(_ view: MPVOpenGLVideoView, sample: Manifest.Sample, manifest: Manifest) throws -> Double {
        guard let surface = view.hdrPrototypeSurface, let bytes = surface.copyPresentedHalfFloats(),
              let width = (surface.facts["width"] as? NSNumber)?.intValue,
              let height = (surface.facts["height"] as? NSNumber)?.intValue else { throw Failure(description:"Missing reference surface") }
        let maximum = sample.patches.flatMap { patch in
            zip(pixel(bytes,x:patch.x*width/manifest.width,y:patch.y*height/manifest.height,width:width),patch.linearRGB).map { abs($0-$1) }
        }.max() ?? .infinity
        guard maximum.isFinite, maximum <= manifest.tolerance else { throw Failure(description:"Lifecycle reference mismatch \(sample.file) at \(width)x\(height): \(maximum)") }
        return maximum
    }
    private static func getCPUTime() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
    }
    private static func pixel(_ data: Data, x: Int, y: Int, width: Int) -> [Double] {
        data.withUnsafeBytes { raw in
            (0..<3).map { Double(Float16(bitPattern:raw.loadUnaligned(fromByteOffset:(y*width+x)*8+$0*2,as:UInt16.self))) }
        }
    }
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let code = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) }
        }
        return code == KERN_SUCCESS ? info.resident_size : 0
    }
    private static func systemCandidates(folder: URL) async -> [[String:Any]] {
        var results: [[String:Any]] = []
        for file in ["pq.mkv","pq.mp4","hlg.mp4","sdr-limited.mp4","contract.mkv"] {
            let asset = AVURLAsset(url: folder.appendingPathComponent(file))
            do {
                let playable = try await asset.load(.isPlayable)
                let video = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                var row: [String:Any] = ["file":file,"playable":playable,"videoTracks":video.count,"audioTracks":audio.count]
                if let track = video.first {
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_64RGBAHalf])
                    if reader.canAdd(output) {
                        reader.add(output)
                        let started = reader.startReading()
                        let sample = started ? output.copyNextSampleBuffer() : nil
                        row["decodedFrame"] = sample != nil
                        if let sample, let pixel = CMSampleBufferGetImageBuffer(sample) {
                            row["pixelFormat"] = CVPixelBufferGetPixelFormatType(pixel)
                            row["transfer"] = CVBufferCopyAttachment(pixel,kCVImageBufferTransferFunctionKey,nil) as? String ?? "unknown"
                            row["primaries"] = CVBufferCopyAttachment(pixel,kCVImageBufferColorPrimariesKey,nil) as? String ?? "unknown"
                        }
                        row["readerErrorCode"] = (reader.error as NSError?)?.code ?? 0
                        reader.cancelReading()
                    } else { row["readerCanAdd"] = false }
                }
                results.append(row)
            } catch { results.append(["file":file,"errorDomain":(error as NSError).domain,"errorCode":(error as NSError).code]) }
        }
        return results
    }

    private final class CandidateContext: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
    }
    private static func gpuCandidate(folder: URL) async -> [String:Any] {
        guard let pointer = nv_mpv_create() else { return ["created":false] }
        let context = CandidateContext(pointer)
        let result = await gpuCandidateBody(context: pointer, folder: folder)
        // macvk creates and tears down Cocoa objects on the main queue.
        // Keep that queue available while the core terminates.
        await Task.detached { nv_mpv_destroy(context.pointer) }.value
        return result
    }
    private static func gpuCandidateBody(context: OpaquePointer, folder: URL) async -> [String:Any] {
        var result: [String:Any] = ["embeddedRenderAPI":false]
        for (key,value) in ["config":"no","vo":"gpu-next","gpu-api":"vulkan","gpu-context":"macvk",
                            "aid":"no","terminal":"no","idle":"yes","keep-open":"yes"] {
            let code = nv_mpv_set_option_string(context,key,value)
            if code < 0 { return ["rejectedOption":key,"code":code] }
        }
        let initialized = nv_mpv_initialize(context)
        result["initializeCode"] = initialized
        guard initialized >= 0 else { return result }
        _ = nv_mpv_request_log_messages(context,"warn")
        var logs: [String] = []
        result["loadRequestCode"] = Int(nv_mpv_command3_async(context,1,"loadfile",folder.appendingPathComponent("pq.mp4").path,"replace"))
        let deadline = Date().addingTimeInterval(5)
        var pending = false
        while Date() < deadline {
            if !pending {
                pending = nv_mpv_get_property_async(context,2,"time-pos") >= 0
                _ = nv_mpv_get_property_async(context,3,"current-vo")
            }
            var event = NVMPVEvent()
            while nv_mpv_wait_event(context,0,&event) >= 0, event.event_id != 0 {
                if let line = event.log_text, logs.count < 16 {
                    logs.append(String(String(cString:line).replacingOccurrences(of:folder.path,with:"<fixture>").prefix(240)))
                    result["warnings"] = logs
                }
                if event.event_id == 7 && event.end_file_error < 0 {
                    result["endFileError"] = Int(event.end_file_error)
                    return result
                }
                if event.event_id == 3 { // MPV_EVENT_GET_PROPERTY_REPLY (4 is SET_PROPERTY_REPLY).
                    if event.reply_userdata == 2 { pending = false }
                    if let value = nv_mpv_copy_event_property_json(&event) {
                        let data = Data(String(cString:value).utf8); nv_mpv_free_string(value)
                        let decoded = try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)
                        if event.reply_userdata == 3 { result["currentVO"] = decoded as? String }
                        if event.reply_userdata == 2, let time = decoded as? Double, time > 0.2 {
                            result["playbackAdvanced"] = true
                            result["observedTimeSeconds"] = time
                        }
                    }
                }
            }
            if result["playbackAdvanced"] as? Bool == true { return result }
            try? await Task.sleep(for:.milliseconds(30))
        }
        result["playbackAdvanced"] = false
        return result
    }
}
#endif
