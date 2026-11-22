import Models
import PlayerEngine
import SwiftUI

/// Keep the popover open across the real receiver → checking → PCM transition.
struct PlaybackVolumePopover: View {
    static let sliderPanelWidth: CGFloat = 52
    static let sliderPanelHeight: CGFloat = 146

    @ObservedObject var playerState: PlayerState
    let setVolume: (Float) -> Void
    var toggleMute: (() -> Void)? = nil
    let usePlayerVolume: () -> Void
    @State private var switchRequest: UUID?
    @State private var requestFailed = false
    @FocusState private var sliderFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if playerState.volumeControl == .player {
                if let toggleMute {
                    Label(L10n.text("音量"), systemImage: "speaker.wave.2")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                    volumeSlider.frame(height: 116)
                    Text(volumePercent)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity)
                    Button(action: toggleMute) {
                        Label(L10n.text(playerState.isMuted ? "取消静音" : "静音"),
                              systemImage: playerState.isMuted ? "speaker.wave.2" : "speaker.slash")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(PlayerControlPopoverRowStyle(isSelected: playerState.isMuted))
                    .foregroundStyle(PlayerHUDPalette.lavender)
                } else {
                    volumeSlider.frame(width: Self.sliderPanelWidth, height: Self.sliderPanelHeight)
                }
            } else {
                Label(L10n.text(playerState.volumeControl == .receiver ? "音箱调音" : "音量"),
                      systemImage: playerState.volumeControl == .receiver ? "hifispeaker" : "speaker.wave.2")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(playerState.volumeControl == .player ? (toggleMute == nil ? 0 : 12) : 18)
        .frame(width: playerState.volumeControl == .player ? (toggleMute == nil ? Self.sliderPanelWidth : 104) : 320)
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

    private var volumePercent: String { "\(Int((playerState.volume * 100).rounded()))%" }

    private var volumeSlider: some View {
        let volume = Binding(get: { playerState.volume }, set: setVolume)
        return GeometryReader { proxy in
            let thumbSize: CGFloat = 16
            let travel = proxy.size.height - thumbSize
            let fraction = CGFloat(volume.wrappedValue)
            Capsule()
                .fill(.white.opacity(0.24))
                .overlay(alignment: .bottom) {
                    if fraction > 0 {
                        Capsule().fill(PlayerHUDPalette.lavender).frame(height: travel * fraction)
                    }
                }
                .frame(width: 5, height: travel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    Circle()
                        .fill(.white.opacity(0.96))
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .offset(y: travel * (1 - fraction))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    sliderFocused = true
                    let fraction = 1 - (gesture.location.y - thumbSize / 2) / travel
                    setVolume(Float(min(1, max(0, fraction))))
                })
        }
        .frame(width: 36, height: 106)
        .focusable()
        .focusEffectDisabled()
        .focused($sliderFocused)
        .onMoveCommand { direction in
            switch direction {
            case .up, .right: setVolume(min(1, volume.wrappedValue + PlayerKeyboardShortcutPolicy.volumeStep))
            case .down, .left: setVolume(max(0, volume.wrappedValue - PlayerKeyboardShortcutPolicy.volumeStep))
            default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: volume, in: 0...1, step: PlayerKeyboardShortcutPolicy.volumeStep)
                .accessibilityLabel(L10n.text("播放器音量"))
                .accessibilityValue(volumePercent)
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
