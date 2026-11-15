import AppKit
import Models
import PlayerEngine
import SwiftUI
import UniformTypeIdentifiers

enum PlaybackInformationTab: CaseIterable, Identifiable {
    case overview, settings, details
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: return L10n.text("输出概览")
        case .settings: return L10n.text("常用设置")
        case .details: return L10n.text("技术详情")
        }
    }
}

struct PlaybackInformationView: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var playerState: PlayerState
    @State private var selectedTab: PlaybackInformationTab
    @State private var isExporting = false
    @State private var exportDocument = PlaybackDiagnosticDocument(text: "{}")
    @State private var exportError: String?
    @State private var copied = false
    @State private var statisticsConsumer = UUID()

    init(playerState: PlayerState, initialTab: PlaybackInformationTab = .overview) {
        self.playerState = playerState
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L10n.text("播放信息"), selection: $selectedTab) {
                ForEach(PlaybackInformationTab.allCases) { tab in Text(tab.title).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if selectedTab == .settings {
                PlaybackColorSettingsView(playerState: playerState)
                PlaybackAudioOutputSettingsView(playerState: playerState)
                PlaybackDialogueSettingsView(playerState: playerState)
            } else if let info = playerState.playbackDiagnostics {
                if selectedTab == .overview {
                    overview(info)
                } else {
                    section(L10n.text("片源")) {
                        row(L10n.text("视频编码"), info.video.codec)
                        row("Profile", info.video.profile)
                        row(L10n.text("分辨率"), resolution(info.video))
                        row(L10n.text("媒体标称帧率"), PlaybackStatistics.fps(info.video.framesPerSecond))
                        row(L10n.text("像素格式"), info.video.pixelFormat)
                        row(L10n.text("位深"), info.video.bitDepth.map { "\($0) bit" })
                        row(L10n.text("片源动态范围"), info.video.signalDescription)
                        row(L10n.text("色域"), info.video.primaries)
                        row(L10n.text("传递函数"), info.video.transfer)
                        row(L10n.text("播放色彩解释"), info.video.interpretedSignalDescription)
                        row(L10n.text("播放色域"), info.video.interpretedPrimaries)
                        row(L10n.text("播放传递函数"), info.video.interpretedTransfer)
                        row(L10n.text("播放矩阵"), info.video.interpretedMatrix)
                        row(L10n.text("播放范围"), info.video.interpretedRange)
                        row(L10n.text("色彩矩阵"), info.video.matrix)
                        row(L10n.text("色彩范围"), info.video.range)
                        row("Dolby Vision Profile", info.video.dolbyVisionProfile.map(String.init))
                        if let dv = info.video.dolbyVision {
                            row(
                                L10n.text("DV 配置 Profile／兼容标记"),
                                "\(dv.configurationProfile.map(String.init) ?? L10n.text("未知")) / \(dv.compatibilityID.map(String.init) ?? L10n.text("未知"))"
                            )
                            row(L10n.text("DV 配置声明 RPU"), observation(dv.configurationRPUFlag))
                            row(
                                L10n.text("本地首帧 RPU／帧元数据"),
                                "\(observation(dv.decodedRPUDetected)) / \(observation(dv.decodedMetadataDetected))")
                            row(L10n.text("运行时 DV 帧标记"), detected(dv.runtimeFrameMetadataDetected))
                            row(L10n.text("RPU 推断 Profile"), dv.rpuInferredProfile.map(String.init))
                            row(L10n.text("DV 当前处理"), dv.route.description)
                            row(L10n.text("DV 动态映射"), dv.dynamicMappingApplied ? L10n.text("已应用") : L10n.text("未使用"))
                            if let renderer = dv.renderer {
                                row(
                                    L10n.text("DV／增强层／FEL 渲染帧"),
                                    "\(renderer.doviFrames) / \(renderer.enhancementFrames) / \(renderer.felFrames)")
                            }
                            if let system = dv.systemPresentation {
                                row(L10n.text("系统 DV 元数据来源"), system.metadataOrigin)
                                row(L10n.text("源元数据实验状态"), system.sourceCaptureReason)
                            }
                            row(L10n.text("Dolby Vision 电视信号"), L10n.text("接收端待确认；系统提交不等于物理 DV 输出"))
                        }
                        row(L10n.text("HDR 静态元数据"), detected(info.video.staticHDRMetadataDetected))
                        row(L10n.text("HDR 动态元数据"), detected(info.video.dynamicHDRMetadataDetected))
                    }
                    section(L10n.text("实际解码")) {
                        row("Decoder", info.video.decoder)
                        row(L10n.text("解码方式"), info.video.decodingDescription)
                        if let fallback = info.video.fallback {
                            row(L10n.text("软件回退"), fallback.description)
                        }
                    }
                    section(L10n.text("当前输出")) {
                        row(L10n.text("输出策略"), info.display.videoOutput?.requestedMode.description)
                        row(L10n.text("视频输出"), info.display.outputDescription)
                        row(L10n.text("输出状态"), info.display.videoOutput?.disposition.description)
                        row(
                            L10n.text("HDR 输出条件"),
                            info.display.videoOutput?.hdrRestrictions.map(\.description).joined(separator: "；"))
                        row(L10n.text("渲染后端"), info.display.renderBackend)
                        row(L10n.text("渲染目标"), info.display.targetFormat)
                        row(
                            L10n.text("输出色彩配置"),
                            info.display.hdrPresentation == nil
                                ? info.display.iccSubmission?.description : L10n.text("扩展线性 sRGB"))
                        row(L10n.text("映射算法"), info.display.toneMapping)
                        row(
                            L10n.text(info.display.hdrPresentation == nil ? "SDR 参考峰值" : "EDR 信号峰值"),
                            info.display.referencePeakNits.map { "\($0) nit" })
                        row(L10n.text("显示器"), info.display.name)
                        if let timing = info.display.timing {
                            row(
                                L10n.text("显示模式刷新率"),
                                timing.configuredRefreshRateHz.map { String(format: "%.3f Hz", $0) })
                            row(L10n.text("帧率匹配"), timing.rateMatching.description)
                            row("QMS", timing.qms.description)
                            Text(L10n.text("模式刷新率不代表实际面板时序；VRR 或无明显黑屏不能证明 QMS。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        row(L10n.text("当前 EDR 余量"), info.display.currentEDRHeadroom.map { String(format: "%.2f×", $0) })
                        row(
                            L10n.text("潜在 EDR 余量"),
                            info.display.potentialEDRHeadroom.map { String(format: "%.2f×", $0) })
                    }
                    section(L10n.text("音频")) {
                        row(L10n.text("音频编码"), info.audio.codec)
                        row(L10n.text("音频 Profile"), info.audio.profile)
                        if let compressed = info.audio.compressedAudio {
                            row(L10n.text("压缩音频片源"), compressed.sourceFormat.description)
                            row(L10n.text("音频实际处理"), compressed.output.description)
                            row(L10n.text("直通请求"), compressed.passthroughRequest.description)
                            row(L10n.text("Atmos 接收端"), compressed.receiverAtmos.description)
                        }
                        if let native = info.audio.nativeAudio {
                            row(L10n.text("原生压缩音频"), native.isRendering ? L10n.text("正在播放") : L10n.text("准备中"))
                            row("E-AC-3 JOC", observation(native.joc))
                            row(L10n.text("原生音频格式"), "\(native.sampleRate) Hz / \(native.channels) ch")
                            row(L10n.text("原生音频包"), String(native.packets))
                        }
                        row(L10n.text("源音频采样率"), info.audio.sourceSampleRate.map { "\($0) Hz" })
                        row(L10n.text("源音频声道数"), info.audio.sourceChannelCount.map(String.init))
                        if let dsd = info.audio.dsd {
                            row(L10n.text("DSD 处理"), dsd.processing.description)
                            row("DoP / Native DSD", L10n.text("未启用"))
                        }
                        row(L10n.text("音频解码器"), info.audio.decoder)
                        row(L10n.text("解码后格式"), info.audio.inputFormat)
                        row(L10n.text("解码后声道"), info.audio.inputLayout)
                        row(L10n.text("解码后声道映射"), info.audio.inputChannels)
                        row(L10n.text("解码后采样率"), info.audio.inputSampleRate.map { "\($0) Hz" })
                        row(L10n.text("输出模式"), info.audio.mode?.description)
                        row(L10n.text("PCM 声道偏好"), info.audio.requestedMode?.description)
                        row(L10n.text("设备请求状态"), info.audio.routeStatus?.description)
                        row(L10n.text("请求声道布局"), info.audio.requestedChannelLayouts)
                        row(L10n.text("输出声道"), info.audio.outputLayout)
                        row(L10n.text("输出声道映射"), info.audio.outputChannels)
                        row(L10n.text("输出采样率"), info.audio.outputSampleRate.map { "\($0) Hz" })
                        row(L10n.text("音频后端"), info.audio.outputDriver)
                        row(L10n.text("引擎输出格式"), info.audio.outputFormat)
                        row(L10n.text("进程输出设备"), info.audio.deviceName)
                        row(L10n.text("进程输出设备数"), info.audio.processDeviceCount.map(String.init))
                        row(L10n.text("系统默认设备"), info.audio.systemDefaultDeviceName)
                        row(L10n.text("设备连接类型"), info.audio.deviceTransport?.rawValue)
                        row(L10n.text("设备配置声道顺序"), info.audio.devicePreferredChannels?.joined(separator: " · "))
                        row(L10n.text("设备可用声道数"), info.audio.deviceChannelCapacity.map(String.init))
                        row(
                            L10n.text("设备标称采样率"),
                            info.audio.deviceNominalSampleRate.map { String(format: "%.0f Hz", $0) })
                        row(
                            L10n.text("设备当前虚拟格式"),
                            info.audio.deviceVirtualFormats?.map(\.summary).joined(separator: "；"))
                        row(
                            L10n.text("设备当前物理格式"),
                            info.audio.devicePhysicalFormats?.map(\.summary).joined(separator: "；"))
                        row(
                            L10n.text("设备报告延迟"),
                            info.audio.deviceReportedLatencySeconds.map { String(format: "%.2f ms", $0 * 1_000) })
                        row(L10n.text("设备缓冲帧数"), info.audio.deviceBufferFrames.map(String.init))
                        row(
                            L10n.text("引擎报告音画偏差"),
                            info.audioVideoOffsetSeconds.map { String(format: "%.2f ms", $0 * 1_000) })
                        Text(L10n.text("设备配置不代表物理声道验证；设备延迟不含软件缓冲和声学传播，音画偏差为引擎报告值。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.text("设备格式为系统读回值，不代表已测量 DAC 载荷或模拟输出。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let spatial = info.audio.spatialAudio {
                        section(L10n.text("空间音频与追踪")) {
                            row(L10n.text("空间音频路线"), spatial.route.description)
                            row(L10n.text("应用虚拟环绕"), spatial.applicationBinaural.description)
                            row(L10n.text("系统空间音频"), spatial.systemSpatialAudio.description)
                            row(L10n.text("动态头部追踪"), spatial.headTracking.description)
                            row(L10n.text("Atmos 对象渲染"), spatial.atmosRendering.description)
                            Text(L10n.text("多声道、耳机型号或系统选项不能证明空间效果；头部追踪需要实际姿态与方向响应。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                statistics(info)
                Divider().overlay(palette.foreground.opacity(0.06))
                HStack(spacing: 10) {
                    Button {
                        let text = info.redactedJSON()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                    } label: {
                        Label(
                            copied ? L10n.text("已复制") : L10n.text("复制诊断"),
                            systemImage: copied ? "checkmark" : "doc.on.doc")
                    }.help(L10n.text("复制脱敏诊断"))
                    Spacer(minLength: 0)
                    Button {
                        exportDocument = PlaybackDiagnosticDocument(text: info.redactedJSON())
                        isExporting = true
                    } label: {
                        Label(L10n.text("导出诊断"), systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.bordered)
                Text(L10n.text("诊断仅含播放参数；账号、媒体地址、路径及设备名称不导出。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FeatureNotice(
                    message: playerState.currentSpec == nil
                        ? L10n.text("开始播放后可查看片源与实际输出。") : L10n.text("正在读取播放信息…"), systemImage: "play.rectangle")
            }
            if let exportError {
                FeatureNotice(message: exportError, role: .danger, systemImage: "exclamationmark.circle")
            }
        }
        .foregroundStyle(palette.foreground)
        .tint(palette.accent)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileExporter(
            isPresented: $isExporting, document: exportDocument,
            contentType: .json, defaultFilename: "NetVplayer-playback-diagnostics"
        ) { result in
            if case .failure = result { exportError = L10n.text("诊断导出失败，请重试。") } else { exportError = nil }
        }
        .onChange(of: playerState.playbackDiagnostics?.mediaID) { _, _ in copied = false }
        .background {
            PlaybackInformationVisibility(enabled: selectedTab != .settings) { visible in
                playerState.setPlaybackInformationVisible(visible, consumer: statisticsConsumer)
            }
        }
        .onDisappear { playerState.setPlaybackInformationVisible(false, consumer: statisticsConsumer) }
    }

    private func statistics(_ info: PlaybackDiagnostics) -> some View {
        let sample = playerState.playbackStatistics
        let advancing = playerState.isPlaying && !playerState.isSeeking && !playerState.isBuffering && !playerState.isMediaLoading
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("播放统计")).font(.caption.weight(.semibold))
            row(L10n.text("媒体标称帧率"), PlaybackStatistics.fps(info.video.framesPerSecond))
                .help("mpv container-fps")
            row(L10n.text("估算输出帧率"), advancing ? PlaybackStatistics.fps(sample?.estimatedOutputFPS) : nil)
                .help("mpv estimated-vf-fps")
            row(L10n.text("估算视频码率"), advancing ? PlaybackStatistics.bitrate(sample?.videoBitsPerSecond) : nil)
                .help("mpv video-bitrate")
            row(L10n.text("估算音频码率"), advancing ? PlaybackStatistics.bitrate(sample?.audioBitsPerSecond) : nil)
                .help("mpv audio-bitrate")
            row(L10n.text("下载／读取速度"), PlaybackStatistics.downloadSpeed(playerState.cacheSpeedBytesPerSecond))
                .help("mpv cache-speed · B/s")
            if let bytes = info.localInputBytes {
                row(L10n.text("本地输入文件大小"), L10n.text("{0} 字节", [String(bytes)]))
                    .help(L10n.text("仅为选中本地输入的字节数，不能证明它包含完整影片。"))
            }
            Text(L10n.text("标称帧率来自媒体声明；输出帧率按最近时间戳估算，不代表屏幕实测。暂停、缓冲或跳转时暂不显示估算。"))
                .font(.caption2).foregroundStyle(.secondary)
            Text(L10n.text("码率来自已解复用的压缩包（bit/s）；读取速度为引擎最近一秒的输入量（B/s），不代表网络带宽。k／M 使用十进制。"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func overview(_ info: PlaybackDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.text("当前实际输出"), systemImage: "display")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.muted)
                Text(info.display.outputDescription).font(.system(size: 20, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let output = info.display.videoOutput {
                    Text(output.disposition.description).font(.system(size: 12)).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !output.hdrRestrictions.isEmpty {
                        FeatureNotice(
                            message: output.hdrRestrictions.map(\.description).joined(separator: "；"),
                            role: .warning, systemImage: "exclamationmark.triangle")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(palette.accent.opacity(0.18), lineWidth: 1) }
            VStack(spacing: 10) {
                row(
                    L10n.text("片源"),
                    [info.video.codec, resolution(info.video), info.video.signalDescription].compactMap { $0 }.joined(
                        separator: " · "))
                Divider()
                row(L10n.text("实际解码"), info.video.decodingDescription)
                Divider()
                row(
                    L10n.text("音频输出"),
                    [
                        info.audio.mode?.description, info.audio.outputLayout,
                        info.audio.outputSampleRate.map { "\($0) Hz" },
                    ].compactMap { $0 }.joined(separator: " · "))
                Divider()
                row(L10n.text("输出设备"), info.audio.deviceName ?? info.audio.systemDefaultDeviceName)
            }.padding(12)
            FeatureNotice(message: L10n.text("这里显示实际播放结果。需要调整时打开“常用设置”，完整参数在“技术详情”。"))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) { content() }.padding(.top, 12)
        } label: {
            Text(title).font(.system(size: 12, weight: .semibold))
        }
        .disclosureGroupStyle(FullRowDisclosureGroupStyle(cardPadding: 12))
        .background(palette.foreground.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(palette.foreground.opacity(0.08), lineWidth: 1) }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("未知"))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func resolution(_ video: PlaybackDiagnostics.Video) -> String? {
        guard let width = video.width, let height = video.height else { return nil }
        return "\(width) × \(height)"
    }

    private func detected(_ value: Bool?) -> String {
        value == true ? L10n.text("已检测") : L10n.text("未知")
    }

    private func observation(_ value: Bool?) -> String {
        value.map { $0 ? L10n.text("是") : L10n.text("否") } ?? L10n.text("未知")
    }
}

struct PlaybackVideoCompatibilityView: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message)
                .font(.callout)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: 460)
                .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                .padding(12)
                .allowsHitTesting(false)
        }
    }
}

private struct PlaybackDiagnosticDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
