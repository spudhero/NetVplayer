import SwiftUI
import Models
import PlayerEngine

struct ChapterButtonAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

enum PlayerChapterVisualPolicy {
    static let panelWidth: CGFloat = 394
    static let rowHeight: CGFloat = 76
    static let previewWidth: CGFloat = 212
    static let nodeHitRadius: CGFloat = 10
    static func listHeight(count: Int, compact: Bool = false) -> CGFloat {
        min(CGFloat(max(1, count)) * (rowHeight + 4), compact ? 96 : 286)
    }
    static func panelHeight(count: Int) -> CGFloat { listHeight(count: count) + 142 }
}

struct ChapterNavigationPanel: View {
    let chapters: [PlayerChapter]
    let position: Double
    let duration: Double
    let spec: PlaySpec?
    let mediaID: String
    let previewStore: PlayerChapterPreviewStore
    var fixtureURL: URL? = nil
    var compact = false
    let onSelect: (Int) -> Void
    let onClose: () -> Void
    private var current: PlayerChapter? { PlayerChapterPolicy.current(at: position, in: chapters) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(PlayerHUDPalette.lavender)
                Text(L10n.text("章节")).font(.system(size: 17, weight: .semibold))
                Text(L10n.text("{0} 个章节", [String(chapters.count)]))
                    .font(.system(size: 11)).foregroundStyle(PlayerHUDPalette.muted)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help(L10n.text("关闭"))
            }
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            ScrollViewReader { scroll in
                ThemedScrollView(theme: .player) {
                    LazyVStack(spacing: 4) {
                        ForEach(chapters) { chapter in
                            ChapterNavigationRow(chapter: chapter, chapters: chapters, duration: duration,
                                isCurrent: current?.id == chapter.id, spec: spec, mediaID: mediaID,
                                previewStore: previewStore, fixtureURL: fixtureURL) { onSelect(chapter.id) }
                                .id(chapter.id)
                        }
                    }
                }
                .frame(height: PlayerChapterVisualPolicy.listHeight(count: chapters.count, compact: compact))
                .onAppear { if let current { scroll.scrollTo(current.id, anchor: .center) } }
            }
            HStack(spacing: 8) {
                navigationButton(title: L10n.text("上一章节"), icon: "backward.end",
                    chapter: PlayerChapterPolicy.previous(at: position, in: chapters))
                navigationButton(title: L10n.text("下一章节"), icon: "forward.end",
                    chapter: PlayerChapterPolicy.next(at: position, in: chapters))
            }
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow").font(.system(size: 10))
                Text(L10n.text("悬停节点预览，点击跳转")).font(.system(size: 11))
            }.foregroundStyle(PlayerHUDPalette.muted)
        }
        .padding(16).frame(width: PlayerChapterVisualPolicy.panelWidth)
        .foregroundStyle(PlayerHUDPalette.foreground)
        .background(PlayerHUDPalette.background.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
        .background(PlayerGlassPanel(cornerRadius: 18, strokeOpacity: 0.30))
        .preferredColorScheme(.dark)
        .onExitCommand(perform: onClose)
    }

    private func navigationButton(title: String, icon: String, chapter: PlayerChapter?) -> some View {
        Button { if let chapter { onSelect(chapter.id) } } label: {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(chapter == nil).opacity(chapter == nil ? 0.35 : 1)
    }
}

