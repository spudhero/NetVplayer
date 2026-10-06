import AppKit
import SwiftUI
import Models
import PlayerEngine

enum PlayerTimelineCoordinatePolicy {
    static func time(at x: CGFloat, width: CGFloat, duration: Double, thumbWidth: CGFloat = 0) -> Double? {
        guard x.isFinite, width.isFinite, thumbWidth.isFinite,
              width > max(0, thumbWidth), duration.isFinite, duration > 0,
              duration < Double(Int64.max) / 1_000 else { return nil }
        let inset = max(0, thumbWidth) / 2
        let ratio = min(1, max(0, Double((x - inset) / (width - inset * 2))))
        return duration * ratio
    }

    static func previewCenter(x: CGFloat, width: CGFloat, bubbleWidth: CGFloat) -> CGFloat {
        guard x.isFinite, width.isFinite, width > 0, bubbleWidth.isFinite else { return 0 }
        let inset = min(width, max(0, bubbleWidth)) / 2
        return min(width - inset, max(inset, x))
    }

    static func label(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) / 1_000 else { return "--:--" }
        let seconds = Int(seconds.rounded(.down))
        if seconds >= 3_600 {
            return String(seconds / 3_600) + String(format: ":%02d:%02d", seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct PlayerTimelinePreview: ViewModifier {
    let duration: Double
    let thumbWidth: CGFloat
    let mediaID: String
    let isEnabled: Bool
    var onReset: () -> Void = {}
    var visualRegressionProgress: Double? = nil
    var chapters: [PlayerChapter] = []
    var spec: PlaySpec? = nil
    var previewStore: PlayerChapterPreviewStore? = nil
    var fixtureURL: URL? = nil
    var isChapterPanelPresented = false
    var isDragging = false
    var compact = false
    var onChapterHover: (Int?) -> Void = { _ in }
    @State private var hoverX: CGFloat?

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = isEnabled ? point.x : nil
                case .ended: hoverX = nil; onChapterHover(nil)
                }
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    if isEnabled, !isChapterPanelPresented, let hoverX = hoverX ?? visualRegressionProgress.map({ CGFloat($0) * proxy.size.width }),
                       let seconds = PlayerTimelineCoordinatePolicy.time(at: hoverX, width: proxy.size.width,
                           duration: duration, thumbWidth: thumbWidth) {
                        let node = isDragging ? nil : PlayerChapterPresentationPolicy.hit(at: hoverX,
                            width: proxy.size.width, chapters: chapters, duration: duration, thumbWidth: thumbWidth)
                        let chapter = node ?? PlayerChapterPolicy.current(at: seconds, in: chapters)
                        if let chapter, let previewStore {
                            PlayerChapterPreviewCard(chapter: chapter, chapters: chapters, duration: duration,
                                seconds: seconds, isNode: node != nil, spec: spec, mediaID: mediaID,
                                previewStore: previewStore, fixtureURL: fixtureURL, compact: compact)
                                .fixedSize()
                                .position(x: PlayerTimelineCoordinatePolicy.previewCenter(x: hoverX,
                                    width: proxy.size.width, bubbleWidth: PlayerChapterVisualPolicy.previewWidth), y: -96)
                                .accessibilityHidden(true)
                                .onAppear { onChapterHover(node?.id) }
                                .onChange(of: node?.id) { _, id in onChapterHover(id) }
                        } else {
                            Text(PlayerTimelineCoordinatePolicy.label(seconds: seconds))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(width: 84, height: 28)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                                .position(x: PlayerTimelineCoordinatePolicy.previewCenter(x: hoverX,
                                    width: proxy.size.width, bubbleWidth: 84), y: -17)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .allowsHitTesting(false)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in reset() }
            }
            .onChange(of: mediaID) { _, _ in reset() }
            .onChange(of: isEnabled) { _, enabled in if !enabled { reset() } }
            .onChange(of: duration) { _, _ in reset() }
            .onChange(of: isChapterPanelPresented) { _, _ in reset() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in reset() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in reset() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in reset() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in reset() }
            .onDisappear { reset() }
    }

    private func reset() {
        hoverX = nil
        onChapterHover(nil)
        onReset()
    }
}
