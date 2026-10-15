import AppKit
import SwiftUI
import Testing
@testable import NetVplayerApp

@Suite("Themed scroll view")
struct ThemedScrollViewTests {
    @Test
    func browserScrollbarFollowsEverySelectedThemeAccent() {
        let legacy = AppThemeCatalog.palette(for: .legacyDeepSpace)
        let orange = AppThemeCatalog.palette(for: .orangeSea)
        let glacier = AppThemeCatalog.palette(for: .glacierBloom)

        #expect(AppScrollbarTheme.standard.colorSet(for: legacy).thumbHex == legacy.primaryAccentHex)
        #expect(AppScrollbarTheme.subtle.colorSet(for: legacy).thumbHex == legacy.primaryAccentHex)
        #expect(AppScrollbarTheme.standard.colorSet(for: orange).thumbHex == orange.primaryAccentHex)
        #expect(AppScrollbarTheme.subtle.colorSet(for: orange).thumbHex == orange.primaryAccentHex)
        #expect(AppScrollbarTheme.standard.colorSet(for: orange).strokeHex == orange.foregroundHex)
        #expect(glacier.primaryAccentHex == 0x87C7FF)
        #expect(AppScrollbarTheme.standard.colorSet(for: glacier).thumbHex == 0x87C7FF)
        #expect(AppScrollbarTheme.subtle.colorSet(for: glacier).thumbHex == 0x87C7FF)

        for id in AppAppearanceThemeID.allCases {
            let palette = AppThemeCatalog.palette(for: id)
            #expect(AppScrollbarTheme.standard.colorSet(for: palette).thumbHex == palette.primaryAccentHex)
            #expect(AppScrollbarTheme.subtle.colorSet(for: palette).thumbHex == palette.primaryAccentHex)
        }
    }

    @Test
    func playerAndLiveScrollbarColorsRemainFixedAcrossBrowserThemes() {
        let aurora = AppThemeCatalog.palette(for: .auroraViolet)
        let orange = AppThemeCatalog.palette(for: .orangeSea)

        #expect(AppScrollbarTheme.player.colorSet(for: aurora).thumbHex == 0xAD96E8)
        #expect(AppScrollbarTheme.player.colorSet(for: orange).thumbHex == 0xAD96E8)
        #expect(AppScrollbarTheme.live.colorSet(for: aurora).thumbHex == 0x40D6C7)
        #expect(AppScrollbarTheme.live.colorSet(for: orange).thumbHex == 0x40D6C7)
    }

    @Test
    func scrollbarInteractionStatesOnlyIncreaseVisualEmphasis() {
        for theme in [AppScrollbarTheme.standard, .subtle, .live, .player] {
            let colors = theme.colorSet(for: AppThemeCatalog.palette(for: .orangeSea))
            #expect(colors.idleOpacity <= colors.hoverOpacity)
            #expect(colors.hoverOpacity <= colors.activeOpacity)
            #expect(colors.webIdleOpacity <= colors.webHoverOpacity)
            #expect(colors.webHoverOpacity <= colors.webActiveOpacity)
        }
    }

    @Test @MainActor
    func webScrollbarScriptIncludesThemeColorAndAllInteractionStates() {
        let script = AppWebScrollbarStyle.userScript(
            for: .standard,
            palette: AppThemeCatalog.palette(for: .orangeSea)
        ).source

        #expect(script.contains(#"rgb(47 98 94 \/ 78%)"#))
        #expect(script.contains("--netvplayer-scrollbar-thumb-hover"))
        #expect(script.contains("--netvplayer-scrollbar-thumb-active"))
        #expect(script.contains("::-webkit-scrollbar-thumb:hover"))
        #expect(script.contains("::-webkit-scrollbar-thumb:active"))

        let glacierScript = AppWebScrollbarStyle.userScript(
            for: .standard,
            palette: AppThemeCatalog.palette(for: .glacierBloom)
        ).source
        #expect(glacierScript.contains(#"rgb(135 199 255 \/ 78%)"#))
    }

