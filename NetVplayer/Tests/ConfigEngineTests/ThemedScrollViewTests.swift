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

    @MainActor
    private func descendantViews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var result = view.subviews.flatMap { descendantViews(of: type, in: $0) }
        if let matchingView = view as? T {
            result.append(matchingView)
        }
        return result
    }
}
