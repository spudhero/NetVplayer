import Models
// NetVplayerApp/Views/ThemedScrollView.swift
// Theme-aware scroll indicators with reserved space or an edge overlay.

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

enum AppScrollbarPlacement {
    case gutter
    /// Full-width artwork can continue beneath the indicator; inset interactive content.
    case overlay
}

struct ThemedScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let theme: AppScrollbarTheme
    private let scrollbarPlacement: AppScrollbarPlacement
    private let content: Content
    private let onScrollPositionChange: ((CGFloat, CGFloat) -> Void)?

    init(
        _ axes: Axis.Set = .vertical,
        theme: AppScrollbarTheme = .standard,
        scrollbarPlacement: AppScrollbarPlacement = .gutter,
        onScrollPositionChange: ((CGFloat, CGFloat) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.axes = axes
        self.theme = theme
        self.scrollbarPlacement = scrollbarPlacement
        self.onScrollPositionChange = onScrollPositionChange
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if axes == .vertical {
            if #available(macOS 15.0, *) {
                GeometryTrackedScrollView(theme: theme, scrollbarPlacement: scrollbarPlacement, content: content, onScrollPositionChange: onScrollPositionChange)
            } else {
                LegacyTrackedScrollView(theme: theme, scrollbarPlacement: scrollbarPlacement, content: content, onScrollPositionChange: onScrollPositionChange)
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
    let scrollbarPlacement: AppScrollbarPlacement
    let content: Content
    var onScrollPositionChange: ((CGFloat, CGFloat) -> Void)?

    @State private var scrollPosition = ScrollPosition()
    @State private var metrics = AppScrollMetrics.zero

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .trailing) {
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
                    onScrollPositionChange?(newMetrics.offsetY, max(0, newMetrics.maximumOffset - newMetrics.offsetY))
                }
                .padding(.trailing, scrollbarPlacement == .gutter ? theme.gutterWidth : 0)

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
    let scrollbarPlacement: AppScrollbarPlacement
    let content: Content
    var onScrollPositionChange: ((CGFloat, CGFloat) -> Void)?

    @State private var coordinateSpaceName = UUID()
    @State private var measurement = LegacyScrollMeasurement.zero

    var body: some View {
        GeometryReader { viewport in
            ZStack(alignment: .trailing) {
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
                    let offset = max(0, -value.minY)
                    onScrollPositionChange?(offset, max(0, value.contentHeight - viewport.size.height - offset))
                }
                .padding(.trailing, scrollbarPlacement == .gutter ? theme.gutterWidth : 0)

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

/// Uses the same theme and thumb geometry as the vertical scrollbar. The small
/// AppKit proxy measures the native clip view and performs pixel scrolling on macOS 14+.
struct ThemedHorizontalScrollView<Content: View>: View {
    let theme: AppScrollbarTheme
    private let content: Content
    @StateObject private var proxy = HorizontalScrollProxy()

    init(theme: AppScrollbarTheme = .subtle, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    content
                        .background(alignment: .topLeading) {
                            NativeScrollerHidingProbe(axis: .horizontal) { proxy.attach(to: $0) }
                                .frame(width: 1, height: 1)
                        }
                }
                .scrollIndicators(.hidden)
                .frame(height: max(0, viewport.size.height - theme.gutterWidth))

                ThemedScrollbar(theme: theme, metrics: proxy.metrics,
                    onScroll: { proxy.scroll(to: $0) }, axis: .horizontal)
                    .frame(height: theme.gutterWidth)
            }
        }
    }
}

@MainActor
final class HorizontalScrollProxy: ObservableObject {
    @Published private(set) var metrics = AppScrollMetrics.zero
    private weak var scrollView: NSScrollView?
    private weak var observedDocument: NSView?
    private let observations = ScrollNotificationObservations()
    private var updateScheduled = false

    func attach(to scrollView: NSScrollView) {
        if self.scrollView !== scrollView || observedDocument !== scrollView.documentView {
            observations.removeAll()
            self.scrollView = scrollView
            observedDocument = scrollView.documentView
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            observedDocument?.postsFrameChangedNotifications = true
            observedDocument?.postsBoundsChangedNotifications = true
            for view in [clip, observedDocument].compactMap({ $0 }) {
                for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                    observations.tokens.append(NotificationCenter.default.addObserver(
                        forName: name, object: view, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleMeasurement() }
                    })
                }
            }
        }
        scheduleMeasurement()
    }

    private func scheduleMeasurement() {
        guard !updateScheduled else { return }
        updateScheduled = true
        // A probe resolves while SwiftUI is laying out. Publish after that layout completes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard let scrollView = self.scrollView, let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            let value = AppScrollMetrics(offsetY: max(0, clip.bounds.origin.x),
                contentHeight: document.bounds.width, containerHeight: clip.bounds.width)
            if self.metrics != value { self.metrics = value }
        }
    }

    func scroll(to offset: CGFloat) {
        guard offset.isFinite, let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: min(max(offset, 0), maximum), y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
        scheduleMeasurement()
    }

}

/// Owns notification tokens without actor isolation so teardown can remove them
/// synchronously even when SwiftUI releases its state object off the main actor.
private final class ScrollNotificationObservations {
    var tokens: [NSObjectProtocol] = []

    func removeAll() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }

    deinit { removeAll() }
}

