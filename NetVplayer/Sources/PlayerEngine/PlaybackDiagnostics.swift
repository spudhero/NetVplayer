import Foundation
import Storage
import CoreFoundation
import Models

/// Facts from the active decoder and host. Source labels and requested options
/// never establish hardware decoding, HDR output, or compressed audio passthrough.
public struct PlaybackDiagnostics: Equatable, Codable, Sendable {
    public struct Video: Equatable, Codable, Sendable {
        public var codec: String?
        public var profile: String?
        public var decoder: String?
        public var width: Int?
        public var height: Int?
        public var framesPerSecond: Double?
        public var pixelFormat: String?
        public var bitDepth: Int?
        public var matrix: String?
        public var range: String?
        public var primaries: String?
        public var transfer: String?
        public var interpretedPrimaries: String?
        public var interpretedTransfer: String?
        public var interpretedMatrix: String?
        public var interpretedRange: String?
        public var dolbyVisionProfile: Int?
        public var dolbyVision: PlaybackDolbyVision?
        public var hdrVivid: PlaybackHDRVivid?
        public var streamIndex: Int?
        public var staticHDRMetadataDetected: Bool?
        public var dynamicHDRMetadataDetected: Bool?
        public var hardwareDecoder: String?
        public var requestedHardwareDecoder: String?
        public var fallback: HardwareFallback?

        public var signalDescription: String {
            if matrix == "dolbyvision" { return "Dolby Vision" }
            if hdrVivid != nil { return "HDR Vivid" }
            switch transfer {
            case "pq", "smpte2084": return "HDR · PQ"
            case "hlg", "arib-std-b67": return "HDR · HLG"
            case "bt.1886", "bt.709", "srgb", "gamma2.2", "gamma2.8": return "SDR"
            default: return L10n.text("未知")
            }
        }

        public var interpretedSignalDescription: String {
            switch interpretedTransfer {
            case "pq", "smpte2084": return "HDR · PQ"
            case "hlg", "arib-std-b67": return "HDR · HLG"
            case "bt.1886", "bt.709", "srgb", "gamma2.2", "gamma2.8": return "SDR"
            default: return L10n.text("未知")
            }
        }

        public var decodingDescription: String {
            guard let hardwareDecoder else { return L10n.text("未知") }
            return hardwareDecoder == "no"
                ? L10n.text("软件解码")
                : L10n.text("硬件解码：{0}", [hardwareDecoder])
        }
    }

    public enum HardwareFallback: String, Codable, Sendable {
        case disabled, initializationFailed, notReported

        public var description: String {
            switch self {
            case .disabled: return L10n.text("当前设置关闭硬件解码")
            case .initializationFailed: return L10n.text("硬件解码初始化失败")
            case .notReported: return L10n.text("回退原因未报告")
            }
        }

        static func detected(in log: String) -> Self? {
            let text = log.lowercased()
            let hardware = text.contains("videotoolbox") || text.contains("hardware decoding")
                || text.contains("hardware decoder") || text.contains("hwdec")
            return hardware && ["failed", "failure", "cannot", "could not", "not supported"].contains(where: text.contains)
                ? .initializationFailed : nil
        }
    }

