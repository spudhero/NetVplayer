import AppKit
import AudioToolbox
import Foundation
import Models
import Storage
import Testing
@testable import PlayerEngine

@Suite struct PlaybackDSDTests {
    private func diagnostics(_ track: [String: Any], decoded: [String: Any] = [:],
                             output: [String: Any] = [:], driver: String = "coreaudio") throws -> PlaybackDiagnostics {
        let values: [String: Any] = ["current-tracks/audio": track, "audio-params": decoded,
                                     "audio-out-params": output, "current-ao": driver]
        return PlaybackDiagnostics(mediaID: UUID(), properties: try values.mapValues {
            try JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed)
        })
    }

    @Test func dsdSourceDecoderAndOutputRatesRemainIndependent() throws {
        for codec in PlaybackDSDAssessment.codecs {
            for (source, raw) in [(2_822_400, 352_800), (5_644_800, 705_600)] {
                let info = try diagnostics(["codec": codec, "demux-samplerate": raw, "demux-channel-count": 2],
                    decoded: ["format": "floatp", "samplerate": raw, "channel-count": 2],
                    output: ["format": "float", "samplerate": 48000, "channel-count": 2])
                #expect(info.audio.sourceSampleRate == source)
                #expect(info.audio.demuxSampleRate == raw)
                #expect(info.audio.inputSampleRate == raw)
                #expect(info.audio.inputFormat == "floatp")
                #expect(info.audio.sourceChannelCount == 2)
                #expect(info.audio.dsd?.processing == .decodedPCM)
                #expect(info.audio.mode == .pcm && info.audio.outputSampleRate == 48000)
                #expect(info.audio.devicePhysicalFormats == nil)
                #expect(try JSONDecoder().decode(PlaybackDiagnostics.self, from: Data(info.redactedJSON().utf8)) == info)
            }
        }
    }

    @Test func namesRatesAndUnknownCodecsNeverProveDSD() throws {
        for codec in ["pcm_f32le", "flac", "DSD128", "dsd_unknown", "dst"] {
            let info = try diagnostics(["codec": codec, "title": "Native DSD128.dsf", "demux-samplerate": 705600],
                decoded: ["format": "floatp", "samplerate": 705600], output: ["format": "s32", "samplerate": 352800])
            #expect(info.audio.dsd == nil)
            if codec == "dst" { #expect(info.audio.sourceSampleRate == nil) }
            #expect(!info.redactedJSON().contains("Native DSD128"))
        }
    }

    @Test func missingMalformedSourceAndUnconfirmedDecodeStayUnknown() throws {
        for rate: Any in [NSNull(), true, -1, 0, 352800.5, 3_072_001, "2822400"] {
            let info = try diagnostics(["codec": "dsd_lsbf_planar", "demux-samplerate": rate],
                decoded: ["format": "floatp", "samplerate": 352800], driver: "null")
            #expect(info.audio.sourceSampleRate == nil)
            #expect(info.audio.dsd?.sourceBitSampleRate == nil)
            #expect(info.audio.dsd?.processing == .decodedPCM)
            #expect(info.audio.mode == nil)
        }
        let unknown = try diagnostics(["codec": "dsd_msbf", "demux-samplerate": 352800],
                                      output: ["format": "float", "samplerate": 48000])
        #expect(unknown.audio.dsd?.processing == .unconfirmed)
        let stopped = try diagnostics([:], decoded: ["format": "floatp", "samplerate": 352800],
                                      output: ["format": "float", "samplerate": 48000])
        #expect(stopped.audio.dsd == nil && stopped.audio.inputFormat == nil && stopped.audio.inputSampleRate == nil)
        #expect(stopped.audio.mode == nil && stopped.audio.outputFormat == nil)
    }

    @Test func physicalReadbackIsBoundedAndSeparateFromVirtualFormat() throws {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let physical = try #require(PlaybackAudioDeviceProbe.streamFormat(asbd))
        #expect(physical.formatID == "lpcm" && physical.sampleRate == 48000 && physical.bitsPerChannel == 32)
        asbd.mFormatFlags = kAudioFormatFlagIsFloat
        let virtual = try #require(PlaybackAudioDeviceProbe.streamFormat(asbd))
        #expect(virtual != physical)
        asbd.mSampleRate = .nan
        #expect(PlaybackAudioDeviceProbe.streamFormat(asbd) == nil)
        asbd.mSampleRate = 48000; asbd.mChannelsPerFrame = 65
        #expect(PlaybackAudioDeviceProbe.streamFormat(asbd) == nil)
        asbd.mChannelsPerFrame = 2; asbd.mBitsPerChannel = 128
        #expect(PlaybackAudioDeviceProbe.streamFormat(asbd) == nil)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_DSD_FIXTURES"] != nil))
    func nativeDSDDecodeSeekTrackRestoreAndStop() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_DSD_FIXTURES"]))
        let report = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_DSD_OUTPUT"]))
        let before = try #require(await PlaybackAudioDeviceProbeWorker.snapshot())
        let expectedOutputRate = try #require(before.outputs.first { $0.id == before.systemDefaultUID }?.nominalSampleRate)
        let suite = "DSDNative.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
        volume.setVolume(0.2); volume.setMuted(true)
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod, audioPreferences: volume, audioOutputPreferences: output)
        let state = PlayerState(); engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
        var reports: [String: String] = [:]
        var previous: UUID?
        for (file, codec, rate) in [("original-dsd64.dsf", "dsd_lsbf_planar", 2_822_400),
                                    ("original-dsd64.dff", "dsd_msbf", 2_822_400),
                                    ("original-dsd128.dsf", "dsd_lsbf_planar", 5_644_800)] {
            await engine.play(spec: PlaySpec(url: folder.appendingPathComponent(file).absoluteString))
            try #require(await wait { state.playbackDiagnostics?.audio.dsd?.processing == .decodedPCM
                && state.playbackDiagnostics?.audio.sourceSampleRate == rate && state.playbackDiagnostics?.audio.devicePhysicalFormats != nil })
            let info = try #require(state.playbackDiagnostics)
            #expect(info.mediaID != previous); previous = info.mediaID
            #expect(info.audio.codec == codec && info.audio.inputFormat == "floatp")
            #expect(info.audio.demuxSampleRate == rate / 8 && info.audio.inputSampleRate == rate / 8)
            #expect(info.audio.sourceChannelCount == 2 && info.audio.outputChannelCount == 2)
            #expect(info.audio.outputDriver == "coreaudio" && info.audio.outputFormat == "float" && info.audio.mode == .pcm)
            #expect(info.audio.outputSampleRate == Int(expectedOutputRate))
            #expect(info.mpvVersion?.contains("0.41.0") == true && info.ffmpegVersion == "9.0.1")
            reports[file] = info.redactedJSON()
            engine.pause(); engine.seek(to: 5000)
            try #require(await wait { !state.isPlaying && abs(state.position - 5) < 0.2 })
            try await Task.sleep(for: .milliseconds(300))
            #expect(abs(state.position - 5) < 0.2)
            engine.speed = 1.5; engine.resume()
            try #require(await wait { state.isPlaying && state.speed == 1.5 && state.position > 6 })
            let clock = ContinuousClock.now
            let startPosition = state.position
            try await Task.sleep(for: .seconds(2))
            let elapsed = clock.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let measuredRate = (state.position - startPosition) / seconds
            #expect(abs(measuredRate - 1.5) < 0.2)
            reports[file + "-measured-speed"] = String(measuredRate)
            #expect(state.playbackDiagnostics?.mediaID == info.mediaID)
            #expect(volume.snapshot.isMuted)
            engine.pause(); engine.speed = 1
        }
        let owner = try #require(state.playbackDiagnostics?.mediaID)
        output.set(.init(deviceUID: "DSD-test-unavailable", mode: .surround71))
        try #require(await wait { state.playbackDiagnostics?.audio.routeStatus == .unavailableFallback
            && state.playbackDiagnostics?.audio.mode == .pcm })
        #expect(!state.isPlaying && state.playbackDiagnostics?.mediaID == owner)
        reports["simulated-missing-device"] = state.playbackDiagnostics?.redactedJSON()
        output.reset()
        engine.audioEnvironmentDidChange(sleeping: true)
        #expect(state.playbackDiagnostics?.audio.devicePhysicalFormats == nil)
        #expect(state.playbackDiagnostics?.audio.dsd == nil)
        engine.audioEnvironmentDidChange(sleeping: false)
        try #require(await wait { state.playbackDiagnostics?.audio.dsd?.processing == .decodedPCM
            && state.playbackDiagnostics?.audio.routeStatus == .automatic
            && state.playbackDiagnostics?.audio.outputSampleRate == Int(expectedOutputRate) })
        #expect(!state.isPlaying && state.playbackDiagnostics?.mediaID == owner)
        reports["simulated-wake"] = state.playbackDiagnostics?.redactedJSON()

        // Use the existing external-track selection path in the same session.
        await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("original-dsd64.dsf").absoluteString,
            externalAudioURL: folder.appendingPathComponent("DSD128-native-name-only.wav").absoluteString,
            initialStartPositionSeconds: 7))
        try #require(await wait { state.audioTracks.count == 2 && state.playbackDiagnostics?.audio.codec == "pcm_s16le" && state.position >= 7 })
        engine.pause()
        let pcmTrack = try #require(state.selectedAudioTrackID)
        let dsdTrack = try #require(state.audioTracks.first { $0.id != pcmTrack }?.id)
        let media = try #require(state.playbackDiagnostics?.mediaID)
        #expect(state.playbackDiagnostics?.audio.dsd == nil)
        engine.selectAudioTrack(id: dsdTrack)
        try #require(await wait { state.playbackDiagnostics?.audio.dsd?.sourceBitSampleRate == 2_822_400 })
        #expect(state.playbackDiagnostics?.mediaID == media && !state.isPlaying)
        reports["selected-dsd-track"] = state.playbackDiagnostics?.redactedJSON()
        engine.selectAudioTrack(id: pcmTrack)
        try #require(await wait { state.playbackDiagnostics?.audio.codec == "pcm_s16le" && state.playbackDiagnostics?.audio.dsd == nil })
        reports["returned-pcm-track"] = state.playbackDiagnostics?.redactedJSON()
        engine.stop()
        try #require(await wait { state.currentSpec == nil && state.playbackDiagnostics == nil })
        await engine.play(spec: PlaySpec(url: folder.appendingPathComponent("original-dsd128.dsf").absoluteString, initialStartPositionSeconds: 9))
        try #require(await wait { state.position >= 9 && state.playbackDiagnostics?.audio.sourceSampleRate == 5_644_800 })
        reports["reopen-resume-nine-seconds"] = state.playbackDiagnostics?.redactedJSON()
        engine.stop()
        let after = try #require(await PlaybackAudioDeviceProbeWorker.snapshot())
        #expect(before.outputs == after.outputs && before.systemDefaultUID == after.systemDefaultUID)
        struct DeviceFormats: Codable {
            let transport: PlaybackAudioOutputDevice.Transport
            let isDefault: Bool
            let virtual: [PlaybackAudioStreamFormat]?
            let physical: [PlaybackAudioStreamFormat]?
        }
        for (name, snapshot) in [("devices-before", before), ("devices-after", after)] {
            let facts = snapshot.outputs.map { DeviceFormats(transport: $0.transport, isDefault: $0.id == snapshot.systemDefaultUID,
                virtual: $0.virtualFormats, physical: $0.physicalFormats) }
            reports[name] = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self)
        }
        try JSONEncoder().encode(reports).write(to: report, options: .withoutOverwriting)
    }

    @MainActor private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }
}
