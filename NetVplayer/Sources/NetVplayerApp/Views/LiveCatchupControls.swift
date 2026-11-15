import SwiftUI
import Models

struct LiveCatchupControls: View {
    let context: LiveCatchupContext
    let phase: LiveCatchupPhase
    let position: Double
    let canSeek: Bool
    let message: String
    var compact = false
    let onSeek: (Double) -> Void
    let onRetry: () -> Void
    let onReplay: () -> Void
    let onReturnToLive: () -> Void
    @State private var draggedPosition: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(L10n.text(phase == .failed ? "回放未完成" : phase == .ended ? "回放结束" : "节目回放"),
                          systemImage: phase == .failed ? "exclamationmark.circle" : "arrow.counterclockwise")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(phase == .failed ? PlayerHUDPalette.accent : PlayerHUDPalette.lavender)
                    Text(L10n.text("回放：{0}", [context.programme.title]))
                        .font(compact ? .caption.bold() : .headline).lineLimit(1)
                    if !compact {
                        Text("\(context.channelName)  ·  \(context.programme.start.formatted(date: .abbreviated, time: .shortened))–\(context.programme.end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if !compact { replayAction }
                returnToLive
            }
            HStack(spacing: 8) {
                Text(Self.clock(draggedPosition ?? position)).monospacedDigit()
                Slider(value: Binding(get: { draggedPosition ?? position }, set: { draggedPosition = $0 }),
                       in: 0...max(1, context.duration), onEditingChanged: { editing in
                    if !editing, let target = draggedPosition {
                        draggedPosition = nil
                        onSeek(target)
                    }
                })
                .disabled(!canSeek)
                .accessibilityLabel(L10n.text("节目回放进度"))
                Text(Self.clock(context.duration)).monospacedDigit()
            }.font(.caption)
            HStack(alignment: .top, spacing: 8) {
                Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if compact { Spacer(minLength: 4); replayAction }
            }
        }
        .padding(compact ? 10 : 14)
        .foregroundStyle(PlayerHUDPalette.foreground)
        .tint(PlayerHUDPalette.accent)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .background(PlayerHUDPalette.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
        .onChange(of: context.requestID) { _, _ in draggedPosition = nil }
    }

    private var returnToLive: some View {
        Button(action: onReturnToLive) {
            Label(L10n.text("返回直播"), systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.medium)).padding(.vertical, 4)
        }.buttonStyle(.borderedProminent).tint(PlayerHUDPalette.lavender)
            .accessibilityIdentifier("catchup-return-live")
    }

    @ViewBuilder private var replayAction: some View {
        if phase == .failed {
            Button(L10n.text("重试回放"), action: onRetry).buttonStyle(.bordered).controlSize(.small)
        } else if phase != .loading {
            Button(L10n.text("重播"), action: onReplay).buttonStyle(.borderless).controlSize(.small)
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, min(seconds, 31_536_000))) : 0
        return value >= 3_600 ? String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
