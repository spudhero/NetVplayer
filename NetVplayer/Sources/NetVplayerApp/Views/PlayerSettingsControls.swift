import SwiftUI
import Models

// Categories keep quick playback choices separate from persistent appearance and diagnostics.
enum PlayerSettingsCategory: String, CaseIterable, Identifiable {
    case playback, subtitles, danmaku, advanced
    var id: Self { self }
    var title: String {
        switch self {
        case .playback: L10n.text("播放")
        case .subtitles: L10n.text("字幕")
        case .danmaku: L10n.text("弹幕")
        case .advanced: L10n.text("更多")
        }
    }
}

struct SubtitleDelayControl: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                Button { adjust(-0.1) } label: { Image(systemName: "minus").frame(width: 32, height: 30) }
                    .disabled(value <= -120).accessibilityLabel(L10n.text("{0}提前 0.1 秒", [title]))
                Text(L10n.text("{0} 秒", [String(format: "%+.1f", value)]))
                    .font(.system(size: 12).monospacedDigit()).frame(width: 78)
                Button { adjust(0.1) } label: { Image(systemName: "plus").frame(width: 32, height: 30) }
                    .disabled(value >= 120).accessibilityLabel(L10n.text("{0}延后 0.1 秒", [title]))
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }.frame(minHeight: 36)
    }

    private func adjust(_ delta: Double) {
        value = min(120, max(-120, ((value + delta) * 10).rounded() / 10))
    }
}
