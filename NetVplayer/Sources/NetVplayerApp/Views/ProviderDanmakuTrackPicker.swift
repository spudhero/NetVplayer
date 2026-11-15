import SwiftUI
import Models

/// Selection is owned by the player. Choosing a row does not assert that the
/// provider returned usable data or change the player's automatic loading rules.
struct ProviderDanmakuTrackPicker: View {
    let tracks: [ProviderDanmaku]
    let selection: Int?
    let enabled: Bool
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("来源弹幕"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PlayerHUDPalette.muted)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.text(enabled ? "选择当前来源提供的弹幕轨道。" : "开启弹幕后可选择轨道。"))
                .font(.caption).foregroundStyle(PlayerHUDPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                let name = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let scheme = URL(string: name)?.scheme?.lowercased()
                let title = name.isEmpty || name == track.url || scheme == "http" || scheme == "https"
                    ? L10n.text("弹幕 {0}", ["\(index + 1)"]) : name
                let selected = selection == index
                Button { onSelect(index) } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? PlayerHUDPalette.accent : PlayerHUDPalette.muted)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.system(size: 13, weight: selected ? .medium : .regular))
                            .foregroundStyle(PlayerHUDPalette.foreground)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .background(selected ? PlayerHUDPalette.accent.opacity(0.12) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
                .help(title)
                .accessibilityLabel(title)
                .accessibilityValue(L10n.text(selected ? "已选择" : "未选择"))
                .accessibilityIdentifier("player.provider-danmaku.\(index)")
            }
        }
    }
}
