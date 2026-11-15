import Foundation
import Models
import MPVShim

/// Source observations and the limitations of the production embedded renderer.
/// A container flag is not evidence that an RPU was decoded or applied.
public struct PlaybackDolbyVision: Equatable, Codable, Sendable {
    public enum Route: String, Codable, Sendable {
        case hdr10BaseLayer, hlgBaseLayer, sdrBaseLayer, blockedProfile5, blockedUnverified
        case preparingReconstruction, reconstructed, reconstructedFEL, blockedRendererFailure
        public var description: String {
            switch self {
            case .hdr10BaseLayer: L10n.text("HDR10 基础层 → SDR；未使用 DV 重建或动态映射")
            case .hlgBaseLayer: L10n.text("HLG 基础层 → SDR；未使用 DV 重建或动态映射")
            case .sdrBaseLayer: L10n.text("SDR 基础层；未使用 DV 重建或动态映射")
            case .blockedProfile5: L10n.text("当前渲染路线不支持 Dolby Vision Profile 5 颜色重建，已隐藏视频并暂停。请选择 HDR10／SDR 版本。")
            case .blockedUnverified: L10n.text("Dolby Vision 基础层兼容性未确认，已隐藏视频并暂停。请选择 HDR10／SDR 版本。")
            case .preparingReconstruction: L10n.text("正在准备 Dolby Vision 画面")
            case .reconstructed: L10n.text("Dolby Vision 动态元数据重建与色调映射")
            case .reconstructedFEL: L10n.text("Dolby Vision FEL 增强层合成与动态色调映射")
            case .blockedRendererFailure: L10n.text("Dolby Vision 画面重建失败，播放已暂停。请重试或切换版本。")
            }
        }
        public var blocksVideo: Bool { [.blockedProfile5, .blockedUnverified, .blockedRendererFailure].contains(self) }
    }
    public var profile: Int?
    public var configurationProfile: Int?
    public var level: Int?
    public var compatibilityID: Int?
    public var configurationRPUFlag: Bool?
    public var enhancementLayerFlag: Bool?
    public var baseLayerFlag: Bool?
    public var decodedRPUDetected: Bool?
    public var decodedMetadataDetected: Bool?
    public var runtimeFrameMetadataDetected: Bool?
    public var rpuHeaderProfile: Int?
    public var rpuInferredProfile: Int?
    public var evidenceConflict: Bool
    public var localProbeStatus: String?
    public var route: Route
    public private(set) var dynamicMappingApplied = false
    public private(set) var dolbyVisionSignalSent = false
    public var renderer: DolbyRendererObservation? = nil
    public var systemPresentation: DolbyVisionSystemPresentation? = nil

    static func assess(video: PlaybackDiagnostics.Video, local: LocalDolbyVisionObservation?,
                       trackIndex: Int?, renderer: DolbyRendererObservation? = nil) -> Self? {
        // An observation of a different track must never bless the selected one.
        let observed = local.flatMap { $0.streamIndex == trackIndex ? $0 : nil }
        let profile = video.dolbyVisionProfile ?? observed?.profile ?? observed?.rpuInferredProfile
        let frameMetadata = video.matrix == "dolbyvision" || observed?.frameMetadata == true
        guard profile != nil || frameMetadata || observed?.frameRPU == true else { return nil }
        let profiles = [video.dolbyVisionProfile, observed?.profile, observed?.rpuInferredProfile].compactMap { $0 }
        let conflict = Set(profiles).count > 1
        let compatibility = observed?.compatibilityID
        let route: Route
        if !conflict, let renderer, renderer.supportsReconstruction {
            if renderer.failed { route = .blockedRendererFailure }
            else if renderer.frameReconstructed { route = renderer.frameFEL ? .reconstructedFEL : .reconstructed }
            else if video.matrix == "dolbyvision", renderer.frames == 0 { route = .preparingReconstruction }
            else { route = .blockedUnverified }
        } else if profile == 5 { route = .blockedProfile5 }
        else if !conflict, profile == 8, observed?.status == "first-frame-inspected",
                observed?.baseLayer == true, observed?.enhancementLayer == false {
            switch compatibility {
            case 1: route = .hdr10BaseLayer
            case 2: route = .sdrBaseLayer
            case 4: route = .hlgBaseLayer
            default: route = .blockedUnverified
            }
        } else { route = .blockedUnverified }
        let inspected = observed?.status == "first-frame-inspected"
        var result = Self(profile: profile, configurationProfile: video.dolbyVisionProfile ?? observed?.profile,
                     level: observed?.level, compatibilityID: compatibility,
                     configurationRPUFlag: observed?.rpuFlag, enhancementLayerFlag: observed?.enhancementLayer,
                     baseLayerFlag: observed?.baseLayer, decodedRPUDetected: inspected ? observed?.frameRPU : nil,
                     decodedMetadataDetected: inspected ? observed?.frameMetadata : nil,
                     runtimeFrameMetadataDetected: video.matrix == "dolbyvision" ? true : nil,
                     rpuHeaderProfile: observed?.rpuHeaderProfile,
                     rpuInferredProfile: observed?.rpuInferredProfile,
                     evidenceConflict: conflict, localProbeStatus: observed?.status, route: route)
        result.renderer = renderer
        result.dynamicMappingApplied = !conflict && renderer?.frameReconstructed == true && !route.blocksVideo
        return result
    }
}

