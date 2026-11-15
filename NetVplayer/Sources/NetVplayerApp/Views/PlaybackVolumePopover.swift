import Models
import PlayerEngine
import SwiftUI

/// Keep the popover open across the real receiver → checking → PCM transition.
struct PlaybackVolumePopover: View {
    @ObservedObject var playerState: PlayerState
    let setVolume: (Float) -> Void
    let toggleMute: () -> Void
    let usePlayerVolume: () -> Void
    @State private var switchRequest: UUID?
    @State private var requestFailed = false
    @FocusState private var sliderFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text(playerState.volumeControl == .receiver ? "音箱调音" : "音量"),
                  systemImage: playerState.volumeControl == .receiver ? "hifispeaker" : "speaker.wave.2")
                .font(.system(size: 14, weight: .semibold))
            if playerState.volumeControl == .player {
                VStack(spacing: 8) {
                    Slider(value: Binding(get: { playerState.volume }, set: { setVolume($0) }), in: 0...1)
                        .tint(PlayerHUDPalette.lavender)
                        .frame(width: 106, height: 44)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 44, height: 120)
                        .accessibilityLabel(L10n.text("播放器音量"))
                        .accessibilityValue("\(Int((playerState.volume * 100).rounded()))%")
                        .focused($sliderFocused)
                    Text("\(Int((playerState.volume * 100).rounded()))%")
                        .monospacedDigit().frame(width: 46)
                }
                .frame(maxWidth: .infinity)
                Button(action: toggleMute) {
                    Label(L10n.text(playerState.isMuted ? "取消静音" : "静音"),
                          systemImage: playerState.isMuted ? "speaker.wave.2" : "speaker.slash")
                }
                .buttonStyle(.borderless).tint(PlayerHUDPalette.lavender)
            } else {
                Text(L10n.text(playerState.volumeControl == .receiver
                    ? "原码直通时，请用电视或音箱调节音量。" : "正在确认音频输出，确认后可调节音量。"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if switchRequest != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("正在切换为 PCM…"))
                    }.frame(minHeight: 36)
                } else if playerState.volumeControl == .receiver || requestFailed {
                    Button {
                        requestFailed = false
                        switchRequest = UUID()
                        usePlayerVolume()
                    } label: {
                        Text(L10n.text(requestFailed ? "重试播放器调音" : "使用播放器调音"))
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent).tint(PlayerHUDPalette.lavender)
                } else {
                    ProgressView().controlSize(.small).frame(minHeight: 36)
                }
                if requestFailed {
                    Text(L10n.text("尚未确认 PCM 输出，请检查音频设备后重试。"))
                        .foregroundStyle(.secondary)
                }
                if playerState.volumeControl == .receiver || switchRequest != nil {
                    Text(L10n.text("将关闭音频直通，PCM 多声道按设备能力输出。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if hasObjectAudio {
                        Text(L10n.text("切换后不再直通 Atmos 或 DTS:X 对象。"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .padding(18)
        .frame(width: playerState.volumeControl == .player ? 104 : 320)
        .preferredColorScheme(.dark)
        .onAppear { sliderFocused = playerState.volumeControl == .player }
        .onChange(of: playerState.volumeControl) { _, control in
            if control == .player {
                switchRequest = nil
                requestFailed = false
                sliderFocused = true
            }
        }
        .task(id: switchRequest) {
            guard let request = switchRequest else { return }
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard switchRequest == request, playerState.volumeControl != .player else { return }
            switchRequest = nil
            requestFailed = true
        }
    }

    private var hasObjectAudio: Bool {
        let audio = playerState.playbackDiagnostics?.audio
        return switch audio?.compressedAudio?.sourceFormat {
        case .eac3JOCReported, .eac3JOCParsed, .trueHDAtmosReported: true
        default: ["DTS-HD MA + DTS:X", "DTS-HD MA + DTS:X IMAX"].contains(audio?.profile ?? "")
        }
    }
}
