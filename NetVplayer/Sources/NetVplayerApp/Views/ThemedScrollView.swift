// NetVplayerApp/Views/ThemedScrollView.swift
// Theme-aware scroll indicators that never cover app content.

import AppKit
import SwiftUI
import WebKit

enum AppScrollbarTheme: Equatable {
    case standard
    case subtle
    case live
    case player

    func colorSet(for palette: AppThemePalette) -> AppScrollbarColorSet {
        let browserHex = palette.primaryAccentHex

        switch self {
        case .standard:
            return AppScrollbarColorSet(
                thumbHex: browserHex,
                trackHex: browserHex,
                strokeHex: palette.foregroundHex,
                glowHex: browserHex,
                trackOpacity: 0.16,
                idleOpacity: 0.90,
                hoverOpacity: 0.96,
                activeOpacity: 1,
                webTrackOpacity: 0.14,
                webIdleOpacity: 0.78,
                webHoverOpacity: 0.92,
                webActiveOpacity: 1,
                strokeOpacity: 0.13,
                glowOpacity: 0.20
            )
        case .subtle:
            return AppScrollbarColorSet(
                thumbHex: browserHex,
                trackHex: browserHex,
                strokeHex: palette.foregroundHex,
                glowHex: browserHex,
                trackOpacity: 0.07,
                idleOpacity: 0.56,
                hoverOpacity: 0.72,
                activeOpacity: 0.86,
                webTrackOpacity: 0.07,
                webIdleOpacity: 0.56,
                webHoverOpacity: 0.72,
                webActiveOpacity: 0.86,
                strokeOpacity: 0,
                glowOpacity: 0
            )
        case .live:
            return .fixed(hex: 0x40D6C7)
        case .player:
            return .fixed(hex: 0xAD96E8)
        }
    }

    fileprivate var gutterWidth: CGFloat {
        self == .subtle ? 10 : AppScrollbarMetrics.gutterWidth
    }

    fileprivate var trackWidth: CGFloat {
        self == .subtle ? 1.5 : 4
    }

    fileprivate var thumbWidth: CGFloat {
        self == .subtle ? 4 : 8
    }

}

struct AppScrollbarColorSet: Equatable {
    let thumbHex: UInt32
    let trackHex: UInt32
    let strokeHex: UInt32
    let glowHex: UInt32
    let trackOpacity: Double
    let idleOpacity: Double
    let hoverOpacity: Double
    let activeOpacity: Double
    let webTrackOpacity: Double
    let webIdleOpacity: Double
    let webHoverOpacity: Double
    let webActiveOpacity: Double
    let strokeOpacity: Double
    let glowOpacity: Double

    static func fixed(hex: UInt32) -> AppScrollbarColorSet {
        AppScrollbarColorSet(
            thumbHex: hex,
            trackHex: hex,
            strokeHex: AppThemePalette.fixedDarkForegroundHex,
            glowHex: hex,
            trackOpacity: 0.16,
            idleOpacity: 0.90,
            hoverOpacity: 0.96,
            activeOpacity: 1,
            webTrackOpacity: 0.14,
            webIdleOpacity: 0.78,
            webHoverOpacity: 0.92,
            webActiveOpacity: 1,
            strokeOpacity: 0.13,
            glowOpacity: 0.20
        )
    }

    func cssColor(hex: UInt32, opacity: Double) -> String {
        let red = (hex >> 16) & 0xFF
        let green = (hex >> 8) & 0xFF
        let blue = hex & 0xFF
        return "rgb(\(red) \(green) \(blue) / \(Int((opacity * 100).rounded()))%)"
    }
}

enum AppScrollbarMetrics {
    static let gutterWidth: CGFloat = 16
}

struct ThemedScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let theme: AppScrollbarTheme
    private let content: Content

    init(
        _ axes: Axis.Set = .vertical,
        theme: AppScrollbarTheme = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.axes = axes
        self.theme = theme
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if axes == .vertical {
            if #available(macOS 15.0, *) {
                GeometryTrackedScrollView(theme: theme, content: content)
            } else {
                LegacyTrackedScrollView(theme: theme, content: content)
            }
        } else {
            ScrollView(axes, showsIndicators: false) {
                content
            }
        }
    }
}

@available(macOS 15.0, *)
private struct GeometryTrackedScrollView<Content: View>: View {
    let theme: AppScrollbarTheme
    let content: Content

    @State private var scrollPosition = ScrollPosition()
    @State private var metrics = AppScrollMetrics.zero

