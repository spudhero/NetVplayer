import Models
import PlayerEngine
import Storage
import SwiftUI

struct PlaybackDialogueSettingsView: View {
    @ObservedObject var playerState: PlayerState
    var initiallyExpanded = false
    @State private var strength = PlaybackDialoguePreferenceStore.shared.snapshot

    var body: some View {
        PlaybackSettingsDisclosure(
            L10n.text("对白清晰度"), summary: strength.description,
            systemImage: "waveform", initiallyExpanded: initiallyExpanded
        ) {
            VStack(alignment: .leading, spacing: 10) {
                PlaybackSettingField(title: L10n.text("处理强度")) {
                    Picker(
                        L10n.text("处理强度"),
                        selection: Binding(
                            get: { strength },
                            set: {
                                strength = $0
                                PlaybackDialoguePreferenceStore.shared.set($0)
                            })
                    ) {
                        ForEach(PlaybackDialogueStrength.allCases, id: \.self) { value in
                            Text(value.description).tag(value)
                        }
                    }
                }
                FeatureNotice(
                    message: playerState.playbackDiagnostics?.audio.dialogue?.status.description
                        ?? (strength == .off
                            ? PlaybackDialogueStatus.off.description : PlaybackDialogueStatus.checking.description),
                    systemImage: "waveform")
                Text(L10n.text("多声道优先保留中央声道；立体声使用均衡与动态压缩，不分离人声和音乐。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    PlaybackDialoguePreferenceStore.shared.reset()
                } label: {
                    Label(L10n.text("恢复原音频"), systemImage: "arrow.counterclockwise")
                }.buttonStyle(.borderless).font(.caption)
                DisclosureGroup(L10n.text("对白设置说明")) {
                    Text(L10n.text("默认关闭。点播与直播共享此偏好，换片后保留；调整时会短暂淡出淡入，音量设置不变。"))
                        .padding(.top, 8).fixedSize(horizontal: false, vertical: true)
                }.disclosureGroupStyle(FullRowDisclosureGroupStyle())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PlaybackDialoguePreferenceStore.didChange)) { _ in
            strength = PlaybackDialoguePreferenceStore.shared.snapshot
        }
    }
}
