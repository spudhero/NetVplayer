import Foundation
import Models
import Storage

extension PlaybackVideoOutputMode {
    public var description: String {
        switch self {
        case .automatic: L10n.text("自动（跟随系统）")
        case .sdr: L10n.text("SDR 映射")
        case .hdrIfAvailable: L10n.text("临时开启 HDR（结束后恢复）")
        }
    }

    public var explanation: String {
        switch self {
        case .automatic:
            L10n.text("跟随系统 HDR 状态，不切换电视模式。系统 HDR 关闭时映射为 SDR；已开启或内建显示器有可用余量时呈现 HDR。")
        case .sdr:
            L10n.text("将 HDR 画面映射为 SDR，不更改系统 HDR 设置。")
        case .hdrIfAvailable:
            L10n.text("仅在 HDR 播放期间临时开启受支持外接显示器的系统 HDR，结束后恢复。切换可能短暂黑屏，并影响整个桌面的显示。")
        }
    }
}

/// Requested policy, actual submitted target and display capability are separate
/// facts. EDR activation requires a submitted floating-point surface and current
/// display headroom. Do not infer measured display nits from EDR ratios.
public struct PlaybackVideoOutputAssessment: Equatable, Codable, Sendable {
    public enum Signal: String, Codable, Sendable {
        case pq, hlg, sdr, dolbyVision, unknown
    }

    public enum Disposition: String, Codable, Sendable {
        case awaitingRender, developmentProbe, edrPresentation, edrPreparing, systemDolbyVisionPresentation, sdrRequested, sdrContent, hdrMappedToSDR, dolbyVisionDeferred, dolbyVisionBaseLayer, dolbyVisionBlocked, unknownContent

        public var description: String {
            switch self {
            case .awaitingRender: L10n.text("等待当前视频画面")
            case .developmentProbe: L10n.text("开发用高精度输出，实屏 HDR 未验证")
            case .edrPresentation: L10n.text("HDR 已通过 EDR 呈现")
            case .edrPreparing: L10n.text("正在请求 EDR，暂按 SDR 白限制高光")
            case .systemDolbyVisionPresentation: L10n.text("已提交系统 DV 呈现，接收端待确认")
            case .sdrRequested: L10n.text("按所选策略使用 SDR 映射")
            case .sdrContent: L10n.text("SDR 片源，使用 SDR 显示")
            case .hdrMappedToSDR: L10n.text("HDR 片源正在映射到 SDR")
            case .dolbyVisionDeferred: L10n.text("Dolby Vision 兼容性待验证，当前使用 SDR 路线")
            case .dolbyVisionBaseLayer: L10n.text("Dolby Vision 兼容基础层正在使用 SDR 路线")
            case .dolbyVisionBlocked: L10n.text("Dolby Vision 视频已安全阻断")
            case .unknownContent: L10n.text("片源动态范围未知，当前使用 SDR 路线")
            }
        }
    }

    public enum HDRRestriction: String, Codable, Sendable {
        case routeNotValidated, displayUnknown, sdrDisplay, headroomUnavailable

        public var description: String {
            switch self {
            case .routeNotValidated: L10n.text("HDR 输出路线尚未通过实屏验收")
            case .displayUnknown: L10n.text("当前显示设备的 EDR 能力未知")
            case .sdrDisplay: L10n.text("当前显示链路未提供 EDR 范围")
            case .headroomUnavailable: L10n.text("当前可用 EDR 余量不足或未知")
            }
        }
    }

    public let requestedMode: PlaybackVideoOutputMode
    public let sourceSignal: Signal
    public let disposition: Disposition
    public let hdrRestrictions: [HDRRestriction]
}

