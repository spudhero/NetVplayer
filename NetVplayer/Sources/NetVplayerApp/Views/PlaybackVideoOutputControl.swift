import Models
import PlayerEngine
import Storage
import SwiftUI

struct PlaybackVideoOutputControl: View {
    @Environment(\.appThemePalette) private var palette
    @State private var preference = PlaybackColorPreferenceStore.shared.snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("HDR 策略")).font(.system(size: 13, weight: .medium))
            Picker(L10n.text("HDR 策略"), selection: Binding(
                get: { preference.videoOutput },
                set: {
                    var latest = PlaybackColorPreferenceStore.shared.snapshot
                    latest.videoOutput = $0
                    PlaybackColorPreferenceStore.shared.set(latest)
                }
            )) {
                Text(L10n.text("跟随系统")).tag(PlaybackVideoOutputMode.automatic)
                Text(L10n.text("临时 HDR")).tag(PlaybackVideoOutputMode.hdrIfAvailable)
                Text(L10n.text("SDR 映射")).tag(PlaybackVideoOutputMode.sdr)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large)
            .tint(palette.lavender).frame(minHeight: 44)
            Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: PlaybackColorPreferenceStore.didChange)) { _ in
            preference = PlaybackColorPreferenceStore.shared.snapshot
        }
    }

    private var explanation: String {
        switch preference.videoOutput {
        case .automatic: L10n.text("不更改系统显示模式，按当前可用能力输出。")
        case .hdrIfAvailable: L10n.text("仅本次播放开启，结束后恢复；切换可能短暂黑屏。")
        case .sdr: L10n.text("将 HDR 片源映射为 SDR，不更改系统显示模式。")
        }
    }
}
