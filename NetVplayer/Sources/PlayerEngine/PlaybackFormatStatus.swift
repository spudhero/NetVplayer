import Foundation
import Models

/// Presentation facts for the current session, independent of output preferences
/// and human-assigned track titles. A gold audio format indicates an active
/// matching bitstream route, not a receiver acknowledgement of object rendering.
public struct PlaybackFormatStatus: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case video, audio }
    public enum State: String, Sendable {
        case enabled, hdrEnabled, standard, preparing, system, pcm, encoded, mappedSDR, baseLayer, blocked

        public var title: String {
            switch self {
            case .enabled: L10n.text("已启用")
            case .hdrEnabled: L10n.text("已开启")
            case .standard: L10n.text("标准输出")
            case .preparing: L10n.text("准备中")
            case .system: L10n.text("系统处理")
            case .pcm: L10n.text("已转为 PCM")
            case .encoded: L10n.text("原码输出")
            case .mappedSDR: L10n.text("已转为 SDR")
            case .baseLayer: L10n.text("已回退")
            case .blocked: L10n.text("不可用")
            }
        }

        public var symbol: String {
            switch self {
            case .enabled, .hdrEnabled: "checkmark.circle"
            case .system, .encoded: "chevron.right.2"
            case .pcm, .mappedSDR, .baseLayer: "arrow.turn.down.right"
            case .preparing: "hourglass"
            case .blocked: "exclamationmark.triangle"
            case .standard: "circle"
            }
        }

        public var isEnabled: Bool { self == .enabled || self == .hdrEnabled }
    }

    public struct Detail: Equatable, Sendable {
        public let label: String
        public let value: String
    }

    public let kind: Kind
    public let format: String
    public let state: State
    public let formatIsActive: Bool
    public let actualOutput: String
    public let explanation: String
    public let source: String
    public let device: String?
    public var details: [Detail] = []
    public var presentedHDR = false
    public var outputChannelCount: Int?
    public var id: Kind { kind }
    public var outputIsActive: Bool { formatIsActive && (state.isEnabled || state == .encoded) }

    static func preparing(_ kind: Kind) -> Self {
        .init(kind: kind, format: L10n.text(kind == .video ? "画面格式" : "音频格式"),
              state: .preparing, formatIsActive: false, actualOutput: L10n.text("正在确认实际输出"),
              explanation: L10n.text("收到当前播放会话的实际结果后更新状态。"),
              source: L10n.text("等待片源信息"), device: nil)
    }
}

public struct PlaybackFormatSummary: Equatable, Sendable {
    public let mediaID: UUID?
    public let video: PlaybackFormatStatus?
    public let audio: PlaybackFormatStatus?
    public var items: [PlaybackFormatStatus] { [video, audio].compactMap { $0 } }

    /// Stable across position, frame counters and diagnostic polling. Switching
    /// media, formats or output devices restarts the short on-screen notice.
    public var noticeIdentity: Self? {
        guard mediaID != nil, items.contains(where: { $0.state != .preparing }) else { return nil }
        return self
    }

    public init(diagnostics: PlaybackDiagnostics?, ownerID: UUID?, hasPlayback: Bool,
                selectedAudioTrackID: String? = nil) {
        guard hasPlayback else {
            mediaID = nil; video = nil; audio = nil
            return
        }
        mediaID = ownerID
        guard let diagnostics, let ownerID, diagnostics.mediaID == ownerID else {
            video = .preparing(.video); audio = .preparing(.audio)
            return
        }
        video = Self.videoStatus(diagnostics)
        if let selectedAudioTrackID, diagnostics.audio.trackID != selectedAudioTrackID {
            audio = .preparing(.audio)
        } else {
            audio = Self.audioStatus(diagnostics.audio)
        }
    }

