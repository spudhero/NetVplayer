import SwiftUI
import Models

/// The same local-only summary is shown after launch and an interrupted refresh.
struct MediaScanRecoveryPanel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var state: FileServicesState
    @Environment(\.appThemePalette) private var palette
    var body: some View {
        if let checkpoint = state.selectedScanCheckpoint, checkpoint.phase != .completed, !state.isRefreshing {
            MediaScanRecoveryContent(checkpoint: checkpoint,
                configurationMatches: state.scanCheckpointMatchesConfiguration(checkpoint),
                canContinue: state.canContinueScan(checkpoint), issue: state.scanTaskIssues[checkpoint.libraryID],
                onEditService: { appState.openTaskSettings() }, onRequest: { state.requestMediaScan($0) })
        }
        if let error = state.scanCheckpointError {
            VStack(alignment: .leading, spacing: 10) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(palette.color(for: .warning))
                Button(L10n.text("重新扫描媒体库")) { state.requestMediaScan(.rescan) }.disabled(state.isRefreshing)
            }.padding(14)
        }
    }
}

/// Presentation only; recovery eligibility and all work remain with the scanner.
struct MediaScanRecoveryContent: View {
    let checkpoint: MediaScanCheckpoint
    let configurationMatches: Bool
    let canContinue: Bool
    let issue: TaskDiagnosticIssue?
    let onEditService: () -> Void
    let onRequest: (MediaScanRequest) -> Void
    @Environment(\.appThemePalette) private var palette

    private var requiresServiceEdit: Bool {
        checkpoint.phase != .cancelled && issue.map {
            [.login, .settings].contains(UserFacingErrorPresenter.taskAction(for: $0.reason))
        } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(checkpoint.phase == .cancelled ? L10n.text("已取消") : L10n.text("上次扫描未完成"),
                  systemImage: checkpoint.phase == .cancelled ? "minus.circle" : "arrow.triangle.2.circlepath")
                .font(.callout.weight(.semibold))
            Text(L10n.text("已完成 {0} 个目录 · 待访问 {1} 个 · 失败 {2} 个", [
                String(checkpoint.completedDirectories), String(checkpoint.pendingDirectories), String(checkpoint.failedDirectories.count)
            ])).font(.caption).foregroundStyle(palette.muted)
            if !configurationMatches || checkpoint.phase == .invalidated {
                Text(L10n.text("服务、账号或媒体库设置已变化，请重新扫描。旧索引仍可浏览。"))
                    .font(.caption).foregroundStyle(palette.muted)
            } else if checkpoint.isExpired() {
                Text(L10n.text("扫描检查点已过期，请手动重新扫描。旧索引仍可浏览。"))
                    .font(.caption).foregroundStyle(palette.muted)
            } else if checkpoint.phase == .cancelled {
                Text(L10n.text("扫描已取消，请手动重新扫描。旧索引仍可浏览。"))
                    .font(.caption).foregroundStyle(palette.muted)
            } else {
                Text(L10n.text("旧索引仍可浏览。")).font(.caption).foregroundStyle(palette.muted)
            }
            if let issue, checkpoint.phase != .cancelled {
                Text(UserFacingErrorPresenter.taskMessage(.init(stage: .scanning,
                    state: issue.reason == .credentialExpired ? .needsLogin : .needsAttention, issue: issue)))
                    .font(.caption).foregroundStyle(palette.muted)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }
                VStack(alignment: .leading, spacing: 10) { actions }
            }
            if !checkpoint.failedDirectories.isEmpty {
                DisclosureGroup(L10n.text("失败目录（{0}）", [String(checkpoint.failedDirectories.count)])) {
                    VStack(alignment: .leading, spacing: 10) {
                        if canContinue {
                            Button(L10n.text("重试全部失败目录")) { onRequest(.retryFailed(paths: checkpoint.failedDirectories)) }
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(checkpoint.failedDirectories, id: \.self) { path in
                                    HStack {
                                        Label(path, systemImage: "folder.badge.questionmark")
                                            .lineLimit(2).textSelection(.enabled)
                                        Spacer()
                                        Button(L10n.text("重试此目录")) { onRequest(.retryFailed(paths: [path])) }
                                            .disabled(!canContinue)
                                    }
                                }
                            }
                        }.frame(maxHeight: 120).font(.caption)
                    }.padding(.top, 6)
                }.disclosureGroupStyle(FullRowDisclosureGroupStyle()).font(.caption)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.foreground.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(palette.foreground.opacity(0.10)) }
    }

    @ViewBuilder private var actions: some View {
        if requiresServiceEdit {
            Button(L10n.text("编辑服务"), action: onEditService).buttonStyle(.borderedProminent)
        } else if canContinue {
            Button(issue.map {
                UserFacingErrorPresenter.taskAction(for: $0.reason) == .retryLater
                    ? TaskResultAction.retryLater.title : L10n.text("继续扫描")
            } ?? L10n.text("继续扫描")) { onRequest(.resume) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("media-scan-resume")
        } else {
            Button(L10n.text("重新扫描媒体库")) { onRequest(.rescan) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("media-scan-rescan")
        }
        if canContinue || requiresServiceEdit {
            Button(L10n.text("重新扫描媒体库")) { onRequest(.rescan) }
                .buttonStyle(.borderless).accessibilityIdentifier("media-scan-rescan")
        }
        if requiresServiceEdit && canContinue {
            Button(L10n.text("继续扫描")) { onRequest(.resume) }
                .accessibilityIdentifier("media-scan-resume")
        }
    }
}