private struct ChapterNavigationRow: View {
    let chapter: PlayerChapter
    let chapters: [PlayerChapter]
    let duration: Double
    let isCurrent: Bool
    let spec: PlaySpec?
    let mediaID: String
    let previewStore: PlayerChapterPreviewStore
    let fixtureURL: URL?
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 13) {
                PlayerChapterThumbnail(chapter: chapter, spec: spec, mediaID: mediaID,
                    store: previewStore, fixtureURL: fixtureURL).frame(width: 88, height: 50)
                    .overlay(alignment: .bottomLeading) {
                        Text(String(format: "%02d", PlayerChapterPresentationPolicy.number(of: chapter, in: chapters)))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 4)).padding(4)
                    }
                VStack(alignment: .leading, spacing: 5) {
                    Text(PlayerChapterPresentationPolicy.title(for: chapter, in: chapters))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(PlayerChapterPresentationPolicy.range(of: chapter, in: chapters, duration: duration))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(PlayerHUDPalette.muted)
                    if isCurrent {
                        Label(L10n.text("正在播放"), systemImage: "waveform")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(PlayerHUDPalette.lavender)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "play.fill")
                    .font(.system(size: isCurrent ? 15 : 10))
                    .foregroundStyle(PlayerHUDPalette.lavender)
                    .opacity(isCurrent || isHovered ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: PlayerChapterVisualPolicy.rowHeight, alignment: .leading)
            .background((isCurrent ? PlayerHUDPalette.lavender : .white).opacity(isCurrent ? 0.13 : (isHovered ? 0.07 : 0)),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(PlayerHUDPalette.lavender.opacity(isCurrent ? 0.28 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { isHovered = $0 }
        .accessibilityLabel(PlayerChapterPresentationPolicy.title(for: chapter, in: chapters)
            + ", " + PlayerChapterPresentationPolicy.range(of: chapter, in: chapters, duration: duration))
        .accessibilityValue(isCurrent ? L10n.text("正在播放") : "")
        .accessibilityHint(L10n.text("点击跳转"))
    }
}

struct CompactChapterControl: View {
    let chapters: [PlayerChapter]
    let position: Double
    let duration: Double
    let spec: PlaySpec?
    let mediaID: String
    let previewStore: PlayerChapterPreviewStore
    let onSelect: (Int) -> Void
    var onPresentationChange: (Bool) -> Void = { _ in }
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPresented ? PlayerHUDPalette.lavender : PlayerHUDPalette.foreground)
                .frame(width: 28, height: 28).background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
        }.buttonStyle(.plain).frame(width: 32, height: 32).help(L10n.text("章节"))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ChapterNavigationPanel(chapters: chapters, position: position, duration: duration,
                spec: spec, mediaID: mediaID, previewStore: previewStore, compact: true,
                onSelect: { onSelect($0); isPresented = false }, onClose: { isPresented = false })
                .presentationBackground(.clear)
        }
        .onChange(of: isPresented) { _, value in onPresentationChange(value) }
        .onChange(of: mediaID) { _, _ in isPresented = false }
        .onDisappear { onPresentationChange(false) }
    }
}

struct ChapterTimelineMarkers: View {
    let chapters: [PlayerChapter]
    let duration: Double
    var thumbWidth: CGFloat = 0
    var position: Double = 0
    var hoveredChapterID: Int? = nil
    var body: some View {
        GeometryReader { proxy in
            ForEach(chapters) { chapter in
                if let x = PlayerChapterPresentationPolicy.center(of: chapter, width: proxy.size.width,
                    duration: duration, thumbWidth: thumbWidth) {
                    let hovered = hoveredChapterID == chapter.id
                    Circle().fill(hovered ? PlayerHUDPalette.lavender :
                        (chapter.seconds <= position ? PlayerHUDPalette.accent : PlayerHUDPalette.foreground.opacity(0.7)))
                        .frame(width: hovered ? 6 : 5, height: hovered ? 6 : 5)
                        .overlay(Circle().stroke(PlayerHUDPalette.background.opacity(0.65), lineWidth: 1.5))
                        .overlay(Circle().stroke(PlayerHUDPalette.lavender.opacity(hovered ? 0.35 : 0), lineWidth: 3).padding(-3))
                        .position(x: x, y: proxy.size.height / 2)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct PlayerChapterPreviewCard: View {
    let chapter: PlayerChapter
    let chapters: [PlayerChapter]
    let duration: Double
    let seconds: Double
    let isNode: Bool
    let spec: PlaySpec?
    let mediaID: String
    let previewStore: PlayerChapterPreviewStore
    var fixtureURL: URL? = nil
    var compact = false
    private var frameSeconds: Double {
        isNode ? chapter.seconds
            : PlayerChapterPreviewPolicy.timelineSeconds(seconds, chapters: chapters, duration: duration)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PlayerChapterThumbnail(chapter: chapter, spec: spec, mediaID: mediaID, store: previewStore,
                fixtureURL: fixtureURL, previewSeconds: frameSeconds)
                .frame(height: compact ? 72 : 106)
                .overlay(alignment: .bottomTrailing) {
                    Text(PlayerTimelineCoordinatePolicy.label(seconds: frameSeconds))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5)).padding(5)
                }
            Text(PlayerChapterPresentationPolicy.title(for: chapter, in: chapters))
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Text(PlayerChapterPresentationPolicy.range(of: chapter, in: chapters, duration: duration))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(PlayerHUDPalette.muted)
                Spacer(minLength: 0)
                if isNode { Text(L10n.text("点击跳转")).font(.system(size: 10)).foregroundStyle(PlayerHUDPalette.lavender) }
            }
        }.padding(9).frame(width: PlayerChapterVisualPolicy.previewWidth)
        .foregroundStyle(PlayerHUDPalette.foreground)
        .background(PlayerHUDPalette.background.opacity(0.88), in: RoundedRectangle(cornerRadius: 13))
        .background(PlayerGlassPanel(cornerRadius: 13))
    }
}
