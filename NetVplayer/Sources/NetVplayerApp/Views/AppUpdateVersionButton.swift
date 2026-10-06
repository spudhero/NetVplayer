import Models
import SwiftUI

struct AppUpdateVersionButton: View {
    enum Placement {
        case sidebar
        case settings
    }

    let placement: Placement

    @ObservedObject private var updates = AppUpdateCoordinator.shared
    @State private var showingUpdate = false

    var body: some View {
        Button {
            showingUpdate = true
        } label: {
            HStack(spacing: 7) {
                if placement == .sidebar {
                    Image(systemName: "info.circle")
                    Text(L10n.text("关于 {0}", ["\(AppVersionDisplay.label())"]))
                        .lineLimit(1)
                } else {
                    Text(AppVersionDisplay.label())
                }
                if updates.hasNewVersion {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(L10n.text("有新版本"))
                }
                if placement == .sidebar {
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: placement == .sidebar ? 11 : 12, weight: .medium))
            .padding(.horizontal, placement == .sidebar ? 10 : 0)
            .frame(height: placement == .sidebar ? 30 : 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("应用版本与更新"))
        .popover(isPresented: $showingUpdate, arrowEdge: .trailing) {
            AppUpdateStatusView()
                .frame(width: 300)
                .padding(16)
                .themedPresentation()
        }
    }
}

private struct AppUpdateStatusView: View {
    @ObservedObject private var updates = AppUpdateCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NetVplayer \(AppVersionDisplay.label())")
                .font(.headline)

            switch updates.phase {
            case .idle:
                Text(L10n.text("当前没有可用更新"))
                    .foregroundStyle(.secondary)
                Button(L10n.text("检查更新")) { updates.checkForUpdateInformation() }
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在检查更新"))
                }
            case let .available(info):
                Text(L10n.text("新版本 v{0}", ["\(info.displayVersion)"]))
                    .font(.subheadline.weight(.semibold))
                releaseNotesLink(for: info)
                if !info.isInformationalOnly {
                    Button(L10n.text("更新")) { updates.beginUpdate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(updates.isCheckingInformation)
                }
            case let .downloading(info):
                Text(L10n.text("正在后台下载并验证 v{0}", ["\(info.displayVersion)"]))
                ProgressView()
                releaseNotesLink(for: info)
            case let .ready(info):
                Text(L10n.text("v{0} 已准备好，退出应用后安装", ["\(info.displayVersion)"]))
                releaseNotesLink(for: info)
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.red)
                Button(L10n.text("重试")) { updates.checkForUpdateInformation() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func releaseNotesLink(for info: AppUpdateInfo) -> some View {
        if let releaseURL = info.releaseURL {
            Link(L10n.text("查看更新说明"), destination: releaseURL)
                .font(.caption)
        }
    }
}
