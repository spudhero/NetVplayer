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
                    Text("关于 \(AppVersionDisplay.label())")
                        .lineLimit(1)
                } else {
                    Text(AppVersionDisplay.label())
                }
                if updates.hasNewVersion {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("有新版本")
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
        .help("应用版本与更新")
        .popover(isPresented: $showingUpdate, arrowEdge: .trailing) {
            AppUpdateStatusView()
                .frame(width: 300)
                .padding(16)
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
                Text("当前没有可用更新")
                    .foregroundStyle(.secondary)
                Button("检查更新") { updates.checkForUpdateInformation() }
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检查更新")
                }
            case let .available(info):
                Text("新版本 v\(info.displayVersion)")
                    .font(.subheadline.weight(.semibold))
                releaseNotesLink(for: info)
                if !info.isInformationalOnly {
                    Button("更新") { updates.beginUpdate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(updates.isCheckingInformation)
                }
            case let .downloading(info):
                Text("正在后台下载并验证 v\(info.displayVersion)")
                ProgressView()
                releaseNotesLink(for: info)
            case let .ready(info):
                Text("v\(info.displayVersion) 已准备好，退出应用后安装")
                releaseNotesLink(for: info)
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.red)
                Button("重试") { updates.checkForUpdateInformation() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func releaseNotesLink(for info: AppUpdateInfo) -> some View {
        if let releaseURL = info.releaseURL {
            Link("查看更新说明", destination: releaseURL)
                .font(.caption)
        }
    }
}
