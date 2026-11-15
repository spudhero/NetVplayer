import AppKit
import CoreAudio
import Foundation
import Models
import QuartzCore
import Storage
import Testing
@testable import PlayerEngine

/// Opt-in hardware regression, using a local E-AC-3 JOC fixture and isolated
/// preferences. HAL transport observations do not establish receiver Atmos lock.
@Suite(.serialized) struct PlaybackHDMITransportTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_HDMI_PCM_FIXTURES"] != nil))
    func sourcePCMChangesRealHDMIClockAndRestoresAfterEachStop() async throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try #require(environment["NETVPLAYER_HDMI_PCM_FIXTURES"]))
        let devices = try #require(await PlaybackAudioDeviceProbeWorker.snapshot())
        let receiver = try #require(devices.outputs.first { $0.id == devices.systemDefaultUID && $0.transport == .hdmi })
        let baseline = try #require(HDMITestHAL.snapshot(uid: receiver.id))
        try #require(baseline.hogPID == -1 && baseline.streams.allSatisfy { $0.physical?.formatID == "lpcm" })
        let suite = "HDMIPCMRate.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
        volume.setMuted(true)
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        output.set(.init(deviceUID: receiver.id, dolbyAudio: .pcm, pcmSampleRate: .source))
        let color = PlaybackColorPreferenceStore(defaults: defaults)
        color.set(.init(videoOutput: .sdr))
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod, stopResourcePolicy: .fullDestroy,
            audioPreferences: volume, audioOutputPreferences: output,
            dialoguePreferences: .init(defaults: defaults), colorPreferences: color)
        let state = PlayerState(); engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        var observations: [HDMITestObservation] = []
        func record(_ phase: String) throws {
            observations.append(.init(phase: phase, state: state, engine: engine,
                                      hal: HDMITestHAL.snapshot(uid: receiver.id)))
            if let report = environment["NETVPLAYER_HDMI_PCM_REPORT"] {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(observations).write(to: URL(fileURLWithPath: report), options: .atomic)
            }
        }
        func restored() -> Bool {
            guard let hal = HDMITestHAL.snapshot(uid: receiver.id) else { return false }
            return hal.hogPID == -1 && hal.streams.map(\.physical) == baseline.streams.map(\.physical)
        }
        defer { engine.stop(); try? record("cleanup"); engine.detach(from: view); window.orderOut(nil) }
        try record("baseline")
        for rate in [44_100, 96_000, 192_000] {
            let fixture = folder.appendingPathComponent("pcm-\(rate).wav")
            try #require(FileManager.default.fileExists(atPath: fixture.path))
            await engine.play(spec: PlaySpec(url: fixture.absoluteString))
            let ready = await wait {
                state.playbackDiagnostics?.audio.outputSampleRate == rate && state.position > 1 &&
                    HDMITestHAL.snapshot(uid: receiver.id)?.streams.allSatisfy { $0.physical?.sampleRate == Double(rate) } == true
            }
            try record("\(rate)-ready")
            try #require(ready, "Compare PCM AO and HAL readback in NETVPLAYER_HDMI_PCM_REPORT")
            let media = state.playbackDiagnostics?.mediaID
            let start = state.position
            // Probe updates must not make the new device clock trigger an AO
            // reset loop. Check stable progress over multiple probe intervals.
            for index in 0..<6 {
                try await Task.sleep(for: .milliseconds(500))
                try record("\(rate)-stable-\(index)")
                #expect(state.playbackDiagnostics?.mediaID == media && state.isPlaying)
                #expect(state.playbackDiagnostics?.audio.outputSampleRate == rate)
                #expect(HDMITestHAL.snapshot(uid: receiver.id)?.streams.allSatisfy { $0.physical?.sampleRate == Double(rate) } == true)
            }
            #expect(state.position > start + 2)
            engine.stop()
            let didRestore = await wait { restored() }
            try record("\(rate)-stopped")
            try #require(didRestore, "Every stop must restore the original physical HDMI format")
        }
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_HDMI_JOC_FIXTURE"] != nil))
    func hdmiJOCSurvivesPlaybackControlsAndRestoresPCMTransport() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(fileURLWithPath: try #require(environment["NETVPLAYER_HDMI_JOC_FIXTURE"]))
        try #require(FileManager.default.fileExists(atPath: fixture.path))
        let devices = try #require(await PlaybackAudioDeviceProbeWorker.snapshot())
        let receiver = try #require(devices.outputs.first {
            $0.id == devices.systemDefaultUID && $0.transport == .hdmi
        }, "The opt-in regression requires the system default output to be HDMI")
        let baseline = try #require(HDMITestHAL.snapshot(uid: receiver.id))
        try #require(baseline.hogPID == -1 && baseline.streams.allSatisfy { $0.physical?.formatID == "lpcm" },
                     "Start with an idle PCM HDMI device so restoration can be checked")
        let suite = "HDMITransport.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        let dialogue = PlaybackDialoguePreferenceStore(defaults: defaults)
        let color = PlaybackColorPreferenceStore(defaults: defaults)
        volume.setVolume(0.25); volume.setMuted(true)
        color.set(.init(videoOutput: .sdr))
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod, stopResourcePolicy: .fullDestroy,
            audioPreferences: volume, audioOutputPreferences: output,
            dialoguePreferences: dialogue, colorPreferences: color)
        let state = PlayerState(); engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.title = "NetVplayer HDMI regression (muted)"
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        // Enables the existing DEBUG observer of fresh libmpv render frames.
        // These are completed host renders, independent of time-pos/audio time.
        engine.performanceDiagnosticsHandler = { _, _ in }
        var observations: [HDMITestObservation] = []
        func record(_ phase: String) throws {
            observations.append(.init(phase: phase, state: state, engine: engine,
                                      hal: HDMITestHAL.snapshot(uid: receiver.id)))
            if let report = environment["NETVPLAYER_HDMI_REPORT"] {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(observations).write(to: URL(fileURLWithPath: report), options: .atomic)
            }
        }
        defer {
            engine.stop()
            try? record("cleanup")
            engine.performanceDiagnosticsHandler = nil
            engine.detach(from: view); window.orderOut(nil)
        }
        func nativePassthrough() -> Bool {
            state.playbackDiagnostics?.audio.mode == .passthrough &&
                engine.nativePropertyJSON("current-ao") == "\"coreaudio_exclusive\"" &&
                HDMITestHAL.snapshot(uid: receiver.id)?.isEAC3Carrier == true
        }
        func restoredPCM() -> Bool {
            guard let current = HDMITestHAL.snapshot(uid: receiver.id) else { return false }
            return current.hogPID == -1 && current.streams.map(\.physical) == baseline.streams.map(\.physical)
        }
        func waitAndRecord(_ phase: String, _ predicate: () -> Bool) async throws {
            let ready = await wait(predicate)
            try record(phase)
            try #require(ready, "HDMI regression phase failed: \(phase); inspect NETVPLAYER_HDMI_REPORT")
        }
        func stablePlayback(_ phase: String, seconds: Double = 5) async throws {
            let startPosition = state.position
            let startFrames = engine.performanceFrameSnapshot.freshFrames
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1_000)))
            var samples = 0
            while ContinuousClock.now < deadline {
                try record("\(phase)-\(samples)")
                try #require(nativePassthrough(), "HDMI passthrough must remain stable across device probe updates")
                try #require(state.isPlaying && !state.isSeeking && state.audioOutputMessage == nil)
                if let offset = state.playbackDiagnostics?.audioVideoOffsetSeconds {
                    #expect(abs(offset) < 0.25, "A/V clock offset must remain bounded after route settling")
                }
                samples += 1
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(state.position > startPosition + seconds * 0.65)
            let frameProgress = engine.performanceFrameSnapshot.freshFrames - startFrames
            #expect(Double(frameProgress) > seconds * 10, "Fresh video frames must progress independently of the audio clock")
            try #require(state.playbackDiagnostics?.audioVideoOffsetSeconds != nil)
        }

        try record("baseline")
        await engine.play(spec: PlaySpec(url: fixture.absoluteString))
        try await waitAndRecord("passthrough-ready") {
            nativePassthrough() && state.position > 2 && !state.isMediaLoading && !state.isSeeking
        }
        let media = try #require(state.playbackDiagnostics?.mediaID)
        let track = state.selectedAudioTrackID
        #expect(state.playbackDiagnostics?.audio.codec == "eac3")
        #expect(state.playbackDiagnostics?.audio.outputFormat == "spdif-eac3")
        #expect(state.playbackDiagnostics?.audio.compressedAudio?.receiverAtmos == .unverified)
        #expect(engine.nativePropertyJSON("options/ao")?.contains("coreaudio_exclusive") == true)
        try await stablePlayback("initial-stable")

        engine.pause()
        try await waitAndRecord("paused") { !state.isPlaying && nativePassthrough() }
        let paused = state.position
        try await Task.sleep(for: .milliseconds(400))
        #expect(abs(state.position - paused) < 0.15)
        engine.seek(to: 20_000)
        try await waitAndRecord("seek-paused") { !state.isPlaying && !state.isSeeking && abs(state.position - 20) < 0.2 }
        output.set(.init(dolbyAudio: .pcm))
        try await waitAndRecord("pcm-override-paused") {
            state.playbackDiagnostics?.audio.mode == .pcm && restoredPCM()
        }
        #expect(!state.isPlaying && abs(state.position - 20) < 0.3)
        output.reset()
        try await waitAndRecord("passthrough-restored-paused") { nativePassthrough() && !state.isPlaying }
        #expect(abs(state.position - 20) < 0.3)
        engine.resume()
        try await waitAndRecord("resumed") { nativePassthrough() && state.isPlaying && state.position > 21 }
        try await stablePlayback("resumed-stable")

        engine.speed = 1.5
        try await waitAndRecord("speed-pcm") {
            state.speed == 1.5 && state.playbackDiagnostics?.audio.mode == .pcm && restoredPCM()
        }
        let speedPosition = state.position
        try await waitAndRecord("speed-progress") { state.position > speedPosition + 1 }
        engine.speed = 1
        try await waitAndRecord("speed-passthrough-restored") { nativePassthrough() && state.speed == 1 }
        try await stablePlayback("speed-restored-stable")

        dialogue.set(.light)
        try await waitAndRecord("dialogue-pcm") {
            state.playbackDiagnostics?.audio.mode == .pcm && restoredPCM() &&
                state.playbackDiagnostics?.audio.dialogue?.filterConfirmed == true
        }
        dialogue.reset()
        try await waitAndRecord("dialogue-passthrough-restored") {
            nativePassthrough() && state.playbackDiagnostics?.audio.dialogue?.status == .off
        }
        try await stablePlayback("dialogue-restored-stable", seconds: 3)
        #expect(state.playbackDiagnostics?.mediaID == media && state.selectedAudioTrackID == track)
        #expect(state.isMuted && state.volume == 0.25 && output.snapshot == .init())

        // The native device UID alias must preserve AO fallback negotiation.
        // Retain the configured PCM surround layout while HAL exposes only the
        // two transport channels used to carry the compressed E-AC-3 bursts.
        output.set(.init(deviceUID: receiver.id, mode: .surround71))
        try await waitAndRecord("explicit-device-passthrough") {
            nativePassthrough() && state.playbackDiagnostics?.audio.routeStatus == .selected
        }
        try await stablePlayback("explicit-device-stable", seconds: 3)
        output.set(.init(deviceUID: receiver.id, mode: .surround71, dolbyAudio: .pcm))
        try await waitAndRecord("explicit-device-pcm-surround") {
            let audio = state.playbackDiagnostics?.audio
            let surround = (audio?.outputChannelCount == 8 && audio?.outputLayout == "7.1") ||
                (audio?.outputChannelCount == 6 && ["5.1", "5.1(side)"].contains(audio?.outputLayout ?? ""))
            return audio?.mode == .pcm && restoredPCM() && surround &&
                audio?.outputDriver == "coreaudio" && audio?.outputSampleRate == 48_000 &&
                audio?.inputChannelCount == 6 && audio?.requestedChannelLayouts == "7.1,5.1,5.1(side),stereo"
        }
        output.set(.init(deviceUID: receiver.id, mode: .surround71))
        try await waitAndRecord("explicit-device-passthrough-restored") { nativePassthrough() }
        output.reset()
        try await waitAndRecord("default-device-restored") {
            nativePassthrough() && state.playbackDiagnostics?.audio.routeStatus == .automatic
        }
        #expect(state.playbackDiagnostics?.mediaID == media && state.selectedAudioTrackID == track)
        #expect(state.isMuted && state.volume == 0.25)
        engine.stop()
        try await waitAndRecord("stopped-restored") {
            state.currentSpec == nil && state.playbackDiagnostics == nil && restoredPCM()
        }
        // Recreate the context with an explicit device already selected. This
        // catches the initial-load alias failure as well as later route changes.
        output.set(.init(deviceUID: receiver.id))
        var coldSpec = PlaySpec(url: fixture.absoluteString)
        coldSpec.mpvOptions = ["ao": "null", "audio-device": "null", "audio-spdif": ""]
        await engine.play(spec: coldSpec)
        try await waitAndRecord("explicit-device-cold-start") {
            nativePassthrough() && state.position > 2 && !state.isSeeking &&
                state.playbackDiagnostics?.audio.routeStatus == .selected
        }
        #expect(state.playbackDiagnostics?.mediaID != media)
        #expect(engine.nativePropertyJSON("options/ao")?.contains("coreaudio_exclusive") == true)
        try await stablePlayback("explicit-device-cold-stable", seconds: 3)
        engine.stop()
        try await waitAndRecord("explicit-device-cold-stop-restored") {
            state.currentSpec == nil && state.playbackDiagnostics == nil && restoredPCM()
        }
    }

    @MainActor private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate(), ContinuousClock.now < deadline {
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }
}