    public struct Audio: Equatable, Codable, Sendable {
        public var trackID: String?
        public var codec: String?
        public var profile: String?
        public var decoder: String?
        /// Container/codec facts, independent of audio-params (decoder output).
        public var demuxSampleRate: Int?
        public var sourceSampleRate: Int?
        public var sourceChannelCount: Int?
        public var inputFormat: String?
        public var dsd: PlaybackDSDAssessment?
        public var inputLayout: String?
        public var inputChannels: String?
        public var inputChannelCount: Int?
        public var inputSampleRate: Int?
        public var outputLayout: String?
        public var outputChannels: String?
        public var outputChannelCount: Int?
        public var outputSampleRate: Int?
        public var outputFormat: String?
        public var outputDriver: String?
        public var mode: AudioMode?
        /// Confirmed by CoreAudio's process output device list, only if unambiguous.
        public var deviceName: String?
        public var systemDefaultDeviceName: String?
        public var requestedMode: PlaybackAudioOutputMode?
        public var routeStatus: PlaybackAudioRouteStatus?
        public var requestedChannelLayouts: String?
        public var limitedToStereo: Bool?
        public var processDeviceCount: Int?
        public var deviceTransport: PlaybackAudioOutputDevice.Transport?
        public var deviceChannelCapacity: Int?
        public var devicePreferredChannels: [String]?
        public var deviceNominalSampleRate: Double?
        public var deviceReportedLatencySeconds: Double?
        public var deviceBufferFrames: Int?
        public var deviceVirtualFormats: [PlaybackAudioStreamFormat]?
        public var devicePhysicalFormats: [PlaybackAudioStreamFormat]?
        public var dialogue: PlaybackDialogueAssessment?
        public var compressedAudio: PlaybackCompressedAudioAssessment?
        public var spatialAudio: PlaybackSpatialAudioAssessment?
        public var nativeAudio: NativeCompressedAudioObservation?
        public var objectAudio: ObjectAudioObservation?
        public var objectRenderingUnavailable: Bool?
    }

    public enum AudioMode: String, Codable, Sendable {
        case pcm, passthrough, nativeCompressedPreparing, nativeCompressed

        public var description: String {
            switch self {
            case .pcm: "PCM"
            case .passthrough: L10n.text("HDMI 压缩码流")
            case .nativeCompressed: L10n.text("系统原生压缩音频")
            case .nativeCompressedPreparing: L10n.text("原生音频准备中")
            }
        }
    }

    public struct Display: Equatable, Codable, Sendable {
        public var name: String?
        public var currentEDRHeadroom: Double?
        public var potentialEDRHeadroom: Double?
        public var renderBackend: String?
        public var targetFormat: String?
        public var edrEnabled: Bool?
        public var iccSubmission: PlaybackICCSubmission?
        public var toneMapping: String?
        public var referencePeakNits: Int?
        public var videoOutput: PlaybackVideoOutputAssessment?
        public var hdrPresentation: PlaybackHDRPresentation?
        public var timing: PlaybackDisplayTiming?

        public init(
            name: String? = nil,
            currentEDRHeadroom: Double? = nil,
            potentialEDRHeadroom: Double? = nil,
            renderBackend: String? = nil,
            targetFormat: String? = nil,
            edrEnabled: Bool? = nil,
            iccSubmission: PlaybackICCSubmission? = nil,
            timing: PlaybackDisplayTiming? = nil
        ) {
            self.name = name
            self.currentEDRHeadroom = PlaybackVideoOutputPolicy.headroom(currentEDRHeadroom)
            self.potentialEDRHeadroom = PlaybackVideoOutputPolicy.headroom(potentialEDRHeadroom)
            self.renderBackend = renderBackend
            self.targetFormat = targetFormat
            self.edrEnabled = edrEnabled
            self.iccSubmission = iccSubmission
            self.timing = timing
        }

        public var outputDescription: String {
            guard let edrEnabled else { return L10n.text("未知") }
            return edrEnabled ? "EDR" : "SDR"
        }
    }

    public let mediaID: UUID
    public var video: Video
    public var audio: Audio
    public var display: Display
    public var quality: PlaybackQualitySummary?
    public var statistics: PlaybackStatistics?
    public var localInputBytes: Int64?
    public var vodRebufferExperimentTarget: Double?
    public let mpvVersion: String?
    public let ffmpegVersion: String?
    public let decoderDroppedFrames: Int?
    public let rendererDroppedFrames: Int?
    public let audioVideoOffsetSeconds: Double?

