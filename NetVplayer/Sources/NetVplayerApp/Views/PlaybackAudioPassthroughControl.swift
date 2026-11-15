import Models
import PlayerEngine
import Storage
import SwiftUI

/// The same policy and copy are used in settings and format details.
struct PlaybackAudioPassthroughControl: View {
    @Environment(\.appThemePalette) private var palette
    @State private var preference = PlaybackAudioOutputPreferenceStore.shared.snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("音频直通")).font(.system(size: 13, weight: .medium))
            Picker(L10n.text("音频直通"), selection: Binding(
                get: { preference.dolbyAudio },
                set: {
                    var latest = PlaybackAudioOutputPreferenceStore.shared.snapshot
                    latest.dolbyAudio = $0
                    PlaybackAudioOutputPreferenceStore.shared.set(latest)
                }
            )) {
                Text(L10n.text("自动")).tag(PlaybackDolbyAudioMode.automatic)
                Text(L10n.text("开启")).tag(PlaybackDolbyAudioMode.passthrough)
                Text(L10n.text("关闭")).tag(PlaybackDolbyAudioMode.pcm)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large)
            .tint(palette.lavender).frame(minHeight: 44)
            Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: PlaybackAudioOutputPreferenceStore.didChange)) { _ in
            preference = PlaybackAudioOutputPreferenceStore.shared.snapshot
        }
    }

    private var explanation: String {
        switch preference.dolbyAudio {
        case .automatic: L10n.text("按片源和设备能力选择，无法直通时使用 PCM。")
        case .passthrough: L10n.text("优先直通，不支持时自动使用 PCM。")
        case .pcm: L10n.text("由播放器解码，可调节音量与音效。")
        }
    }
}