struct AppScrollMetrics: Equatable {
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
    var axis: Axis = .vertical

    @State private var dragGrabOffset: CGFloat?
    @State private var isHovered = false

    var body: some View {
        GeometryReader { geometry in
            let layout = ScrollbarLayout(metrics: metrics, availableHeight: axis == .vertical ? geometry.size.height : geometry.size.width)
            let colors = theme.colorSet(for: palette)
            let thumbOpacity = dragGrabOffset != nil
                ? colors.activeOpacity
                : (isHovered ? colors.hoverOpacity : colors.idleOpacity)

            ZStack(alignment: axis == .vertical ? .top : .leading) {
                Capsule()
                    .fill(Color(appHex: colors.trackHex).opacity(colors.trackOpacity))
                    .frame(width: axis == .vertical ? theme.trackWidth : layout.trackHeight,
                           height: axis == .vertical ? layout.trackHeight : theme.trackWidth)
                    .offset(x: axis == .horizontal ? layout.verticalInset : 0, y: axis == .vertical ? layout.verticalInset : 0)

                Capsule()
                    .fill(Color(appHex: colors.thumbHex).opacity(thumbOpacity))
                    .frame(width: axis == .vertical ? theme.thumbWidth : layout.thumbHeight,
                           height: axis == .vertical ? layout.thumbHeight : theme.thumbWidth)
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
                    .offset(x: axis == .horizontal ? layout.thumbOffset : 0, y: axis == .vertical ? layout.thumbOffset : 0)
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
            .accessibilityLabel(L10n.text("滚动条"))
            .accessibilityValue("\(Int(layout.progress * 100))%")
        }
    }

    private func dragGesture(layout: ScrollbarLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard let onScroll, layout.travelDistance > 0 else { return }

                if dragGrabOffset == nil {
                    let positionInsideThumb = (axis == .vertical ? value.startLocation.y : value.startLocation.x) - layout.thumbOffset
                    dragGrabOffset = (0...layout.thumbHeight).contains(positionInsideThumb)
                        ? positionInsideThumb
                        : layout.thumbHeight / 2
                }

                let targetThumbOffset = (axis == .vertical ? value.location.y : value.location.x) - (dragGrabOffset ?? layout.thumbHeight / 2)
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
    var axis: Axis = .vertical
    var onResolve: ((NSScrollView) -> Void)?

    func makeNSView(context _: Context) -> NativeScrollerHidingProbeView {
        let view = NativeScrollerHidingProbeView()
        view.axis = axis
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NativeScrollerHidingProbeView, context _: Context) {
        nsView.axis = axis
        nsView.onResolve = onResolve
        nsView.hideEnclosingNativeScroller()
    }
}

final class NativeScrollerHidingProbeView: NSView {
    var axis: Axis = .vertical {
        didSet { if oldValue != axis { stopMonitoringScroller() } }
    }
    var onResolve: ((NSScrollView) -> Void)?
    private var isUpdateScheduled = false
    private var isHidingScroller = false
    private weak var monitoredScrollView: NSScrollView?
    private weak var monitoredScroller: NSScroller?
    private var scrollerEnabledObservation: NSKeyValueObservation?
    private var scrollerObservation: NSKeyValueObservation?
    private var scrollerVisibilityObservation: NSKeyValueObservation?
    private var enabledKeyPath: ReferenceWritableKeyPath<NSScrollView, Bool> {
        axis == .vertical ? \.hasVerticalScroller : \.hasHorizontalScroller
    }
    private var scrollerKeyPath: ReferenceWritableKeyPath<NSScrollView, NSScroller?> {
        axis == .vertical ? \.verticalScroller : \.horizontalScroller
    }

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
        onResolve?(scrollView)

        guard !isHidingScroller else { return }
        isHidingScroller = true
        defer { isHidingScroller = false }

        // A legacy scroller can leave a 17-point document inset after it is hidden.
        // Keep this owned host in overlay mode across scrolling and host updates.
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        if scrollView[keyPath: enabledKeyPath] {
            scrollView[keyPath: enabledKeyPath] = false
        }
        monitorVisibility(of: scrollView[keyPath: scrollerKeyPath], in: scrollView)
        if let scroller = scrollView[keyPath: scrollerKeyPath], !scroller.isHidden {
            scroller.isHidden = true
        }
    }

    private func monitorScroller(in scrollView: NSScrollView) {
        guard monitoredScrollView !== scrollView else {
            monitorVisibility(of: scrollView[keyPath: scrollerKeyPath], in: scrollView)
            return
        }

        stopMonitoringScroller()
        monitoredScrollView = scrollView
        scrollerEnabledObservation = scrollView.observe(
            enabledKeyPath,
            options: [.new]
        ) { [weak self] scrollView, change in
            guard change.newValue == true else { return }
            MainActor.assumeIsolated {
                self?.hideScroller(in: scrollView)
            }
        }
        scrollerObservation = scrollView.observe(
            scrollerKeyPath,
            options: [.new]
        ) { [weak self] scrollView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.monitorVisibility(of: scrollView[keyPath: self.scrollerKeyPath], in: scrollView)
                self.hideScroller(in: scrollView)
            }
        }
        monitorVisibility(of: scrollView[keyPath: scrollerKeyPath], in: scrollView)
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
        scrollerEnabledObservation = nil
        scrollerObservation = nil
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
