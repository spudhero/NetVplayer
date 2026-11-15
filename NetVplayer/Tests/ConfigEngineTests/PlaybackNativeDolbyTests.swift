import AppKit
import Foundation
import QuartzCore
import Models
import Storage
import Testing
@testable import PlayerEngine

/// Explicit local fixtures and a pinned runtime are required; this never contacts
/// a third-party server or writes to the user's playback preferences.
@Suite(.serialized) struct PlaybackNativeDolbyTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_BLUETOOTH_JOC_FIXTURE"] != nil))
    func bluetoothNativeAudioSurvivesExplicitRouteChanges() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(fileURLWithPath: try #require(environment["NETVPLAYER_BLUETOOTH_JOC_FIXTURE"]))
        let devices = try #require(await PlaybackAudioDeviceProbeWorker.snapshot())
        let headphone = try #require(devices.outputs.first { $0.transport == .bluetooth })
        let suite = "BluetoothDolby.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        volume.setVolume(0.25); volume.setMuted(true)
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod, audioPreferences: volume,
            audioOutputPreferences: output, dialoguePreferences: .init(defaults: defaults),
            colorPreferences: .init(defaults: defaults))
        let state = PlayerState(); engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
        var reports: [String: String] = [:]
        func record(_ phase: String) throws {
            reports[phase] = state.playbackDiagnostics?.redactedJSON()
            if let path = environment["NETVPLAYER_BLUETOOTH_JOC_REPORT"] {
                try JSONEncoder().encode(reports).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        await engine.play(spec: PlaySpec(url: fixture.absoluteString))
        try #require(await wait { state.playbackDiagnostics?.audio.mode == .nativeCompressed })
        let media = state.playbackDiagnostics?.mediaID
        try record("default-native")
        #expect(state.playbackDiagnostics?.audio.nativeAudio?.rendererMuted == true)
        #expect(state.playbackDiagnostics?.audio.nativeAudio?.rendererVolume == 0)
        output.set(.init(deviceUID: headphone.id))
        let explicit = await wait { state.playbackDiagnostics?.audio.routeStatus == .selected &&
            state.playbackDiagnostics?.audio.mode == .nativeCompressed && state.position > 3 }
        try record("explicit-native")
        try #require(explicit)
        #expect(state.playbackDiagnostics?.mediaID == media)
        #expect(state.playbackDiagnostics?.audio.nativeAudio?.joc == true)
        #expect(state.playbackDiagnostics?.audio.nativeAudio?.rendererMuted == true)
        engine.pause()
        let paused = state.position
        // Read the actual native sink, not the preference echoed in PlayerState.
        // Stay paused while unmuting so this regression never plays test audio.
        engine.setMuted(false)
        try #require(await wait { state.playbackDiagnostics?.audio.nativeAudio?.rendererMuted == false })
        #expect(abs((state.playbackDiagnostics?.audio.nativeAudio?.rendererVolume ?? -1) - pow(0.25, 3)) < 0.00001)
        try record("native-volume-paused")
        engine.setMuted(true)
        try #require(await wait { state.playbackDiagnostics?.audio.nativeAudio?.rendererMuted == true })
        output.set(.init(deviceUID: headphone.id, dolbyAudio: .pcm))
        try #require(await wait { state.playbackDiagnostics?.audio.mode == .pcm })
        try record("explicit-pcm-paused")
        #expect(!state.isPlaying && abs(state.position - paused) < 0.3)
        output.set(.init(deviceUID: headphone.id))
        try #require(await wait { state.playbackDiagnostics?.audio.mode == .nativeCompressedPreparing })
        try record("explicit-native-paused")
        engine.resume()
        try #require(await wait { state.playbackDiagnostics?.audio.mode == .nativeCompressed && state.position > paused + 1 })
        try record("explicit-native-resumed")
        #expect(state.playbackDiagnostics?.audio.nativeAudio?.rendererMuted == true)
        output.reset()
        try #require(await wait { state.playbackDiagnostics?.audio.routeStatus == .automatic &&
            state.playbackDiagnostics?.audio.mode == .nativeCompressed })
        try record("default-restored")
        #expect(state.playbackDiagnostics?.mediaID == media)
        #expect(state.isMuted && state.volume == 0.25 && state.audioOutputMessage == nil)
        #expect(state.playbackDiagnostics?.audio.nativeAudio?.rendererMuted == true)
        engine.stop()
        try #require(await wait { state.currentSpec == nil && state.playbackDiagnostics == nil })
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_NATIVE_DOLBY_FIXTURES"] != nil))
    func reconstructedVideoAndNativeAudioSurviveSessionChanges() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_NATIVE_DOLBY_FIXTURES"]))
        let suite = "NativeDolby.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        let color = PlaybackColorPreferenceStore(defaults: defaults)
        let dialogue = PlaybackDialoguePreferenceStore(defaults: defaults)
        volume.setVolume(0.25); volume.setMuted(true)
        color.set(.init(videoOutput: .sdr))
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod, audioPreferences: volume,
            audioOutputPreferences: output, dialoguePreferences: dialogue, colorPreferences: color)
        let state = PlayerState(); engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.title = "NetVplayer Dolby regression (muted)"
        // An off-space/occluded layer cannot activate EDR. Keep this opt-in
        // hardware test visible even when another app owns a fullscreen space.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.performanceDiagnosticsHandler = nil; engine.stop(); engine.detach(from: view); window.orderOut(nil) }
        var reports: [String: String] = [:]
        var displayObservations: [[String: Any]] = []
        engine.performanceDiagnosticsHandler = { info, _ in
            displayObservations.append(["display": info.redactedJSON(),
                                        "surface": view.hdrPrototypeSurface?.facts ?? [:]])
            if let data = try? JSONSerialization.data(withJSONObject: displayObservations, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("native-display-observations.json"), options: .atomic)
            }
        }
        func record(_ phase: String) throws {
            reports[phase] = state.playbackDiagnostics?.redactedJSON()
            try JSONEncoder().encode(reports).write(to: folder.appendingPathComponent("native-dolby-results.json"), options: .atomic)
        }
        var media: UUID?
        for (name, route, seek) in [("grinch-p7.mkv", PlaybackDolbyVision.Route.reconstructedFEL, 20.0),
                                  ("p5.mp4", .reconstructed, 1.0), ("p81-a.mp4", .reconstructed, 1.0)] {
            await engine.play(spec: PlaySpec(url: folder.appendingPathComponent(name).absoluteString))
            try #require(await wait { state.playbackDiagnostics?.video.dolbyVision?.route == route })
            let info = try #require(state.playbackDiagnostics)
            #expect(info.ffmpegVersion == "9.0.1")
            #expect(info.mediaID != media); media = info.mediaID
            #expect(info.video.dolbyVision?.dynamicMappingApplied == true)
            #expect(info.video.dolbyVision?.renderer?.failures == 0)
            #expect(info.audio.nativeAudio == nil)
            engine.pause(); engine.seek(to: Int64(seek * 1_000))
            try #require(await wait { !state.isPlaying && abs(state.position - seek) < 0.2 })
            #expect(state.playbackDiagnostics?.video.dolbyVision?.route == route)
            let paused = state.position
            try await Task.sleep(for: .milliseconds(250))
            #expect(abs(state.position - paused) < 0.1)
              let previewData = try #require(await PlayerChapterThumbnailDecoder().imageData(
                  spec: PlaySpec(url: folder.appendingPathComponent(name).absoluteString), seconds: seek))
              let preview = try #require(NSBitmapImageRep(data: previewData))
              #expect(preview.pixelsWide == 320 && preview.pixelsHigh == 180)
              #expect(state.playbackDiagnostics?.mediaID == media)
              #expect(!state.isPlaying && abs(state.position - paused) < 0.1)
            if name == "grinch-p7.mkv", (window.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1.01 {
                color.set(.init(videoOutput: .automatic))
                let hdrReady = await wait { state.playbackDiagnostics?.display.edrEnabled == true }
                try record("fel-automatic-hdr-attempt")
                try #require(hdrReady)
                #expect(state.playbackDiagnostics?.display.targetFormat == "GL_RGBA16F / rgba16Float")
                #expect(state.playbackDiagnostics?.display.videoOutput?.hdrRestrictions.isEmpty == true)
                #expect(!state.isPlaying && abs(state.position - paused) < 0.1)
                try record("fel-automatic-hdr")
                color.set(.init(videoOutput: .sdr))
                try #require(await wait { state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" })
                #expect(state.playbackDiagnostics?.video.dolbyVision?.route == .reconstructedFEL)
            }
            engine.resume()
            try #require(await wait { state.isPlaying && state.position > seek + 0.5 })
            try record(name)
        }
        await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("p5-no-rpu.mp4").absoluteString))
        try #require(await wait { state.playbackDiagnostics?.video.dolbyVision?.route.blocksVideo == true })
        #expect(state.playbackDiagnostics?.video.dolbyVision?.dynamicMappingApplied == false)
        try record("missing-rpu-blocked")

        await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("players-eac3-joc.mkv").absoluteString))
        try #require(await wait { state.playbackDiagnostics?.audio.mode == .nativeCompressed })
        #expect(state.playbackDiagnostics?.audio.nativeAudio?.joc == true)
        #expect(state.playbackDiagnostics?.audio.nativeAudio?.sampleRate == 48_000)
        #expect(state.playbackDiagnostics?.audio.outputDriver == "avfoundation")
        #expect(state.playbackDiagnostics?.video.codec == "h264")
        try record("joc-native")
        engine.pause(); engine.seek(to: 20_000)
        try #require(await wait { !state.isPlaying && abs(state.position - 20) < 0.2 })
        let paused = state.position
        output.set(.init(dolbyAudio: .pcm))
        try #require(await wait { state.playbackDiagnostics?.audio.mode == .pcm })
        #expect(!state.isPlaying && abs(state.position - paused) < 0.3)
        #expect(state.isMuted && state.volume == 0.25)
        try record("joc-pcm-override")
        output.set(.init())
        // Paused AOs are selected but intentionally receive no packets until
        // resume. Treating that state as a device failure prevents resuming.
        let restored = await wait { state.playbackDiagnostics?.audio.mode == .nativeCompressedPreparing }
        try record("joc-restore-attempt")
        try #require(restored)
        #expect(!state.isPlaying && abs(state.position - paused) < 0.3)
        engine.resume()
        try #require(await wait { state.isPlaying && state.position > 21 &&
            state.playbackDiagnostics?.audio.mode == .nativeCompressed })
        try record("joc-native-restored")
        engine.speed = 1.5
        try #require(await wait { state.speed == 1.5 && state.position > 23 &&
            state.playbackDiagnostics?.audio.mode == .pcm })
        #expect(state.audioOutputMessage == nil)
        try record("joc-speed-change")
        engine.speed = 1
        try #require(await wait { state.playbackDiagnostics?.audio.mode == .nativeCompressed })
        dialogue.set(.light)
        try #require(await wait { state.playbackDiagnostics?.audio.mode == .pcm &&
            state.playbackDiagnostics?.audio.dialogue?.filterConfirmed == true &&
            state.playbackDiagnostics?.audio.dialogue?.status == .center })
        try record("joc-dialogue-pcm")
        dialogue.reset()
        try #require(await wait { state.playbackDiagnostics?.audio.mode == .nativeCompressed &&
            state.playbackDiagnostics?.audio.dialogue?.status == .off })
        try record("joc-controls-restored")
        if let devices = await PlaybackAudioDeviceProbeWorker.snapshot(),
           let builtIn = devices.outputs.first(where: { $0.transport == .builtIn }) {
            engine.pause()
            let position = state.position
            output.set(.init(deviceUID: builtIn.id))
            try #require(await wait { state.playbackDiagnostics?.audio.routeStatus == .selected &&
                state.playbackDiagnostics?.audio.mode == .nativeCompressedPreparing })
            #expect(!state.isPlaying && abs(state.position - position) < 0.3)
            engine.resume()
            try #require(await wait { state.playbackDiagnostics?.audio.mode == .nativeCompressed &&
                state.playbackDiagnostics?.audio.deviceTransport == .builtIn })
            try record("joc-built-in-device")
            output.reset()
            try #require(await wait { state.playbackDiagnostics?.audio.routeStatus == .automatic &&
                state.playbackDiagnostics?.audio.mode == .nativeCompressed })
            try record("joc-default-device-restored")
        }
          // Return from the ordinary-video/native-audio path to Dolby in the
          // same render context; stale queue state must not black out the frame.
          await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("p5.mp4").absoluteString))
          try #require(await wait { state.playbackDiagnostics?.video.dolbyVision?.route == .reconstructed })
          #expect(state.playbackDiagnostics?.video.dolbyVision?.renderer?.failures == 0)
          #expect(state.playbackDiagnostics?.audio.nativeAudio == nil)
          try record("dolby-restored-after-joc")
        engine.stop()
        try #require(await wait { state.currentSpec == nil && state.playbackDiagnostics == nil })
    }

    @MainActor private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate(), ContinuousClock.now < deadline {
            // Swift Testing does not run NSApplication's normal event loop.
            // Commit the actual layer tree so WindowServer sees EDR requests.
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }
}