    var body: some View {
        GeometryReader { viewport in
            HStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .background(alignment: .topLeading) {
                            NativeScrollerHidingProbe()
                                .frame(width: 1, height: 1)
                        }
                }
                .scrollIndicators(.hidden)
                .background {
                    NativeScrollerHidingProbe()
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: AppScrollMetrics.self) { geometry in
                    AppScrollMetrics(geometry: geometry)
                } action: { _, newMetrics in
                    metrics = newMetrics
                }
                .frame(width: max(0, viewport.size.width - theme.gutterWidth))

                ThemedScrollbar(theme: theme, metrics: metrics) { targetOffset in
                    scrollPosition.scrollTo(y: targetOffset)
                }
                .frame(width: theme.gutterWidth)
            }
        }
    }

}

private struct LegacyTrackedScrollView<Content: View>: View {
    let theme: AppScrollbarTheme
    let content: Content

    @State private var coordinateSpaceName = UUID()
    @State private var measurement = LegacyScrollMeasurement.zero

    var body: some View {
        GeometryReader { viewport in
            HStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .background {
                            GeometryReader { contentGeometry in
                                Color.clear.preference(
                                    key: LegacyScrollMeasurementKey.self,
                                    value: LegacyScrollMeasurement(
                                        minY: contentGeometry.frame(in: .named(coordinateSpaceName)).minY,
                                        contentHeight: contentGeometry.size.height
                                    )
                                )
                            }
                        }
                        .background(alignment: .topLeading) {
                            NativeScrollerHidingProbe()
                                .frame(width: 1, height: 1)
                        }
                }
                .background {
                    NativeScrollerHidingProbe()
                }
                .coordinateSpace(name: coordinateSpaceName)
                .onPreferenceChange(LegacyScrollMeasurementKey.self) { value in
                    measurement = value
                }
                .frame(width: max(0, viewport.size.width - theme.gutterWidth))

                ThemedScrollbar(
                    theme: theme,
                    metrics: AppScrollMetrics(
                        offsetY: max(0, -measurement.minY),
                        contentHeight: measurement.contentHeight,
                        containerHeight: viewport.size.height
                    ),
                    onScroll: nil
                )
                .frame(width: theme.gutterWidth)
            }
        }
    }
}

private struct AppScrollMetrics: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat

    static let zero = AppScrollMetrics(offsetY: 0, contentHeight: 0, containerHeight: 0)

    var maximumOffset: CGFloat {
        max(0, contentHeight - containerHeight)
    }

    var isScrollable: Bool {
        maximumOffset > 1
    }

    @available(macOS 15.0, *)
    init(geometry: ScrollGeometry) {
        let verticalInsets = geometry.contentInsets.top + geometry.contentInsets.bottom
        offsetY = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        contentHeight = geometry.contentSize.height + verticalInsets
        containerHeight = geometry.containerSize.height
    }

    init(offsetY: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat) {
        self.offsetY = offsetY
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
    }
}

private struct ThemedScrollbar: View {
    @Environment(\.appThemePalette) private var palette
    let theme: AppScrollbarTheme
    let metrics: AppScrollMetrics
    let onScroll: ((CGFloat) -> Void)?

    @State private var dragGrabOffset: CGFloat?
    @State private var isHovered = false

    var body: some View {
        GeometryReader { geometry in
            let layout = ScrollbarLayout(metrics: metrics, availableHeight: geometry.size.height)
            let colors = theme.colorSet(for: palette)
            let thumbOpacity = dragGrabOffset != nil
                ? colors.activeOpacity
                : (isHovered ? colors.hoverOpacity : colors.idleOpacity)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color(appHex: colors.trackHex).opacity(colors.trackOpacity))
                    .frame(width: theme.trackWidth, height: layout.trackHeight)
                    .offset(y: layout.verticalInset)

                Capsule()
                    .fill(Color(appHex: colors.thumbHex).opacity(thumbOpacity))
                    .frame(width: theme.thumbWidth, height: layout.thumbHeight)
                    .overlay {
                        Capsule()
                            .stroke(
                                Color(appHex: colors.strokeHex).opacity(colors.strokeOpacity),
                                lineWidth: colors.strokeOpacity == 0 ? 0 : 0.5
                            )
                    }
                    .shadow(
                        color: Color(appHex: colors.glowHex).opacity(colors.glowOpacity),
                        radius: colors.glowOpacity == 0 ? 0 : 2
                    )
                    .offset(y: layout.thumbOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(layout: layout))
            .opacity(metrics.isScrollable ? 1 : 0)
            .allowsHitTesting(metrics.isScrollable && onScroll != nil)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.10), value: dragGrabOffset != nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("滚动条")
            .accessibilityValue("\(Int(layout.progress * 100))%")
        }
    }

    private func dragGesture(layout: ScrollbarLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard let onScroll, layout.travelDistance > 0 else { return }

                if dragGrabOffset == nil {
                    let positionInsideThumb = value.startLocation.y - layout.thumbOffset
                    dragGrabOffset = (0...layout.thumbHeight).contains(positionInsideThumb)
                        ? positionInsideThumb
                        : layout.thumbHeight / 2
                }

                let targetThumbOffset = value.location.y - (dragGrabOffset ?? layout.thumbHeight / 2)
                let trackRelativeOffset = targetThumbOffset - layout.verticalInset
                let progress = min(max(trackRelativeOffset / layout.travelDistance, 0), 1)
                onScroll(progress * metrics.maximumOffset)
            }
            .onEnded { _ in
                dragGrabOffset = nil
            }
    }
}

