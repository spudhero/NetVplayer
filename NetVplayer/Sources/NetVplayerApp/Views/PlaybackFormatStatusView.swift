import SwiftUI
import Models
import PlayerEngine

enum PlaybackFormatPalette {
    static let active = Color(red: 232.0 / 255, green: 198.0 / 255, blue: 106.0 / 255)
}

// Preserve verified Dolby Vision processing alongside the actual HDR/SDR
// presentation. Source metadata alone must not activate the Dolby label.
extension PlaybackFormatStatus {
    private var hasActiveDolbyVisionMapping: Bool {
        kind == .video && format == "Dolby Vision" && formatIsActive && state == .enabled
    }

    private var hasActiveDynamicMapping: Bool {
        kind == .video && ["Dolby Vision", "HDR Vivid"].contains(format) && formatIsActive && state == .enabled
    }

    var compactTitle: String {
        if state == .preparing { return L10n.text(kind == .video ? "画面" : "音频") }
        if hasActiveDynamicMapping { return format }
        if kind == .video { return state == .blocked ? L10n.text("画面") : (presentedHDR ? "HDR" : "SDR") }
        if state == .standard || state == .pcm {
            let layout = [2: "2.0", 6: "5.1", 7: "6.1", 8: "7.1"][outputChannelCount ?? 0]
            return layout.map { "PCM " + $0 } ?? "PCM"
        }
        if state == .system { return L10n.text("系统音频") }
        if format == "DTS-HD MA" { return "DTS-HD" }
        return format
    }

    var compactState: String {
        if state == .preparing { return L10n.text("确认中") }
        if state == .blocked { return L10n.text("不可用") }
        if hasActiveDynamicMapping { return L10n.text(presentedHDR ? "HDR 映射" : "SDR 映射") }
        if kind == .video {
            return presentedHDR ? "EDR" : L10n.text(state == .standard ? "标准" : "映射")
        }
        switch state {
        case .encoded: return L10n.text("直通")
        case .standard, .pcm: return L10n.text("播放器调音")
        default: return state.title
        }
    }

    var compactIsActive: Bool { kind == .video ? (hasActiveDynamicMapping || presentedHDR) : outputIsActive }

    var dolbyLogoFormat: DolbyMediaFormat? {
        if hasActiveDolbyVisionMapping { return .vision }
        if kind == .audio, format == "Dolby Atmos", outputIsActive { return .atmos }
        return nil
    }

    var accessibleOutput: String {
        hasActiveDynamicMapping ? "\(format) · \(actualOutput)" : actualOutput
    }
}

struct PlaybackFormatStatusBar: View {
    let summary: PlaybackFormatSummary
    @ObservedObject var playerState: PlayerState
    @Binding var selection: PlaybackFormatStatus.Kind?
    @State private var hoveredKind: PlaybackFormatStatus.Kind?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(summary.items) { status in
                Button {
                    selection = selection == status.kind ? nil : status.kind
                } label: {
                    HStack(spacing: 7) {
                        if let format = status.dolbyLogoFormat {
                            DolbyFormatLogo(format: format, height: 13)
                        } else {
                            Text(status.compactTitle).font(.system(size: 12, weight: .semibold))
                        }
                        Text(status.compactState).font(.system(size: 11))
                            .foregroundStyle(status.compactIsActive ? PlaybackFormatPalette.active.opacity(0.85) : .white.opacity(0.65))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .foregroundStyle(status.compactIsActive ? PlaybackFormatPalette.active : .white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.black.opacity(hoveredKind == status.kind ? 0.78 : 0.64), in: Capsule())
                    .overlay { Capsule().strokeBorder(status.compactIsActive
                        ? PlaybackFormatPalette.active.opacity(0.36) : .white.opacity(0.16)) }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredKind = $0 ? status.kind : nil }
                .accessibilityLabel(L10n.text(status.kind == .video ? "当前实际画面：{0}" : "当前实际声音：{0}", [status.accessibleOutput]))
                .help(L10n.text("查看当前实际输出"))
                .popover(isPresented: Binding(get: { selection == status.kind }, set: { if !$0 { selection = nil } }), arrowEdge: .bottom) {
                    PlaybackFormatDetailsView(status: status, playerState: playerState) { selection = nil }
                        .environment(\.appThemePalette, AppThemeCatalog.palette(for: .legacyDeepSpace))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("当前播放格式"))
    }
}

private struct PlaybackOutputContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 280
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct PlaybackFormatDetailsView: View {
    let status: PlaybackFormatStatus
    @ObservedObject var playerState: PlayerState
    let onClose: () -> Void
    @State private var contentHeight: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text(status.kind == .video ? "当前画面" : "当前声音"))
                    .font(.system(size: 13, weight: .medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L10n.text("关闭"))
                .accessibilityLabel(L10n.text("关闭格式详情"))
                .keyboardShortcut(.cancelAction)
            }.padding(.leading, 18).padding(.trailing, 5).frame(height: 54)
            Divider()
            ScrollView {
                Group {
                    if status.kind == .audio {
                        PlaybackAudioOutputSettingsContent(playerState: playerState, status: status)
                    } else {
                        PlaybackColorSettingsContent(playerState: playerState, status: status)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { GeometryReader { proxy in
                    Color.clear.preference(key: PlaybackOutputContentHeightKey.self, value: proxy.size.height)
                } }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(440, contentHeight))
        }
        .onPreferenceChange(PlaybackOutputContentHeightKey.self) { contentHeight = $0 }
        .frame(width: 360)
        .preferredColorScheme(.dark)
    }
}

struct PlaybackFormatNotice: View {
    let summary: PlaybackFormatSummary
    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isVisible {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("当前播放格式")).font(.caption).foregroundStyle(.white.opacity(0.65))
                    ForEach(summary.items) { status in
                        HStack(spacing: 8) {
                            Image(systemName: status.state.symbol)
                                .foregroundStyle(status.compactIsActive ? PlaybackFormatPalette.active : .white.opacity(0.75))
                            if let format = status.dolbyLogoFormat {
                                DolbyFormatLogo(format: format, height: 14)
                            } else {
                                Text(status.compactTitle).fontWeight(.semibold)
                                    .foregroundStyle(status.compactIsActive ? PlaybackFormatPalette.active : .white.opacity(0.9))
                            }
                            Spacer(minLength: 12)
                            Text(status.compactState)
                                .foregroundStyle(status.compactIsActive ? PlaybackFormatPalette.active : .white.opacity(0.75))
                        }
                    }
                }
                .font(.system(size: 12))
                .padding(16)
                .frame(width: 285)
                .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.16)) }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isVisible)
        .task(id: summary.noticeIdentity) {
            isVisible = false
            guard summary.noticeIdentity != nil else { return }
            isVisible = true
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            isVisible = false
        }
        .allowsHitTesting(false)
    }
}
