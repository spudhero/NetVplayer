import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Models

struct DriveTaskRecoveryView: View {
    private enum Page: Hashable { case recovery, history }
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    @State private var page: Page = .recovery
    @State private var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("任务记录")).font(.title2.weight(.semibold))
                    Text(L10n.text("手动继续会先核对原账号和目标，不会重新提交未知结果的转存。"))
                        .font(.callout).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(palette.muted)
                    .accessibilityLabel(L10n.text("关闭")).keyboardShortcut(.cancelAction)
            }.padding(24)
            Picker(L10n.text("任务记录"), selection: $page) {
                Text(L10n.text("转存核对")).tag(Page.recovery)
                Text(L10n.text("最近任务")).tag(Page.history)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 16)
            if appState.driveTaskStorageFailed {
                Text(L10n.text("无法保存或读取转存记录，已停止转存。请检查本机存储后重试。"))
                    .foregroundStyle(palette.color(for: .danger)).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if appState.taskDiagnosticsUnavailable {
                Text(L10n.text("本地任务历史暂时不可用，转存核对记录仍独立保留。"))
                    .foregroundStyle(palette.muted).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if let message = appState.driveTaskMessage {
                Text(message).font(.callout).padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if page == .history {
                        if appState.recentTaskDiagnostics.isEmpty { emptyState(L10n.text("暂无最近任务")) }
                        ForEach(appState.recentTaskDiagnostics) { record in historyRow(record) }
                    } else {
                        if appState.driveTaskSummaries.isEmpty { emptyState(L10n.text("暂无转存记录")) }
                        ForEach(appState.driveTaskSummaries) { task in recoveryRow(task) }
                    }
                }
                // Both pages use the same task IDs. Rebuild the lazy rows when
                // switching pages so macOS does not retain the other row type.
                .id(page)
                    .padding(24)
            }.frame(maxHeight: .infinity)
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                if let exportMessage { Text(exportMessage).font(.caption).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Text(L10n.text("本地诊断详情")).font(.caption).foregroundStyle(palette.muted)
                    Spacer()
                    Button { export() } label: {
                        Label(L10n.text("导出本地任务摘要"), systemImage: "square.and.arrow.up")
                    }.accessibilityIdentifier("task-diagnostics-export")
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(minWidth: 580, idealWidth: 680, minHeight: 380, idealHeight: 540)
        .themedPresentation()
        .onAppear {
            appState.refreshDriveTaskSummaries()
            page = appState.driveTaskSummaries.contains(where: \.canContinue) ? .recovery : .history
        }
    }

    private func recoveryRow(_ task: DriveTransferTask) -> some View {
        let summary = appState.recentTaskDiagnostics.first { $0.id == task.id } ?? .transfer(task)
        let event = summary.latest
        let active = appState.driveRecoveryBusy.contains(task.id) || appState.activeTaskDiagnosticIDs.contains(task.id)
        let action = UserFacingErrorPresenter.taskAction(for: event.reason)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(task.scope.provider.localizedDisplayName, systemImage: "externaldrive")
                    .font(.callout.weight(.semibold))
                Spacer()
                TaskStatusLabel(event: event, isActive: active)
            }
            Text(UserFacingErrorPresenter.taskMessage(event, isActive: active)).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if task.cancelled && task.submitted {
                Text(L10n.text("已提交的转存可能仍在服务端完成，记录会保留。"))
                    .font(.caption).foregroundStyle(palette.muted)
            }
            Text(task.updatedAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption).foregroundStyle(palette.muted)
            HStack(spacing: 12) {
                if task.canContinue {
                    if !active {
                        Button(action.title) {
                            if action == .login {
                                appState.pendingTaskLogin = task.scope.provider; appState.showsDriveTaskRecovery = false
                            } else if action == .settings {
                                appState.pendingTaskSettings = true; appState.showsDriveTaskRecovery = false
                            } else { appState.continueDriveTask(task) }
                        }.buttonStyle(ThemedDialogButtonStyle(isPrimary: true))
                        if action == .login || action == .settings {
                            Button(TaskResultAction.continueTask.title) { appState.continueDriveTask(task) }
                        }
                    }
                    Spacer()
                    Button(L10n.text("取消任务")) { appState.cancelDriveTask(task) }.buttonStyle(.borderless)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(palette.foreground.opacity(0.08)) }
    }

    private func historyRow(_ record: TaskDiagnosticRecord) -> some View {
        let event = record.latest
        let active = appState.activeTaskDiagnosticIDs.contains(record.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.kind == .metadataMatch ? L10n.text("匹配影视资料") : record.kind == .mediaScan ? L10n.text("扫描媒体库") : record.provider?.localizedDisplayName ?? L10n.text("转存核对"))
                    .fontWeight(.semibold)
                Spacer()
                TaskStatusLabel(event: event, isActive: active)
            }
            Text(UserFacingErrorPresenter.taskMessage(event, isActive: active)).font(.callout)
            Text(event.time, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
            if appState.driveTaskSummaries.contains(where: { $0.id == record.id && $0.canContinue }) {
                Button(L10n.text("查看转存核对")) { page = .recovery; appState.driveTaskMessage = nil }
            } else if record.kind == .mediaScan && event.state == .needsLogin {
                Button(L10n.text("编辑服务")) {
                    appState.pendingTaskSettings = true; appState.showsDriveTaskRecovery = false
                }
            }
            DisclosureGroup(L10n.text("本地诊断详情")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                    ForEach(Array(record.events.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.time, style: .time)
                            Text(UserFacingErrorPresenter.taskStage(item.stage))
                            Text(L10n.text("重试 {0} 次", [String(item.retryCount)]))
                            if let code = item.serviceCode { Text(L10n.text("服务错误码 {0}", [code])) }
                            if let status = item.httpStatus { Text(String(status)) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.font(.caption).disclosureGroupStyle(FullRowDisclosureGroupStyle())
            Divider().opacity(0.35)
        }
    }

    private func emptyState(_ title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 28, weight: .light))
            Text(title).font(.callout)
        }.foregroundStyle(palette.muted).frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = "NetVplayer-Task-Summary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.exportTaskDiagnostics(to: url)
            exportMessage = L10n.text("本地任务摘要已导出，不包含文件、路径或账号信息。")
        } catch {
            exportMessage = UserFacingErrorPresenter.message(for: error, context: .storage(operation: L10n.text("导出任务摘要")))
        }
    }
}