/// Observations from the active GPU renderer, reset by the runtime on media or
/// timeline changes. Capability alone never means a Dolby frame was rendered.
public struct DolbyRendererObservation: Equatable, Codable, Sendable {
    public var capabilities: UInt64
    public var generation: UInt64
    public var frames: UInt64
    public var doviFrames: UInt64
    public var enhancementFrames: UInt64
    public var felFrames: UInt64
    public var failures: UInt64
    public var frameFlags: UInt64
    public var pts: Double
    public var supportsReconstruction: Bool { capabilities & 3 == 3 }
    public var failed: Bool { frameFlags & 8 != 0 }
    public var frameReconstructed: Bool { !failed && frameFlags & 1 != 0 && doviFrames > 0 }
    public var frameFEL: Bool { frameReconstructed && frameFlags & 4 != 0 && felFrames > 0 }

    static func read(_ context: OpaquePointer) -> Self? {
        let value = nv_mpv_dolby_renderer_status(context)
        guard value.version == 1, value.capabilities != 0 else { return nil }
        return .init(capabilities: value.capabilities, generation: value.generation,
                     frames: value.rendered_frames, doviFrames: value.dovi_frames,
                     enhancementFrames: value.enhancement_frames, felFrames: value.fel_frames,
                     failures: value.failures, frameFlags: value.frame_flags, pts: value.pts)
    }
}

struct LocalDolbyVisionObservation: Equatable, Sendable {
    var profile: Int?, level: Int?, compatibilityID: Int?
    var rpuFlag: Bool?, enhancementLayer: Bool?, baseLayer: Bool?
    var frameRPU: Bool, frameMetadata: Bool
    var rpuHeaderProfile: Int?
    var rpuInferredProfile: Int?
    var streamIndex: Int?
    var status: String

    static func read(library: String, file: URL) -> Self {
        let p = nv_mpv_probe_local_dovi(library, file.path)
        func positive(_ value: Int32) -> Int? { value >= 0 ? Int(value) : nil }
        func flag(_ value: Int32) -> Bool? { value >= 0 ? value != 0 : nil }
        return .init(profile: positive(p.profile), level: positive(p.level), compatibilityID: positive(p.compatibility_id),
                     rpuFlag: flag(p.rpu_flag), enhancementLayer: flag(p.el_flag), baseLayer: flag(p.bl_flag),
                     frameRPU: p.frame_rpu != 0, frameMetadata: p.frame_metadata != 0,
                     rpuHeaderProfile: positive(p.rpu_profile),
                     rpuInferredProfile: p.inferred_profile > 0 ? Int(p.inferred_profile) : nil,
                     streamIndex: positive(p.stream_index),
                     status: p.status == 1 ? "first-frame-inspected" : p.status == 2 ? "budget-exhausted" : "unavailable")
    }
}

/// One filesystem/decoder probe at a time across both engines. Cancelled queued
/// media never start a decode, and a retired in-flight read cannot publish results.
actor LocalDolbyVisionProbeWorker {
    static let shared = LocalDolbyVisionProbeWorker()
    func read(library: String, file: URL) -> LocalDolbyVisionObservation? {
        guard !Task.isCancelled else { return nil }
        let result = LocalDolbyVisionObservation.read(library: library, file: file)
        return Task.isCancelled ? nil : result
    }
}