    private static func videoStatus(_ info: PlaybackDiagnostics) -> PlaybackFormatStatus? {
        let video = info.video, display = info.display
        guard video.codec != nil || video.pixelFormat != nil else { return nil }
        let edr = display.edrEnabled == true && display.videoOutput?.disposition == .edrPresentation
        let source = video.dolbyVision != nil ? "Dolby Vision" : video.signalDescription
        var result = PlaybackFormatStatus(kind: .video, format: "SDR", state: .standard,
            formatIsActive: false, actualOutput: L10n.text("SDR 显示"),
            explanation: L10n.text("当前画面以 SDR 呈现。"), source: source, device: display.name)

        if let dv = video.dolbyVision {
            if dv.route.blocksVideo {
                result = .init(kind: .video, format: "Dolby Vision", state: .blocked, formatIsActive: false,
                    actualOutput: L10n.text("杜比视界画面不可用"), explanation: dv.route.description,
                    source: source, device: display.name)
            } else if dv.systemPresentation?.currentFrameSubmitted == true {
                result = .init(kind: .video, format: "Dolby Vision", state: .enabled, formatIsActive: true,
                    actualOutput: L10n.text("系统 DV 呈现 · 待设备确认"),
                    explanation: L10n.text("重建画面已生成新的逐帧杜比视界元数据并提交系统显示层。电视实际接收格式仍待确认。"),
                    source: source, device: display.name)
            } else if dv.dynamicMappingApplied {
                result = .init(kind: .video, format: "Dolby Vision", state: .enabled, formatIsActive: true,
                    actualOutput: edr ? L10n.text("动态映射 · EDR HDR") : L10n.text("动态映射 · SDR 呈现"),
                    explanation: L10n.text("杜比视界动态映射已生效，当前输出为 EDR HDR 或 SDR，不发送电视原生 Dolby Vision 信号。"),
                    source: source, device: display.name)
            } else if dv.route == .preparingReconstruction {
                result = .init(kind: .video, format: "Dolby Vision", state: .preparing, formatIsActive: false,
                    actualOutput: L10n.text("正在准备杜比视界画面"), explanation: dv.route.description,
                    source: source, device: display.name)
            } else {
                let base = dv.route == .hdr10BaseLayer ? "HDR10" : (dv.route == .hlgBaseLayer ? "HDR · HLG" : "SDR")
                result = .init(kind: .video, format: base, state: .baseLayer,
                    formatIsActive: edr && base != "SDR",
                    actualOutput: edr ? L10n.text("HDR 基础层 · EDR 呈现") : L10n.text("兼容基础层 · SDR 呈现"),
                    explanation: L10n.text("当前使用兼容基础层，杜比视界动态映射未启用。"),
                    source: source, device: display.name)
            }
        } else if let vivid = video.hdrVivid {
            result = .init(kind: .video, format: "HDR Vivid",
                state: vivid.dynamicMappingApplied ? .enabled : .baseLayer,
                formatIsActive: vivid.dynamicMappingApplied,
                actualOutput: vivid.dynamicMappingApplied
                    ? (edr ? L10n.text("动态映射 · EDR HDR") : L10n.text("动态映射 · SDR 呈现"))
                    : (edr ? L10n.text("HDR 基础层 · EDR 呈现") : L10n.text("兼容基础层 · SDR 呈现")),
                explanation: vivid.dynamicMappingApplied
                    ? L10n.text("HDR Vivid 动态映射已生效，画面已适配当前显示亮度。")
                    : L10n.text("当前 HDR Vivid 元数据暂不可用，正在使用 PQ 或 HLG 基础画面。"),
                source: "HDR Vivid", device: display.name)
        } else if video.dolbyVisionProfile != nil || video.matrix == "dolbyvision" {
            result = .init(kind: .video, format: "Dolby Vision", state: .preparing, formatIsActive: false,
                actualOutput: L10n.text("正在确认杜比视界画面"),
                explanation: L10n.text("片源标记不代表动态映射已经生效。"), source: "Dolby Vision", device: display.name)
        } else if ["pq", "smpte2084", "hlg", "arib-std-b67"].contains(video.transfer ?? "") {
            if edr {
                result = .init(kind: .video, format: "HDR", state: .hdrEnabled, formatIsActive: true,
                    actualOutput: L10n.text("HDR · EDR 呈现"),
                    explanation: L10n.text("当前画面已通过 EDR 呈现 HDR。"), source: source, device: display.name)
            } else if display.videoOutput?.disposition == .edrPreparing || display.targetFormat == nil {
                result = .init(kind: .video, format: "HDR", state: .preparing, formatIsActive: false,
                    actualOutput: L10n.text("正在确认 HDR 输出"),
                    explanation: L10n.text("HDR 输出尚未确认，点亮状态以当前呈现结果为准。"), source: source, device: display.name)
            } else {
                result = .init(kind: .video, format: "HDR", state: .mappedSDR, formatIsActive: false,
                    actualOutput: L10n.text("HDR → SDR 映射"),
                    explanation: display.videoOutput?.requestedMode == .automatic
                        ? L10n.text("自动模式跟随系统；当前未获得可用 HDR 输出，已映射为 SDR。")
                        : L10n.text("片源为 HDR，当前使用 SDR 映射。"), source: source, device: display.name)
            }
        } else if display.targetFormat == nil {
            return .preparing(.video)
        }
        result.presentedHDR = edr && result.state != .blocked && result.state != .preparing
        result.details = display.videoOutput.map {
            [.init(label: L10n.text("输出策略"), value: $0.requestedMode.description)]
        } ?? []
        result.details += [
            .init(label: L10n.text("呈现格式"), value: display.targetFormat ?? L10n.text("未知")),
            .init(label: L10n.text("色调映射"), value: display.toneMapping ?? L10n.text("未知"))
        ]
        return result
    }