/// Report only typed transport/clock facts. No fixture paths, device UIDs,
/// receiver names, track titles, account preferences or network URLs are saved.
private struct HDMITestObservation: Codable {
    let phase: String
    let monotonicTime: Double
    let position: Double
    let isPlaying: Bool
    let isSeeking: Bool
    let speed: Double
    let isMuted: Bool
    let codec: String?
    let profile: String?
    let inputFormat: String?
    let outputFormat: String?
    let audioMode: PlaybackDiagnostics.AudioMode?
    let outputDriver: String?
    let inputLayout: String?
    let inputChannelCount: Int?
    let outputLayout: String?
    let outputChannelCount: Int?
    let outputSampleRate: Int?
    let requestedChannelLayouts: String?
    let currentAO: String?
    let freshVideoFrames: Int
    let audioVideoOffsetSeconds: Double?
    let decoderDroppedFrames: Int?
    let rendererDroppedFrames: Int?
    let hal: HDMITestHAL.Snapshot?

    @MainActor init(phase: String, state: PlayerState, engine: MPVPlayerEngine, hal: HDMITestHAL.Snapshot?) {
        self.phase = phase; monotonicTime = ProcessInfo.processInfo.systemUptime
        position = state.position; isPlaying = state.isPlaying; isSeeking = state.isSeeking
        speed = Double(state.speed); isMuted = state.isMuted
        let info = state.playbackDiagnostics
        codec = info?.audio.codec; profile = info?.audio.profile
        inputFormat = info?.audio.inputFormat; outputFormat = info?.audio.outputFormat
        audioMode = info?.audio.mode; outputDriver = info?.audio.outputDriver
        inputLayout = info?.audio.inputLayout; inputChannelCount = info?.audio.inputChannelCount
        outputLayout = info?.audio.outputLayout
        outputChannelCount = info?.audio.outputChannelCount; outputSampleRate = info?.audio.outputSampleRate
        requestedChannelLayouts = info?.audio.requestedChannelLayouts
        currentAO = engine.nativePropertyJSON("current-ao").flatMap { raw in
            (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String
        }
        freshVideoFrames = engine.performanceFrameSnapshot.freshFrames
        audioVideoOffsetSeconds = info?.audioVideoOffsetSeconds
        decoderDroppedFrames = info?.decoderDroppedFrames; rendererDroppedFrames = info?.rendererDroppedFrames
        self.hal = hal
    }
}

/// Independent read-only HAL probe; deliberately does not reuse the product's
/// cached stream format diagnostics, so stale decoder facts cannot pass the test.
private enum HDMITestHAL {
    struct Format: Codable, Equatable {
        let formatID: String
        let sampleRate: Double
        let channels: UInt32
        let bitsPerChannel: UInt32
        let bytesPerFrame: UInt32
        let bytesPerPacket: UInt32
        let framesPerPacket: UInt32
        let flags: UInt32
        init(_ asbd: AudioStreamBasicDescription) {
            let bytes = [24, 16, 8, 0].map { UInt8((asbd.mFormatID >> $0) & 0xff) }
            formatID = bytes.allSatisfy { (32...126).contains($0) }
                ? String(bytes: bytes, encoding: .ascii)! : String(format: "0x%08X", asbd.mFormatID)
            sampleRate = asbd.mSampleRate; channels = asbd.mChannelsPerFrame
            bitsPerChannel = asbd.mBitsPerChannel; bytesPerFrame = asbd.mBytesPerFrame
            bytesPerPacket = asbd.mBytesPerPacket; framesPerPacket = asbd.mFramesPerPacket
            flags = asbd.mFormatFlags
        }
        var isEAC3Carrier: Bool {
            formatID == "cec3" && sampleRate == 192_000 && channels == 2 &&
                bitsPerChannel == 16 && bytesPerFrame == 4
        }
    }
    struct Stream: Codable, Equatable { let physical: Format?; let virtual: Format? }
    struct Snapshot: Codable {
        let hogPID: Int32?
        let nominalSampleRate: Double?
        let streams: [Stream]
        var isEAC3Carrier: Bool {
            hogPID == getpid() && !streams.isEmpty && streams.allSatisfy {
                $0.physical?.isEAC3Carrier == true && $0.virtual?.isEAC3Carrier == true
            }
        }
    }
    static func snapshot(uid: String) -> Snapshot? {
        guard let devices: [AudioObjectID] = array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices),
              let device = devices.first(where: { candidate in
                  let value: CFString? = scalar(candidate, kAudioDevicePropertyDeviceUID, initial: Optional<CFString>.none) ?? nil
                  return value.map { $0 as String == uid } == true
              }),
              let streams: [AudioObjectID] = array(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
              !streams.isEmpty else { return nil }
        return .init(hogPID: scalar(device, kAudioDevicePropertyHogMode, initial: Int32(-1)),
            nominalSampleRate: scalar(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)),
            streams: streams.map {
                .init(physical: scalar($0, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription()).map(Format.init),
                      virtual: scalar($0, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()).map(Format.init))
            })
    }
    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value = initial; var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }
    private static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size <= 65_536, Int(size) % MemoryLayout<T>.stride == 0 else { return nil }
        if size == 0 { return [] }
        var data = Data(count: Int(size)); let capacity = size
        let status = data.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, size == capacity else { return nil }
        return data.withUnsafeBytes { raw in
            stride(from: 0, to: Int(size), by: MemoryLayout<T>.stride).map { raw.loadUnaligned(fromByteOffset: $0, as: T.self) }
        }
    }
}
