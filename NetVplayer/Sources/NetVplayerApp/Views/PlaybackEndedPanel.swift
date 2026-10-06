import SwiftUI
import Models

enum EpisodeListLoadState: Equatable {
    case loading, ready, incomplete
}

struct PlaybackEndedPanel: View {
    var compact = false
    let interrupted: Bool
    let listState: EpisodeListLoadState
    let hasNext: Bool
    let onReplay: () -> Void
    let onNext: () -> Void
    let onRetryList: () -> Void

    var body: some View {
        VStack(spacing: compact ? 10 : 16) {
            Image(systemName: interrupted ? "exclamationmark.triangle" : "checkmark")
                .font(.system(size: compact ? 16 : 22, weight: .semibold))
                .foregroundStyle(PlayerHUDPalette.accent)
                .frame(width: compact ? 30 : 48, height: compact ? 30 : 48)
                .background(PlayerHUDPalette.accent.opacity(0.12), in: Circle())
            Text(interrupted ? L10n.text("播放意外结束") : L10n.text("本集播放结束"))
                .font(.system(size: compact ? 17 : 21, weight: .semibold))
            switch listState {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在加载完整剧集列表…"))
                }
                .foregroundStyle(PlayerHUDPalette.muted)
            case .incomplete:
                Text(L10n.text("剧集列表尚未加载完整，可重试获取后续剧集。"))
                    .foregroundStyle(PlayerHUDPalette.muted)
            case .ready:
                if !hasNext {
                    Text(L10n.text("当前列表中没有可自动衔接的下一集。"))
                        .foregroundStyle(PlayerHUDPalette.muted)
                }
            }
            HStack(spacing: 10) {
                actionButton(L10n.text("从头重播"), symbol: "arrow.counterclockwise", prominent: true, action: onReplay)
                if listState == .incomplete {
                    actionButton(L10n.text("重试剧集列表"), symbol: "arrow.clockwise", action: onRetryList)
                } else if listState == .ready, hasNext {
                    actionButton(L10n.text("下一集"), symbol: "forward.end", action: onNext)
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 13))
        .foregroundStyle(PlayerHUDPalette.foreground)
        .multilineTextAlignment(.center)
        .padding(compact ? 16 : 24)
        .frame(maxWidth: 420)
        .background(PlayerGlassPanel())
        .accessibilityElement(children: .contain)
    }

    private func actionButton(_ title: String, symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: compact ? 32 : 40)
                .background(prominent ? PlayerHUDPalette.accent.opacity(0.22) : Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(prominent ? PlayerHUDPalette.accent.opacity(0.55) : Color.white.opacity(0.13), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}