    private static func audioStatus(_ audio: PlaybackDiagnostics.Audio) -> PlaybackFormatStatus? {
        guard audio.codec != nil else { return nil }
        let sourceFormat = audio.compressedAudio?.sourceFormat
        let atmos = sourceFormat == .eac3JOCReported || sourceFormat == .eac3JOCParsed || sourceFormat == .trueHDAtmosReported
        let matchingEncodedFormat = (audio.codec?.lowercased() == "eac3" && audio.outputFormat == "spdif-eac3")
            || (audio.codec?.lowercased() == "truehd" && audio.outputFormat == "spdif-truehd")
        let encodedAtmos = atmos && audio.mode == .passthrough && matchingEncodedFormat
            && audio.outputDriver.map { !$0.isEmpty && $0 != "null" } == true
        let encodedDTS = audio.codec?.lowercased() == "dts" && audio.outputFormat == "spdif-dts"
            && audio.mode == .passthrough && audio.outputDriver.map { !$0.isEmpty && $0 != "null" } == true
        let encodedDTSHD = audio.codec?.lowercased() == "dts" && audio.outputFormat == "spdif-dtshd"
            && ["DTS-HD MA", "DTS-HD MA + DTS:X", "DTS-HD MA + DTS:X IMAX"].contains(audio.profile ?? "")
            && audio.mode == .passthrough && audio.outputDriver.map { !$0.isEmpty && $0 != "null" } == true
        let source = audio.compressedAudio.flatMap { assessment in
            assessment.sourceFormat == .other ? nil : assessment.sourceFormat.description
        } ?? audio.codec?.uppercased() ?? L10n.text("未知")
        let dtsCore = sourceFormat == .dtsHD
        let format = atmos ? "Dolby Atmos" : (encodedDTSHD ? "DTS-HD MA" : (encodedDTS ? (dtsCore ? L10n.text("DTS 核心") : "DTS")
            : (audio.mode == .pcm ? "PCM" : L10n.text("音频"))))
        let state: PlaybackFormatStatus.State
        let actual: String, explanation: String
        switch audio.mode {
        case .pcm:
            state = atmos ? .pcm : .standard
            actual = pcmDescription(audio)
            explanation = atmos
                ? L10n.text("当前以 PCM 输出，未确认杜比全景声对象渲染。")
                : L10n.text("声道与采样率来自当前实际输出。")
        case .nativeCompressed:
            state = .system
            actual = L10n.text("已交给系统处理")
            explanation = L10n.text("原始压缩音频已交给系统，接收端的 Atmos 对象渲染未确认。")
        case .nativeCompressedPreparing:
            state = .preparing
            actual = L10n.text("正在准备系统音频")
            explanation = L10n.text("尚未确认当前音频已经开始输出。")
        case .passthrough:
            state = .encoded
            if encodedDTSHD {
                actual = L10n.text("DTS-HD MA · 原码输出")
                explanation = L10n.text("正在直通完整 DTS-HD MA 码流（含 HD 扩展）。最终解码及 DTS:X 对象输出请查看音箱的输入信息。")
            } else if encodedDTS {
                actual = dtsCore ? L10n.text("DTS 核心 · 原码输出") : L10n.text("DTS · 原码输出")
                explanation = dtsCore
                    ? L10n.text("当前仅传输 DTS 核心，未传输 HD 无损扩展；关闭直通可用 PCM 保留完整声道音频。")
                    : L10n.text("DTS 码流正在直通，由音箱解码。最终解码格式请查看音箱的输入信息。")
            } else {
                actual = encodedAtmos ? L10n.text("Dolby Atmos · 原码输出") : L10n.text("压缩码流输出")
                explanation = encodedAtmos
                    ? L10n.text("Atmos 音轨正在原码输出，由音箱解码。此处高亮表示直通正在工作；最终解码格式请查看音箱的输入信息。")
                    : L10n.text("引擎已报告原码输出，接收端的 Atmos 对象渲染未确认。")
            }
        case nil:
            state = .preparing
            actual = L10n.text("正在确认实际输出")
            explanation = L10n.text("尚未确认当前音频输出，片源标记不会点亮杜比全景声。")
        }
        // Highlight the observed matching route. ReceiverAtmos remains
        // unverified: this does not claim the receiver decoded Atmos objects.
        var result = PlaybackFormatStatus(kind: .audio, format: format, state: state, formatIsActive: encodedAtmos || encodedDTS || encodedDTSHD,
            actualOutput: actual, explanation: explanation, source: source, device: audio.deviceName)
        result.outputChannelCount = audio.outputChannelCount
        result.details = [
            .init(label: L10n.text("音频后端"), value: audio.outputDriver ?? L10n.text("未知")),
            .init(label: L10n.text("输出格式"), value: audio.outputFormat ?? L10n.text("未知"))
        ]
        if let rate = audio.sourceSampleRate ?? audio.demuxSampleRate {
            result.details.append(.init(label: L10n.text("片源采样率"), value: sampleRateDescription(Double(rate))))
        }
        if let rate = audio.outputSampleRate {
            result.details.append(.init(label: L10n.text(audio.mode == .passthrough ? "码流逻辑频率" : "播放器输出采样率"),
                                        value: sampleRateDescription(Double(rate))))
        }
        let physicalRates = Set((audio.devicePhysicalFormats ?? []).map(\.sampleRate).filter { $0.isFinite && $0 > 0 })
        if !physicalRates.isEmpty {
            result.details.append(.init(label: L10n.text(audio.mode == .passthrough ? "设备传输频率" : "设备实际采样率"),
                                        value: physicalRates.sorted().map(sampleRateDescription).joined(separator: " / ")))
        }
        return result
    }

    private static func pcmDescription(_ audio: PlaybackDiagnostics.Audio) -> String {
        let layout: String
        if audio.outputChannelCount == 2 || audio.outputLayout == "stereo" { layout = L10n.text("PCM 立体声") }
        else if let channels = audio.outputChannelCount { layout = L10n.text("PCM · {0} 声道", [String(channels)]) }
        else { layout = "PCM" }
        guard let rate = audio.outputSampleRate else { return layout }
        return layout + " · " + sampleRateDescription(Double(rate))
    }

    private static func sampleRateDescription(_ rate: Double) -> String {
        let kHz = rate / 1_000
        return String(format: kHz.rounded() == kHz ? "%.0f kHz" : "%.1f kHz", kHz)
    }
}
