import Models
import PlayerEngine
import SubtitleEngine
import SwiftUI
import UniformTypeIdentifiers

struct SubtitleRecognitionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var model: SubtitleRecognitionModel
    @ObservedObject var player: PlayerState
    let useDocument: (SubtitleDocument, String) -> Void
    @State private var format = SubtitleExportFormat.srt
    @State private var exportMessage: String?
    @State private var exportFailed = false
    var body: some View {
        VStack(spacing: 0) {
            FeaturePanelHeader(
                title: L10n.text("图片字幕／音频识别"),
                subtitle: L10n.text("Apple 本机识别 · 生成可编辑、可翻译的文本字幕"), systemImage: "waveform"
            ) { dismiss() }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sourceStep
                    recognitionStep
                    exportStep
                    DisclosureGroup(L10n.text("格式、隐私与恢复说明")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("使用 Apple 本机 OCR 或语音识别。识别内容保存在本机；准备语音模型时可能下载 Apple 系统资源。"))
                            Text(
                                L10n.text(
                                    "支持本地 PGS（SUP）及 16-bit PCM／32-bit float WAV，单声道或双声道。请选择与影片时间轴匹配的文件；内嵌轨道和远程自动提取尚未接入。"
                                ))
                            Text(L10n.text("识别可能有误，请核对结果。整份识别完成后可导出或作为文本字幕继续翻译；关闭面板继续识别，停止或换片会取消当前任务。"))
                        }.padding(.top, 8).fixedSize(horizontal: false, vertical: true)
                    }.disclosureGroupStyle(FullRowDisclosureGroupStyle())
                        .font(.caption).foregroundStyle(palette.muted)
                }.padding(20)
            }
        }.frame(minWidth: 600, idealWidth: 680, maxWidth: 680, minHeight: 520, idealHeight: 680, maxHeight: 680)
            .themedPresentation()
            .onChange(of: model.language) { _, _ in
                model.languageChanged()
                exportMessage = nil
            }
            .onChange(of: model.document?.fingerprint) { _, _ in exportMessage = nil }
            .task { model.refreshAvailability() }
    }

    private var sourceStep: some View {
        FeatureStepCard(number: 1, title: L10n.text("选择识别文件")) {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.gearshape").foregroundStyle(palette.accent).font(.title2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.source?.name ?? L10n.text("尚未选择文件"))
                        .font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.middle)
                    Text(L10n.text("SUP 图片字幕 · WAV 音频"))
                        .font(.caption).foregroundStyle(palette.muted)
                }
                Spacer()
                Button(L10n.text("选择文件…")) { selectFile() }.disabled(player.currentSpec == nil || model.busy)
                    .help(L10n.text("选择 SUP／WAV 文件…"))
            }
            if player.currentSpec == nil {
                FeatureNotice(message: L10n.text("请先开始播放，再选择对应字幕。"), role: .warning, systemImage: "play.circle")
            }
        }
    }

    private var recognitionStep: some View {
        FeatureStepCard(number: 2, title: L10n.text("识别为文本字幕")) {
            Picker(L10n.text("识别语言"), selection: $model.language) {
                ForEach(
                    ["en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR"],
                    id: \.self
                ) { code in
                    Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                }
            }.disabled(model.busy)
            if model.source?.kind == .audio {
                if #available(macOS 26.0, *) {
                    switch model.speechAvailability {
                    case .installed:
                        FeatureNotice(message: L10n.text("本机语音模型已就绪。"), role: .success, systemImage: "checkmark.circle")
                    case .needsModel:
                        FeatureNotice(
                            message: L10n.text("请先准备本机语音模型，再开始识别。"), role: .warning, systemImage: "arrow.down.circle")
                        Button(L10n.text("准备本机语音模型")) { model.prepareModel() }.disabled(model.busy)
                            .buttonStyle(ThemedDialogButtonStyle(isPrimary: true))
                    case .unsupported:
                        FeatureNotice(message: L10n.text("当前设备或语言的本机语音识别不可用。"), role: .warning)
                    }
                } else {
                    FeatureNotice(message: L10n.text("本机音频识别需要 macOS 26 或更新版本；图片字幕识别仍可使用。"), role: .warning)
                }
            }
            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在识别…")).font(.caption).foregroundStyle(palette.muted)
                    Spacer()
                    Button(L10n.text("停止识别")) { model.cancel() }
                } else if model.coverage?.complete != true,
                    model.source?.kind != .audio || model.speechAvailability == .installed
                {
                    Button(model.coverage?.translations.isEmpty == false ? L10n.text("继续识别") : L10n.text("开始识别")) {
                        model.update(player)
                        model.start()
                    }.buttonStyle(ThemedDialogButtonStyle(isPrimary: true)).disabled(model.source == nil)
                    Spacer()
                    Text(L10n.text("可随时停止并恢复")).font(.caption).foregroundStyle(palette.muted)
                }
            }
            if let source = model.source {
                FeatureProgress(
                    title: model.coverage?.complete == true ? L10n.text("识别已完成") : L10n.text("已保存的识别进度"),
                    completed: model.coverage?.translations.count ?? 0, total: source.units.count)
                if !model.canResumeAcrossSessions {
                    Text(L10n.text("此来源缺少稳定身份，缓存仅限当前播放会话。")).font(.caption).foregroundStyle(palette.muted)
                }
            }
            if let message = model.message {
                FeatureNotice(
                    message: message, role: model.busy ? .secondaryText : .warning,
                    systemImage: model.busy ? "info.circle" : "exclamationmark.circle")
            }
            Text(L10n.text("关闭面板后继续识别；停止或换片会取消任务。"))
                .font(.caption).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exportStep: some View {
        FeatureStepCard(number: 3, title: L10n.text("导出或继续翻译")) {
            HStack {
                Picker(L10n.text("格式"), selection: $format) {
                    Text("SRT").tag(SubtitleExportFormat.srt)
                    Text("ASS").tag(SubtitleExportFormat.ass)
                }.frame(width: 150)
                Spacer()
            }
            HStack {
                Button(L10n.text("导出识别字幕…")) { export() }.disabled(model.document == nil || model.busy)
                Spacer()
                Button(L10n.text("继续翻译")) {
                    if let document = model.document {
                        useDocument(document, model.language)
                        dismiss()
                    }
                }.buttonStyle(ThemedDialogButtonStyle(isPrimary: true)).disabled(model.document == nil || model.busy)
                    .help(L10n.text("使用并打开字幕翻译"))
            }
            if model.document == nil || model.busy {
                Text(L10n.text("整份识别完成后可导出或继续翻译。"))
                    .font(.caption).foregroundStyle(palette.muted)
            }
            if let exportMessage {
                FeatureNotice(
                    message: exportMessage, role: exportFailed ? .danger : .success,
                    systemImage: exportFailed ? "exclamationmark.circle" : "checkmark.circle")
            }
        }
    }
    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sup"), UTType(filenameExtension: "wav")].compactMap {
            $0
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { model.load(file: url) }
    }
    private func export() {
        guard let document = model.document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        panel.nameFieldStringValue = "recognized." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SubtitleExporter.save(SubtitleExporter.render(document: document, format: format), to: url)
            exportFailed = false
            exportMessage = L10n.text("字幕已导出到所选本地文件。")
        } catch {
            exportFailed = true
            exportMessage = L10n.text("字幕导出失败，请重试。")
        }
    }
}
