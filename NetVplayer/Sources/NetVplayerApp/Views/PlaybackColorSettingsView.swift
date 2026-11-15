import Models
import PlayerEngine
import MPVShim
import Storage
import SwiftUI

struct PlaybackColorSettingsView: View {
    @ObservedObject var playerState: PlayerState
    var initiallyExpanded = false

    var body: some View {
        PlaybackSettingsDisclosure(
            L10n.text("色彩与视频输出"), summary: playerState.currentOutputSummary.video?.actualOutput ?? L10n.text("播放后显示实际输出"),
            systemImage: "paintpalette", initiallyExpanded: initiallyExpanded
        ) {
            PlaybackColorSettingsContent(playerState: playerState)
        }
    }
}

struct PlaybackColorSettingsContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var playerState: PlayerState
    var status: PlaybackFormatStatus?
    var searchRequest: UUID? = nil
    var searchAdvanced = false
    @State var advancedExpanded = false
    @State private var preference = PlaybackColorPreferenceStore.shared.snapshot
    @State private var hasInterruptedHDRChange = !SystemHDRController.shared.pendingRecovery.isEmpty

    private var actual: PlaybackFormatStatus? { playerState.currentOutputSummary.video ?? status }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PlaybackOutputActualSummary(status: actual)
            if hasInterruptedHDRChange {
                Button {
                    for change in SystemHDRController.shared.pendingRecovery {
                        SystemHDRController.shared.restoreInterruptedChange(displayUUID: change.displayUUID)
                    }
                } label: {
                    Label(L10n.text("恢复上次显示设置"), systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }.buttonStyle(.bordered)
            }
            PlaybackVideoOutputControl().settingsSearchAnchor(.video)
            VStack(spacing: 0) {
                DisclosureGroup(L10n.text("高级设置"), isExpanded: $advancedExpanded) {
                    advancedSettings.padding(.bottom, 8)
                }.disclosureGroupStyle(FullRowDisclosureGroupStyle(cardPadding: 4))
                Divider()
                PlaybackOutputTechnicalInfo(status: actual) {
                    VStack(alignment: .leading, spacing: 8) {
                        if playerState.playbackDiagnostics?.video.dolbyVision != nil {
                            Text(playerState.playbackDiagnostics?.video.dolbyVision?.systemPresentation?.currentFrameSubmitted == true
                                ? L10n.text("系统显示层已接收带逐帧杜比视界元数据的画面；电视接收格式需连接设备确认。")
                                : L10n.text("杜比视界片源会重建并映射为当前可用的 EDR HDR 或 SDR，不发送电视原生 Dolby Vision 信号。"))
                        }
                        if preference.systemDolbyVision {
                            Text(L10n.text("需 macOS 15 或更高版本及可用 HDR 输出。生成新的逐帧元数据交给系统；电视接收格式待设备确认，失败时返回常规映射。"))
                        }
                        Text(L10n.text("临时 HDR 不会关闭原先已开启的系统 HDR；播放期间手动关闭后，本次播放不再自动开启。"))
                    }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                DisclosureGroup(L10n.text("显示帮助")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            openWindow(id: AppWindowID.displayInspection)
                        } label: {
                            Label(L10n.text("显示测试图与指引"), systemImage: "display")
                        }.buttonStyle(.bordered)
                        Text(L10n.text("SDR 使用显示器色彩配置，默认 BT.2390、203 nit。上述映射设置仅用于 SDR；EDR 高光随当前可用余量调整，信号峰值不代表实测亮度。"))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 4).padding(.bottom, 8)
                }.disclosureGroupStyle(FullRowDisclosureGroupStyle(cardPadding: 4))
            }.font(.system(size: 12))
        }
        .onAppear { if searchAdvanced { advancedExpanded = true } }
        .onChange(of: searchRequest) { _, _ in if searchAdvanced { advancedExpanded = true } }
        .onReceive(NotificationCenter.default.publisher(for: PlaybackColorPreferenceStore.didChange)) { _ in
            preference = PlaybackColorPreferenceStore.shared.snapshot
        }
        .onReceive(NotificationCenter.default.publisher(for: .systemHDRStateDidChange)) { _ in
            hasInterruptedHDRChange = !SystemHDRController.shared.pendingRecovery.isEmpty
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            PlaybackOutputSettingRow(title: L10n.text("映射算法")) {
                Picker(L10n.text("映射算法"), selection: Binding(
                    get: { preference.toneMapping?.rawValue ?? "auto" },
                    set: { value in update { $0.toneMapping = PlaybackToneMapping(rawValue: value) } }
                )) {
                    Text(L10n.text("自动")).tag("auto")
                    Text("BT.2390").tag(PlaybackToneMapping.bt2390.rawValue)
                    Text("Mobius").tag(PlaybackToneMapping.mobius.rawValue)
                    Text("Reinhard").tag(PlaybackToneMapping.reinhard.rawValue)
                }
            }.settingsSearchAnchor(.toneMapping)
            PlaybackOutputSettingRow(title: L10n.text("SDR 参考峰值")) {
                Picker(L10n.text("SDR 参考峰值"), selection: Binding(
                    get: { preference.peakNits ?? 0 }, set: { value in update { $0.peakNits = value == 0 ? nil : value } }
                )) {
                    Text(L10n.text("自动")).tag(0)
                    ForEach([100, 150, 203], id: \.self) { peak in Text("\(peak) nit").tag(peak) }
                }
            }.settingsSearchAnchor(.sdrPeak)
            Text(L10n.text("映射算法和参考峰值仅影响 SDR 输出。"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PlaybackSystemDolbyVisionSetting(isOn: Binding(
                get: { preference.systemDolbyVision },
                set: { value in update { $0.systemDolbyVision = value } }
            ), sourceMetadata: Binding(
                get: { preference.sourceDolbyVisionMetadata },
                set: { value in update { $0.sourceDolbyVisionMetadata = value } }
            ), available: NVDolbyVisionSurface.available)
                .padding(.top, 10).settingsSearchAnchor(.dolbyVision)
            Button {
                PlaybackColorPreferenceStore.shared.reset()
            } label: {
                Label(L10n.text("恢复色彩默认"), systemImage: "arrow.counterclockwise")
            }.buttonStyle(.borderless).padding(.top, 8)
        }
    }

    private func update(_ change: (inout PlaybackColorPreference) -> Void) {
        var latest = PlaybackColorPreferenceStore.shared.snapshot
        change(&latest)
        PlaybackColorPreferenceStore.shared.set(latest)
    }
}
