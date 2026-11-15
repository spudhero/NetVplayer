import Models
import PlayerEngine
import SubtitleEngine
import SwiftUI
@preconcurrency import Translation
import UniformTypeIdentifiers

struct SubtitleTranslationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var model: SubtitleTranslationModel
    @ObservedObject var player: PlayerState
    let attachOriginal: (Sub) -> Void
    @State private var format: SubtitleExportFormat = .srt
    @State private var bilingual = true
    @State private var exportMessage: String?
    @State private var exportFailed = false
    @State private var completeDocument = false
    private let languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "it", "pt", "ru"]

    var body: some View {
        VStack(spacing: 0) {
            FeaturePanelHeader(
                title: L10n.text("文本字幕翻译"),
                subtitle: L10n.text("Apple 本机翻译 · 保留原字幕时间轴"), systemImage: "character.bubble"
            ) { dismiss() }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sourceStep
                    translationStep
                    exportStep
                    helpSection
                }.padding(20)
            }
        }.frame(minWidth: 600, idealWidth: 680, maxWidth: 680, minHeight: 520, idealHeight: 680, maxHeight: 680)
            .themedPresentation()
            .onChange(of: model.original?.id) { _, _ in
                exportMessage = nil
                if model.owns(player.currentSpec, playbackID: player.chapterOwnerID), let sub = model.original {
                    attachOriginal(sub)
                }
            }
            .onChange(of: model.sourceLanguage) { _, _ in
                model.invalidateLanguages()
                exportMessage = nil
            }
            .onChange(of: model.targetLanguage) { _, _ in
                model.invalidateLanguages()
                exportMessage = nil
            }
    }

    private var sourceStep: some View {
        FeatureStepCard(number: 1, title: L10n.text("选择字幕")) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(palette.accent).font(.title2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.document == nil ? L10n.text("尚未选择字幕") : model.sourceName)
                        .font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.middle)
                    Text("SRT · ASS · SSA · VTT").font(.caption).foregroundStyle(palette.muted)
                }
                Spacer()
                Button(L10n.text("选择文件…")) { selectFile() }
                    .disabled(player.currentSpec == nil || model.isProcessing)
            }
            if let subs = player.currentSpec?.subs, !subs.isEmpty {
                Menu(L10n.text("选择已有外挂字幕")) {
                    ForEach(subs) { sub in Button(sub.name) { model.load(sub) } }
                }.disabled(model.isProcessing)
            }
            if player.currentSpec == nil {
                FeatureNotice(message: L10n.text("请先开始播放，再选择对应字幕。"), role: .warning, systemImage: "play.circle")
            }
        }
    }

    private var translationStep: some View {
        FeatureStepCard(number: 2, title: L10n.text("翻译")) {
            HStack(spacing: 12) {
                languagePicker(L10n.text("源语言"), selection: $model.sourceLanguage)
                Image(systemName: "arrow.right").foregroundStyle(palette.muted).padding(.top, 18).accessibilityHidden(
                    true)
                languagePicker(L10n.text("目标语言"), selection: $model.targetLanguage)
            }.disabled(model.isProcessing)
            if model.sourceLanguage == model.targetLanguage {
                FeatureNotice(
                    message: L10n.text("源语言与目标语言相同，请选择不同语言。"), role: .warning, systemImage: "exclamationmark.triangle")
            }
            if #available(macOS 15.0, *) {
                if model.coverage?.complete != true {
                    Picker(L10n.text("翻译方式"), selection: $completeDocument) {
                        Text(L10n.text("跟随播放")).tag(false)
                        Text(L10n.text("整份字幕")).tag(true)
                    }.pickerStyle(.segmented).disabled(model.isProcessing)
                }
                translationActions
                if model.coverage?.complete != true {
                    Text(completeDocument ? L10n.text("补全全部字幕，暂停播放时也可进行。") : L10n.text("播放时优先翻译当前片段；暂停时可切换为“整份字幕”。"))
                        .font(.caption).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                FeatureNotice(message: L10n.text("Apple 本机翻译需要 macOS 15 或更新版本。当前系统可导出原字幕。"), role: .warning)
            }
            if let document = model.document {
                FeatureProgress(
                    title: L10n.text("已保存的翻译进度"),
                    completed: model.coverage?.translations.count ?? 0, total: document.cues.count)
                if !model.canResumeAcrossSessions {
                    Text(L10n.text("此来源缺少稳定身份，缓存仅限当前播放会话。")).font(.caption).foregroundStyle(palette.muted)
                }
            }
            if let message = model.message {
                FeatureNotice(message: message, role: .warning, systemImage: "exclamationmark.circle")
            }
        }
    }

    private var exportStep: some View {
        FeatureStepCard(number: 3, title: L10n.text("导出字幕")) {
            HStack(spacing: 16) {
                Picker(L10n.text("格式"), selection: $format) {
                    Text("SRT").tag(SubtitleExportFormat.srt)
                    Text("ASS").tag(SubtitleExportFormat.ass)
                }.frame(width: 150)
                Toggle(L10n.text("双语字幕"), isOn: $bilingual).font(.system(size: 12))
                Spacer(minLength: 0)
            }
            HStack {
                Button(L10n.text("导出原字幕…")) { export(translated: false) }.disabled(model.document == nil)
                Spacer()
                Button(L10n.text("导出译文…")) { export(translated: true) }
                    .buttonStyle(ThemedDialogButtonStyle(isPrimary: true)).disabled(model.coverage?.complete != true)
            }
            if model.coverage?.complete != true {
                Text(L10n.text("译文完整后可导出；原字幕可随时导出。"))
                    .font(.caption).foregroundStyle(palette.muted)
            }
            if let exportMessage {
                FeatureNotice(
                    message: exportMessage, role: exportFailed ? .danger : .success,
                    systemImage: exportFailed ? "exclamationmark.circle" : "checkmark.circle")
            }
        }
    }

    private var helpSection: some View {
        DisclosureGroup(L10n.text("格式、隐私与恢复说明")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Apple 本机翻译仅处理所选字幕文本，不发送音频或视频。首次使用可能由系统提示下载语言模型。"))
                Text(L10n.text("支持已有本地或已下载的 SRT、ASS、SSA、VTT，也可使用图片字幕／音频识别结果。请选与当前影片时间轴匹配的文本；内嵌轨道自动提取尚未接入。"))
                Text(L10n.text("部分缓存保存在本机，可停止后重试恢复。翻译失败或迟到继续使用原字幕；导出仅写入你选择的本地文件。ASS 导出保留时间轴，使用统一文本样式。"))
            }.padding(.top, 8).fixedSize(horizontal: false, vertical: true)
        }.disclosureGroupStyle(FullRowDisclosureGroupStyle())
            .font(.caption).foregroundStyle(palette.muted)
    }

    private var translationActions: some View {
        HStack {
            if model.isProcessing {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在翻译…")).font(.caption).foregroundStyle(palette.muted)
                Spacer()
                Button(L10n.text("停止翻译")) { model.cancel() }
            } else if model.coverage?.complete == true {
                Label(L10n.text("翻译已完成"), systemImage: "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(palette.color(for: .success))
                Spacer()
                if model.active {
                    Button(L10n.text("停用译文")) { model.cancel() }
                } else {
                    Button(L10n.text("使用译文")) {
                        model.update(player)
                        model.start(completing: completeDocument)
                    }
                }
            } else {
                Button(model.coverage?.translations.isEmpty == false ? L10n.text("继续翻译") : L10n.text("开始翻译")) {
                    model.update(player)
                    model.start(completing: completeDocument)
                }.buttonStyle(ThemedDialogButtonStyle(isPrimary: true))
                    .disabled(model.document == nil || model.sourceLanguage == model.targetLanguage)
                Spacer()
                Text(L10n.text("可随时停止并恢复")).font(.caption).foregroundStyle(palette.muted)
            }
        }
    }

    private func languagePicker(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(palette.muted)
            Picker(title, selection: selection) {
                ForEach(languages, id: \.self) { code in
                    Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(title)
        }
    }
    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { model.load(file: url) }
    }
    private func export(translated: Bool) {
        guard let document = model.document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        panel.nameFieldStringValue =
            "subtitle" + (translated ? "." + model.targetLanguage : ".original") + "." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try SubtitleExporter.render(
                document: document, coverage: translated ? model.coverage : nil,
                format: format, bilingual: translated && bilingual)
            try SubtitleExporter.save(data, to: url)
            exportFailed = false
            exportMessage = L10n.text("字幕已导出到所选本地文件。")
        } catch {
            exportFailed = true
            exportMessage = L10n.text("字幕导出失败，请重试。")
        }
    }
}

