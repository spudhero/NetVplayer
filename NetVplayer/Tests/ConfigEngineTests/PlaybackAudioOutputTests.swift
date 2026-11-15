import AppKit
import Foundation
import Models
import Storage
import Testing
@testable import PlayerEngine

@Suite(.serialized) struct PlaybackAudioOutputTests {
    @Test func rejectedCompressedOutputRecoversAfterPersistentMissingAO() {
        let stalled = PlaybackDiagnostics.Audio(codec: "truehd", inputFormat: "spdif-truehd")
        var recovery = PlaybackCompressedAudioRecovery()
        func observe(_ now: TimeInterval) -> Bool {
            recovery.shouldRecover(audio: stalled, nativeRequested: true, now: now)
        }
        #expect(!observe(0))
        #expect(!observe(5))
        recovery.observeLog(prefix: "ao/avfoundation", text: "avfoundation does not support SPDIF")
        #expect(!observe(6))
        #expect(!observe(6.5))
        #expect(observe(7))
        #expect(recovery.requiresPCM)
        #expect(!observe(8))
        recovery = .init()
        #expect(!recovery.requiresPCM)
        #expect(!observe(20))
    }

    @Test func transientMissingOutputAndSuccessfulNativeRoutesDoNotForcePCM() {
        let stalled = PlaybackDiagnostics.Audio(codec: "truehd", inputFormat: "spdif-truehd")
        var recovery = PlaybackCompressedAudioRecovery()
        func observe(_ audio: PlaybackDiagnostics.Audio, _ now: TimeInterval, nativeRequested: Bool = true) -> Bool {
            recovery.shouldRecover(audio: audio, nativeRequested: nativeRequested, now: now)
        }
        recovery.observeLog(prefix: "ao/coreaudio_exclusive", text: "No usable substream found.")
        #expect(!observe(stalled, 0))
        #expect(!observe(stalled, 5))
        recovery.observeLog(prefix: "ao/avfoundation", text: "avfoundation does not support SPDIF")
        #expect(!observe(stalled, 6))
        let native = PlaybackDiagnostics.Audio(codec: "eac3", inputFormat: "spdif-eac3",
            outputFormat: "spdif-eac3", outputDriver: "avfoundation", mode: .nativeCompressed)
        #expect(!observe(native, 7))
        #expect(!observe(stalled, 8))
        let pcm = PlaybackDiagnostics.Audio(codec: "truehd", inputFormat: "s32",
            outputFormat: "float", outputDriver: "coreaudio", mode: .pcm)
        #expect(!observe(pcm, 9))
        #expect(!observe(stalled, 10, nativeRequested: false))
        #expect(!recovery.requiresPCM)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_TRUEHD_RECOVERY_FIXTURE"] != nil))
    func nativeTrueHDRecoveryPreservesPausedSessionAndPreferences() async throws {
        let file = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_TRUEHD_RECOVERY_FIXTURE"])
        let suite = "TrueHDRecovery.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
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
        var spec = PlaySpec(url: URL(fileURLWithPath: file).absoluteString)
        spec.initialStartPositionSeconds = 2
        await engine.play(spec: spec)
        try #require(await wait {
            state.playbackDiagnostics?.audio.inputFormat == "spdif-truehd"
                && state.playbackDiagnostics?.audio.outputDriver == nil
        })
        engine.pause()
        let media = try #require(state.playbackDiagnostics?.mediaID)
        let track = state.selectedAudioTrackID
        try #require(await wait { state.playbackDiagnostics?.audio.mode == .pcm })
        #expect(state.playbackDiagnostics?.audio.codec == "truehd")
        #expect(state.playbackDiagnostics?.audio.outputDriver == "coreaudio")
        #expect(state.playbackDiagnostics?.mediaID == media)
        #expect(state.selectedAudioTrackID == track)
        #expect(!state.isPlaying && state.isMuted && state.volume == 0.25)
        #expect(abs(state.position - 2) < 0.2)
        #expect(output.snapshot == .init())
        // History restoration can reapply the already selected track after
        // decoder metadata changes. That must not retire a successful fallback.
        engine.selectAudioTrack(id: try #require(track))
        let stableUntil = ContinuousClock.now.advanced(by: .seconds(2.2))
        while ContinuousClock.now < stableUntil {
            try #require(state.playbackDiagnostics?.audio.mode == .pcm,
                         "Reselecting the same track must preserve the active PCM output")
            try await Task.sleep(for: .milliseconds(50))
        }
        engine.resume()
        try #require(await wait { state.position > 3 && !state.isMediaLoading && !state.isSeeking })
        #expect(state.playbackDiagnostics?.audio.mode == .pcm)
        #expect(state.playbackDiagnostics?.mediaID == media)
    }

    /// Requires a local TrueHD video fixture of at least 60 seconds.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_TRUEHD_DEVICE_SWITCH_FIXTURE"] != nil))
    func nativeTrueHDDeviceChangesRecoverWhileVideoIsPlaying() async throws {
        let environment = ProcessInfo.processInfo.environment
        let file = try #require(environment["NETVPLAYER_TRUEHD_DEVICE_SWITCH_FIXTURE"])
        let devices = try #require(await PlaybackAudioDeviceProbeWorker.snapshot())
        let builtIn = try #require(devices.outputs.first { $0.transport == .builtIn })
        let suite = "TrueHDDeviceChanges.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
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
            if let path = environment["NETVPLAYER_AUDIO_SWITCH_REPORT"] {
                try JSONEncoder().encode(reports).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        var spec = PlaySpec(url: URL(fileURLWithPath: file).absoluteString)
        spec.initialStartPositionSeconds = 30
        await engine.play(spec: spec)
        let started = await wait { state.playbackDiagnostics?.audio.mode == .pcm && state.position > 31 }
        try record("initial-playing")
        try #require(started)
        let media = try #require(state.playbackDiagnostics?.mediaID)
        let track = state.selectedAudioTrackID
        var targets: [PlaybackAudioOutputDevice?] = [builtIn]
        if let display = devices.outputs.first(where: { $0.transport == .displayPort }) { targets.append(display) }
        targets += [nil, builtIn]
        for (index, target) in targets.enumerated() {
            let position = state.position
            let startedAt = ProcessInfo.processInfo.systemUptime
            let expected = target ?? devices.outputs.first { $0.id == devices.systemDefaultUID }
            output.set(.init(deviceUID: target?.id))
            let recovered = await wait { state.playbackDiagnostics?.audio.mode == .pcm &&
                state.playbackDiagnostics?.audio.routeStatus == (target == nil ? .automatic : .selected) &&
                state.playbackDiagnostics?.audio.deviceName == expected?.name &&
                state.volumeControl == .player &&
                state.position > position + 1 && state.audioOutputMessage == nil }
            try record("playing-switch-\(index)")
            try #require(recovered)
            #expect(state.playbackDiagnostics?.audio.outputDriver == "coreaudio")
            #expect(state.playbackDiagnostics?.mediaID == media)
            #expect(state.selectedAudioTrackID == track)
            #expect(state.isPlaying && state.isMuted && state.volume == 0.25 && state.speed == 1)
            #expect(state.position <= position + ProcessInfo.processInfo.systemUptime - startedAt + 0.5)
            #expect(output.snapshot == .init(deviceUID: target?.id))
        }
        engine.pause()
        try #require(await wait { !state.isPlaying })
        let paused = state.position
        output.reset()
        let pausedRecovery = await wait { state.playbackDiagnostics?.audio.mode == .pcm &&
            state.playbackDiagnostics?.audio.routeStatus == .automatic && state.volumeControl == .player }
        try record("paused-switch")
        try #require(pausedRecovery)
        #expect(!state.isPlaying && abs(state.position - paused) < 0.3)
        engine.resume()
        try #require(await wait { state.position > paused + 1 && state.playbackDiagnostics?.audio.mode == .pcm })
        try record("resumed")
        #expect(state.playbackDiagnostics?.mediaID == media)
    }

    @MainActor @Test func incompleteAudioObservationsDoNotFailAValidatedRoute() throws {
        let suite = "AudioObservation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        output.set(.init(deviceUID: "receiver"))
        let engine = MPVPlayerEngine(videoSurface: .vod, audioPreferences: .init(defaults: defaults),
            audioOutputPreferences: output, dialoguePreferences: .init(defaults: defaults),
            colorPreferences: .init(defaults: defaults))
        let state = PlayerState(); engine.playerState = state
        let receiver = device(surround)
        engine.receiveAudioDevices(.init(enumerationSucceeded: true, outputs: [receiver], systemDefaultUID: receiver.id))
        for driver in [nil, "avfoundation"] as [String?] {
            for _ in 0..<4 {
                var preparing = PlaybackDiagnostics.Audio(codec: "eac3", outputDriver: driver)
                #expect(engine.updateAudioDiagnostics(&preparing))
                #expect(preparing.routeStatus == .selected)
                #expect(state.audioOutputMessage == nil)
            }
        }
        engine.receiveAudioDevices(.init())
        var valid = PlaybackDiagnostics.Audio(codec: "eac3", outputDriver: "avfoundation", mode: .nativeCompressed)
        #expect(engine.updateAudioDiagnostics(&valid))
        #expect(valid.routeStatus == .selected)
        #expect(state.audioOutputDevices == [receiver])
        // A successful enumeration with the selected device absent still falls back.
        engine.receiveAudioDevices(.init(enumerationSucceeded: true))
        #expect(engine.updateAudioDiagnostics(&valid))
        #expect(valid.routeStatus == .unavailableFallback)
        // A confirmed null sink must still block playback.
        var failed = PlaybackDiagnostics.Audio(codec: "eac3", outputDriver: "null")
        for _ in 0..<2 { _ = engine.updateAudioDiagnostics(&failed) }
        #expect(state.audioOutputMessage != nil)
    }

    @Test func dolbyRoutingRequiresRuntimeCapabilityAndPreservesSelectedDevice() {
        let receiver = device(surround)
        let snapshot = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [receiver], systemDefaultUID: receiver.id)
        let preference = PlaybackAudioOutputPreference(deviceUID: receiver.id)
        let native = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: snapshot, nativeDolbyAvailable: true)
        #expect(native.device == "netvplayer/receiver")
        #expect(native.options["ao"] == "coreaudio_exclusive,avfoundation,coreaudio")
        #expect(native.options["audio-spdif"] == "eac3,truehd")
        #expect(native.options["coreaudio-spdif-only"] == "yes")
        #expect(native.options["coreaudio-truehd-mat"] == nil)
        let mat = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: snapshot,
            nativeDolbyAvailable: true, nativeTrueHDMATAvailable: true)
        #expect(mat.options["coreaudio-truehd-mat"] == "yes")
        let legacy = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: snapshot)
        #expect(legacy.device == "coreaudio/receiver")
        #expect(legacy.options["coreaudio-spdif-only"] == nil)
        #expect(legacy.options["audio-spdif"] == "")
        let pcm = PlaybackAudioOutputPolicy.resolve(preference: .init(deviceUID: receiver.id, dolbyAudio: .pcm), devices: snapshot,
            nativeDolbyAvailable: true, nativeTrueHDMATAvailable: true)
        #expect(pcm.options["coreaudio-truehd-mat"] == "no")
        #expect(pcm.options["audio-spdif"] == "")
        #expect(pcm.options["ao"] == "coreaudio")
        let processing = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: snapshot,
            nativeDolbyAvailable: true, requiresPCM: true)
        #expect(processing.device == "coreaudio/receiver")
        #expect(processing.options["audio-spdif"] == "")
    }

    @Test func compressedHDMICarrierDoesNotReplacePCMClockOrSurroundCapacity() {
        let receiver = device(surround + ["SL", "SR"])
        let pcm = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [receiver], systemDefaultUID: receiver.id)
        let carrier = PlaybackAudioStreamFormat(formatID: "cec3", sampleRate: 192_000,
            channels: 2, bitsPerChannel: 16, bytesPerFrame: 4, flags: 76)
        let raw = PlaybackAudioOutputDevice(id: receiver.id, name: receiver.name, transport: .hdmi,
            channelCapacity: 2, preferredChannels: ["FL", "FR"], nominalSampleRate: 192_000,
            reportedLatencySeconds: 0.005, bufferFrames: 512, virtualFormats: [carrier], physicalFormats: [carrier])
        let observed = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [raw], systemDefaultUID: raw.id)
        let planning = observed.retainingPCMConfiguration(from: pcm)
        let preference = PlaybackAudioOutputPreference(deviceUID: receiver.id, mode: .surround71)
        let before = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: pcm, nativeDolbyAvailable: true)
        let during = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: planning, nativeDolbyAvailable: true)
        // A device probe must not cause an AO reload or turn a two-channel IEC
        // carrier into a stereo speaker configuration / 192 kHz PCM resampler.
        #expect(during.options == before.options)
        let fallback = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: planning,
            nativeDolbyAvailable: true, requiresPCM: true)
        #expect(fallback.channels == "7.1,5.1,5.1(side),stereo")
        #expect(fallback.sampleRate == 48_000)
        #expect(fallback.device == "coreaudio/receiver")
        let stereo = PlaybackAudioOutputPolicy.resolve(preference: .init(deviceUID: receiver.id, mode: .stereo),
            devices: planning, nativeDolbyAvailable: true, requiresPCM: true)
        #expect(stereo.channels == "stereo")
        #expect(observed.outputs[0].channelCapacity == 2 && observed.outputs[0].nominalSampleRate == 192_000)
        #expect(observed.outputs[0].preferredChannels == ["FL", "FR"])
        #expect(planning.outputs[0].preferredChannels == receiver.preferredChannels)
        #expect(planning.outputs[0].physicalFormats == [carrier])
        // Repeated carrier observations retain the original PCM configuration.
        #expect(observed.retainingPCMConfiguration(from: planning) == planning)
        // The cache never invents a PCM layout for an unknown device.
        #expect(observed.retainingPCMConfiguration(from: .init()) == observed)
    }

    @Test func compressedPlanningPreservesRealLayoutDefaultAndDeviceChanges() {
        let old = device(surround + ["SL", "SR"])
        let before = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [old], systemDefaultUID: old.id)
        let carrier = PlaybackAudioStreamFormat(formatID: "cec3", sampleRate: 192_000,
            channels: 2, bitsPerChannel: 16, bytesPerFrame: 4, flags: 76)
        let changed = PlaybackAudioOutputDevice(id: old.id, name: old.name, transport: .hdmi,
            channelCapacity: 2, preferredChannels: surround, nominalSampleRate: 192_000,
            reportedLatencySeconds: nil, bufferFrames: nil, virtualFormats: [carrier], physicalFormats: [carrier])
        let observed = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [changed], systemDefaultUID: "other")
        let planning = observed.retainingPCMConfiguration(from: before)
        #expect(planning.systemDefaultUID == "other")
        #expect(planning.outputs[0].preferredChannels == surround)
        let selected = PlaybackAudioOutputPolicy.resolve(preference: .init(deviceUID: old.id, mode: .surround71),
            devices: planning, nativeDolbyAvailable: true)
        #expect(selected.channels == "5.1,stereo")
        let removed = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true).retainingPCMConfiguration(from: planning)
        #expect(removed.outputs.isEmpty)
        let ordinaryPCM = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true,
            outputs: [.init(id: old.id, name: old.name, transport: .hdmi, channelCapacity: 2,
                preferredChannels: ["FL", "FR"], nominalSampleRate: 96_000,
                reportedLatencySeconds: nil, bufferFrames: nil)], systemDefaultUID: old.id)
        #expect(ordinaryPCM.retainingPCMConfiguration(from: planning) == ordinaryPCM)
    }

    @Test func sourceAudioOptionsCannotOverridePCMOrNativeUserRoutes() {
        var spec = PlaySpec(url: "file:///fixture.mp4")
        spec.mpvOptions = ["ao": "null", "audio-device": "null", "audio-spdif": "truehd", "audio-exclusive": "yes"]
        let receiver = device(surround)
        let devices = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [receiver], systemDefaultUID: receiver.id)
        for dolby in [PlaybackDolbyAudioMode.automatic, .pcm] {
            let route = PlaybackAudioOutputPolicy.resolve(preference: .init(deviceUID: receiver.id, dolbyAudio: dolby),
                devices: devices, nativeDolbyAvailable: true)
            let resolved = MPVOptionPolicy.resolve(spec: spec, user: route.options, session: [:])
            #expect(resolved["ao"]?.value == route.options["ao"] && resolved["ao"]?.origin == .user)
            #expect(resolved["audio-device"]?.value == route.device)
            #expect(resolved["audio-spdif"]?.value == route.options["audio-spdif"])
            #expect(resolved["audio-exclusive"]?.value == "no")
        }
    }

    @Test func olderRuntimeKeepsDTSCoreAndProcessingCanStillDecode() {
        let receiver = device(surround)
        let snapshot = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [receiver], systemDefaultUID: receiver.id)
        let preference = PlaybackAudioOutputPreference(deviceUID: receiver.id, dolbyAudio: .passthrough)
        let encoded = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: snapshot, nativeDolbyAvailable: true)
        #expect(encoded.options["audio-spdif"] == "ac3,eac3,truehd,dts")
        #expect(!encoded.options["audio-spdif"]!.contains("dts-hd"))
        #expect(encoded.device == "netvplayer/receiver")
        for unavailable in [
            PlaybackAudioOutputPolicy.resolve(preference: preference, devices: snapshot),
            PlaybackAudioOutputPolicy.resolve(preference: preference, devices: snapshot,
                nativeDolbyAvailable: true, requiresPCM: true),
            PlaybackAudioOutputPolicy.resolve(preference: .init(dolbyAudio: .pcm), devices: snapshot,
                nativeDolbyAvailable: true)
        ] {
            #expect(unavailable.options["audio-spdif"] == "")
            #expect(unavailable.options["ao"] == "coreaudio")
        }
    }

    @Test func completeDTSHDRequiresDedicatedRuntimeCapabilityAndRespectsPCM() {
        let receiver = device(surround)
        let devices = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [receiver], systemDefaultUID: receiver.id)
        for mode in [PlaybackDolbyAudioMode.automatic, .passthrough] {
            let preference = PlaybackAudioOutputPreference(deviceUID: receiver.id, dolbyAudio: mode)
            let route = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: devices,
                nativeDolbyAvailable: true, nativeDTSHDHBRAvailable: true)
            #expect(route.options["audio-spdif"] == (mode == .automatic ? "eac3,truehd,dts-hd" : "ac3,eac3,truehd,dts,dts-hd"))
            #expect(route.options["coreaudio-dtshd-hbr"] == "yes")
            #expect(route.device == "netvplayer/receiver")
            let processing = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: devices,
                nativeDolbyAvailable: true, nativeDTSHDHBRAvailable: true, requiresPCM: true)
            #expect(processing.options["audio-spdif"] == "")
            #expect(processing.options["coreaudio-dtshd-hbr"] == "no")
        }
        let disabled = PlaybackAudioOutputPolicy.resolve(preference: .init(dolbyAudio: .pcm), devices: devices,
            nativeDolbyAvailable: true, nativeDTSHDHBRAvailable: true)
        #expect(disabled.options["coreaudio-dtshd-hbr"] == "no")
        #expect(disabled.options["audio-spdif"] == "")
        let incompleteRuntime = PlaybackAudioOutputPolicy.resolve(preference: .init(), devices: devices,
            nativeDTSHDHBRAvailable: true)
        #expect(incompleteRuntime.options["coreaudio-dtshd-hbr"] == nil)
        #expect(incompleteRuntime.options["audio-spdif"] == "")
        #expect(PlaybackAudioOutputPolicy.managedNames.contains("coreaudio-dtshd-hbr"))
    }

    @Test func sourcePCMFollowsWithoutPinningTheObservedDeviceClock() {
        let receiver = device(surround)
        var snapshot = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [receiver], systemDefaultUID: receiver.id)
        let preference = PlaybackAudioOutputPreference(pcmSampleRate: .source)
        let source = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: snapshot,
            nativeDolbyAvailable: true, nativePCMSampleRateAvailable: true)
        #expect(source.followSourceSampleRate)
        #expect(source.options["audio-samplerate"] == "0")
        #expect(source.options["coreaudio-change-physical-format"] == "yes")
        #expect(source.options["ao"] == "coreaudio_exclusive,coreaudio,avfoundation")
        snapshot.outputs[0] = .init(id: receiver.id, name: receiver.name, transport: .hdmi,
            channelCapacity: 8, preferredChannels: surround, nominalSampleRate: 96_000,
            reportedLatencySeconds: nil, bufferFrames: nil)
        let switched = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: snapshot,
            nativeDolbyAvailable: true, nativePCMSampleRateAvailable: true)
        #expect(switched.options == source.options)
        let oldRuntime = PlaybackAudioOutputPolicy.resolve(preference: preference, devices: snapshot)
        #expect(!oldRuntime.followSourceSampleRate)
        #expect(oldRuntime.options["coreaudio-change-physical-format"] == "no")
        #expect(oldRuntime.options["audio-samplerate"] == "96000")
        let device = PlaybackAudioOutputPolicy.resolve(preference: .init(), devices: snapshot,
            nativePCMSampleRateAvailable: true)
        #expect(device.options["audio-samplerate"] == "96000")
        #expect(device.options["coreaudio-change-physical-format"] == "no")
    }

    private func device(_ layout: [String]?, capacity: Int = 8, id: String = "receiver") -> PlaybackAudioOutputDevice {
        .init(id: id, name: "Private receiver", transport: .hdmi, channelCapacity: capacity,
              preferredChannels: layout, nominalSampleRate: 48000, reportedLatencySeconds: 0.005, bufferFrames: 512)
    }
    private let surround = ["FL", "FR", "FC", "LFE", "BL", "BR"]

    @Test func automaticStaysSafeAndExplicitModesNeedPositions() {
        let receiver = device(surround + ["SL", "SR"])
        let snapshot = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [receiver], systemDefaultUID: receiver.id)
        #expect(PlaybackAudioOutputPolicy.resolve(preference: .init(), devices: snapshot).channels == "auto-safe")
        let seven = PlaybackAudioOutputPolicy.resolve(preference: .init(mode: .surround71), devices: snapshot)
        #expect(seven.channels == "7.1,5.1,5.1(side),stereo")
        #expect(seven.options["audio-spdif"] == "")
        #expect(seven.options["audio-exclusive"] == "no")
        #expect(seven.options["audio-samplerate"] == "48000")
        for labels in [nil, ["unknown", "unknown"], ["FL", "FR"], surround + ["BL", "BR"]] as [[String]?] {
            let unknown = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [device(labels)], systemDefaultUID: "receiver")
            let plan = PlaybackAudioOutputPolicy.resolve(preference: .init(mode: .surround71), devices: unknown)
            #expect(plan.channels == "stereo")
            #expect(plan.limitedToStereo)
        }
    }

    @Test func sideAndRearLayoutsAreNotInterchangeableAndCapacityCannotProveLayout() {
        for (labels, expected) in [(surround, "5.1,stereo"), (["FL", "FR", "FC", "LFE", "SL", "SR"], "5.1(side),stereo")] {
            let snapshot = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [device(labels)], systemDefaultUID: "receiver")
            #expect(PlaybackAudioOutputPolicy.resolve(preference: .init(mode: .surround51), devices: snapshot).channels == expected)
        }
        let inconsistent = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [device(surround, capacity: 2)], systemDefaultUID: "receiver")
        #expect(PlaybackAudioOutputPolicy.resolve(preference: .init(mode: .surround71), devices: inconsistent).limitedToStereo)
    }

    @Test func missingFailedAndReturningDevicesDoNotRewritePreference() {
        let request = PlaybackAudioOutputPreference(deviceUID: "receiver", mode: .surround71)
        let builtIn = device(["FL", "FR"], capacity: 2, id: "built-in")
        var snapshot = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [builtIn], systemDefaultUID: builtIn.id)
        let missing = PlaybackAudioOutputPolicy.resolve(preference: request, devices: snapshot)
        #expect(missing.device == "auto")
        #expect(missing.status == .unavailableFallback)
        #expect(missing.channels == "stereo")
        snapshot.outputs.append(device(surround))
        let restored = PlaybackAudioOutputPolicy.resolve(preference: request, devices: snapshot)
        #expect(restored.device == "coreaudio/receiver")
        #expect(restored.channels == "5.1,stereo")
        #expect(PlaybackAudioOutputPolicy.resolve(preference: request, devices: snapshot, failedDeviceUID: "receiver").status == .failedFallback)
        #expect(request.deviceUID == "receiver")
        #expect(request.mode == .surround71)
        #expect(PlaybackAudioOutputPolicy.resolve(preference: request, devices: .init()).status == .checking)
        #expect(PlaybackAudioOutputPolicy.resolve(preference: request, devices: snapshot, sleeping: true).status == .suspended)
    }

    @Test func unvalidatedVirtualDefaultDoesNotRedirectOrOpenHAL() {
        let virtual = PlaybackAudioOutputDevice(id: "virtual", name: "Virtual", transport: .virtual, channelCapacity: 2,
            preferredChannels: ["FL", "FR"], nominalSampleRate: 48000, reportedLatencySeconds: nil, bufferFrames: nil)
        let snapshot = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [virtual], systemDefaultUID: virtual.id)
        let plan = PlaybackAudioOutputPolicy.resolve(preference: .init(), devices: snapshot)
        #expect(plan.device == "null")
        #expect(plan.status == .unsupportedDefault)
        #expect(!virtual.supportsPCMSelection)
    }

    @Test func persistedOutputNeverChangesVolumeMuteAndResetIsSeparate() throws {
        let suite = "AudioOutputTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
        volume.setVolume(0.37); volume.setMuted(true)
        let original = volume.snapshot
        let store = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        store.set(.init(deviceUID: "receiver", mode: .surround51, dolbyAudio: .passthrough, pcmSampleRate: .source))
        #expect(PlaybackAudioOutputPreferenceStore(defaults: defaults).snapshot == store.snapshot)
        store.reset()
        #expect(store.snapshot == .init())
        #expect(volume.snapshot == original)
        #expect(PlaybackAudioOutputPreference(deviceUID: "bad\nuid").deviceUID == nil)
        defaults.set(Data(#"{"version":1,"deviceUID":"receiver","mode":"future"}"#.utf8), forKey: PlaybackAudioOutputPreferenceStore.key)
        #expect(PlaybackAudioOutputPreferenceStore(defaults: defaults).snapshot.mode == .automatic)
        #expect(PlaybackAudioOutputPreferenceStore(defaults: defaults).snapshot.pcmSampleRate == .device)
        defaults.set(Data(#"{"version":1,"dolbyAudio":"pcm","pcmSampleRate":"future"}"#.utf8), forKey: PlaybackAudioOutputPreferenceStore.key)
        #expect(PlaybackAudioOutputPreferenceStore(defaults: defaults).snapshot.dolbyAudio == .pcm)
        #expect(PlaybackAudioOutputPreferenceStore(defaults: defaults).snapshot.pcmSampleRate == .device)
    }

    @Test func processDeviceMustBeUniqueAndNeverFallsBackToSystemDefault() {
        let one = device(surround)
        var snapshot = PlaybackAudioDeviceSnapshot(enumerationSucceeded: true, outputs: [one], systemDefaultUID: one.id)
        #expect(snapshot.systemDefaultDeviceName == one.name)
        #expect(snapshot.processOutputDevice == nil)
        snapshot.processOutputUIDs = []
        #expect(snapshot.processOutputDevice == nil)
        snapshot.processOutputUIDs = [one.id, "other"]
        #expect(snapshot.processOutputDevice == nil)
        snapshot.processOutputUIDs = [one.id]
        #expect(snapshot.processOutputDevice == one)
    }

    @Test func layoutDecoderBoundsMalformedDataAndPreservesPhysicalOrder() {
        func layout(_ labels: [UInt32]) -> Data {
            var data = Data()
            for var value in [UInt32(0), 0, UInt32(labels.count)] { withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            for label in labels {
                for var value in [label, 0, 0, 0, 0] { withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            }
            return data
        }
        #expect(PlaybackAudioDeviceProbe.channelNames(layoutData: Data(repeating: 0xff, count: 12)) == nil)
        #expect(PlaybackAudioDeviceProbe.channelNames(layoutData: layout([1,2,3,4,5,6])) == surround)
        #expect(PlaybackAudioDeviceProbe.channelNames(layoutData: layout([1,2,3,4,5,6,33,34])) == ["FL","FR","FC","LFE","SL","SR","BL","BR"])
        #expect(PlaybackAudioDeviceProbe.channelNames(layoutData: layout([1,99])) == ["FL", "unknown"])
        #expect(PlaybackAudioDeviceProbe.channelNames(layoutData: layout([1,2]).prefix(20)) == nil)
    }

    @Test func diagnosticsKeepRequestedAndActualLayoutsRatesAndIdentitySeparate() throws {
        let values: [String: Any] = ["current-tracks/audio": ["codec":"pcm_s24le"],
            "audio-params": ["channels":"7.1","hr-channels":"7.1","channel-count":8,"samplerate":96000],
            "audio-out-params": ["channels":"fl-fr","hr-channels":"stereo","channel-count":2,"samplerate":96000,"format":"float"],
            "current-ao":"coreaudio"]
        let properties = try values.mapValues { try JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
        var info = PlaybackDiagnostics(mediaID: UUID(), properties: properties)
        info.audio.requestedMode = .surround71
        info.audio.deviceName = "Private receiver"
        info.audio.deviceNominalSampleRate = 48000
        info.audio.devicePreferredChannels = ["FL","FR"]
        #expect(info.audio.inputChannelCount == 8)
        #expect(info.audio.outputChannelCount == 2)
        #expect(info.audio.outputChannels == "fl-fr")
        #expect(info.audio.outputLayout == "stereo")
        #expect(info.audio.outputSampleRate == 96000)
        #expect(info.audio.deviceNominalSampleRate == 48000)
        #expect(!info.redactedJSON().contains("Private"))
        #expect(!info.redactedJSON().contains("deviceUID"))
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_AUDIO_FIXTURES"] != nil))
    func nativePCMNegotiationDeviceFallbackAndSessionContracts() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_AUDIO_FIXTURES"]))
        let suite = "AudioNative.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        let volume = PlaybackAudioPreferenceStore(defaults: defaults)
        volume.setVolume(0.25); volume.setMuted(true)
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod, audioPreferences: volume, audioOutputPreferences: output)
        let state = PlayerState()
        engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:640,height:360), styleMask:[.borderless], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine:engine,surface:.vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to:view,surface:.vod)
        defer { engine.stop(); engine.detach(from:view); window.orderOut(nil) }
        var reports: [String:String] = [:]
        func checkpoint(_ phase: String) throws {
            let url = folder.appendingPathComponent("native-checkpoint.json")
            try JSONEncoder().encode(["phase": phase]).write(to: url, options: .atomic)
        }
        var previous: UUID?
        for (file, count, rate) in [("av07-2ch-44100.mkv",2,44100),("av07-6ch-48000.mkv",6,48000),("av07-8ch-96000.mkv",8,96000)] {
            try checkpoint("load-" + file)
            await engine.play(spec:PlaySpec(url:folder.appendingPathComponent(file).absoluteString))
            try #require(await wait { state.playbackDiagnostics?.audio.inputChannelCount == count && state.playbackDiagnostics?.audio.mode == .pcm && state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" })
            let info = try #require(state.playbackDiagnostics)
            #expect(info.audio.inputSampleRate == rate)
            #expect(info.audio.outputSampleRate == 48000)
            #expect(info.mediaID != previous); previous = info.mediaID
            #expect(info.mpvVersion?.contains("0.41.0") == true)
            #expect(info.ffmpegVersion == "9.0.1")
            #expect(info.audio.outputChannelCount == 2)
            reports[file] = info.redactedJSON()
        }
        try checkpoint("begin-sync-measurement")
        var sync: [Double] = []
        for _ in 0..<16 {
            try await Task.sleep(for: .seconds(1))
            let reading = try #require(state.playbackDiagnostics?.audioVideoOffsetSeconds)
            sync.append(reading)
            #expect(abs(reading) <= 0.080)
            #expect(state.playbackDiagnostics?.audio.mode == .pcm)
        }
        reports["sync-16-seconds"] = String(decoding: try JSONEncoder().encode(sync), as: UTF8.self)
        let media = try #require(state.playbackDiagnostics?.mediaID)
        if let virtual = state.audioOutputDevices.first(where: { $0.transport == .virtual }) {
            try checkpoint("unvalidated-virtual-fallback")
            output.set(.init(deviceUID: virtual.id, mode: .surround51))
            try #require(await wait { state.playbackDiagnostics?.audio.routeStatus == .unsupportedFallback && state.playbackDiagnostics?.audio.mode == .pcm })
            #expect(state.playbackDiagnostics?.mediaID == media)
            reports["unvalidated-virtual-fallback"] = state.playbackDiagnostics?.redactedJSON()
        }
        try checkpoint("pause-after-virtual")
        engine.pause()
        let position = state.position
        try checkpoint("missing-device")
        output.set(.init(deviceUID:"AV07-intentionally-unavailable", mode:.surround71))
        try #require(await wait { state.playbackDiagnostics?.audio.routeStatus == .unavailableFallback && state.playbackDiagnostics?.audio.mode == .pcm })
        #expect(state.playbackDiagnostics?.audio.limitedToStereo == true)
        #expect(state.playbackDiagnostics?.audio.outputChannelCount == 2)
        #expect(state.playbackDiagnostics?.mediaID == media)
        #expect(abs(state.position-position) < 0.3)
        #expect(!state.isPlaying && state.isMuted && state.volume == 0.25)
        #expect(output.snapshot.deviceUID == "AV07-intentionally-unavailable")
        reports["unavailable-request-fallback"] = state.playbackDiagnostics?.redactedJSON()
        let builtIn = try #require(state.audioOutputDevices.first { $0.transport == .builtIn })
        try checkpoint("restore-built-in")
        output.set(.init(deviceUID:builtIn.id,mode:.stereo))
        try #require(await wait { state.playbackDiagnostics?.audio.routeStatus == .selected && state.playbackDiagnostics?.audio.mode == .pcm })
        reports["selected-built-in"] = state.playbackDiagnostics?.redactedJSON()
        try checkpoint("simulate-sleep-wake")
        engine.audioEnvironmentDidChange(sleeping:true)
        #expect(state.playbackDiagnostics?.audio.routeStatus == .suspended)
        #expect(state.playbackDiagnostics?.audio.deviceName == nil)
        engine.audioEnvironmentDidChange(sleeping:false)
        try #require(await wait { state.playbackDiagnostics?.audio.mode == .pcm })
        #expect(!state.isPlaying)
        #expect(state.playbackDiagnostics?.mediaID == media)
        reports["simulated-sleep-wake"] = state.playbackDiagnostics?.redactedJSON()
        // A synthetic AO failure tests the recovery state machine separately
        // from physical device removal (which requires external hardware).
        try checkpoint("simulate-AO-failure")
        var failed = PlaybackDiagnostics.Audio(codec: "pcm_s24le", outputDriver: "null")
        for _ in 0..<4 { _ = engine.updateAudioDiagnostics(&failed) }
        #expect(state.audioOutputMessage != nil)
        engine.resume()
        #expect(!state.isPlaying)
        try #require(await wait { state.audioOutputMessage == nil && state.playbackDiagnostics?.audio.mode == .pcm })
        #expect(!state.isPlaying)
        reports["synthetic-null-AO-recovery"] = state.playbackDiagnostics?.redactedJSON()
        output.reset()
        try checkpoint("resume-volume-speed")
        engine.setVolume(0.37); engine.setMuted(false)
        engine.speed = 1.5
        engine.resume()
        try #require(await wait { state.position > position + 1 && state.speed == 1.5 && !state.isMuted && state.playbackDiagnostics?.audio.mode == .pcm })
        #expect(state.volume == 0.37)
        reports["rate-volume-resume"] = state.playbackDiagnostics?.redactedJSON()
        engine.setMuted(true); engine.speed = 1
        try checkpoint("external-audio")
        await engine.play(spec:PlaySpec(url:folder.appendingPathComponent("av07-2ch-44100.mkv").absoluteString,
                                       externalAudioURL:folder.appendingPathComponent("av07-6ch-48000.wav").absoluteString))
        try #require(await wait { state.audioTracks.count >= 2 && state.playbackDiagnostics?.audio.inputChannelCount == 6 })
        let external = try #require(state.selectedAudioTrackID)
        engine.selectAudioTrack(id: try #require(state.audioTracks.first { $0.id != external }?.id))
        try #require(await wait { state.playbackDiagnostics?.audio.inputChannelCount == 2 })
        engine.selectAudioTrack(id:external)
        try #require(await wait { state.playbackDiagnostics?.audio.inputChannelCount == 6 })
        reports["external-audio-return"] = state.playbackDiagnostics?.redactedJSON()
        // Independent live surface, shared preferences, different native media.
        try checkpoint("dual-engine")
        let live = MPVPlayerEngine(videoSurface: .live, audioPreferences: volume, audioOutputPreferences: output)
        let liveState = PlayerState(); live.playerState = liveState
        let liveWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        liveWindow.isReleasedWhenClosed = false; liveWindow.alphaValue = 0.01; liveWindow.ignoresMouseEvents = true
        let liveView = try #require(MPVOpenGLVideoView(engine: live, surface: .live))
        liveView.frame = liveWindow.contentView!.bounds; liveWindow.contentView = liveView; liveWindow.orderFrontRegardless()
        live.attach(to: liveView, surface: .live)
        defer { live.stop(); live.detach(from: liveView); liveWindow.orderOut(nil) }
        await live.play(spec: PlaySpec(url: folder.appendingPathComponent("av07-8ch-96000.mkv").absoluteString, metadata: ["playback.kind": "live"]))
        try #require(await wait { liveState.playbackDiagnostics?.audio.inputChannelCount == 8 && liveState.playbackDiagnostics?.audio.mode == .pcm })
        #expect(liveState.playbackDiagnostics?.mediaID != state.playbackDiagnostics?.mediaID)
        #expect(state.playbackDiagnostics?.audio.inputChannelCount == 6)
        output.set(.init(mode: .surround71))
        try #require(await wait { liveState.playbackDiagnostics?.audio.limitedToStereo == true && state.playbackDiagnostics?.audio.limitedToStereo == true })
        reports["live-shared-preference"] = liveState.playbackDiagnostics?.redactedJSON()
        reports["vod-independent-media"] = state.playbackDiagnostics?.redactedJSON()
        output.reset()
        live.stop()
        engine.stop()
        try #require(await wait { state.currentSpec == nil })
        #expect(state.playbackDiagnostics == nil && state.audioOutputDevices.isEmpty)
        try checkpoint("completed")
        try JSONEncoder().encode(reports).write(to:folder.appendingPathComponent("native-audio.json"), options:.withoutOverwriting)
    }

    @MainActor private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by:.seconds(12))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for:.milliseconds(30)) }
        return predicate()
    }
}
