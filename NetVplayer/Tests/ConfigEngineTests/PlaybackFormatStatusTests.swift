import Foundation
import Models
import Testing
@testable import PlayerEngine

enum PlaybackFormatTestFixtures {
    static let owner = UUID(uuidString: "CC061018-0000-4000-8000-000000000001")!

    static func diagnostics(hdr: Bool = true, mode: PlaybackDiagnostics.AudioMode? = .pcm,
                            frameDrops: Int = 0) throws -> PlaybackDiagnostics {
        let values: [String: Any] = [
            "current-tracks/video": ["codec": "hevc", "ff-index": 0],
            "video-dec-params": ["pixelformat": "yuv420p10le", "gamma": "pq", "colormatrix": "bt.2020-ncl"],
            "current-tracks/audio": ["id": 1, "codec": "truehd", "codec-profile": "Dolby TrueHD + Dolby Atmos"],
            "audio-params": ["format": "s32p", "channels": "7.1", "channel-count": 8, "samplerate": 48000],
            "audio-out-params": ["format": "float", "channels": "stereo", "channel-count": 2, "samplerate": 48000],
            "current-ao": "coreaudio", "frame-drop-count": frameDrops
        ]
        var info = PlaybackDiagnostics(mediaID: owner, properties: try values.mapValues {
            try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed])
        }, display: .init(name: "界面验证显示器", currentEDRHeadroom: 4, potentialEDRHeadroom: 4,
                         targetFormat: hdr ? "GL_RGBA16F / rgba16Float" : "GL_RGBA8", edrEnabled: hdr))
        if hdr { info.display.hdrPresentation = .plan(headroom: 4, awaitingHeadroom: false) }
        info.display.videoOutput = PlaybackVideoOutputPolicy.assess(mode: .automatic, video: info.video, display: info.display)
        info.audio.mode = mode
        info.audio.deviceName = "界面验证音频设备"
        info.audio.compressedAudio = .init(codec: info.audio.codec, profile: info.audio.profile,
                                          mode: mode, passthroughProperty: nil)
        return info
    }

    static func summary(_ info: PlaybackDiagnostics, owner: UUID? = owner, selectedAudio: String? = "1") -> PlaybackFormatSummary {
        .init(diagnostics: info, ownerID: owner, hasPlayback: true, selectedAudioTrackID: selectedAudio)
    }

    static func reconstructDolby(_ info: inout PlaybackDiagnostics, failed: Bool = false) {
        info.video.dolbyVisionProfile = 8
        info.video.dolbyVision = PlaybackDolbyVision.assess(video: info.video, local: nil, trackIndex: 0,
            renderer: DolbyRendererObservation(capabilities: 15, generation: 1, frames: 1, doviFrames: 1,
                enhancementFrames: 0, felFrames: 0, failures: failed ? 1 : 0, frameFlags: failed ? 8 : 1, pts: 0))
    }
}

@Suite("Playback format status")
struct PlaybackFormatStatusTests {
    @Test func hdrSourceAndDisplayCapabilityDoNotLightSDROutput() throws {
        var info = try PlaybackFormatTestFixtures.diagnostics(hdr: false)
        #expect(info.display.currentEDRHeadroom == 4)
        let status = try #require(PlaybackFormatTestFixtures.summary(info).video)
        #expect(status.state == .mappedSDR && !status.formatIsActive)
        // A preference/capability or inconsistent EDR flag alone is insufficient.
        info.display.edrEnabled = true
        #expect(PlaybackFormatTestFixtures.summary(info).video?.formatIsActive == false)
    }

    @Test func onlyCurrentEDRPresentationLightsHDR() throws {
        var info = try PlaybackFormatTestFixtures.diagnostics()
        #expect(PlaybackFormatTestFixtures.summary(info).video?.formatIsActive == true)
        info.display.hdrPresentation = .plan(headroom: 1, awaitingHeadroom: true)
        info.display.videoOutput = PlaybackVideoOutputPolicy.assess(mode: .automatic, video: info.video, display: info.display)
        #expect(PlaybackFormatTestFixtures.summary(info).video?.state == .preparing)
        #expect(PlaybackFormatTestFixtures.summary(info).video?.formatIsActive == false)
    }