enum PlaybackVideoOutputPolicy {
    /// A finite ratio is a capability observation, never a luminance measurement.
    static func headroom(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 1 ? $0 : nil }
    }

    static func signal(_ video: PlaybackDiagnostics.Video) -> PlaybackVideoOutputAssessment.Signal {
        if video.dolbyVision != nil || video.matrix == "dolbyvision" || (video.dolbyVisionProfile ?? 0) > 0 {
            return .dolbyVision
        } else {
            // Use decoder facts, not filenames, bit depth or inferred output tags.
            switch video.transfer {
            case "pq", "smpte2084": return .pq
            case "hlg", "arib-std-b67": return .hlg
            case "bt.1886", "bt.709", "srgb", "gamma2.2", "gamma2.8": return .sdr
            default: return .unknown
            }
        }
    }

    static func allowsHDRPresentation(mode: PlaybackVideoOutputMode, video: PlaybackDiagnostics.Video) -> Bool {
        mode != .sdr && ([.pq, .hlg].contains(signal(video)) ||
            video.dolbyVision?.dynamicMappingApplied == true)
    }

    /// Only the explicit temporary mode may acquire a system HDR lease.
    /// Automatic can use EDR without taking ownership of a display preference.
    static func requestsSystemHDR(mode: PlaybackVideoOutputMode, video: PlaybackDiagnostics.Video) -> Bool {
        mode == .hdrIfAvailable && allowsHDRPresentation(mode: mode, video: video)
    }

    /// Native EDR may need a bounded surface activation from an idle 1x. On an
    /// external display automatic must first observe HDR already enabled, or
    /// current public EDR headroom. Potential headroom alone cannot authorize a
    /// mode change or turn an SDR desktop into an HDR desktop.
    static func allowsEDRActivation(mode: PlaybackVideoOutputMode, currentHeadroom: Double?,
                                    potentialHeadroom: Double?, isBuiltin: Bool,
                                    systemHDREnabled: Bool?) -> Bool {
        guard mode != .sdr, (headroom(potentialHeadroom) ?? 1) > 1.01 else { return false }
        if mode == .hdrIfAvailable || isBuiltin { return true }
        // A known OFF preference wins over stale headroom during a restore.
        if let systemHDREnabled { return systemHDREnabled }
        return (headroom(currentHeadroom) ?? 1) > 1.01
    }

    static func assess(mode: PlaybackVideoOutputMode, video: PlaybackDiagnostics.Video,
                       display: PlaybackDiagnostics.Display) -> PlaybackVideoOutputAssessment {
        let signal = signal(video)
        var restrictions: [PlaybackVideoOutputAssessment.HDRRestriction] = []
        if let potential = headroom(display.potentialEDRHeadroom) {
            if potential <= 1 { restrictions.append(.sdrDisplay) }
            else if (headroom(display.currentEDRHeadroom) ?? 1) <= 1 { restrictions.append(.headroomUnavailable) }
        } else {
            restrictions.append(.displayUnknown)
        }
        let disposition: PlaybackVideoOutputAssessment.Disposition
        if video.dolbyVision?.route.blocksVideo == true { disposition = .dolbyVisionBlocked }
        else { switch display.targetFormat {
        case "GL_RGBA16F / CVPixelBuffer / HLG":
            disposition = video.dolbyVision?.systemPresentation?.currentFrameSubmitted == true
                ? .systemDolbyVisionPresentation : .awaitingRender
        case "GL_RGBA16F / rgba16Float":
            if let hdr = display.hdrPresentation { disposition = hdr.awaitingHeadroom ? .edrPreparing : .edrPresentation }
            else { disposition = .developmentProbe }
        case "GL_RGBA8":
            if video.dolbyVision?.dynamicMappingApplied == true { disposition = .hdrMappedToSDR }
            else if video.dolbyVision != nil { disposition = .dolbyVisionBaseLayer }
            else if mode == .sdr { disposition = .sdrRequested }
            else {
                switch signal {
                case .sdr: disposition = .sdrContent
                case .pq, .hlg: disposition = .hdrMappedToSDR
                case .dolbyVision: disposition = .dolbyVisionDeferred
                case .unknown: disposition = .unknownContent
                }
            }
        default: disposition = .awaitingRender
        } }
        return .init(requestedMode: mode, sourceSignal: signal, disposition: disposition, hdrRestrictions: restrictions)
    }
}