private struct ScrollbarLayout {
    let verticalInset: CGFloat = 6
    let trackHeight: CGFloat
    let thumbHeight: CGFloat
    let travelDistance: CGFloat
    let progress: CGFloat
    let thumbOffset: CGFloat

    init(metrics: AppScrollMetrics, availableHeight: CGFloat) {
        trackHeight = max(0, availableHeight - verticalInset * 2)

        let visibleRatio = metrics.contentHeight > 0
            ? min(max(metrics.containerHeight / metrics.contentHeight, 0), 1)
            : 1
        thumbHeight = min(trackHeight, max(44, trackHeight * visibleRatio))
        travelDistance = max(0, trackHeight - thumbHeight)
        progress = metrics.maximumOffset > 0
            ? min(max(metrics.offsetY / metrics.maximumOffset, 0), 1)
            : 0
        thumbOffset = verticalInset + travelDistance * progress
    }
}

private struct LegacyScrollMeasurement: Equatable {
    let minY: CGFloat
    let contentHeight: CGFloat

    static let zero = LegacyScrollMeasurement(minY: 0, contentHeight: 0)
}

private struct LegacyScrollMeasurementKey: PreferenceKey {
    static let defaultValue = LegacyScrollMeasurement.zero

    static func reduce(value: inout LegacyScrollMeasurement, nextValue: () -> LegacyScrollMeasurement) {
        value = nextValue()
    }
}

private struct NativeScrollerHidingProbe: NSViewRepresentable {
    func makeNSView(context _: Context) -> NativeScrollerHidingProbeView {
        NativeScrollerHidingProbeView()
    }

    func updateNSView(_ nsView: NativeScrollerHidingProbeView, context _: Context) {
        nsView.hideEnclosingNativeScroller()
    }
}

final class NativeScrollerHidingProbeView: NSView {
    private var isUpdateScheduled = false
    private var isHidingScroller = false
    private weak var monitoredScrollView: NSScrollView?
    private weak var monitoredScroller: NSScroller?
    private var verticalScrollerEnabledObservation: NSKeyValueObservation?
    private var verticalScrollerObservation: NSKeyValueObservation?
    private var scrollerVisibilityObservation: NSKeyValueObservation?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil else {
            stopMonitoringScroller()
            return
        }
        hideEnclosingNativeScroller()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            stopMonitoringScroller()
            return
        }
        hideEnclosingNativeScroller()
    }

    override func layout() {
        super.layout()
        hideEnclosingNativeScroller()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func hideEnclosingNativeScroller() {
        hideEnclosingNativeScrollerNow()

        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isUpdateScheduled = false
            self.hideEnclosingNativeScrollerNow()
        }
    }

    private func hideEnclosingNativeScrollerNow() {
        if let enclosingScrollView = firstScrollViewAncestor() {
            hideScroller(in: enclosingScrollView)
            return
        }

        guard let contentView = window?.contentView else { return }
        let probePoint = convert(
            NSPoint(x: bounds.midX, y: bounds.midY),
            to: nil
        )
        let candidates = descendantScrollViews(in: contentView).filter { scrollView in
            scrollView.convert(scrollView.bounds, to: nil)
                .insetBy(dx: -2, dy: -2)
                .contains(probePoint)
        }
        guard let nearest = candidates.min(by: { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }) else { return }

        hideScroller(in: nearest)
    }

    private func hideScroller(in scrollView: NSScrollView) {
        monitorScroller(in: scrollView)

        guard !isHidingScroller else { return }
        isHidingScroller = true
        defer { isHidingScroller = false }

        if scrollView.hasVerticalScroller {
            scrollView.hasVerticalScroller = false
        }
        monitorVisibility(of: scrollView.verticalScroller, in: scrollView)
        if let scroller = scrollView.verticalScroller, !scroller.isHidden {
            scroller.isHidden = true
        }
    }

    private func monitorScroller(in scrollView: NSScrollView) {
        guard monitoredScrollView !== scrollView else {
            monitorVisibility(of: scrollView.verticalScroller, in: scrollView)
            return
        }

        stopMonitoringScroller()
        monitoredScrollView = scrollView
        verticalScrollerEnabledObservation = scrollView.observe(
            \.hasVerticalScroller,
            options: [.new]
        ) { [weak self] scrollView, change in
            guard change.newValue == true else { return }
            MainActor.assumeIsolated {
                self?.hideScroller(in: scrollView)
            }
        }
        verticalScrollerObservation = scrollView.observe(
            \.verticalScroller,
            options: [.new]
        ) { [weak self] scrollView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.monitorVisibility(of: scrollView.verticalScroller, in: scrollView)
                self.hideScroller(in: scrollView)
            }
        }
        monitorVisibility(of: scrollView.verticalScroller, in: scrollView)
    }

    private func monitorVisibility(of scroller: NSScroller?, in scrollView: NSScrollView) {
        guard monitoredScroller !== scroller else { return }

        scrollerVisibilityObservation = nil
        monitoredScroller = scroller
        scrollerVisibilityObservation = scroller?.observe(
            \.isHidden,
            options: [.new]
        ) { [weak self, weak scrollView] _, change in
            guard change.newValue == false, let scrollView else { return }
            MainActor.assumeIsolated {
                self?.hideScroller(in: scrollView)
            }
        }
    }

    private func stopMonitoringScroller() {
        verticalScrollerEnabledObservation = nil
        verticalScrollerObservation = nil
        scrollerVisibilityObservation = nil
        monitoredScrollView = nil
        monitoredScroller = nil
    }

    private func firstScrollViewAncestor() -> NSScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            ancestor = view.superview
        }
        return nil
    }

    private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            result.append(scrollView)
        }
        for subview in view.subviews {
            result.append(contentsOf: descendantScrollViews(in: subview))
        }
        return result
    }
}