    @Test func dolbyMetadataNeedsSuccessfulCurrentFrameAndDoesNotClaimTVSignal() throws {
        var info = try PlaybackFormatTestFixtures.diagnostics()
        info.video.dolbyVisionProfile = 8
        #expect(PlaybackFormatTestFixtures.summary(info).video?.formatIsActive == false)
        PlaybackFormatTestFixtures.reconstructDolby(&info)
        let active = try #require(PlaybackFormatTestFixtures.summary(info).video)
        #expect(active.format == "Dolby Vision" && active.state == .enabled && active.formatIsActive)
        #expect(info.video.dolbyVision?.dolbyVisionSignalSent == false)
        #expect(active.explanation.contains(L10n.text("杜比视界动态映射已生效，当前输出为 EDR HDR 或 SDR，不发送电视原生 Dolby Vision 信号。")))
        PlaybackFormatTestFixtures.reconstructDolby(&info, failed: true)
        #expect(PlaybackFormatTestFixtures.summary(info).video?.state == .blocked)
        #expect(PlaybackFormatTestFixtures.summary(info).video?.formatIsActive == false)
    }

    @Test func dolbyMappingAndHDRPresentationRemainSeparate() throws {
        var info = try PlaybackFormatTestFixtures.diagnostics(hdr: false)
        PlaybackFormatTestFixtures.reconstructDolby(&info)
        let active = try #require(PlaybackFormatTestFixtures.summary(info).video)
        #expect(active.formatIsActive && active.actualOutput == L10n.text("动态映射 · SDR 呈现"))
    }

    @Test func SDRMappingDetailsExplainFollowSystemPolicy() throws {
        let info = try PlaybackFormatTestFixtures.diagnostics(hdr: false)
        let status = try #require(PlaybackFormatTestFixtures.summary(info).video)
        #expect(status.explanation == L10n.text("自动模式跟随系统；当前未获得可用 HDR 输出，已映射为 SDR。"))
        #expect(status.details.contains(.init(label: L10n.text("输出策略"), value: L10n.text("自动（跟随系统）"))))
    }

    @Test func compatibleBaseLayerNeverLightsDolbyVision() throws {
        var info = try PlaybackFormatTestFixtures.diagnostics(hdr: false)
        info.video.dolbyVisionProfile = 8
        info.video.dolbyVision = PlaybackDolbyVision.assess(video: info.video,
            local: .init(profile: 8, level: 6, compatibilityID: 1, rpuFlag: true,
                         enhancementLayer: false, baseLayer: true, frameRPU: true, frameMetadata: true,
                         rpuHeaderProfile: 8, rpuInferredProfile: 8, streamIndex: 0, status: "first-frame-inspected"),
            trackIndex: 0)
        let fallback = try #require(PlaybackFormatTestFixtures.summary(info).video)
        #expect(fallback.format == "HDR10" && fallback.state == .baseLayer && !fallback.formatIsActive)
        // If EDR presentation is subsequently observed, only the HDR base
        // format becomes gold. The fallback state is never a Dolby success.
        info.display = try PlaybackFormatTestFixtures.diagnostics().display
        let hdr = try #require(PlaybackFormatTestFixtures.summary(info).video)
        #expect(hdr.format == "HDR10" && hdr.formatIsActive && !hdr.state.isEnabled)
    }

    @Test func atmosPCMUsesActualStereoOutputInsteadOfSourceChannels() throws {
        let info = try PlaybackFormatTestFixtures.diagnostics()
        let audio = try #require(PlaybackFormatTestFixtures.summary(info).audio)
        #expect(audio.format == "Dolby Atmos" && audio.state == .pcm && !audio.formatIsActive)
        #expect(audio.actualOutput == L10n.text("PCM 立体声") + " · 48 kHz")
        #expect(info.audio.inputChannelCount == 8 && info.audio.outputChannelCount == 2)
    }

