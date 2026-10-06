import SwiftUI
import Models
import PlayerEngine

struct SubtitleTrackControls: View {
    @ObservedObject var state: PlayerState
    let select: (SubtitleSlot, PlayerTrackInfo?) -> Void
    @State private var slot: SubtitleSlot = .primary

    private var selectedID: String? {
        slot == .primary ? state.selectedSubtitleTrackID : state.selectedSecondarySubtitleTrackID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                slotButton(.primary, title: L10n.text("主字幕"), selected: state.selectedSubtitleTrackID)
                slotButton(.secondary, title: L10n.text("副字幕"), selected: state.selectedSecondarySubtitleTrackID)
            }
            ThemedScrollView(theme: .player) {
                VStack(spacing: 4) {
                    option(L10n.text("关闭字幕"), selected: selectedID == nil) { select(slot, nil) }
                    ForEach(state.subtitleTracks) { track in
                        option(track.displayName, selected: track.id == selectedID) { select(slot, track) }
                    }
                    if state.subtitleTracks.isEmpty {
                        Text(L10n.text("当前视频没有内嵌字幕，可在下方搜索在线字幕。"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(10)
                    }
                }
            }
            .frame(height: min(240, CGFloat(max(2, state.subtitleTracks.count + 1)) * 42))
        }
    }

    private func slotButton(_ value: SubtitleSlot, title: String, selected: String?) -> some View {
        Button { slot = value } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(state.subtitleTracks.first { $0.id == selected }?.displayName ?? L10n.text("关闭字幕"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color.white.opacity(slot == value ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(slot == value ? PlayerHUDPalette.lavender.opacity(0.7) : .clear, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(slot == value ? .isSelected : [])
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? PlayerHUDPalette.lavender : .white.opacity(0.4))
                Text(title).font(.system(size: 13)).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(minHeight: 38)
            .background(Color.white.opacity(selected ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