@MainActor
enum AppWebScrollbarStyle {
    static func userScript(
        for theme: AppScrollbarTheme,
        palette: AppThemePalette
    ) -> WKUserScript {
        WKUserScript(
            source: source(for: theme, palette: palette),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    static func apply(
        theme: AppScrollbarTheme,
        palette: AppThemePalette,
        to webView: WKWebView
    ) {
        webView.evaluateJavaScript(source(for: theme, palette: palette))
    }

    private static func source(
        for theme: AppScrollbarTheme,
        palette: AppThemePalette
    ) -> String {
        let colors = theme.colorSet(for: palette)
        let thumb = colors.cssColor(hex: colors.thumbHex, opacity: colors.webIdleOpacity)
        let thumbHover = colors.cssColor(hex: colors.thumbHex, opacity: colors.webHoverOpacity)
        let thumbActive = colors.cssColor(hex: colors.thumbHex, opacity: colors.webActiveOpacity)
        let track = colors.cssColor(hex: colors.trackHex, opacity: colors.webTrackOpacity)
        let css = """
        :root {
            --netvplayer-scrollbar-thumb: \(thumb);
            --netvplayer-scrollbar-thumb-hover: \(thumbHover);
            --netvplayer-scrollbar-thumb-active: \(thumbActive);
            --netvplayer-scrollbar-track: \(track);
            scrollbar-color: var(--netvplayer-scrollbar-thumb) var(--netvplayer-scrollbar-track);
            scrollbar-width: thin;
            scrollbar-gutter: stable;
        }
        ::-webkit-scrollbar {
            width: 10px;
            height: 10px;
        }
        ::-webkit-scrollbar-track {
            background: var(--netvplayer-scrollbar-track);
        }
        ::-webkit-scrollbar-thumb {
            min-height: 44px;
            border: 2px solid transparent;
            border-radius: 999px;
            background: var(--netvplayer-scrollbar-thumb);
            background-clip: content-box;
        }
        ::-webkit-scrollbar-thumb:hover {
            background: var(--netvplayer-scrollbar-thumb-hover);
            background-clip: content-box;
        }
        ::-webkit-scrollbar-thumb:active {
            background: var(--netvplayer-scrollbar-thumb-active);
            background-clip: content-box;
        }
        """

        let source = """
        (() => {
            const styleID = 'netvplayer-scrollbar-theme';
            let style = document.getElementById(styleID);
            if (!style) {
                style = document.createElement('style');
                style.id = styleID;
                (document.head || document.documentElement).appendChild(style);
            }
            style.textContent = \(javascriptStringLiteral(css));
        })();
        """
        return source
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        guard
            let data,
            let json = String(data: data, encoding: .utf8),
            json.count >= 2
        else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
    }
}