    @Test(arguments: [PlaybackDiagnostics.AudioMode.nativeCompressed, .nativeCompressedPreparing, .passthrough])
    func sourceMetadataWithoutMatchingOutputDoesNotLightAtmos(mode: PlaybackDiagnostics.AudioMode) throws {
        let audio = try #require(PlaybackFormatTestFixtures.summary(try PlaybackFormatTestFixtures.diagnostics(mode: mode)).audio)
        #expect(audio.format == "Dolby Atmos" && !audio.formatIsActive && !audio.state.isEnabled)
    }

    @Test(arguments: ["truehd", "eac3"])
    func matchingAtmosPassthroughLightsRouteWithoutClaimingReceiver(codec: String) throws {
        var info = try PlaybackFormatTestFixtures.diagnostics(mode: .passthrough)
        info.audio.codec = codec
        info.audio.profile = codec == "truehd" ? "Dolby TrueHD + Dolby Atmos" : "Dolby Digital Plus + Dolby Atmos"
        info.audio.outputDriver = "coreaudio_exclusive"
        info.audio.outputFormat = "spdif-" + codec
        info.audio.compressedAudio = .init(codec: codec, profile: info.audio.profile, mode: .passthrough, passthroughProperty: nil)
        let audio = try #require(PlaybackFormatTestFixtures.summary(info).audio)
        #expect(audio.format == "Dolby Atmos" && audio.state == .encoded)
        #expect(audio.formatIsActive && audio.outputIsActive)
        #expect(audio.actualOutput == L10n.text("Dolby Atmos · 原码输出"))
        #expect(info.audio.compressedAudio?.receiverAtmos == .unverified)

        info.audio.outputFormat = codec == "truehd" ? "spdif-eac3" : "spdif-truehd"
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.formatIsActive == false)
        info.audio.outputFormat = "spdif-" + codec
        info.audio.outputDriver = "null"
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.formatIsActive == false)
        info.audio.outputDriver = nil
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.formatIsActive == false)

        info.audio.outputDriver = "coreaudio_exclusive"
        info.audio.compressedAudio = .init(codec: codec, profile: nil, mode: .passthrough, passthroughProperty: nil)
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.formatIsActive == false)
    }

    @Test func DTSCoreRouteNeverClaimsFullLosslessHDOutput() throws {
        var info = try PlaybackFormatTestFixtures.diagnostics(mode: .passthrough)
        info.audio.codec = "dts"
        info.audio.profile = "DTS-HD MA"
        info.audio.outputDriver = "coreaudio_exclusive"
        info.audio.outputFormat = "spdif-dts"
        info.audio.compressedAudio = .init(codec: "dts", profile: "DTS-HD MA", mode: .passthrough, passthroughProperty: nil)
        let core = try #require(PlaybackFormatTestFixtures.summary(info).audio)
        #expect(core.format == L10n.text("DTS 核心") && core.outputIsActive)
        #expect(core.source == "DTS-HD")
        #expect(core.actualOutput == L10n.text("DTS 核心 · 原码输出"))
        info.audio.outputFormat = "spdif-dtshd"
        let complete = try #require(PlaybackFormatTestFixtures.summary(info).audio)
        #expect(complete.format == "DTS-HD MA" && complete.outputIsActive)
        #expect(complete.actualOutput == L10n.text("DTS-HD MA · 原码输出"))
        info.audio.outputFormat = "spdif-dts"
        info.audio.outputDriver = "null"
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.formatIsActive == false)
        info.audio.outputDriver = "coreaudio"
        info.audio.mode = .pcm
        info.audio.outputFormat = "float"
        let decoded = try #require(PlaybackFormatTestFixtures.summary(info).audio)
        #expect(decoded.format == "PCM" && !decoded.outputIsActive)
    }

    @Test func DTSXSourceDoesNotClaimReceiverObjectsOrActivateMismatchedOutput() throws {
        var info = try PlaybackFormatTestFixtures.diagnostics(mode: .passthrough)
        info.audio.codec = "dts"
        info.audio.profile = "DTS-HD MA + DTS:X"
        info.audio.outputDriver = "coreaudio_exclusive"
        info.audio.outputFormat = "spdif-dtshd"
        info.audio.compressedAudio = .init(codec: "dts", profile: info.audio.profile, mode: .passthrough, passthroughProperty: nil)
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.format == "DTS-HD MA")
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.outputIsActive == true)
        #expect(info.audio.compressedAudio?.receiverAtmos == .unverified)
        info.audio.outputDriver = "null"
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.outputIsActive == false)
        info.audio.outputDriver = "coreaudio_exclusive"
        info.audio.outputFormat = "spdif-truehd"
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.outputIsActive == false)
        info.audio.outputFormat = "spdif-dtshd"
        info.audio.profile = "DTS-HD HRA"
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.outputIsActive == false)
    }

    @Test func sampleRateDetailsKeepSourceLogicalAndPhysicalRatesSeparate() throws {
        var info = try PlaybackFormatTestFixtures.diagnostics(mode: .passthrough)
        info.audio.sourceSampleRate = 48_000
        info.audio.outputSampleRate = 192_000
        info.audio.devicePhysicalFormats = [.init(formatID: "mtct", sampleRate: 768_000,
            channels: 2, bitsPerChannel: 16, bytesPerFrame: 4, flags: 76)]
        let encoded = try #require(PlaybackFormatTestFixtures.summary(info).audio)
        #expect(encoded.details.contains(.init(label: L10n.text("片源采样率"), value: "48 kHz")))
        #expect(encoded.details.contains(.init(label: L10n.text("码流逻辑频率"), value: "192 kHz")))
        #expect(encoded.details.contains(.init(label: L10n.text("设备传输频率"), value: "768 kHz")))
        info.audio.mode = .pcm
        info.audio.sourceSampleRate = 44_100
        info.audio.outputSampleRate = 44_100
        info.audio.devicePhysicalFormats = [.init(formatID: "lpcm", sampleRate: 48_000,
            channels: 8, bitsPerChannel: 24, bytesPerFrame: 32, flags: 12)]
        let pcm = try #require(PlaybackFormatTestFixtures.summary(info).audio)
        #expect(pcm.details.contains(.init(label: L10n.text("片源采样率"), value: "44.1 kHz")))
        #expect(pcm.details.contains(.init(label: L10n.text("播放器输出采样率"), value: "44.1 kHz")))
        #expect(pcm.details.contains(.init(label: L10n.text("设备实际采样率"), value: "48 kHz")))
    }

    @Test func trackTitlesAndUnknownProfileDoNotInventAtmos() throws {
        var info = try PlaybackFormatTestFixtures.diagnostics()
        info.audio.profile = nil
        info.audio.compressedAudio = .init(codec: "truehd", profile: "Atmos cinema 7.1", mode: .pcm, passthroughProperty: nil)
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.format == "PCM")
    }

    @Test func staleMediaAndTrackObservationsClearSuccessfulStates() throws {
        let info = try PlaybackFormatTestFixtures.diagnostics()
        let previous = PlaybackFormatTestFixtures.summary(info, owner: UUID())
        #expect(previous.items.allSatisfy { !$0.formatIsActive && $0.state == .preparing })
        let changedTrack = PlaybackFormatTestFixtures.summary(info, selectedAudio: "2")
        #expect(changedTrack.video?.formatIsActive == true && changedTrack.audio?.state == .preparing)
        #expect(changedTrack.audio?.format != "Dolby Atmos")
        let stopped = PlaybackFormatSummary(diagnostics: info, ownerID: info.mediaID, hasPlayback: false)
        #expect(stopped.items.isEmpty && stopped.noticeIdentity == nil)
    }

    @Test func diagnosticCountersDoNotRepeatNoticesButDeviceChangesDo() throws {
        let first = PlaybackFormatTestFixtures.summary(try PlaybackFormatTestFixtures.diagnostics(frameDrops: 0))
        var updated = try PlaybackFormatTestFixtures.diagnostics(frameDrops: 4)
        #expect(first.noticeIdentity == PlaybackFormatTestFixtures.summary(updated).noticeIdentity)
        updated.audio.deviceName = "另一输出设备"
        #expect(first.noticeIdentity != PlaybackFormatTestFixtures.summary(updated).noticeIdentity)
    }
}