/// This host stays on the player, so closing the configuration sheet does not
/// invalidate Apple's view-scoped session. Media teardown cancels it.
@available(macOS 15.0, *)
struct AppleSubtitleTranslationHost: View {
    @ObservedObject var model: SubtitleTranslationModel
    @State private var configuration: TranslationSession.Configuration?
    @State private var configuredRequestID: UUID?
    var body: some View {
        let requestID = configuredRequestID
        return Color.clear.frame(width: 0, height: 0)
            .onChange(of: model.requestID) { _, id in
                configuredRequestID = id
                if id == nil {
                    configuration = nil
                } else if configuration != nil {
                    configuration?.source = Locale.Language(identifier: model.sourceLanguage)
                    configuration?.target = Locale.Language(identifier: model.targetLanguage)
                    configuration?.invalidate()
                } else {
                    configuration = TranslationSession.Configuration(
                        source: Locale.Language(identifier: model.sourceLanguage),
                        target: Locale.Language(identifier: model.targetLanguage))
                }
            }
            .translationTask(configuration) { session in
                guard let requestID, model.requestID == requestID else { return }
                do {
                    try await session.prepareTranslation()
                    try Task.checkCancellation()
                    guard model.requestID == requestID else { return }
                    await model.session.run(service: AppleSubtitleTranslationService(session: session))
                } catch {
                    guard !Task.isCancelled, model.requestID == requestID else { return }
                    SubtitleTranslationModel.logFailure(error, stage: "preparation")
                    model.preparationFailed()
                }
            }
    }
}
