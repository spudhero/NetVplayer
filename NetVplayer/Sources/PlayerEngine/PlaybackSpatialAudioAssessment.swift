import Foundation
import Models

/// The AO identifies a delivery route, never a listening effect. Neither an
/// Atmos source profile nor stereo output proves spatialization or head tracking.
public struct PlaybackSpatialAudioAssessment: Equatable, Codable, Sendable {
    public enum Route: String, Codable, Sendable {
        case coreAudioPCM, avFoundationPCM, nativeCompressed, otherPCM, encoded, unavailable

        public var description: String {
            switch self {
            case .coreAudioPCM: L10n.text("CoreAudio PCM；未确认系统空间化")
            case .avFoundationPCM: L10n.text("AVFoundation PCM；未确认系统空间化")
            case .nativeCompressed: L10n.text("原生压缩音频；系统按输出设备进行空间渲染")
            case .otherPCM: L10n.text("其他 PCM 路线；空间化未确认")
            case .encoded: L10n.text("压缩码流；空间渲染由接收端决定")
            case .unavailable: L10n.text("尚未确认音频输出")
            }
        }
    }

    public enum ApplicationBinaural: String, Codable, Sendable {
        case notEnabled, hrtf
        public var description: String {
            self == .hrtf ? L10n.text("应用 HRTF 双耳渲染运行中") : L10n.text("应用未启用虚拟环绕")
        }
    }
    public enum SystemSpatialAudio: String, Codable, Sendable {
        case unverified
        public var description: String { L10n.text("系统空间音频未确认") }
    }
    public enum HeadTracking: String, Codable, Sendable {
        case unverified, waitingForPose, receivingPose
        public var description: String {
            switch self {
            case .unverified: L10n.text("未取得实际姿态与方向响应")
            case .waitingForPose: L10n.text("等待耳机姿态；当前固定空间音频")
            case .receivingPose: L10n.text("已接入实时耳机姿态；听感待实机验收")
            }
        }
    }
    public enum AtmosRendering: String, Codable, Sendable {
        case unverified, applicationObjects, partialFallback
        public var description: String {
            switch self {
            case .unverified: L10n.text("未验证 Atmos 对象渲染")
            case .applicationObjects: L10n.text("TrueHD 对象与位置已参与应用渲染；设备效果待验收")
            case .partialFallback: L10n.text("对象渲染存在回退或解码错误，详见诊断")
            }
        }
    }

    public let route: Route
    public let applicationBinaural: ApplicationBinaural
    public let systemSpatialAudio: SystemSpatialAudio
    public let headTracking: HeadTracking
    public let atmosRendering: AtmosRendering

    init(driver: String?, mode: PlaybackDiagnostics.AudioMode?, objects: ObjectAudioObservation? = nil,
         decoder: String? = nil, outputChannels: Int? = nil) {
        switch mode {
        case .pcm:
            switch driver {
            case "coreaudio", "coreaudio_exclusive": route = .coreAudioPCM
            case "avfoundation": route = .avFoundationPCM
            case nil, "null": route = .unavailable
            default: route = .otherPCM
            }
        case .passthrough: route = .encoded
        case .nativeCompressed, .nativeCompressedPreparing: route = .nativeCompressed
        case nil: route = .unavailable
        }
        let live = mode == .pcm && route != .unavailable && decoder?.hasPrefix("truehd_objects_") == true ? objects : nil
        applicationBinaural = live?.isBinaural == true && outputChannels == 2 ? .hrtf : .notEnabled
        systemSpatialAudio = .unverified
        headTracking = applicationBinaural == .hrtf && live?.trackingRequested == true
            ? (live?.hasLiveTracking == true ? .receivingPose : .waitingForPose) : .unverified
        atmosRendering = live?.hasFallback == true ? .partialFallback
            : (live?.hasRenderedObjects == true ? .applicationObjects : .unverified)
    }
}
