import Testing
import CoreGraphics
import SwiftUI
@testable import NetVplayerApp

@Suite("Home visual policy")
struct HomeVisualPolicyTests {
    @Test
    func testSidebarOrderKeepsSearchInTheHeader() {
        #expect(HomeVisualPolicy.sidebarTabs(webHomeEnabled: false) == [
            .vodHome,
            .liveStream,
            .history,
            .favorites,
            .settings,
        ])
        #expect(HomeVisualPolicy.sidebarTabs(webHomeEnabled: true) == [
            .vodHome,
            .liveStream,
            .history,
            .favorites,
            .webHome,
            .settings,
        ])
    }

    @Test
    func testHomeGeometryMatchesTheDesktopLibraryContract() {
        #expect(HomeVisualPolicy.sidebarIdealWidth == 218)
        #expect(HomeVisualPolicy.primarySidebarOuterInset == 8)
        #expect(HomeVisualPolicy.primarySidebarPaneMinWidth == 204)
        #expect(HomeVisualPolicy.primarySidebarPaneIdealWidth == 226)
        #expect(HomeVisualPolicy.primarySidebarPaneMaxWidth == 226)
        #expect(HomeVisualPolicy.primarySidebarPanelCornerRadius == 20)
        #expect(HomeVisualPolicy.primarySidebarShadowRadius == 14)
        #expect(HomeVisualPolicy.primarySidebarShadowY == 5)
        #expect(HomeVisualPolicy.primarySidebarLightShadowOpacity == 0.14)
        #expect(HomeVisualPolicy.primarySidebarDarkShadowOpacity == 0.24)
        #expect(HomeVisualPolicy.sidebarNavigationRowHeight == 48)
        #expect(HomeVisualPolicy.sidebarNavigationTopPadding == 10)
        #expect(HomeVisualPolicy.sidebarBrandIconSize == 36)
        #expect(HomeVisualPolicy.sidebarBrandIconFieldSize == 41)
        #expect(HomeVisualPolicy.sidebarBrandIconCornerRadius == 11)
        #expect(HomeVisualPolicy.sidebarBrandSpacing == 9)
        #expect(HomeVisualPolicy.sidebarBrandCopySpacing == 3)
        #expect(HomeVisualPolicy.sidebarBrandContentLeadingPadding == 14)
        #expect(HomeVisualPolicy.sidebarBrandContentTrailingPadding == 19)
        #expect(HomeVisualPolicy.sidebarBrandTopPadding == 8)
        #expect(HomeVisualPolicy.sidebarBrandBottomPadding == 12)
        #expect(HomeVisualPolicy.sidebarBrandBackdropLeadingInset == 9)
        #expect(HomeVisualPolicy.sidebarBrandBackdropTrailingInset == 12)
        #expect(HomeVisualPolicy.sidebarBrandBackdropCornerRadius == 14)
        #expect(HomeVisualPolicy.sidebarBrandBackdropLavenderOpacity == 0.088)
        #expect(HomeVisualPolicy.sidebarBrandBackdropSurfaceOpacity == 0.104)
        #expect(HomeVisualPolicy.sidebarBrandBackdropBottomInset == 4)
        #expect(HomeVisualPolicy.sidebarBrandBackdropFadeStart == 0.76)
        #expect(HomeVisualPolicy.sidebarBrandDividerAccentLeadingInset == 36)
        #expect(HomeVisualPolicy.sidebarBrandDividerAccentWidth == 28)
        #expect(HomeVisualPolicy.sidebarBrandDividerTrailingInset == 18)
        #expect(HomeVisualPolicy.sidebarBrandDividerHeight == 0.5)
        #expect(HomeVisualPolicy.sidebarBrandDividerAccentOpacity == 0.50)
        #expect(HomeVisualPolicy.sidebarBrandDividerLavenderOpacity == 0.25)
        #expect(HomeVisualPolicy.sidebarBrandSurfaceOpacity == 0.30)
        #expect(HomeVisualPolicy.sidebarBrandBorderOpacity == 0.22)
        #expect(HomeVisualPolicy.sidebarBrandSubtitleOpacity == 0.88)

        let backdropBottomClearance = HomeVisualPolicy.sidebarBrandHeaderHeight
            - HomeVisualPolicy.sidebarBrandBackdropBottomInset
            - HomeVisualPolicy.sidebarBrandTopPadding
            - HomeVisualPolicy.sidebarBrandIconFieldSize
        #expect(HomeVisualPolicy.sidebarBrandHeaderHeight == 61)
        #expect(backdropBottomClearance == HomeVisualPolicy.sidebarBrandTopPadding)
        #expect(
            HomeVisualPolicy.sidebarBrandContentLeadingPadding
                - HomeVisualPolicy.sidebarBrandBackdropLeadingInset == 5
        )

        #expect(HomeVisualPolicy.contentTopPadding == 29)
        #expect(HomeVisualPolicy.headerControlHeight == 42)
        #expect(HomeVisualPolicy.headerControlTopInset == 32)
        #expect(HomeVisualPolicy.primarySidebarTopInset == HomeVisualPolicy.headerControlTopInset)
        #expect(HomeVisualPolicy.primarySidebarNavigationTopDistance == 103)
        #expect(HomeVisualPolicy.sitePickerWidth == 288)
        #expect(HomeVisualPolicy.collapsedHeaderLeadingInset == 184)
        #expect(HomeVisualPolicy.isSidebarPresented(detailLeadingEdge: 218))
        #expect(!HomeVisualPolicy.isSidebarPresented(detailLeadingEdge: 0))
        #expect(HomeVisualPolicy.headerLeadingInset(isSidebarPresented: true) == 0)
        #expect(HomeVisualPolicy.headerLeadingInset(isSidebarPresented: false) == 184)
        #expect(HomeVisualPolicy.categoryHeight == 34)
        #expect(HomeVisualPolicy.posterMinimumWidth == 148)
        #expect(HomeVisualPolicy.posterMaximumWidth == 196)
        #expect(HomeVisualPolicy.posterHorizontalGap == 18)
        #expect(HomeVisualPolicy.posterVerticalGap == 24)
        #expect(HomeVisualPolicy.posterCornerRadius == 12)
        #expect(AppScrollbarMetrics.gutterWidth == 16)
        #expect(HomeVisualPolicy.posterAvailableWidth(containerWidth: 987) == 915)

        let standardGrid = HomeVisualPolicy.posterGridLayout(availableWidth: 915)
        #expect(standardGrid.columnCount == 5)
        #expect(abs(standardGrid.itemWidth - 168.6) < 0.01)

        let compactGrid = HomeVisualPolicy.posterGridLayout(availableWidth: 300)
        #expect(compactGrid.columnCount == 1)
        #expect(compactGrid.itemWidth == HomeVisualPolicy.posterMaximumWidth)

        let wideGrid = HomeVisualPolicy.posterGridLayout(availableWidth: 1_082)
        #expect(wideGrid.columnCount == 6)
        #expect(abs(wideGrid.itemWidth - 165.33) < 0.01)

        #expect(HomeVisualPolicy.posterRowStarts(itemCount: 13, columnCount: 5) == [0, 5, 10])
        #expect(HomeVisualPolicy.posterRowStarts(itemCount: 0, columnCount: 5).isEmpty)
    }

    @Test @MainActor
    func testPosterAspectContainerOwnsStableGeometry() {
        let landscape = NSHostingView(rootView:
            PosterAspectContainer(width: 180) {
                Color.red.frame(width: 800, height: 100)
            }
        )
        let portrait = NSHostingView(rootView:
            PosterAspectContainer(width: 180) {
                Color.blue.frame(width: 100, height: 800)
            }
        )

        #expect(abs(landscape.fittingSize.width - 180) < 0.5)
        #expect(abs(landscape.fittingSize.height - 270) < 0.5)
        #expect(abs(portrait.fittingSize.width - 180) < 0.5)
        #expect(abs(portrait.fittingSize.height - 270) < 0.5)
    }

    @Test
    func testHomeColorPostureReusesThePlayerPalette() {
        #expect(PlayerHUDPalette.backgroundHex == 0x03050F)
        #expect(PlayerHUDPalette.surfaceHex == 0x1B2037)
        #expect(PlayerHUDPalette.accentHex == 0x53D8F3)
        #expect(PlayerHUDPalette.lavenderHex == 0xA69AD8)
        #expect(PlayerHUDPalette.foregroundHex == 0xEFF2F6)
        #expect(PlayerHUDPalette.mutedHex == 0xABB2BD)
        #expect(HomeVisualPolicy.selectedBackgroundOpacity == 0.16)
        #expect(HomeVisualPolicy.selectedBorderOpacity == 0.46)
        #expect(HomeVisualPolicy.hoverBorderOpacity == 0.64)
    }

    @Test
    func testSharedPageSurfacesKeepNavigationAndPanelsAligned() {
        #expect(AppSurfaceVisualPolicy.pageBackgroundSurfaceOpacity == 0.72)
        #expect(AppSurfaceVisualPolicy.pageHorizontalPadding == 28)
        #expect(AppSurfaceVisualPolicy.pageHeaderHeight == 64)
        #expect(AppSurfaceVisualPolicy.settingsHeaderHeight == 86)
        #expect(AppSurfaceVisualPolicy.settingsTitleTopPadding == 29)
        #expect(AppSurfaceVisualPolicy.settingsTitleTopPadding == HomeVisualPolicy.contentTopPadding)
        #expect(AppSurfaceVisualPolicy.settingsContentMaxWidth == 920)
        #expect(AppSurfaceVisualPolicy.settingsBottomPadding == 32)
        #expect(AppSurfaceVisualPolicy.pageSectionGap == 18)
        #expect(AppSurfaceVisualPolicy.panelCornerRadius == 16)
        #expect(AppSurfaceVisualPolicy.localSidebarWidth == HomeVisualPolicy.sidebarIdealWidth)
        #expect(AppSurfaceVisualPolicy.localNavigationRowHeight == 46)
        #expect(AppSurfaceVisualPolicy.localNavigationGap == HomeVisualPolicy.sidebarNavigationGap)
    }

    @Test
    func testMainWindowTitlebarInteractionExpandsIntoHomeBlankChromeOnly() {
        #expect(MainWindowTitlebarInteractionPolicy.regionHeight == 22)
        #expect(MainWindowTitlebarInteractionPolicy.leadingControlExclusionWidth == 128)
        #expect(MainWindowTitlebarInteractionPolicy.sidebarBlankRegionWidth == 196)
        #expect(MainWindowTitlebarInteractionPolicy.defaultSidebarWidth == 226)
        #expect(MainWindowTitlebarInteractionPolicy.sidebarNavigationTopDistance == 103)
        #expect(MainWindowTitlebarInteractionPolicy.homeCategoryTopDistance == 89)
        #expect(MainWindowTitlebarInteractionPolicy.homeHeaderControlTopDistance == 32)
        #expect(MainWindowTitlebarInteractionPolicy.homeHeaderControlBottomDistance == 74)
        #expect(MainWindowTitlebarInteractionPolicy.shouldToggleZoom(clickCount: 1) == false)
        #expect(MainWindowTitlebarInteractionPolicy.shouldToggleZoom(clickCount: 2) == true)
        #expect(MainWindowTitlebarInteractionPolicy.shouldToggleZoom(clickCount: 3) == false)

        let contentLayoutRect = CGRect(x: 0, y: 0, width: 1_200, height: 760)
        #expect(MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 128, y: 778),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 127, y: 780),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 500, y: 777),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800
        ))
        #expect(MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 500, y: 725),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 500, y: 726),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true
        ))
        #expect(MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 650, y: 745),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 900, y: 745),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true
        ))
        #expect(MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 500, y: 712),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 500, y: 711),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true
        ))
        #expect(MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 100, y: 698),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true,
            sidebarWidth: 196
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 197, y: 670),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true,
            sidebarWidth: 196
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 100, y: 697),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true,
            sidebarWidth: 196
        ))

        let compactContentLayoutRect = CGRect(x: 0, y: 0, width: 960, height: 640)
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 500, y: 647),
            contentLayoutRect: compactContentLayoutRect,
            windowFrameHeight: 692,
            isHomePresented: true,
            sidebarWidth: 208
        ))
        #expect(MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 550, y: 647),
            contentLayoutRect: compactContentLayoutRect,
            windowFrameHeight: 692,
            isHomePresented: true,
            sidebarWidth: 208
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 800, y: 647),
            contentLayoutRect: compactContentLayoutRect,
            windowFrameHeight: 692,
            isHomePresented: true,
            sidebarWidth: 208
        ))

        #expect(MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 150, y: 745),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true,
            sidebarWidth: 0
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 220, y: 745),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true,
            sidebarWidth: 0
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 480, y: 745),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true,
            sidebarWidth: 0
        ))
        #expect(MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 510, y: 745),
            contentLayoutRect: contentLayoutRect,
            windowFrameHeight: 800,
            isHomePresented: true,
            sidebarWidth: 0
        ))

        let visibleFrame = CGRect(x: 0, y: 23, width: 1_920, height: 1_057)
        let windowedFrame = CGRect(x: 360, y: 151.5, width: 1_200, height: 800)
        let maximize = MainWindowTitlebarInteractionPolicy.zoomTransition(
            currentFrame: windowedFrame,
            visibleFrame: visibleFrame,
            restoreFrame: nil
        )
        #expect(maximize.targetFrame == visibleFrame)
        #expect(maximize.nextRestoreFrame == windowedFrame)

        let restore = MainWindowTitlebarInteractionPolicy.zoomTransition(
            currentFrame: visibleFrame,
            visibleFrame: visibleFrame,
            restoreFrame: maximize.nextRestoreFrame
        )
        #expect(restore.targetFrame == windowedFrame)
        #expect(restore.nextRestoreFrame == nil)

        let fallbackRestore = MainWindowTitlebarInteractionPolicy.zoomTransition(
            currentFrame: visibleFrame,
            visibleFrame: visibleFrame,
            restoreFrame: nil
        )
        #expect(fallbackRestore.targetFrame == windowedFrame)
        #expect(fallbackRestore.nextRestoreFrame == nil)
    }

    @Test @MainActor
    func testSitePickerMenuControlKeepsSemanticLabelAndFixedGeometry() {
        let shortTarget = SitePickerMenuControl(title: "短源")
        let longTarget = SitePickerMenuControl(title: "这是一个文字明显更长的站点名称")
        let expectedSize = CGSize(
            width: HomeVisualPolicy.sitePickerWidth,
            height: HomeVisualPolicy.headerControlHeight
        )

        #expect(shortTarget.accessibilityLabel == "短源")
        #expect(shortTarget.accessibilityTitle == "当前站点：短源")
        #expect(shortTarget.controlSize == expectedSize)
        #expect(longTarget.controlSize == expectedSize)

        let fallback = SitePickerMenuControl(title: "")
        #expect(fallback.accessibilityLabel == "未命名站点")
        #expect(fallback.accessibilityTitle == "当前站点：未命名站点")
        #expect(fallback.controlSize == expectedSize)
    }

    @Test
    func testSitePickerMenuTitleHidesInternalNativeStatus() {
        let native = SitePickerMenuItem.statusPresentation(for: .native)
        let upstreamUnavailable = SitePickerMenuItem.statusPresentation(for: .upstreamUnavailable)

        #expect(native.text == nil)
        #expect(upstreamUnavailable.text == "上游失效")
        #expect(
            SitePickerMenuItem.displayTitle(siteName: "厂长", statusText: native.text)
                == "厂长"
        )
        #expect(
            SitePickerMenuItem.displayTitle(siteName: "失效源", statusText: upstreamUnavailable.text)
                == "失效源 · 上游失效"
        )
    }
}