    init(
        mediaID: UUID,
        properties: [String: Data],
        fallback: HardwareFallback? = nil,
        display: Display = Display()
    ) {
        func value(_ name: String) -> Any? {
            guard let data = properties[name], data.count <= PlaybackDiagnosticsSampler.maximumPropertyBytes else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
        func object(_ name: String) -> [String: Any] { value(name) as? [String: Any] ?? [:] }
        func text(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.count <= 256 else { return nil }
            // Decoder facts have a small vocabulary. Arbitrary paths, URLs,
            // track titles, device UIDs and free-form metadata are never kept.
            guard text.range(of: #"^[a-zA-Z0-9 ._+():,-]+$"#, options: .regularExpression) != nil,
                  !text.contains("://"), !text.contains("/Users/"),
                  !text.contains("@"), !text.contains("=") else { return nil }
            return text
        }
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        func color(_ value: Any?) -> String? {
            guard let result = text(value), !["auto", "unknown", "unspecified"].contains(result) else { return nil }
            return result
        }
        func integer(_ value: Any?, maximum: Int = 1_000_000_000, minimum: Int = 1) -> Int? {
            guard let n = number(value), n >= Double(minimum), n <= Double(maximum), n.rounded() == n else { return nil }
            return Int(n)
        }
        let track = object("current-tracks/video")
        let params = object("video-dec-params")
        let interpreted = object("video-params")
        let pixel = text(params["hw-pixelformat"]) ?? text(params["pixelformat"])
        let hardware = text(value("hwdec-current"))
        let requestedHardware = text(value("hwdec"))
            ?? (value("hwdec") as? [String]).flatMap { text($0.joined(separator: ",")) }
        let staticMetadata = ["max-luma", "max-cll", "max-fall"].contains { (number(params[$0]) ?? 0) > 0 }
        let dynamicMetadata = text(params["colormatrix"]) == "dolbyvision"
            || ["scene-max-r", "scene-max-g", "scene-max-b"].contains { (number(params[$0]) ?? 0) > 0 }
        let fps = number(value("container-fps"))
        self.mediaID = mediaID
        self.video = Video(
            codec: text(track["codec"]),
            profile: text(track["codec-profile"]),
            decoder: text(track["decoder"]),
            width: integer(params["w"], maximum: 65_536),
            height: integer(params["h"], maximum: 65_536),
            framesPerSecond: fps.flatMap { $0 > 0 && $0 <= 1_000 ? $0 : nil },
            pixelFormat: pixel,
            bitDepth: Self.bitDepth(pixelFormat: pixel),
            matrix: color(params["colormatrix"]),
            range: color(params["colorlevels"]),
            primaries: color(params["primaries"]),
            transfer: color(params["gamma"]),
            interpretedPrimaries: color(interpreted["primaries"]),
            interpretedTransfer: color(interpreted["gamma"]),
            interpretedMatrix: color(interpreted["colormatrix"]),
            interpretedRange: color(interpreted["colorlevels"]),
            dolbyVisionProfile: integer(track["dolby-vision-profile"], maximum: 20),
            streamIndex: integer(track["ff-index"], maximum: 1_000_000, minimum: 0),
            staticHDRMetadataDetected: staticMetadata ? true : nil,
            dynamicHDRMetadataDetected: dynamicMetadata ? true : nil,
            hardwareDecoder: hardware,
            requestedHardwareDecoder: requestedHardware,
            fallback: hardware == "no" ? (requestedHardware == "no" ? .disabled : fallback ?? .notReported) : nil
        )
        let audioTrack = object("current-tracks/audio")
        let input = object("audio-params")
        let output = object("audio-out-params")
        let format = text(output["format"])
        let driver = text(value("current-ao"))
        let hasAudio = !audioTrack.isEmpty
        let pcmFormats = PlaybackDSDAssessment.pcmFormats
        let codec = text(audioTrack["codec"])
        let demuxRate = integer(audioTrack["demux-samplerate"], maximum: 3_072_000)
        let decodedFormat = hasAudio ? text(input["format"]) : nil
        let dsd = PlaybackDSDAssessment(codec: codec, demuxSampleRate: demuxRate, decodedFormat: decodedFormat)
        let nativeAudio = NativeCompressedAudioObservation(object("netvplayer-audio"))
        let mode: AudioMode? = hasAudio && driver != nil && driver != "null"
            ? (format?.hasPrefix("spdif-") == true
                ? (driver == "avfoundation" ? (nativeAudio?.rendererState == 2 ? nil
                    : (nativeAudio?.isRendering == true ? .nativeCompressed : .nativeCompressedPreparing)) : .passthrough)
                : (pcmFormats.contains(format ?? "") ? .pcm : nil))
            : nil
        self.audio = Audio(
            trackID: integer(audioTrack["id"], maximum: 1_000_000, minimum: 0).map(String.init),
            codec: codec,
            profile: text(audioTrack["codec-profile"]),
            decoder: text(audioTrack["decoder"]),
            demuxSampleRate: demuxRate,
            // DST is compressed DSD; its source-rate semantics are not covered
            // by the four uncompressed codecs verified here.
            sourceSampleRate: codec == "dst" ? nil : (dsd != nil ? dsd?.sourceBitSampleRate : demuxRate),
            sourceChannelCount: integer(audioTrack["demux-channel-count"], maximum: 64),
            inputFormat: decodedFormat,
            dsd: dsd,
            inputLayout: hasAudio ? text(input["hr-channels"]) ?? text(input["channels"]) : nil,
            inputChannels: hasAudio ? text(input["channels"]) : nil,
            inputChannelCount: hasAudio ? integer(input["channel-count"], maximum: 64) : nil,
            inputSampleRate: hasAudio ? integer(input["samplerate"], maximum: 3_072_000) : nil,
            outputLayout: hasAudio ? text(output["hr-channels"]) ?? text(output["channels"]) : nil,
            outputChannels: hasAudio ? text(output["channels"]) : nil,
            outputChannelCount: hasAudio ? integer(output["channel-count"], maximum: 64) : nil,
            outputSampleRate: hasAudio ? integer(output["samplerate"], maximum: 3_072_000) : nil,
            outputFormat: hasAudio ? format : nil,
            outputDriver: hasAudio ? driver : nil,
            mode: mode
        )
        if hasAudio {
            self.audio.nativeAudio = nativeAudio
            self.audio.objectAudio = ObjectAudioObservation(object("netvplayer-object-audio"))
            self.audio.compressedAudio = .init(codec: self.audio.codec, profile: self.audio.profile,
                mode: mode, passthroughProperty: properties["options/audio-spdif"], nativeAudio: nativeAudio)
            self.audio.spatialAudio = .init(driver: self.audio.outputDriver, mode: mode,
                objects: self.audio.objectAudio, decoder: self.audio.decoder, outputChannels: self.audio.outputChannelCount)
        }
        self.display = display
        let curve = text(value("options/tone-mapping"))
        self.display.toneMapping = curve.flatMap { PlaybackColorPolicy.curves.contains($0) ? $0 : nil }
        self.display.referencePeakNits = integer(value("options/target-peak"), maximum: 203, minimum: 80)
        self.mpvVersion = text(value("mpv-version"))
        self.ffmpegVersion = text(value("ffmpeg-version"))
        self.decoderDroppedFrames = integer(value("decoder-frame-drop-count"), minimum: 0)
        self.rendererDroppedFrames = integer(value("frame-drop-count"), minimum: 0)
        self.audioVideoOffsetSeconds = number(value("avsync")).flatMap { abs($0) <= 60 ? $0 : nil }
    }

    static func bitDepth(pixelFormat: String?) -> Int? {
        guard let format = pixelFormat?.lowercased() else { return nil }
        if ["nv12", "nv21", "yuv420p", "yuv422p", "yuv444p", "yuvj420p", "yuvj422p", "yuvj444p",
            "rgba", "bgra", "rgb24", "bgr24", "rgb0", "bgr0", "gbrp", "gray"].contains(format) { return 8 }
        if ["p010", "p010le", "p010be"].contains(format) { return 10 }
        if ["p016", "p016le", "p016be"].contains(format) { return 16 }
        let pattern = #"^(?:yuva?[0-9]+p|gbrap|gbrp|gray)(9|10|12|14|16)(?:le|be)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: format, range: NSRange(format.startIndex..., in: format)),
              let range = Range(match.range(at: 1), in: format) else { return nil }
        return Int(format[range])
    }

    /// Exports typed facts only. Human-assigned device/display names can contain
    /// account information, so the default export omits them as well.
    public func redactedJSON() -> String {
        var redacted = self
        redacted.display.name = nil
        redacted.audio.deviceName = nil
        redacted.audio.systemDefaultDeviceName = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(redacted), data.count <= 16_384 else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One in-flight batch, at most 1 Hz, 64 KiB total; IDs are never reused on reset.
/// A late native reply must match the original request and media, not the owner
/// observed while draining the event queue.
struct PlaybackDiagnosticsSampler {
    static let maximumPropertyBytes = 8_192
    static let maximumSampleBytes = 65_536
    static let properties = [
        "current-tracks/video", "video-dec-params", "video-params", "container-fps", "hwdec-current", "hwdec",
        "current-tracks/audio", "audio-params", "audio-out-params", "current-ao",
        "mpv-version", "ffmpeg-version",
            "options/tone-mapping", "options/target-peak", "af", "options/audio-spdif", "netvplayer-audio", "netvplayer-object-audio"
    ]
    static let presentationProperties = [
        "estimated-vf-fps", "video-bitrate", "audio-bitrate",
        "decoder-frame-drop-count", "frame-drop-count", "avsync"
    ]
    private(set) var presentationGeneration: UInt64?
    struct Request: Equatable {
        let id: UInt64
        let name: String
    }
    private var nextID: UInt64 = 0xA000_0000_0000_0000
    private var owner: UUID?
    private var pending: [UInt64: String] = [:]
    private var values: [String: Data] = [:]
    private var bytes = 0
    private var startedAt: TimeInterval = 0
    private var nextSampleAt: TimeInterval = 0

    mutating func reset() {
        owner = nil
        pending.removeAll()
        values.removeAll()
        bytes = 0
        nextSampleAt = 0
        presentationGeneration = nil
    }

    mutating func begin(owner: UUID, now: TimeInterval, additionalProperties: [String] = [],
                        presentationGeneration: UInt64? = nil) -> [Request] {
        guard pending.isEmpty, now >= nextSampleAt else { return [] }
        self.owner = owner
        self.presentationGeneration = presentationGeneration
        values.removeAll()
        bytes = 0
        startedAt = now
        nextSampleAt = now + 1
        var seen: Set<String> = []
        return (Self.properties + additionalProperties).filter { seen.insert($0).inserted }.map { name in
            nextID += 1
            pending[nextID] = name
            return Request(id: nextID, name: name)
        }
    }

    mutating func receive(id: UInt64, name: String, json: String?, owner: UUID) -> [String: Data]? {
        guard self.owner == owner, let expected = pending[id], name.isEmpty || expected == name else { return nil }
        pending.removeValue(forKey: id)
        if let json, json.utf8.count <= Self.maximumPropertyBytes,
           bytes + json.utf8.count <= Self.maximumSampleBytes {
            let data = Data(json.utf8)
            if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                values[expected] = data
                bytes += data.count
            }
        }
        return pending.isEmpty ? values : nil
    }

    mutating func expire(owner: UUID, now: TimeInterval) -> [String: Data]? {
        guard self.owner == owner, !pending.isEmpty, now - startedAt >= 2 else { return nil }
        pending.removeAll()
        return values
    }
}
