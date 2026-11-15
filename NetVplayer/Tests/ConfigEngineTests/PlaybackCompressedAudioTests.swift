import AppKit
import Foundation
import Models
import Storage
import Testing
@testable import PlayerEngine

@Suite struct PlaybackCompressedAudioTests {
    @Test func nativePacketsRequireAnActiveRendererAndKeepCarrierSeparate() throws {
        var native: [String: Any] = ["samplerate": 48_000, "channels": 6,
            "renderer-state": 1, "joc": true, "spatial-allowed": true,
            "packets": 292, "payload-bytes": 897_024, "generation": 1]
        func reading() throws -> PlaybackDiagnostics {
            let values: [String: Any] = ["current-tracks/audio": ["codec": "eac3"],
                "current-ao": "avfoundation", "netvplayer-audio": native,
                "audio-out-params": ["format": "spdif-eac3", "samplerate": 192_000, "channel-count": 2]]
            return PlaybackDiagnostics(mediaID: UUID(), properties: try values.mapValues {
                try JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed)
            })
        }
        let active = try reading()
        #expect(active.audio.mode == .nativeCompressed)
        #expect(active.audio.nativeAudio?.sampleRate == 48_000)
        #expect(active.audio.nativeAudio?.channels == 6)
        #expect(active.audio.outputSampleRate == 192_000)
        #expect(active.audio.compressedAudio?.sourceFormat == .eac3JOCParsed)
        #expect(active.audio.compressedAudio?.receiverAtmos == .unverified)
        #expect(active.audio.spatialAudio?.route == .nativeCompressed)
        let exported = try JSONDecoder().decode(PlaybackDiagnostics.self, from: Data(active.redactedJSON().utf8))
        #expect(exported.audio.nativeAudio == active.audio.nativeAudio)
        native["renderer-state"] = 0
        #expect(try reading().audio.mode == .nativeCompressedPreparing)
        native["renderer-state"] = 2
        #expect(try reading().audio.mode == nil)
        native["renderer-state"] = 1
        native["packets"] = 0
        #expect(try reading().audio.mode == .nativeCompressedPreparing)
        native["packets"] = -1
        #expect(try reading().audio.nativeAudio == nil)
        native["packets"] = 1
        native["channels"] = 99
        #expect(try reading().audio.nativeAudio == nil)
    }

    private func info(codec: String = "eac3", profile: String? = nil, format: String = "float",
                      driver: String = "coreaudio", request: Any = [String]()) throws -> PlaybackDiagnostics {
        var track = ["codec": codec, "title": "Dolby Atmos JOC TrueHD 7.1.4"]
        track["codec-profile"] = profile
        return PlaybackDiagnostics(mediaID: UUID(), properties: try [
            "current-tracks/audio": track as Any,
            "audio-out-params": ["format": format], "current-ao": driver,
            "options/audio-spdif": request
        ].mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) })
    }

    @Test func sourceProfilesNeverEstablishReceiverAtmos() throws {
        for (codec, profile, source) in [
            ("ac3", "Dolby Digital Plus + Dolby Atmos", PlaybackCompressedAudioAssessment.SourceFormat.ac3),
            ("eac3", "", .eac3), ("eac3", "Atmos", .eac3),
            ("eac3", "Dolby Digital Plus + Dolby Atmos", .eac3JOCReported),
            ("truehd", "", .trueHD), ("truehd", "Dolby TrueHD + Dolby Atmos", .trueHDAtmosReported),
            ("dts", "DTS-HD MA", .dtsHD), ("dts", "DTS-HD MA + DTS:X", .dtsHD),
            ("dts", "DTS-HD HRA", .dtsHD), ("dts", "DTS Express", .dtsHD),
            ("dts", "DTS", .dts), ("dts", "Atmos DTS-HD movie", .dts),
            ("aac", "Dolby Digital Plus + Dolby Atmos", .other)
        ] {
            let assessment = try #require(info(codec: codec, profile: profile).audio.compressedAudio)
            #expect(assessment.sourceFormat == source)
            #expect(assessment.output == .decodedPCM)
            #expect(assessment.receiverAtmos == .unverified)
        }
    }

    @Test func requestsAndEngineBitstreamsDoNotConfirmAReceiver() throws {
        for request: Any in [["eac3", "truehd"], "ac3", "all"] {
            let pcm = try #require(info(request: request).audio.compressedAudio)
            #expect(pcm.passthroughRequest == .requested && pcm.output == .decodedPCM)
            let encoded = try #require(info(format: "spdif-eac3", request: request).audio.compressedAudio)
            #expect(encoded.output == .encodedStreamObserved && encoded.receiverAtmos == .unverified)
        }
        #expect(try info(request: "").audio.compressedAudio?.passthroughRequest == .disabled)
        #expect(try info(request: [String: String]()).audio.compressedAudio?.passthroughRequest == .unknown)
        #expect(try info(format: "spdif-eac3", driver: "null").audio.compressedAudio?.output == .unknown)
        #expect(try info(format: "unknown").audio.compressedAudio?.output == .unknown)
        let empty = PlaybackDiagnostics(mediaID: UUID(), properties: [:])
        #expect(empty.audio.compressedAudio == nil)
    }

    @Test func profileAndRequestsStayWithinRedactedTypedFacts() throws {
        let secret = "https://account:password@private.invalid/movie?token=secret"
        let reading = try info(profile: secret, request: [secret])
        #expect(reading.audio.profile == nil)
        #expect(reading.audio.compressedAudio?.sourceFormat == .eac3)
        let exported = reading.redactedJSON()
        for forbidden in ["private.invalid", "password", "secret", "7.1.4"] { #expect(!exported.contains(forbidden)) }
        #expect(exported.contains("unverified") && exported.utf8.count < 16_384)
        let roundTrip = try JSONDecoder().decode(PlaybackDiagnostics.self, from: Data(exported.utf8))
        #expect(roundTrip.audio.compressedAudio == reading.audio.compressedAudio)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_COMPRESSED_AUDIO_FIXTURES"] != nil))
    func nativeBundledPCMAndSourceOverrideControls() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_COMPRESSED_AUDIO_FIXTURES"]))
        let suite = "CompressedAudioNative.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        output.set(.init(dolbyAudio: .pcm))
        let dialogue = PlaybackDialoguePreferenceStore(defaults: defaults)
        volume.setVolume(0.37); volume.setMuted(true)
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod, audioPreferences: volume,
                                     audioOutputPreferences: output, dialoguePreferences: dialogue)
        let state = PlayerState(); engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
        var reports: [String: String] = [:]
        var previous: UUID?
        for codec in ["ac3", "eac3", "truehd"] {
            await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("av09-\(codec).mkv").absoluteString,
                mpvOptions: ["audio-spdif": "ac3,eac3,truehd", "audio-exclusive": "yes", "audio-format": "spdif-eac3"]))
            try #require(await wait {
                state.playbackDiagnostics?.audio.codec == codec && state.playbackDiagnostics?.audio.mode == .pcm
                    && state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8"
            })
            let info = try #require(state.playbackDiagnostics)
            #expect(info.mpvVersion?.contains("0.41.0") == true && info.ffmpegVersion == "9.0.1")
            #expect(info.audio.inputChannelCount == 6 && info.audio.inputSampleRate == 48000)
            #expect(info.audio.outputChannelCount == 2 && info.audio.outputSampleRate == 48000)
            #expect(info.audio.outputDriver == "coreaudio" && info.audio.outputFormat == "float")
            #expect(info.audio.compressedAudio?.passthroughRequest == .disabled)
            #expect(info.audio.compressedAudio?.receiverAtmos == .unverified)
            #expect(info.audio.spatialAudio?.route == .coreAudioPCM)
            #expect(info.audio.spatialAudio?.applicationBinaural == .notEnabled)
            #expect(info.audio.spatialAudio?.systemSpatialAudio == .unverified)
            #expect(info.audio.spatialAudio?.headTracking == .unverified)
            #expect(info.audio.spatialAudio?.atmosRendering == .unverified)
            #expect(info.mediaID != previous); previous = info.mediaID
            #expect(state.isMuted && state.volume == 0.37)
            engine.pause(); engine.seek(to: 5_000)
            try #require(await wait { !state.isPlaying && abs(state.position - 5) < 0.3 })
            engine.speed = 1.5
            engine.setVolume(0.25); engine.setMuted(false)
            #expect(volume.snapshot.volume == 0.25 && !volume.snapshot.isMuted)
            engine.setMuted(true)
            if codec == "eac3" {
                dialogue.set(.light)
                try #require(await wait { state.playbackDiagnostics?.audio.dialogue?.filterConfirmed == true
                    && state.playbackDiagnostics?.audio.dialogue?.status == .center })
                #expect(dialogue.snapshot == .light)
                #expect(state.playbackDiagnostics?.audio.spatialAudio?.applicationBinaural == .notEnabled)
                reports["eac3-dialogue"] = state.playbackDiagnostics?.redactedJSON()
                dialogue.reset()
                try #require(await wait { state.playbackDiagnostics?.audio.dialogue?.status == .off })
            }
            engine.resume()
            try #require(await wait { state.isPlaying && state.position > 6 && state.speed == 1.5 })
            #expect(state.playbackDiagnostics?.mediaID == info.mediaID)
            #expect(state.playbackDiagnostics?.audio.mode == .pcm)
            reports[codec] = state.playbackDiagnostics?.redactedJSON()
            engine.pause(); engine.speed = 1
            engine.setVolume(0.37); engine.setMuted(true)
        }
        try JSONEncoder().encode(reports).write(to: folder.appendingPathComponent("native-compressed-audio.json"))
        engine.stop()
        try #require(await wait { state.currentSpec == nil })
        #expect(state.playbackDiagnostics == nil)
        #expect(output.snapshot == .init(dolbyAudio: .pcm) && dialogue.snapshot == .off)
    }

    @MainActor private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }
}
