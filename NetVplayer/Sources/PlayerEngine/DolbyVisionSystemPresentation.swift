import Foundation
import Storage
import MPVShim

@MainActor
func renderDolbyVisionFrame(context: OpaquePointer, surface: NVDolbyVisionSurface, width: Int32, height: Int32) -> Int32 {
    if surface.sourceMetadataEnabled && nv_mpv_dolby_renderer_status(context).capabilities & 32 != 0 {
        return nv_mpv_render_fp16_source(context, surface.framebuffer, width, height,
            nv_mpv_capture_dolby_source, Unmanaged.passUnretained(surface).toOpaque())
    }
    return nv_mpv_render_fp16(context, surface.framebuffer, width, height, 0)
}

/// A regenerated HLG image or compatible untouched source image was submitted.
/// This cannot observe system RPU use, HDMI VSIF packets or the TV's mode.
public struct DolbyVisionSystemPresentation: Equatable, Codable, Sendable {
    public let metadataFrames: UInt64
    public let submittedFrames: UInt64
    public let metadataBytes: Int
    public let currentFrameSubmitted: Bool
    public let readyForDisplay: Bool
    public let lastError: Int
    public let outputProfile: String
    public let metadataOrigin: String
    public var sourceCaptureReason: String? = nil
    public var sourceDisableResidual: Int? = nil
    public var sourceCopyMilliseconds: Double? = nil

    static func read(facts: [String: Any], renderer: DolbyRendererObservation?, sameMedia: Bool) -> Self {
        func number(_ key: String) -> NSNumber? { facts[key] as? NSNumber }
        let frames = number("submittedFrames")?.uint64Value ?? 0
        let metadataFrames = number("metadataFrames")?.uint64Value ?? 0
        let bytes = number("metadataBytes")?.intValue ?? 0
        let error = number("lastError")?.intValue ?? -1
        let status = number("rendererStatus")?.intValue
        let matches = renderer.map { $0.frameReconstructed && $0.pts.isFinite &&
            $0.generation == number("generation")?.uint64Value &&
            abs($0.pts - (number("lastPTS")?.doubleValue ?? .infinity)) < 0.000_001 } ?? false
        let origin = facts["metadataOrigin"] as? String
        let source = origin == "source-rpu-unmodified"
        let profile = facts["outputProfile"] as? String
        let sourceProof = !source || (number("sourceRPUBytesPreserved")?.boolValue == true &&
            number("sourceDisableResidual")?.intValue == 1 &&
            number("sourceRPUBytes")?.intValue == bytes && (profile == "8.1" || profile == "8.4"))
        return .init(metadataFrames: metadataFrames, submittedFrames: frames,
            metadataBytes: bytes, currentFrameSubmitted: sameMedia && matches && frames > 0 && bytes > 0 && error == 0 &&
                metadataFrames >= frames && sourceProof && number("currentMetadataSubmitted")?.boolValue == true &&
                (status == 0 || status == 1),
            readyForDisplay: number("readyForDisplay")?.boolValue == true, lastError: error,
            outputProfile: source ? (profile ?? "unknown") : "8.4",
            metadataOrigin: source ? "source-rpu-unmodified" : "system-regenerated+gpu-l1",
            sourceCaptureReason: facts["sourceCaptureReason"] as? String,
            sourceDisableResidual: number("sourceDisableResidual")?.intValue,
            sourceCopyMilliseconds: number("sourceCopyMS")?.doubleValue)
    }
}

enum DolbyVisionSystemPresentationPolicy {
    static func sourceCompatibility(_ video: PlaybackDolbyVision?, options: [String: String]) -> Int32 {
        guard let video, !video.evidenceConflict, video.configurationProfile == 8,
              video.configurationRPUFlag == true, video.baseLayerFlag == true,
              video.enhancementLayerFlag == false,
              let compatibility = video.compatibilityID, [1, 4].contains(compatibility) else { return 0 }
        // Source filters can change pixels while retaining side data. This first
        // experiment only accepts the unfiltered source; geometry/OSD is also
        // checked at the actual rendered frame in the runtime.
        guard !options.keys.contains(where: { $0 == "vf" || $0.hasPrefix("vf-") ||
            ["brightness", "contrast", "saturation", "gamma", "hue", "glsl-shaders"].contains($0) }) else { return 0 }
        return Int32(compatibility)
    }
    static func eligible(preference: PlaybackColorPreference, reconstructed: Bool,
                         hasHDRPresentation: Bool, systemAvailable: Bool, failed: Bool) -> Bool {
        preference.systemDolbyVision && preference.videoOutput != .sdr && reconstructed &&
            hasHDRPresentation && systemAvailable && !failed
    }

    /// Apple currently generates a real payload for BT.2020/HLG. PQ or linear
    /// input can return success without any RPU. Never just retag EDR pixels.
    /// This is a new 1000-nit HLG mapping, not preservation of the source grade.
    static let options = [
        "target-prim": "bt.2020", "target-trc": "hlg", "target-peak": "1000",
        "icc-profile-auto": "no", "icc-profile": "", "dither-depth": "no",
        "fbo-format": "rgba32f", "tone-mapping": "bt.2390", "tone-mapping-param": "1",
        "gamut-mapping-mode": "clip", "blend-subtitles": "no"
    ]
}
