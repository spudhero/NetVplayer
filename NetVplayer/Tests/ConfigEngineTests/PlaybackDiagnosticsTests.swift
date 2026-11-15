import AppKit
import Foundation
import Models
import Testing
@testable import PlayerEngine

@Suite struct PlaybackDiagnosticsTests {
    private func properties(_ values: [String: Any]) throws -> [String: Data] {
        try values.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
    }

    @Test func inputFactsDoNotClaimHardwareOrHDROutput() throws {
        let info = PlaybackDiagnostics(mediaID: UUID(), properties: try properties([
            "current-tracks/video": ["codec": "hevc", "codec-profile": "Main 10", "decoder": "hevc",
                                     "dolby-vision-profile": 8, "title": "4K Dolby Atmos"],
            "video-dec-params": ["w": 3840, "h": 2160, "pixelformat": "yuv420p10le",
                                 "gamma": "pq", "primaries": "bt.2020", "colormatrix": "bt.2020-ncl",
                                 "max-luma": 1000],
            "container-fps": 59.94, "hwdec": "videotoolbox-copy", "hwdec-current": "no"
        ]), display: .init(currentEDRHeadroom: 4, targetFormat: "GL_RGBA8", edrEnabled: false))
        #expect(info.video.codec == "hevc")
        #expect(info.video.bitDepth == 10)
        #expect(info.video.dolbyVisionProfile == 8)
        #expect(info.video.staticHDRMetadataDetected == true)
        #expect(info.video.dynamicHDRMetadataDetected == nil)
        #expect(info.video.hardwareDecoder == "no")
        #expect(info.video.fallback == .notReported)
        #expect(info.display.edrEnabled == false)
        #expect(info.audio.mode == nil)
    }

    @Test func unknownAndInvalidValuesRemainUnknown() throws {
        let info = PlaybackDiagnostics(mediaID: UUID(), properties: try properties([
            "video-dec-params": ["w": true, "h": -1, "pixelformat": "videotoolbox_vld", "average-bpp": 24,
                                 "gamma": "unknown", "max-luma": 0],
            "container-fps": -1, "hwdec": "videotoolbox-copy",
            "current-tracks/video": ["dolby-vision-profile": true]
        ]))
        #expect(info.video.width == nil)
        #expect(info.video.height == nil)
        #expect(info.video.bitDepth == nil)
        #expect(info.video.framesPerSecond == nil)
        #expect(info.video.hardwareDecoder == nil)
        #expect(info.video.fallback == nil)
        #expect(info.video.dolbyVisionProfile == nil)
        #expect(info.video.staticHDRMetadataDetected == nil)
        #expect(info.video.transfer == nil)
        #expect(info.display.edrEnabled == nil)
        #expect(PlaybackDiagnostics.bitDepth(pixelFormat: "nv12") == 8)
        #expect(PlaybackDiagnostics.bitDepth(pixelFormat: "p010le") == 10)
        #expect(PlaybackDiagnostics.bitDepth(pixelFormat: "yuv444p12le") == 12)
        #expect(PlaybackDiagnostics.bitDepth(pixelFormat: "gbrp16be") == 16)
    }

