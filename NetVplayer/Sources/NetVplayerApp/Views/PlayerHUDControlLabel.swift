import SwiftUI
import Models

/// Every regular-player control reserves the same icon, title and status rows.
/// An absent status still takes space so adjacent controls keep their baselines.
struct PlayerHUDControlLabel<Icon: View>: View {
    let title: String
    var detail: String? = nil
    var width: CGFloat = PlayerHUDVisualPolicy.menuControlWidth
    var isActive = false
    var disabled = false
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        VStack(spacing: PlayerHUDVisualPolicy.controlRowSpacing) {
            icon()
                .frame(width: PlayerHUDVisualPolicy.iconRowHeight, height: PlayerHUDVisualPolicy.iconRowHeight)
                .foregroundStyle(disabled ? foreground : (isActive ? PlayerHUDPalette.lavender : foreground))
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(PlayerHUDPalette.lavender.opacity(PlayerHUDVisualPolicy.activeLavenderBackgroundOpacity))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(PlayerHUDPalette.lavender.opacity(PlayerHUDVisualPolicy.activeLavenderBorderOpacity), lineWidth: 1)
                            }
                    }
                }
            Text(title)
                .font(.system(size: PlayerHUDVisualPolicy.controlLabelFontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(height: PlayerHUDVisualPolicy.controlLabelHeight)
            Text(detail ?? " ")
                .font(.system(size: PlayerHUDVisualPolicy.controlDetailFontSize, design: .monospaced))
                .foregroundStyle(PlayerHUDPalette.muted.opacity(disabled ? PlayerHUDVisualPolicy.disabledControlOpacity : 0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(height: PlayerHUDVisualPolicy.controlDetailHeight)
                .opacity(detail == nil ? 0 : 1)
                .accessibilityHidden(detail == nil)
        }
        .foregroundStyle(foreground)
        .frame(width: width, height: PlayerHUDVisualPolicy.menuControlHeight, alignment: .top)
        .contentShape(Rectangle())
    }

    private var foreground: Color {
        PlayerHUDPalette.foreground.opacity(disabled
            ? PlayerHUDVisualPolicy.disabledControlOpacity : PlayerHUDVisualPolicy.controlForegroundOpacity)
    }
}

struct PlayerFloatingWindowButton: View {
    @ObservedObject var windowContext: PlayerWindowContext
    var usesHUDLabel = true
    var onInteraction: () -> Void = {}

    var body: some View {
        Button {
            _ = windowContext.enterFloatingWindow()
            onInteraction()
        } label: {
            if usesHUDLabel {
                PlayerHUDControlLabel(title: L10n.text("小窗")) {
                    Image(systemName: "pip.enter").font(.system(size: 21, weight: .regular))
                }
            } else {
                Image(systemName: "pip.enter")
                    .font(.system(size: 16))
                    .frame(width: 32, height: 32)
            }
        }
        .buttonStyle(.plain)
        .help(L10n.text("将播放器缩小并置顶，继续播放当前视频"))
        .accessibilityLabel(L10n.text("小窗"))
        .accessibilityIdentifier("player.floating-window.enter")
    }
}
