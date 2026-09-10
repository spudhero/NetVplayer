import Foundation
import SwiftUI

struct PlayerPlaybackActivityPhase: Equatable {
    enum Kind: Equatable {
        case hidden
        case loading
        case buffering
    }

    var kind: Kind
    var title: String
    var message: String?

    static let hidden = PlayerPlaybackActivityPhase(kind: .hidden, title: "", message: nil)
}

enum PlayerPlaybackActivityPolicy {
    static let bufferingDelay: TimeInterval = 0
    static let blocksVideoGestures = false

    static func isActive(
        isSourceLoading: Bool,
        isMediaLoading: Bool,
        isBuffering: Bool
    ) -> Bool {
        isSourceLoading || isMediaLoading || isBuffering
    }

    static func vodPhase(
        isSourceLoading: Bool,
        sourceLoadingMessage: String,
        isMediaLoading: Bool,
        isBuffering: Bool,
        hasBlockingUI: Bool
    ) -> PlayerPlaybackActivityPhase {
        phase(
            isSourceLoading: isSourceLoading,
            sourceLoadingTitle: "正在加载视频",
            sourceLoadingMessage: sourceLoadingMessage,
            isMediaLoading: isMediaLoading,
            mediaLoadingTitle: "正在加载视频",
            mediaLoadingMessage: "正在等待画面开始播放。",
            isBuffering: isBuffering,
            hasBlockingUI: hasBlockingUI
        )
    }

    static func livePhase(
        isSourceLoading: Bool,
        sourceLoadingMessage: String,
        isMediaLoading: Bool,
        isBuffering: Bool,
        hasBlockingUI: Bool
    ) -> PlayerPlaybackActivityPhase {
        phase(
            isSourceLoading: isSourceLoading,
            sourceLoadingTitle: "正在连接直播",
            sourceLoadingMessage: sourceLoadingMessage,
            isMediaLoading: isMediaLoading,
            mediaLoadingTitle: "正在连接直播",
            mediaLoadingMessage: "线路已就绪，正在等待直播画面。",
            isBuffering: isBuffering,
            hasBlockingUI: hasBlockingUI
        )
    }

    static func presentationDelay(for kind: PlayerPlaybackActivityPhase.Kind) -> TimeInterval {
        kind == .buffering ? bufferingDelay : 0
    }

    static func speedText(bytesPerSecond: Int64?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        if bytesPerSecond >= 1_048_576 {
            return fixedDecimal(Double(bytesPerSecond) / 1_048_576) + " MB/s"
        }
        if bytesPerSecond >= 1_024 {
            return fixedDecimal(Double(bytesPerSecond) / 1_024) + " KB/s"
        }
        return "\(bytesPerSecond) B/s"
    }

    static func progressText(_ progress: Double?) -> String? {
        guard let progress, progress.isFinite, progress > 0 else { return nil }
        let percentage = Int((min(1, max(0, progress)) * 100).rounded())
        return "\(percentage)%"
    }

    static func bufferedAheadText(_ duration: Double) -> String? {
        guard duration.isFinite, duration > 0 else { return nil }
        if duration < 10 {
            return "已缓冲 \(fixedDecimal(duration)) 秒"
        }
        return "已缓冲 \(Int(duration.rounded())) 秒"
    }

    private static func phase(
        isSourceLoading: Bool,
        sourceLoadingTitle: String,
        sourceLoadingMessage: String,
        isMediaLoading: Bool,
        mediaLoadingTitle: String,
        mediaLoadingMessage: String,
        isBuffering: Bool,
        hasBlockingUI: Bool
    ) -> PlayerPlaybackActivityPhase {
        guard !hasBlockingUI else { return .hidden }
        if isSourceLoading {
            return PlayerPlaybackActivityPhase(
                kind: .loading,
                title: sourceLoadingTitle,
                message: normalizedMessage(sourceLoadingMessage)
            )
        }
        if isMediaLoading {
            return PlayerPlaybackActivityPhase(
                kind: .loading,
                title: mediaLoadingTitle,
                message: mediaLoadingMessage
            )
        }
        if isBuffering {
            return PlayerPlaybackActivityPhase(
                kind: .buffering,
                title: "正在缓冲",
                message: "网络速度较慢，正在补充播放缓存。"
            )
        }
        return .hidden
    }

    private static func normalizedMessage(_ message: String) -> String? {
        let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func fixedDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded(.toNearestOrAwayFromZero) / 10
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }
}

enum PlayerPlaybackActivityVisualPolicy {
    static let diameter: CGFloat = 196
    static let ringInset: CGFloat = 12
    static let ringDiameter: CGFloat = diameter - ringInset * 2
    static let ringLineWidth: CGFloat = 3
    static let contentWidth: CGFloat = 126
    static let indeterminateArcFraction: CGFloat = 0.24
    static let indeterminateRotationDuration: TimeInterval = 1.45
    static let materialOpacity = PlayerHUDVisualPolicy.hudGlassMaterialOpacity
    static let surfaceOpacity = PlayerHUDVisualPolicy.hudGlassSurfaceOpacity
    static let rimOpacity: CGFloat = 0.08
    static let innerRimOpacity: CGFloat = 0.025
    static let shadowOpacity: CGFloat = 0.24
    static let shadowRadius: CGFloat = 23
    static let shadowYOffset: CGFloat = 9
}