    @Test func hlgAndHardwareAndSoftwareFallbackAreIndependent() throws {
        let base = try properties([
            "current-tracks/video": ["codec": "av1", "decoder": "libdav1d"],
            "video-dec-params": ["gamma": "hlg"],
            "hwdec": "videotoolbox-copy", "hwdec-current": "videotoolbox-copy"
        ])
        let hardware = PlaybackDiagnostics(mediaID: UUID(), properties: base, fallback: .initializationFailed)
        #expect(hardware.video.signalDescription == "HDR · HLG")
        #expect(hardware.video.hardwareDecoder == "videotoolbox-copy")
        #expect(hardware.video.fallback == nil)
        var software = base
        software["hwdec-current"] = Data(#""no""#.utf8)
        #expect(PlaybackDiagnostics(mediaID: UUID(), properties: software, fallback: .initializationFailed).video.fallback == .initializationFailed)
        software["hwdec"] = Data(#""no""#.utf8)
        #expect(PlaybackDiagnostics(mediaID: UUID(), properties: software).video.fallback == .disabled)
        #expect(PlaybackDiagnostics.HardwareFallback.detected(in: "Failed to initialize VideoToolbox") == .initializationFailed)
        #expect(PlaybackDiagnostics.HardwareFallback.detected(in: "TLS connection failed") == nil)
    }

    @Test func audioUsesActualOutputFormatInsteadOfCodecOrPassthroughPreference() throws {
        var values = try properties([
            "current-tracks/audio": ["codec": "eac3", "decoder": "eac3", "title": "Atmos"],
            "audio-params": ["format": "floatp", "channels": "5.1", "samplerate": 48000],
            "audio-out-params": ["format": "float", "channels": "stereo", "samplerate": 48000],
            "current-ao": "coreaudio", "audio-spdif": "eac3,truehd"
        ])
        let pcm = PlaybackDiagnostics(mediaID: UUID(), properties: values)
        #expect(pcm.audio.mode == .pcm)
        #expect(pcm.audio.inputLayout == "5.1")
        #expect(pcm.audio.outputLayout == "stereo")
        #expect(pcm.audio.deviceName == nil)
        values["audio-out-params"] = try properties(["x": ["format": "spdif-eac3"]])["x"]
        #expect(PlaybackDiagnostics(mediaID: UUID(), properties: values).audio.mode == .passthrough)
        values["current-ao"] = Data(#""null""#.utf8)
        #expect(PlaybackDiagnostics(mediaID: UUID(), properties: values).audio.mode == nil)
        values.removeValue(forKey: "current-tracks/audio")
        #expect(PlaybackDiagnostics(mediaID: UUID(), properties: values).audio.outputLayout == nil)
    }

    @Test func exportedFactsExcludePrivatePathsCredentialsAndDeviceNames() throws {
        let privateValue = "https://user:password@nas.invalid/Private/movie.mkv?token=secret"
        var info = PlaybackDiagnostics(mediaID: UUID(), properties: try properties([
            "current-tracks/video": ["codec": "h264", "title": privateValue, "external-filename": privateValue,
                                     "metadata": ["Cookie": "account=secret"], "codec-profile": "/Volumes/NAS/Private/movie"],
            "video-dec-params": ["pixelformat": "yuv420p"],
            "mpv-version": privateValue,
            "path": privateValue
        ]), display: .init(name: "Alice's display"))
        info.audio.deviceName = "Alice's headphones"
        info.audio.systemDefaultDeviceName = "Alice's home receiver"
        let exported = info.redactedJSON()
        #expect(exported.contains("h264"))
        for secret in ["nas.invalid", "password", "secret", "Private", "Alice", "Cookie", "Volumes", "external-filename"] {
            #expect(!exported.contains(secret))
        }
        #expect(try JSONSerialization.jsonObject(with: Data(exported.utf8)) is [String: Any])
        #expect(exported.utf8.count < 16_384)
    }

    @Test func samplerRejectsLateRepliesAndBoundsRateAndTimeout() {
        var sampler = PlaybackDiagnosticsSampler()
        let oldOwner = UUID(), newOwner = UUID()
        let old = sampler.begin(owner: oldOwner, now: 10)
        #expect(old.count == PlaybackDiagnosticsSampler.properties.count)
        #expect(sampler.begin(owner: oldOwner, now: 10.5).isEmpty)
        sampler.reset()
        let current = sampler.begin(owner: newOwner, now: 11)
        #expect(Set(old.map(\.id)).isDisjoint(with: Set(current.map(\.id))))
        #expect(sampler.receive(id: old[0].id, name: old[0].name, json: #"{"codec":"old"}"#, owner: newOwner) == nil)
        #expect(sampler.receive(id: current[0].id, name: current[0].name, json: #"{"codec":"wrong-owner"}"#, owner: oldOwner) == nil)
        #expect(sampler.receive(id: current[0].id, name: current[1].name, json: "1", owner: newOwner) == nil)
        #expect(sampler.receive(id: current[0].id, name: current[0].name, json: #"{"codec":"av1"}"#, owner: newOwner) == nil)
        #expect(sampler.expire(owner: newOwner, now: 12.9) == nil)
        let partial = sampler.expire(owner: newOwner, now: 13)
        #expect(partial?.count == 1)
        #expect(sampler.receive(id: current[1].id, name: current[1].name, json: "1", owner: newOwner) == nil)
        #expect(!sampler.begin(owner: newOwner, now: 13).isEmpty)
    }

    @Test func samplerRejectsOversizedAndInvalidJSONWithoutStalling() {
        var sampler = PlaybackDiagnosticsSampler()
        let owner = UUID()
        let requests = sampler.begin(owner: owner, now: 1)
        var sample: [String: Data]?
        for (index, request) in requests.enumerated() {
            let json = index == 0 ? String(repeating: "x", count: 8193) : (index == 1 ? "invalid" : "null")
            sample = sampler.receive(id: request.id, name: request.name, json: json, owner: owner)
        }
        #expect(sample?.count == requests.count - 2)
        #expect(sampler.begin(owner: owner, now: 1.9).isEmpty)
        #expect(!sampler.begin(owner: owner, now: 2).isEmpty)
    }

    @Test func samplerBoundsWholeBatchAndKeepsRawAndInterpretedColorSeparate() throws {
        var sampler = PlaybackDiagnosticsSampler()
        let owner = UUID()
        let requests = sampler.begin(owner: owner, now: 1)
        var sample: [String: Data]?
        for request in requests {
            sample = sampler.receive(
                id: request.id, name: request.name,
                json: "\"" + String(repeating: "x", count: 8_000) + "\"", owner: owner
            )
        }
        #expect(sample?.values.reduce(0, { $0 + $1.count }) ?? Int.max <= 65_536)
        #expect(sample?.count == 8)
        let info = PlaybackDiagnostics(mediaID: UUID(), properties: try properties([
            "video-dec-params": ["gamma": "hlg"],
            "video-params": ["gamma": "pq"]
        ]))
        #expect(info.video.transfer == "hlg")
        #expect(info.video.interpretedTransfer == "pq")
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_AV_DIAGNOSTIC_FIXTURES"] != nil))
    func nativeFormatsMediaReplacementAndStop() async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_AV_DIAGNOSTIC_FIXTURES"])
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod)
        let state = PlayerState()
        engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds
        window.contentView = view
        window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
        var previousID: UUID?
        var reports: [String: String] = [:]
        for (file, codec, transfer) in [
            ("sdr.mp4", "h264", "bt.1886"),
            ("hdr10.mkv", "hevc", "pq"),
            ("hlg.mkv", "hevc", "hlg"),
            ("av1.mkv", "av1", "bt.1886")
        ] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
            await engine.play(spec: PlaySpec(url: url.absoluteString, title: "AV diagnostics fixture"))
            #expect(state.playbackDiagnostics?.mediaID == nil || state.playbackDiagnostics?.mediaID != previousID)
            try #require(await wait { state.playbackDiagnostics?.video.codec == codec && state.playbackDiagnostics?.display.targetFormat != nil })
            let info = try #require(state.playbackDiagnostics)
            if file == "sdr.mp4" {
                try #require(await wait { state.playbackDiagnostics?.audio.systemDefaultDeviceName != nil })
                try #require(await wait { state.playbackDiagnostics?.audio.deviceName != nil })
                #expect(state.playbackDiagnostics?.audio.mode == .pcm)
            }
            #expect(info.mediaID != previousID)
            #expect(info.video.interpretedTransfer == transfer)
            #expect(info.video.width == 320)
            #expect(info.display.targetFormat == "GL_RGBA8")
            #expect(info.display.edrEnabled == false)
            previousID = info.mediaID
            reports[file] = info.redactedJSON()
        }
        let dvURL = URL(fileURLWithPath: folder).appendingPathComponent("dv84.mov")
        await engine.play(spec: PlaySpec(url: dvURL.absoluteString))
        try #require(await wait { state.playbackDiagnostics?.video.dolbyVisionProfile == 8
            && state.playbackDiagnostics?.display.targetFormat == "GL_RGBA8" })
        let dv = try #require(state.playbackDiagnostics)
        #expect(dv.video.codec == "hevc")
        #expect(dv.video.width == 1920)
        #expect(dv.display.edrEnabled == false)
        reports["dv84.mov"] = dv.redactedJSON()
        await engine.play(spec: PlaySpec(
            url: URL(fileURLWithPath: folder).appendingPathComponent("sdr.mp4").absoluteString,
            mpvOptions: ["hwdec": "no"]
        ))
        try #require(await wait { state.playbackDiagnostics?.video.hardwareDecoder == "no" })
        #expect(state.playbackDiagnostics?.video.fallback == .disabled)
        #expect(state.playbackDiagnostics?.video.dolbyVisionProfile == nil)
        reports["forced-software"] = state.playbackDiagnostics?.redactedJSON()
        try JSONEncoder().encode(reports).write(to: URL(fileURLWithPath: folder).appendingPathComponent("native-diagnostics.json"))
        engine.stop()
        try #require(await wait { state.currentSpec == nil })
        #expect(state.playbackDiagnostics == nil)
    }

    @MainActor
    private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }
}
