import SwiftUI

enum CompactPlayerKind: Equatable {
    case vod
    case live
}

enum CompactPlayerLayoutPolicy {
    static let regularThreshold = CGSize(width: 960, height: 640)
    static let minimumContentSize = CGSize(width: 427, height: 240)
    static let controlsFadeDuration = 0.14

    static func isCompact(contentSize: CGSize) -> Bool {
        contentSize.width < regularThreshold.width
            || contentSize.height < regularThreshold.height
    }

    static func normalizedProgress(position: Double, duration: Double) -> Double? {
        guard position.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(1, max(0, position / duration))
    }

    static func showsProgress(kind: CompactPlayerKind, duration: Double) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        switch kind {
        case .vod, .live:
            return true
        }
    }
}

struct CompactPlayerControls: View {
    let kind: CompactPlayerKind
    let isPlaying: Bool
    let isPlaybackEnabled: Bool
    let position: Double
    let duration: Double
    let isAlwaysOnTop: Bool
    let isVisible: Bool
    let onTogglePlayback: () -> Void
    let onSeek: (Double) -> Void
    let onToggleAlwaysOnTop: () -> Void
    let onRestoreWindow: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggedProgress: Double?

    private var normalizedProgress: Double? {
        guard CompactPlayerLayoutPolicy.showsProgress(kind: kind, duration: duration) else {
            return nil
        }
        return draggedProgress
            ?? CompactPlayerLayoutPolicy.normalizedProgress(position: position, duration: duration)
    }

    private var primaryAccent: Color {
        kind == .vod ? PlayerHUDPalette.lavender : PlayerHUDPalette.accent
    }

    private var secondaryAccent: Color {
        kind == .vod ? PlayerHUDPalette.accent : PlayerHUDPalette.lavender
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                compactButton(
                    systemImage: isAlwaysOnTop ? "pin.fill" : "pin",
                    help: isAlwaysOnTop ? "取消置顶" : "钉在最前",
                    isActive: isAlwaysOnTop,
                    action: onToggleAlwaysOnTop
                )
                compactButton(
                    systemImage: "macwindow",
                    help: "恢复普通窗口",
                    action: onRestoreWindow
                )
                compactButton(
                    systemImage: "xmark",
                    help: "关闭播放器",
                    role: .destructive,
                    action: onClose
                )
            }
            .padding(.top, 8)
            .padding(.horizontal, 8)

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button(action: onTogglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PlayerHUDPalette.foreground)
                        .frame(width: 36, height: 36)
                        .background(primaryAccent.opacity(0.24), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(primaryAccent.opacity(0.82), lineWidth: 1)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isPlaybackEnabled)
                .opacity(isPlaybackEnabled ? 1 : 0.45)
                .help(isPlaying ? "暂停" : "播放")
                .accessibilityLabel(isPlaying ? "暂停" : "播放")

                if let normalizedProgress {
                    compactProgressBar(progress: normalizedProgress)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(compactGlassPanel)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(
            reduceMotion ? nil : .easeOut(duration: CompactPlayerLayoutPolicy.controlsFadeDuration),
            value: isVisible
        )
        .accessibilityHidden(!isVisible)
    }

    private func compactButton(
        systemImage: String,
        help: String,
        isActive: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    role == .destructive
                        ? Color.white
                        : (isActive ? primaryAccent : PlayerHUDPalette.foreground)
                )
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(PlayerHUDVisualPolicy.hudGlassMaterialOpacity)
                        .overlay {
                            Circle()
                                .fill(
                                    role == .destructive
                                        ? Color.red.opacity(0.48)
                                        : PlayerHUDPalette.surface.opacity(
                                            PlayerHUDVisualPolicy.hudGlassSurfaceOpacity
                                        )
                                )
                        }
                }
                .overlay {
                    Circle()
                        .stroke(
                            isActive ? primaryAccent.opacity(0.78) : Color.white.opacity(0.16),
                            lineWidth: 1
                        )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func compactProgressBar(progress: Double) -> some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let clampedProgress = min(1, max(0, progress))
            let thumbOffset = min(max(0, width * clampedProgress - 5), max(0, width - 10))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.20))
                    .frame(height: 4)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [primaryAccent, secondaryAccent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * clampedProgress, height: 4)

                Circle()
                    .fill(PlayerHUDPalette.foreground)
                    .frame(width: 10, height: 10)
                    .shadow(color: primaryAccent.opacity(0.42), radius: 4)
                    .offset(x: thumbOffset)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        draggedProgress = min(1, max(0, value.location.x / width))
                    }
                    .onEnded { value in
                        let committedProgress = min(1, max(0, value.location.x / width))
                        draggedProgress = nil
                        onSeek(duration * committedProgress)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(Int((clampedProgress * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                let step = duration * 0.05
                switch direction {
                case .increment:
                    onSeek(min(duration, position + step))
                case .decrement:
                    onSeek(max(0, position - step))
                @unknown default:
                    break
                }
            }
        }
        .frame(minWidth: 48, maxWidth: .infinity, minHeight: 32, maxHeight: 32)
    }

    private var compactGlassPanel: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(PlayerHUDVisualPolicy.hudGlassMaterialOpacity)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        PlayerHUDPalette.surface.opacity(
                            PlayerHUDVisualPolicy.hudGlassSurfaceOpacity
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
    }
}

struct CompactPlayerStatusOverlay: View {
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        if isLoading || errorMessage != nil {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PlayerHUDPalette.accent)
                        .accessibilityLabel("正在加载播放内容")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .accessibilityLabel(errorMessage ?? "播放失败")
                }
            }
            .frame(width: 44, height: 44)
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .opacity(PlayerHUDVisualPolicy.hudGlassMaterialOpacity)
                    .overlay {
                        Circle()
                            .fill(
                                PlayerHUDPalette.surface.opacity(
                                    PlayerHUDVisualPolicy.hudGlassSurfaceOpacity
                                )
                            )
                    }
            }
            .overlay {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
            .help(errorMessage ?? "正在加载播放内容")
            .allowsHitTesting(false)
        }
    }
}