struct PlayerPlaybackActivityView: View {
    let phase: PlayerPlaybackActivityPhase
    let progress: Double?
    let speedBytesPerSecond: Int64?
    let bufferedAheadDuration: Double
    let showsImmediately: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        phase: PlayerPlaybackActivityPhase,
        progress: Double?,
        speedBytesPerSecond: Int64?,
        bufferedAheadDuration: Double,
        showsImmediately: Bool = false
    ) {
        self.phase = phase
        self.progress = progress
        self.speedBytesPerSecond = speedBytesPerSecond
        self.bufferedAheadDuration = bufferedAheadDuration
        self.showsImmediately = showsImmediately
    }

    var body: some View {
        Group {
            if phase.kind != .hidden {
                activityPanel
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(PlayerPlaybackActivityPolicy.blocksVideoGestures)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: phase.kind)
    }

    private var activityPanel: some View {
        ZStack {
            PlayerPlaybackActivityIndicator(
                progress: normalizedProgress,
                isStatic: reduceMotion || showsImmediately
            )

            VStack(spacing: 0) {
                Text(phase.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PlayerHUDPalette.foreground)
                    .lineLimit(1)

                if let progressValue = normalizedProgress {
                    Text(PlayerPlaybackActivityPolicy.progressText(progressValue) ?? "")
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(PlayerHUDPalette.foreground)
                        .padding(.top, 3)
                } else if reduceMotion || showsImmediately {
                    Image(systemName: "hourglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(PlayerHUDPalette.foreground.opacity(0.88))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        }
                        .padding(.top, 6)
                } else {
                    Circle()
                        .fill(PlayerHUDPalette.lavender)
                        .frame(width: 6, height: 6)
                        .shadow(color: PlayerHUDPalette.lavender.opacity(0.48), radius: 7)
                        .padding(.vertical, 12)
                }

                if metricTexts.isEmpty, let message = phase.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(PlayerHUDPalette.muted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.88)
                        .padding(.top, 4)
                } else if !metricTexts.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(metricTexts, id: \.self) { metric in
                            Text(metric)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(PlayerHUDPalette.muted)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(width: PlayerPlaybackActivityVisualPolicy.contentWidth)
        }
        .frame(
            width: PlayerPlaybackActivityVisualPolicy.diameter,
            height: PlayerPlaybackActivityVisualPolicy.diameter
        )
        .background {
            Circle()
                .fill(.ultraThinMaterial)
                .opacity(PlayerPlaybackActivityVisualPolicy.materialOpacity)
                .overlay {
                    Circle()
                        .fill(PlayerHUDPalette.surface.opacity(PlayerPlaybackActivityVisualPolicy.surfaceOpacity))
                }
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(PlayerPlaybackActivityVisualPolicy.rimOpacity), lineWidth: 1)
                }
                .overlay {
                    Circle()
                        .inset(by: 2)
                        .stroke(Color.white.opacity(PlayerPlaybackActivityVisualPolicy.innerRimOpacity), lineWidth: 1)
                }
        }
        .shadow(
            color: .black.opacity(PlayerPlaybackActivityVisualPolicy.shadowOpacity),
            radius: PlayerPlaybackActivityVisualPolicy.shadowRadius,
            y: PlayerPlaybackActivityVisualPolicy.shadowYOffset
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(phase.title))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var normalizedProgress: Double? {
        guard let progress, progress.isFinite, progress > 0 else { return nil }
        return min(1, max(0, progress))
    }

    private var metricTexts: [String] {
        [
            PlayerPlaybackActivityPolicy.speedText(bytesPerSecond: speedBytesPerSecond),
            PlayerPlaybackActivityPolicy.bufferedAheadText(bufferedAheadDuration),
        ].compactMap { $0 }
    }

    private var accessibilityValue: String {
        ([phase.message, PlayerPlaybackActivityPolicy.progressText(normalizedProgress)].compactMap { $0 } + metricTexts)
            .joined(separator: "，")
    }
}

private struct PlayerPlaybackActivityIndicator: View {
    let progress: Double?
    let isStatic: Bool

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    PlayerHUDPalette.foreground.opacity(0.13),
                    lineWidth: PlayerPlaybackActivityVisualPolicy.ringLineWidth
                )

            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        PlayerHUDPalette.accent,
                        style: StrokeStyle(
                            lineWidth: PlayerPlaybackActivityVisualPolicy.ringLineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: PlayerPlaybackActivityVisualPolicy.indeterminateArcFraction)
                    .stroke(
                        PlayerHUDPalette.lavender,
                        style: StrokeStyle(
                            lineWidth: PlayerPlaybackActivityVisualPolicy.ringLineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(isStatic ? -90 : rotation - 90))
                    .animation(
                        isStatic
                            ? nil
                            : .linear(duration: PlayerPlaybackActivityVisualPolicy.indeterminateRotationDuration)
                                .repeatForever(autoreverses: false),
                        value: rotation
                    )
            }
        }
        .frame(
            width: PlayerPlaybackActivityVisualPolicy.ringDiameter,
            height: PlayerPlaybackActivityVisualPolicy.ringDiameter
        )
        .onAppear {
            updateRotation()
        }
        .onChange(of: progress) { _, _ in
            updateRotation()
        }
        .onChange(of: isStatic) { _, _ in
            updateRotation()
        }
        .accessibilityHidden(true)
    }

    private func updateRotation() {
        rotation = progress == nil && !isStatic ? 360 : 0
    }
}
