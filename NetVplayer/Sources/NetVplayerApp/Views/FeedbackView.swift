import SwiftUI
import Models

struct FeedbackPreviewSnapshot: Equatable {
    let draft: FeedbackDraft
    let report: FeedbackReport

    func report(matching currentDraft: FeedbackDraft) -> FeedbackReport? {
        draft == currentDraft ? report : nil
    }
}

struct FeedbackView: View {
    @Environment(\.appThemePalette) private var palette
    @EnvironmentObject private var appState: AppState

    @State private var draft = FeedbackDraft()
    @State private var previewSnapshot: FeedbackPreviewSnapshot?
    @State private var isShowingPreview = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var repositoryURL: URL? {
        FeedbackDestination.repositoryURL()
    }

    private var previewReport: FeedbackReport? {
        previewSnapshot?.report(matching: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSurfaceVisualPolicy.pageSectionGap) {
            GroupBox(label: SettingsPanelLabel(
                title: "问题说明",
                subtitle: "提交可复现的现象和操作路径。",
                systemImage: "exclamationmark.bubble"
            )) {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsControlRow(title: "问题分类", caption: "用于确定排障层级") {
                        Picker("问题分类", selection: categoryBinding) {
                            ForEach(FeedbackCategory.allCases) { category in
                                Text(category.title).tag(category)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    feedbackTextField(title: "标题", prompt: "简要说明问题", text: binding(\.title))
                    feedbackTextArea(title: "问题现象", text: binding(\.problemDescription), height: 110)
                    feedbackTextArea(title: "复现步骤", text: binding(\.reproductionSteps), height: 110)
                    feedbackTextArea(title: "预期结果", text: binding(\.expectedResult), height: 82)
                    feedbackTextArea(title: "实际结果", text: binding(\.actualResult), height: 82)
                }
                .padding(.top, 6)
            }

            GroupBox(label: SettingsPanelLabel(
                title: "复现资料",
                subtitle: "配置只生成指纹；原始地址不会自动公开。",
                systemImage: "shield.lefthalf.filled",
                statusText: reproductionStatus,
                statusColor: reproductionStatusColor
            )) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("与配置源或播放线路有关", isOn: binding(\.isSourceRelated))

                    if draft.isSourceRelated {
                        feedbackTextField(
                            title: "公开复现源",
                            prompt: "https://example.com/minimal-config.json（可选）",
                            text: binding(\.publicSourceURL)
                        )
                        if !draft.publicSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Toggle(
                                "我确认该地址和返回内容可以公开访问",
                                isOn: binding(\.confirmsPublicSource)
                            )
                            if let publicSourceValidationMessage {
                                Label(publicSourceValidationMessage, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(palette.color(for: .warning))
                            }
                        }
                    }

                    Divider()

                    Toggle("附带本次和上次会话的脱敏日志", isOn: binding(\.includeLogs))
                    Label(
                        "GitHub Issue 和手动附加的日志会公开可访问",
                        systemImage: "eye"
                    )
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                }
                .padding(.top, 6)
            }

            HStack(spacing: 10) {
                Button {
                    generatePreview(showPreview: true)
                } label: {
                    Label("生成预览", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)

                Button {
                    isShowingPreview = previewReport != nil
                } label: {
                    Label("查看预览", systemImage: "doc.plaintext")
                }
                .buttonStyle(.bordered)
                .disabled(previewReport == nil)

                Spacer(minLength: 12)

                Button {
                    continueToGitHub()
                } label: {
                    Label("在 GitHub 中继续", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .disabled(previewReport == nil || repositoryURL == nil)
            }

            if repositoryURL == nil {
                Label("当前构建未配置有效的 GitHub 反馈仓库", systemImage: "link.badge.plus")
                    .font(.caption)
                    .foregroundStyle(palette.color(for: .warning))
            }

            if let statusMessage {
                Label(
                    statusMessage,
                    systemImage: statusIsError ? "xmark.circle" : "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(statusIsError ? palette.color(for: .danger) : palette.color(for: .success))
                .textSelection(.enabled)
            }
        }
        .sheet(isPresented: $isShowingPreview) {
            previewSheet
        }
    }

    private var categoryBinding: Binding<FeedbackCategory> {
        Binding(
            get: { draft.category },
            set: { category in
                draft.category = category
                draft.isSourceRelated = category.defaultsToSourceRelated
                invalidatePreview()
            }
        )
    }

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<FeedbackDraft, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                guard draft[keyPath: keyPath] != value else { return }
                draft[keyPath: keyPath] = value
                invalidatePreview()
            }
        )
    }

    private func feedbackTextField(title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.muted)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func feedbackTextArea(title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.muted)
            TextEditor(text: text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.background.opacity(0.55))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(palette.foreground.opacity(0.12), lineWidth: 1)
                        }
                }
        }
    }

    @ViewBuilder
    private var previewSheet: some View {
        if let previewReport {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("反馈报告预览")
                            .font(.title2.bold())
                        Text(previewReport.reproductionLevel.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成") {
                        isShowingPreview = false
                    }
                }
                .padding(18)

                Divider()

                ScrollView {
                    Text(previewReport.attachmentText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(18)
                }
            }
            .frame(minWidth: 720, minHeight: 560)
        }
    }

    private var reproductionStatus: String {
        if !draft.isSourceRelated { return FeedbackReproductionLevel.generic.title }
        if publicSourceValidationMessage == nil,
           !draft.publicSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return FeedbackReproductionLevel.publicSource.title
        }
        return FeedbackReproductionLevel.diagnosticOnly.title
    }

    private var reproductionStatusColor: Color {
        if !draft.isSourceRelated { return palette.color(for: .success) }
        return publicSourceValidationMessage == nil &&
            !draft.publicSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? palette.color(for: .success)
            : palette.color(for: .warning)
    }

    private var publicSourceValidationMessage: String? {
        let value = draft.publicSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        do {
            _ = try PublicReproductionSourceValidator.validate(
                value,
                confirmed: draft.confirmsPublicSource
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func generatePreview(showPreview: Bool) {
        let requestedDraft = draft
        Task { @MainActor in
            do {
                let sourceContext = await appState.feedbackSourceContext(for: requestedDraft.category)
                let report = try FeedbackReportBuilder.build(
                    draft: requestedDraft,
                    sourceContext: sourceContext,
                    environment: .current(),
                    diagnosticLogs: requestedDraft.includeLogs ? DiagnosticLog.reportText() : ""
                )
                guard requestedDraft == draft else { return }
                previewSnapshot = FeedbackPreviewSnapshot(draft: requestedDraft, report: report)
                statusMessage = "预览已生成；字段变化后需要重新生成"
                statusIsError = false
                isShowingPreview = showPreview
            } catch {
                previewSnapshot = nil
                statusMessage = error.localizedDescription
                statusIsError = true
                isShowingPreview = false
            }
        }
    }

    private func continueToGitHub() {
        guard let previewReport, let repositoryURL else { return }
        do {
            let result = try FeedbackSubmissionCoordinator.handoff(
                draft: draft,
                report: previewReport,
                repositoryURL: repositoryURL
            )
            if let attachmentURL = result.attachmentURL {
                statusMessage = result.copiedToClipboard
                    ? "GitHub 空白 Issue 已打开；请粘贴正文并拖入日志：\(attachmentURL.path)"
                    : "GitHub 已打开；请从 Finder 拖入日志：\(attachmentURL.path)"
            } else {
                statusMessage = result.copiedToClipboard
                    ? "GitHub 空白 Issue 已打开，完整正文已复制到剪贴板"
                    : "GitHub 已打开，请检查后提交"
            }
            statusIsError = false
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    private func invalidatePreview() {
        previewSnapshot = nil
        isShowingPreview = false
        statusMessage = nil
        statusIsError = false
    }
}
