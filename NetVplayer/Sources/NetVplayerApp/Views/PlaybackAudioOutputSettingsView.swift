import Models
import PlayerEngine
import Storage
import SwiftUI

struct PlaybackAudioOutputSettingsView: View {
    @ObservedObject var playerState: PlayerState
    var initiallyExpanded = false

    var body: some View {
        PlaybackSettingsDisclosure(
            L10n.text("音频输出与设备"), summary: playerState.currentOutputSummary.audio?.actualOutput ?? L10n.text("播放后显示实际输出"),
            systemImage: "speaker.wave.2", initiallyExpanded: initiallyExpanded
        ) {
            PlaybackAudioOutputSettingsContent(playerState: playerState)
        }
    }
}

/// Shared by the settings drawer and the compact output popover.
struct PlaybackAudioOutputSettingsContent: View {
    @ObservedObject var playerState: PlayerState
    var status: PlaybackFormatStatus?
    var searchRequest: UUID? = nil
    var searchAdvanced = false
    @State var advancedExpanded = false
    @State private var preference = PlaybackAudioOutputPreferenceStore.shared.snapshot

    private var actual: PlaybackFormatStatus? { playerState.currentOutputSummary.audio ?? status }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PlaybackOutputActualSummary(status: actual)
            PlaybackAudioPassthroughControl().settingsSearchAnchor(.audio)
            if playerState.playbackDiagnostics?.audio.limitedToStereo == true {
                FeatureNotice(message: L10n.text("设备未确认环绕布局，当前安全下混为立体声。"),
                              role: .warning, systemImage: "exclamationmark.triangle")
            }
            VStack(spacing: 0) {
                DisclosureGroup(L10n.text("高级设置"), isExpanded: $advancedExpanded) {
                    advancedSettings.padding(.bottom, 8)
                }
                .disclosureGroupStyle(FullRowDisclosureGroupStyle(cardPadding: 4))
                Divider()
                PlaybackOutputTechnicalInfo(status: actual) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let route = playerState.playbackDiagnostics?.audio.routeStatus {
                            Text(route.description)
                        }
                        Text(L10n.text("倍速、对白增强或音频滤镜启用时使用 PCM；恢复原速并关闭处理后，自动恢复原生音频。"))
                        Text(L10n.text("所选设备不可用时暂用系统默认设备，恢复连接后重新尝试；声道选择不改变系统扬声器配置。"))
                        Text(L10n.text("仅提供支持选择的实体设备；虚拟与聚合设备暂不提供选择。"))
                    }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.font(.system(size: 12))
        }
        .onAppear { if searchAdvanced { advancedExpanded = true } }
        .onChange(of: searchRequest) { _, _ in if searchAdvanced { advancedExpanded = true } }
        .onReceive(NotificationCenter.default.publisher(for: PlaybackAudioOutputPreferenceStore.didChange)) { _ in
            preference = PlaybackAudioOutputPreferenceStore.shared.snapshot
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            PlaybackOutputSettingRow(title: L10n.text("输出设备偏好")) {
                Picker(L10n.text("输出设备偏好"), selection: Binding(
                    get: { preference.deviceUID ?? "" },
                    set: { value in update { $0.deviceUID = value.isEmpty ? nil : value } }
                )) {
                    Text(L10n.text("自动（系统默认设备）")).tag("")
                    ForEach(playerState.audioOutputDevices.filter(\.supportsPCMSelection)) { device in
                        Text(device.name).tag(device.id)
                    }
                    if let uid = preference.deviceUID,
                       !playerState.audioOutputDevices.contains(where: { $0.id == uid && $0.supportsPCMSelection }) {
                        Text(L10n.text("所选设备（当前不可用）")).tag(uid)
                    }
                }
            }.settingsSearchAnchor(.audioDevice)
            PlaybackOutputSettingRow(title: L10n.text("PCM 声道偏好")) {
                Picker(L10n.text("PCM 声道偏好"), selection: Binding(
                    get: { preference.mode }, set: { value in update { $0.mode = value } }
                )) {
                    ForEach(PlaybackAudioOutputMode.allCases, id: \.self) { mode in
                        Text(mode.description).tag(mode)
                    }
                }
            }.disabled(playerState.volumeControl != .player).settingsSearchAnchor(.audioChannels)
            PlaybackOutputSettingRow(title: L10n.text("PCM 采样率")) {
                Picker(L10n.text("PCM 采样率"), selection: Binding(
                    get: { preference.pcmSampleRate }, set: { value in update { $0.pcmSampleRate = value } }
                )) {
                    Text(L10n.text("跟随设备")).tag(PlaybackPCMSampleRateMode.device)
                    Text(L10n.text("跟随片源")).tag(PlaybackPCMSampleRateMode.source)
                }
            }.disabled(playerState.volumeControl != .player).settingsSearchAnchor(.audioRate)
            if playerState.volumeControl == .receiver {
                Text(L10n.text("原码直通保留片源码流；声道和采样率由音箱解码。"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if preference.pcmSampleRate == .source {
                Text(L10n.text("按片源尝试切换设备采样率，设备不支持时使用可用频率；停止播放后恢复。压缩直通保持原始码流。"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            PlaybackTrueHDObjectSettings(selection: Binding(
                get: { preference.trueHDObjects }, set: { value in update { $0.trueHDObjects = value } }
            ), unavailable: playerState.playbackDiagnostics?.audio.objectRenderingUnavailable == true)
                .padding(.top, 10).settingsSearchAnchor(.trueHD)
            Button {
                PlaybackAudioOutputPreferenceStore.shared.reset()
            } label: {
                Label(L10n.text("恢复音频输出默认"), systemImage: "arrow.counterclockwise")
            }.buttonStyle(.borderless).padding(.top, 8)
        }
    }

    private func update(_ change: (inout PlaybackAudioOutputPreference) -> Void) {
        var latest = PlaybackAudioOutputPreferenceStore.shared.snapshot
        change(&latest)
        PlaybackAudioOutputPreferenceStore.shared.set(latest)
    }
}