    @Test @MainActor
    func nativeScrollerIsHiddenBeforeTheCurrentRunLoopTurnEnds() {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let documentView = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 720))
        let probe = NativeScrollerHidingProbeView(frame: .zero)

        scrollView.documentView = documentView
        documentView.addSubview(probe)
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.isHidden = false

        probe.hideEnclosingNativeScroller()

        #expect(!scrollView.hasVerticalScroller)
        #expect(scrollView.verticalScroller?.isHidden != false)
    }

    @Test @MainActor
    func nativeScrollerStaysHiddenWhenTheHostReenablesIt() {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let documentView = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 720))
        let probe = NativeScrollerHidingProbeView(frame: .zero)

        scrollView.documentView = documentView
        documentView.addSubview(probe)
        probe.hideEnclosingNativeScroller()

        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.isHidden = false

        #expect(!scrollView.hasVerticalScroller)
        #expect(scrollView.verticalScroller?.isHidden != false)
    }

    @Test @MainActor
    func horizontalProbeOnlyHidesItsAxisAndSurvivesNativeReplacement() {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 720))
        let probe = NativeScrollerHidingProbeView(frame: .zero)
        probe.axis = .horizontal
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        document.addSubview(probe)
        probe.hideEnclosingNativeScroller()
        #expect(scrollView.hasVerticalScroller)
        #expect(!scrollView.hasHorizontalScroller)

        scrollView.horizontalScroller = NSScroller()
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScroller?.isHidden = false
        #expect(scrollView.hasVerticalScroller)
        #expect(!scrollView.hasHorizontalScroller)
        #expect(scrollView.horizontalScroller?.isHidden != false)
    }

    @Test @MainActor
    func horizontalDraggingClampsToContentAndPreservesVerticalPosition() {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 720))
        scrollView.documentView = document
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 48))
        let proxy = HorizontalScrollProxy()
        proxy.attach(to: scrollView)
        proxy.scroll(to: 160)
        #expect(scrollView.contentView.bounds.origin.x == 160)
        #expect(scrollView.contentView.bounds.origin.y == 48)
        proxy.scroll(to: 2000)
        #expect(scrollView.contentView.bounds.origin.x == document.bounds.width - scrollView.contentView.bounds.width)
        proxy.scroll(to: -100)
        #expect(scrollView.contentView.bounds.origin.x == 0)
        proxy.scroll(to: .nan)
        #expect(scrollView.contentView.bounds.origin.x == 0)
    }

    @Test @MainActor
    func horizontalMetricsFollowNativeScrollingResizingAndDocumentReplacement() async {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 240))
        scrollView.documentView = document
        let proxy = HorizontalScrollProxy()
        proxy.attach(to: scrollView)
        await flushScrollMeasurement()
        #expect(proxy.metrics.isScrollable)
        #expect(proxy.metrics.contentHeight == 960)
        #expect(proxy.metrics.containerHeight == scrollView.contentView.bounds.width)

        // Native scrolling (including a trackpad) must update the custom thumb.
        scrollView.contentView.scroll(to: NSPoint(x: 160, y: 0))
        await flushScrollMeasurement()
        #expect(proxy.metrics.offsetY == 160)

        document.setFrameSize(CGSize(width: 1200, height: 240))
        scrollView.setFrameSize(CGSize(width: 480, height: 240))
        scrollView.tile()
        await flushScrollMeasurement()
        #expect(proxy.metrics.contentHeight == 1200)
        #expect(proxy.metrics.containerHeight == scrollView.contentView.bounds.width)

        scrollView.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 240))
        proxy.attach(to: scrollView)
        await flushScrollMeasurement()
        #expect(!proxy.metrics.isScrollable)
        document.setFrameSize(CGSize(width: 1800, height: 240))
        await flushScrollMeasurement()
        #expect(!proxy.metrics.isScrollable)
    }

    @MainActor
    private func flushScrollMeasurement() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test @MainActor
    func containerProbeHidesTheSpatiallyMatchingScrollerSynchronously() {
        let contentView = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 440, height: 320))
        let documentView = NSView(frame: CGRect(x: 0, y: 0, width: 440, height: 960))
        let probe = NativeScrollerHidingProbeView(frame: scrollView.frame)
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        scrollView.documentView = documentView
        contentView.addSubview(scrollView)
        contentView.addSubview(probe)
        window.contentView = contentView
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.isHidden = false

        probe.hideEnclosingNativeScroller()

        #expect(!scrollView.hasVerticalScroller)
        #expect(scrollView.verticalScroller?.isHidden != false)
    }

    @Test @MainActor
    func hostedLazyLoadingContentHasNoNativeVerticalScrollerOnFirstLayout() {
        let size = CGSize(width: 480, height: 320)
        let rootView = ThemedScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<18, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.gray.opacity(0.15))
                        .frame(height: 180)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let scrollViews = descendantScrollViews(in: hostingView)
        #expect(!scrollViews.isEmpty)
        #expect(scrollViews.allSatisfy { !$0.hasVerticalScroller })
        #expect(scrollViews.allSatisfy { $0.verticalScroller?.isHidden != false })
    }

    @Test @MainActor
    func hostedScrollViewKeepsAnExactProbeInsideItsDocumentView() {
        let size = CGSize(width: 480, height: 320)
        let rootView = ThemedScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                ForEach(0..<18, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.gray.opacity(0.15))
                        .frame(height: 180)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let scrollViews = descendantScrollViews(in: hostingView)
        #expect(!scrollViews.isEmpty)
        #expect(scrollViews.allSatisfy { scrollView in
            guard let documentView = scrollView.documentView else { return false }
            return !descendantViews(of: NativeScrollerHidingProbeView.self, in: documentView).isEmpty
        })
    }

    @MainActor
    private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
        var result = view.subviews.flatMap(descendantScrollViews)
        if let scrollView = view as? NSScrollView {
            result.append(scrollView)
        }
        return result
    }

    @Test @MainActor
    func contentReachesTheIntendedEdgeAfterScrollingResizingAndNativeScrollerReenable() async throws {
        for placement in [AppScrollbarPlacement.gutter, .overlay] {
            let root = ThemedScrollView(theme: .subtle, scrollbarPlacement: placement) {
                VStack(spacing: 0) {
                    Color.purple.frame(height: 420)
                    Color.blue.frame(height: 1200)
                }
                .frame(maxWidth: .infinity)
                .background(ScrollContentEdgeProbe())
            }
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            defer { window.orderOut(nil); window.close() }
            for width in [480.0, 720.0, 360.0] {
                window.setContentSize(CGSize(width: width, height: 320))
                hosting.frame = CGRect(x: 0, y: 0, width: width, height: 320)
                hosting.layoutSubtreeIfNeeded()
                await flushScrollMeasurement()
                let scroll = try #require(descendantScrollViews(in: hosting).first)
                // A host update can reenable the system scroller after the initial render.
                scroll.scrollerStyle = .legacy
                scroll.hasVerticalScroller = true
                scroll.verticalScroller?.isHidden = false
                for y in [0.0, 300.0, 1300.0] {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    hosting.layoutSubtreeIfNeeded()
                    await flushScrollMeasurement()
                    let marker = try #require(descendantViews(of: ScrollContentEdgeMarker.self, in: hosting).first)
                    let expected = width - (placement == .gutter ? 10 : 0)
                    #expect(abs(marker.bounds.width - expected) < 1)
                    #expect(abs(scroll.contentView.frame.maxX - scroll.bounds.maxX) < 1)
                    #expect(!scroll.hasVerticalScroller)
                    #expect(scroll.verticalScroller?.isHidden != false)
                }
            }
        }
    }

    @MainActor
    private func descendantViews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var result = view.subviews.flatMap { descendantViews(of: type, in: $0) }
        if let matchingView = view as? T {
            result.append(matchingView)
        }
        return result
    }
}

private final class ScrollContentEdgeMarker: NSView {}
private struct ScrollContentEdgeProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollContentEdgeMarker { ScrollContentEdgeMarker() }
    func updateNSView(_ nsView: ScrollContentEdgeMarker, context: Context) {}
}
