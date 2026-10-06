import SwiftUI
import Models
import ProviderRuntime
import ProviderSDK

struct ProviderInstallationProgressView: View {
    @Environment(\.appThemePalette) private var palette
    let installation: ProviderInstallationPresentation
    let isBusy: Bool
    let displayName: (String) -> String
    let retry: (ProviderVersionReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("组件安装进度"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !installation.rows.isEmpty {
                    Text(L10n.text("已就绪 {0} / {1}", ["\(installation.readyCount)", "\(installation.rows.count)"]))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(palette.muted)
                }
            }

            switch installation.phase {
            case .fetchingCatalog:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在获取组件列表"))
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
            case .completed:
                Label(L10n.text("全部安装完成"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(palette.color(for: .success))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(palette.color(for: .warning))
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .installing:
                EmptyView()
            }

            ForEach(installation.rows) { row in
                ProviderInstallationProgressRow(
                    row: row, isBusy: isBusy,
                    title: displayName(row.id.providerID),
                    retry: { retry(row.id) }
                )
            }
        }
        .foregroundStyle(palette.foreground)
    }
}

private struct ProviderInstallationProgressRow: View {
    @Environment(\.appThemePalette) private var palette
    let row: ProviderInstallationRow
    let isBusy: Bool
    let title: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text("\(row.id.providerID) · v\(row.id.version)")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                statusLabel.font(.caption)
                if case .failed = row.status {
                    Button(action: retry) {
                        Label(L10n.text("重试"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                    .help(L10n.text("下载并启用此播放扩展"))
                }
            }

            if case .installing(let progress) = row.status {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                    Text(L10n.text("{0}% · {1} / {2}", [
                        "\(Int(fraction * 100))",
                        byteCount(progress.receivedBytes),
                        byteCount(progress.expectedBytes ?? 0),
                    ]))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(palette.muted)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if progress.phase == .downloading {
                            Text(progress.receivedBytes > 0
                                ? L10n.text("已下载 {0}", [byteCount(progress.receivedBytes)])
                                : L10n.text("正在连接下载服务…"))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(palette.muted)
                        }
                    }
                }
            }
            if case .failed(let message) = row.status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(palette.color(for: .warning))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch row.status {
        case .queued:
            Text(L10n.text("等待下载")).foregroundStyle(palette.muted)
        case .ready:
            Label(L10n.text("已就绪"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(palette.color(for: .success))
        case .failed:
            Text(L10n.text("安装失败")).foregroundStyle(palette.color(for: .warning))
        case .installing(let progress):
            Text(phaseLabel(progress.phase)).foregroundStyle(palette.muted)
        }
    }

    private func phaseLabel(_ phase: ProviderInstallPhase) -> String {
        switch phase {
        case .fetchingCatalog: L10n.text("正在获取组件列表")
        case .downloading: L10n.text("正在下载")
        case .verifyingArchive: L10n.text("正在校验下载文件")
        case .extracting: L10n.text("正在解包")
        case .verifyingPackage: L10n.text("正在验证组件签名")
        case .launching: L10n.text("正在验证启动")
        case .completed: L10n.text("已就绪")
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
