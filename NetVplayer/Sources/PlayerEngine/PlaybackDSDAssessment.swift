import Foundation
import Models

/// Source identification never uses a filename, PCM rate or device capabilities.
public struct PlaybackDSDAssessment: Equatable, Codable, Sendable {
    public enum Processing: String, Codable, Sendable {
        case decodedPCM, unconfirmed

        public var description: String {
            switch self {
            case .decodedPCM: L10n.text("DSD 已解码为 PCM")
            case .unconfirmed: L10n.text("DSD 解码格式未确认")
            }
        }
    }

    public let sourceBitSampleRate: Int?
    public let processing: Processing

    static let codecs: Set<String> = ["dsd_lsbf", "dsd_msbf", "dsd_lsbf_planar", "dsd_msbf_planar"]
    static let pcmFormats: Set<String> = ["u8", "u8p", "s16", "s16p", "s32", "s32p", "s64", "s64p", "float", "floatp", "double", "doublep"]

    init?(codec: String?, demuxSampleRate: Int?, decodedFormat: String?) {
        guard let codec, Self.codecs.contains(codec) else { return nil }
        // Frozen FFmpeg DSF/DFF demuxers expose bytes per second per channel;
        // their DSD decoder emits one float PCM sample per input byte. Do not
        // derive this from audio-params, which may be missing or resampled.
        sourceBitSampleRate = demuxSampleRate.flatMap { (1...3_072_000).contains($0) ? $0 * 8 : nil }
        processing = Self.pcmFormats.contains(decodedFormat ?? "") ? .decodedPCM : .unconfirmed
    }
}
