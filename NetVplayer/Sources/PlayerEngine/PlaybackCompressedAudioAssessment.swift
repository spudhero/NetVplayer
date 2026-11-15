import Foundation
import Models

/// Decoder profile, engine output and receiver evidence have separate owners.
/// No application API currently supplies receiver/object confirmation. HDMI
/// bitstream output requires a verified compressed HAL format in the runtime.
public struct PlaybackCompressedAudioAssessment: Equatable, Codable, Sendable {
    public enum SourceFormat: String, Codable, Sendable {
        case ac3, eac3, eac3JOCReported, eac3JOCParsed, trueHD, trueHDAtmosReported, dts, dtsHD, other

        public var description: String {
            switch self {
            case .ac3: "AC-3"
            case .eac3: L10n.text("E-AC-3（JOC 未确认）")
            case .eac3JOCReported: L10n.text("E-AC-3 JOC（片源标记）")
            case .eac3JOCParsed: L10n.text("E-AC-3 JOC（已解析 Atmos 元数据）")
            case .trueHD: L10n.text("TrueHD（Atmos 未确认）")
            case .trueHDAtmosReported: L10n.text("TrueHD Atmos（片源标记）")
            case .dts: "DTS"
            case .dtsHD: "DTS-HD"
            case .other: L10n.text("其他或未知编码")
            }
        }
    }

    public enum Output: String, Codable, Sendable {
        case decodedPCM, encodedStreamObserved, nativeCompressedPreparing, nativeCompressed, unknown

        public var description: String {
            switch self {
            case .decodedPCM: L10n.text("PCM 解码输出")
            case .encodedStreamObserved: L10n.text("引擎报告压缩码流；接收端未确认")
            case .nativeCompressed: L10n.text("原始压缩音频交由系统解码与空间渲染")
            case .nativeCompressedPreparing: L10n.text("原生音频已就绪，等待播放数据")
            case .unknown: L10n.text("尚未确认音频输出")
            }
        }
    }

    public enum Request: String, Codable, Sendable {
        case disabled, requested, unknown

        public var description: String {
            switch self {
            case .disabled: L10n.text("未请求压缩直通")
            case .requested: L10n.text("已请求；不代表实际直通")
            case .unknown: L10n.text("直通请求未知")
            }
        }
    }

    /// Deliberately has no confirmed case: a codec/profile, HDMI transport,
    /// channel count or mpv spdif format cannot establish receiver Atmos.
    public enum ReceiverAtmos: String, Codable, Sendable {
        case unverified
        public var description: String { L10n.text("未确认接收端及 Atmos 对象输出") }
    }

    public let sourceFormat: SourceFormat
    public let output: Output
    public let passthroughRequest: Request
    public let receiverAtmos: ReceiverAtmos

    init(codec: String?, profile: String?, mode: PlaybackDiagnostics.AudioMode?, passthroughProperty: Data?,
         nativeAudio: NativeCompressedAudioObservation? = nil) {
        // Only the decoder's exact, fixed FFmpeg profile vocabulary is used.
        // Track titles, filenames and arbitrary strings containing Atmos are
        // excluded, and an absent profile never proves absence of objects.
        switch codec?.lowercased() {
        case "ac3": sourceFormat = .ac3
        case "eac3": sourceFormat = nativeAudio?.joc == true ? .eac3JOCParsed
            : (profile == "Dolby Digital Plus + Dolby Atmos" ? .eac3JOCReported : .eac3)
        case "truehd": sourceFormat = profile == "Dolby TrueHD + Dolby Atmos" ? .trueHDAtmosReported : .trueHD
        case "dts": sourceFormat = ["DTS-HD HRA", "DTS-HD MA", "DTS-HD MA + DTS:X", "DTS-HD MA + DTS:X IMAX", "DTS Express"].contains(profile ?? "") ? .dtsHD : .dts
        default: sourceFormat = .other
        }
        switch mode {
        case .pcm: output = .decodedPCM
        case .passthrough: output = .encodedStreamObserved
        case .nativeCompressed: output = .nativeCompressed
        case .nativeCompressedPreparing: output = .nativeCompressedPreparing
        case nil: output = .unknown
        }
        if let data = passthroughProperty, data.count <= PlaybackDiagnosticsSampler.maximumPropertyBytes,
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let list = value as? [String] {
                passthroughRequest = list.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ? .disabled : .requested
            } else if let text = value as? String {
                passthroughRequest = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .disabled : .requested
            } else { passthroughRequest = .unknown }
        } else { passthroughRequest = .unknown }
        receiverAtmos = .unverified
    }
}
