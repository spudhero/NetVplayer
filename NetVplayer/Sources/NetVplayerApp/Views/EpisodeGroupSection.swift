import SwiftUI
import DriveEngine
import Models

/// Shared visible series boundary for the detail picker and player drawer.
struct EpisodeGroupSection<Content: View>: View {
    @Environment(\.appThemePalette) private var palette
    let group: EpisodeGroup
    let ordinal: Int
    let isCurrent: Bool
    let isHistory: Bool
    let usesPlayerPalette: Bool
    let prefersExpanded: Bool
    let content: Content
    @State private var isExpanded: Bool

    init(
        group: EpisodeGroup,
        ordinal: Int,
        isCurrent: Bool,
        isHistory: Bool,
        usesPlayerPalette: Bool = false,
        prefersExpanded: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.group = group
        self.ordinal = ordinal
        self.isCurrent = isCurrent
        self.isHistory = isHistory
        self.usesPlayerPalette = usesPlayerPalette
        self.prefersExpanded = prefersExpanded
        self.content = content()
        _isExpanded = State(initialValue: prefersExpanded)
    }

    private var color: Color {
        switch ordinal % 3 {
        case 1: usesPlayerPalette ? PlayerHUDPalette.accent : palette.accent
        case 2: .mint
        default: usesPlayerPalette ? PlayerHUDPalette.lavender : palette.lavender
        }
    }

    private var foreground: Color { usesPlayerPalette ? PlayerHUDPalette.foreground : palette.foreground }
    private var muted: Color { usesPlayerPalette ? PlayerHUDPalette.muted : palette.muted }
    private var surface: Color { usesPlayerPalette ? PlayerHUDPalette.surface : palette.surface }

    private var title: String {
        let label = L10n.text("资源组 {0}", ["\(ordinal + 1)"])
        return group.name.isEmpty ? label : "\(label) · \(group.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(muted)
                        .frame(width: 12)
                    Circle().fill(color).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(foreground)
                            .lineLimit(2)
                        Text(L10n.text("{0} 个文件", ["\(group.episodes.count)"]))
                            .font(.caption)
                            .foregroundStyle(muted)
                    }
                    Spacer(minLength: 4)
                    if isCurrent {
                        Label(L10n.text("正在播放"), systemImage: "play.fill")
                            .font(.caption2)
                            .foregroundStyle(color)
                    } else if isHistory {
                        Label(L10n.text("上次"), systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)，\(L10n.text("{0} 个文件", ["\(group.episodes.count)"]))")
            .accessibilityValue(isExpanded ? L10n.text("已展开") : L10n.text("已折叠"))
            .help(isExpanded ? L10n.text("折叠资源组") : L10n.text("展开资源组"))

            if isExpanded { content }
        }
        .padding(12)
        .background(surface.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(color.opacity(isCurrent ? 0.45 : 0.2), lineWidth: 1)
        }
        .onChange(of: prefersExpanded) { _, preferred in
            if preferred { isExpanded = true }
        }
    }
}
