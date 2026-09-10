import Testing
import Foundation
import CoreGraphics
import AppKit
import DanmakuEngine
import PlayerEngine
@testable import NetVplayerApp

@Suite("Player HUD visual policy")
struct PlayerHUDVisualPolicyTests {
    @Test
    func testBottomControlSlotsMatchOpenDesignOrder() {
        #expect(PlayerHUDVisualPolicy.bottomControlSlots == [
            .previousEpisode,
            .nextEpisode,
            .episodeGrid,
            .rewind10,
            .forward10,
            .openingSkip,
            .endingSkip,
            .subtitles,
            .audio,
            .aspectRatio,
            .speed,
            .volume,
            .settings,
            .fullscreen,
        ])
    }

    @Test
    func testEpisodeSortSymbolsAreAvailableOnSupportedMacOS() {
        let descending = PlayerHUDVisualPolicy.episodeSortSymbolName(descending: true)
        let ascending = PlayerHUDVisualPolicy.episodeSortSymbolName(descending: false)

        #expect(descending == "arrow.down.to.line.compact")
        #expect(ascending == "arrow.up.to.line.compact")
        #expect(NSImage(systemSymbolName: descending, accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: ascending, accessibilityDescription: nil) != nil)
    }

    @Test
    func testHUDReferenceCanvasMatchesOpenDesignAndScalesUniformly() {
        #expect(PlayerHUDLayoutPolicy.referenceSize == CGSize(width: 1_480, height: 833))
        #expect(abs(PlayerHUDLayoutPolicy.minimumWindowedScale - (640.0 / 833.0)) < 0.0001)
        #expect(PlayerHUDLayoutPolicy.maximumWindowedScale == 1)
        #expect(PlayerHUDLayoutPolicy.scale(for: CGSize(width: 1_480, height: 833)) == 1)
        #expect(PlayerHUDLayoutPolicy.scale(for: CGSize(width: 1_920, height: 1_200)) == 1)
        #expect(PlayerHUDLayoutPolicy.scale(for: .zero) == 0)

        let scaled = PlayerHUDLayoutPolicy.scaledSize(for: CGSize(width: 1_200, height: 675))
        #expect(abs(scaled.width / scaled.height - 1_480.0 / 833.0) < 0.0001)
        #expect(scaled.width <= 1_200)
        #expect(scaled.height <= 675)
    }

    @Test
    func testCompactPlayerThresholdAndMinimumSizeContract() {
        #expect(CompactPlayerLayoutPolicy.regularThreshold == CGSize(width: 960, height: 640))
        #expect(CompactPlayerLayoutPolicy.minimumContentSize == CGSize(width: 427, height: 240))
        #expect(!CompactPlayerLayoutPolicy.isCompact(contentSize: CGSize(width: 960, height: 640)))
        #expect(CompactPlayerLayoutPolicy.isCompact(contentSize: CGSize(width: 959, height: 640)))
        #expect(CompactPlayerLayoutPolicy.isCompact(contentSize: CGSize(width: 960, height: 639)))
        #expect(CompactPlayerLayoutPolicy.isCompact(contentSize: CGSize(width: 1_400, height: 500)))
    }

    @Test
    func testCompactPlayerProgressClampsAndRejectsUnseekableTimelines() {
        #expect(CompactPlayerLayoutPolicy.normalizedProgress(position: -10, duration: 100) == 0)
        #expect(CompactPlayerLayoutPolicy.normalizedProgress(position: 25, duration: 100) == 0.25)
        #expect(CompactPlayerLayoutPolicy.normalizedProgress(position: 120, duration: 100) == 1)
        #expect(CompactPlayerLayoutPolicy.normalizedProgress(position: 20, duration: 0) == nil)
        #expect(CompactPlayerLayoutPolicy.normalizedProgress(position: .nan, duration: 100) == nil)
        #expect(CompactPlayerLayoutPolicy.normalizedProgress(position: 20, duration: .infinity) == nil)
        #expect(!CompactPlayerLayoutPolicy.showsProgress(kind: .live, duration: 0))
        #expect(!CompactPlayerLayoutPolicy.showsProgress(kind: .live, duration: .infinity))
        #expect(CompactPlayerLayoutPolicy.showsProgress(kind: .live, duration: 3_600))
        #expect(CompactPlayerLayoutPolicy.showsProgress(kind: .vod, duration: 6_000))
    }

    @Test
    func testPlayerWindowPresentationPolicyPreservesDesignAspectAndBounds() {
        let defaultTarget = PlayerWindowPresentationPolicy.targetContentSize(
            currentContentSize: CGSize(width: 1_200, height: 800),
            visibleFrameSize: CGSize(width: 1_800, height: 1_100)
        )
        #expect(abs(defaultTarget.width - 1_200) < 0.0001)
        #expect(abs(defaultTarget.height - (1_200 * 833.0 / 1_480.0)) < 0.0001)

        let minimumTarget = PlayerWindowPresentationPolicy.targetContentSize(
            currentContentSize: CGSize(width: 960, height: 640),
            visibleFrameSize: CGSize(width: 1_800, height: 1_100)
        )
        #expect(abs(minimumTarget.height - 640) < 0.0001)
        #expect(abs(minimumTarget.width / minimumTarget.height - 1_480.0 / 833.0) < 0.0001)

        let maximumTarget = PlayerWindowPresentationPolicy.targetContentSize(
            currentContentSize: CGSize(width: 1_800, height: 1_100),
            visibleFrameSize: CGSize(width: 2_400, height: 1_400)
        )
        #expect(maximumTarget == CGSize(width: 1_480, height: 833))

        let clamped = PlayerWindowPresentationPolicy.frameKeepingCenter(
            currentFrame: CGRect(x: 850, y: 550, width: 1_200, height: 800),
            targetFrameSize: CGSize(width: 1_000, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_400, height: 900)
        )
        #expect(clamped.maxX <= 1_400)
        #expect(clamped.maxY <= 900)
        #expect(clamped.minX >= 0)
        #expect(clamped.minY >= 0)
    }

    @Test
    func testPlayerNavigationDoubleClickUsesWindowZoomRegionOnly() {
        let referenceLayout = CGRect(
            origin: .zero,
            size: PlayerHUDLayoutPolicy.referenceSize
        )
        let windowHeight = referenceLayout.height

        #expect(MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 400, y: windowHeight - 32),
            contentLayoutRect: referenceLayout,
            windowFrameHeight: windowHeight,
            isPlaybackPresented: true
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 400, y: windowHeight - 43),
            contentLayoutRect: referenceLayout,
            windowFrameHeight: windowHeight,
            isPlaybackPresented: true
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 100, y: windowHeight - 20),
            contentLayoutRect: referenceLayout,
            windowFrameHeight: windowHeight,
            isPlaybackPresented: true
        ))
    }

    @Test
    func testPlayerNavigationZoomRegionTracksScaledHUDHeight() {
        let minimumLayoutSize = PlayerHUDLayoutPolicy.minimumWindowedSize
        let scaledHeight = MainWindowTitlebarInteractionPolicy.playerNavigationRegionHeight(
            contentLayoutSize: minimumLayoutSize
        )
        let expectedHeight = PlayerHUDVisualPolicy.topBarHeight
            * PlayerHUDLayoutPolicy.minimumWindowedScale

        #expect(abs(scaledHeight - expectedHeight) < 0.0001)
        #expect(MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 400, y: minimumLayoutSize.height - scaledHeight + 0.5),
            contentLayoutRect: CGRect(origin: .zero, size: minimumLayoutSize),
            windowFrameHeight: minimumLayoutSize.height,
            isPlaybackPresented: true
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.contains(
            locationInWindow: CGPoint(x: 400, y: minimumLayoutSize.height - scaledHeight - 0.5),
            contentLayoutRect: CGRect(origin: .zero, size: minimumLayoutSize),
            windowFrameHeight: minimumLayoutSize.height,
            isPlaybackPresented: true
        ))
    }

    @Test
    func testWindowZoomIgnoresFullscreenAndNonDoubleClicks() {
        #expect(MainWindowTitlebarInteractionPolicy.shouldToggleZoom(clickCount: 2))
        #expect(!MainWindowTitlebarInteractionPolicy.shouldToggleZoom(
            clickCount: 2,
            isFullScreen: true
        ))
        #expect(!MainWindowTitlebarInteractionPolicy.shouldToggleZoom(clickCount: 1))
    }

    @Test
    func testHUDVisualTokensTrackOpenDesignGeometry() {
        #expect(PlayerHUDVisualPolicy.topBarHeight == 42)
        #expect(PlayerHUDVisualPolicy.topBarBackButtonLeadingInset == 156)
        #expect(PlayerHUDVisualPolicy.topBarVerticalPadding == 0)
        #expect(PlayerHUDVisualPolicy.topTitleGap == 8)
        #expect(PlayerHUDVisualPolicy.topBrandIconSize == 18)
        #expect(PlayerHUDVisualPolicy.topBrandIconGap == 6)
        #expect(PlayerHUDVisualPolicy.topTitleFontSize == 20)
        #expect(PlayerHUDVisualPolicy.topBackFontSize == 12)
        #expect(PlayerHUDVisualPolicy.topRouteFontSize == 11)
        #expect(PlayerHUDVisualPolicy.topBackButtonHeight == 30)
        #expect(PlayerHUDVisualPolicy.topBackButtonHorizontalPadding == 10)
        #expect(PlayerHUDVisualPolicy.topRouteChipHeight == 28)
        #expect(PlayerHUDVisualPolicy.topRouteChipHorizontalPadding == 8)
        #expect(PlayerHUDVisualPolicy.topBackIconSize == 14)
        #expect(PlayerHUDVisualPolicy.topRouteIconSize == 12)
        #expect(PlayerHUDVisualPolicy.topControlCornerRadius == 8)
        #expect(PlayerHUDVisualPolicy.bottomHorizontalInset == 22)
        #expect(PlayerHUDVisualPolicy.bottomBottomInset == 20)
        #expect(PlayerHUDVisualPolicy.bottomCornerRadius == 28)
        #expect(PlayerHUDVisualPolicy.bottomMinHeight == 202)
        #expect(PlayerHUDVisualPolicy.bottomHorizontalPadding == 23)
        #expect(PlayerHUDVisualPolicy.bottomTopPadding == 19)
        #expect(PlayerHUDVisualPolicy.bottomBottomPadding == 18)
        #expect(PlayerHUDVisualPolicy.progressPlayColumnWidth == 58)
        #expect(PlayerHUDVisualPolicy.progressTrackTimeWidth == 82)
        #expect(PlayerHUDVisualPolicy.progressTimeFontSize == 14)
        #expect(PlayerHUDVisualPolicy.progressPlayButtonSize == 48)
        #expect(PlayerHUDVisualPolicy.progressPlayGlyphSize == 26)
        #expect(PlayerHUDVisualPolicy.timelineHeight == 32)
        #expect(PlayerHUDVisualPolicy.timelineTrackHeight == 6)
        #expect(PlayerHUDVisualPolicy.timelineThumbSize == 17)
        #expect(PlayerHUDVisualPolicy.progressRowSpacing == 18)
        #expect(PlayerHUDVisualPolicy.controlGridGap == 12)
        #expect(PlayerHUDVisualPolicy.controlGridDividerWidth == 1)
        #expect(PlayerHUDVisualPolicy.controlClusterGap == 13)
        #expect(PlayerHUDVisualPolicy.skipClusterGap == 13)
        #expect(PlayerHUDVisualPolicy.featureClusterGap == 6)
        #expect(PlayerHUDVisualPolicy.functionDividerHeight == 82)
        #expect(PlayerHUDVisualPolicy.statusBadgeBottomOffset == 252)
        #expect(PlayerHUDVisualPolicy.iconControlWidth == 66)
        #expect(PlayerHUDVisualPolicy.iconControlHeight == 92)
        #expect(PlayerHUDVisualPolicy.iconRowHeight == 38)
        #expect(PlayerHUDVisualPolicy.controlLabelFontSize == 13)
        #expect(PlayerHUDVisualPolicy.controlDetailFontSize == 11)
        #expect(PlayerHUDVisualPolicy.controlLabelHeight == 16)
        #expect(PlayerHUDVisualPolicy.controlDetailHeight == 14)
        #expect(PlayerHUDVisualPolicy.menuIconBoxSize == 38)
        #expect(PlayerHUDVisualPolicy.menuGlyphSize == 26)
        #expect(PlayerHUDVisualPolicy.iconGlyphStrokeWidth == 1.7)
        #expect(PlayerHUDVisualPolicy.menuGlyphStrokeWidth == 1.65)
        #expect(PlayerHUDVisualPolicy.primaryGlyphStrokeWidth == 2)
        #expect(PlayerHUDVisualPolicy.openDesignGlyphStrokeWidth == 1.65)
        #expect(PlayerHUDVisualPolicy.skipGlyphViewBoxSize == 32)
        #expect(PlayerHUDVisualPolicy.skipIconBoxSize == 38)
        #expect(PlayerHUDVisualPolicy.skipIconSize == 27)
        #expect(PlayerHUDVisualPolicy.skipIconStrokeWidth == 1.5)
        #expect(PlayerHUDVisualPolicy.skipIconTextSize == 12)
        #expect(PlayerHUDVisualPolicy.skipButtonHeight == 62)
        #expect(PlayerHUDVisualPolicy.timelineSkipMarkerDotSize == 10)
        #expect(PlayerHUDVisualPolicy.timelineSkipMarkerTickWidth == 2)
        #expect(PlayerHUDVisualPolicy.timelineSkipMarkerTickHeight == 19)
        #expect(PlayerHUDVisualPolicy.timelineSkipMarkerHeight == 30)
        #expect(PlayerHUDVisualPolicy.statusBadgeFontSize == 14)
        #expect(PlayerHUDVisualPolicy.statusBadgeMinHeight == 38)
        #expect(PlayerHUDVisualPolicy.statusBadgeHorizontalPadding == 12)
        #expect(PlayerHUDVisualPolicy.drawerWidth == 480)
        #expect(PlayerHUDVisualPolicy.drawerTopInset == 30)
        #expect(PlayerHUDVisualPolicy.drawerBottomInset == 34)
        #expect(PlayerHUDVisualPolicy.drawerHorizontalInset == 22)
        #expect(PlayerHUDVisualPolicy.drawerCornerRadius == 24)
        #expect(PlayerHUDVisualPolicy.drawerContentPadding == 22)
        #expect(PlayerHUDVisualPolicy.drawerTitleFontSize == 24)
        #expect(PlayerHUDVisualPolicy.drawerCloseButtonSize == 42)
        #expect(PlayerHUDVisualPolicy.drawerCloseButtonCornerRadius == 13)
        #expect(PlayerHUDVisualPolicy.drawerHeaderBottomPadding == 14)
        #expect(PlayerHUDVisualPolicy.drawerHeaderBottomSpacing == 16)
        #expect(PlayerHUDVisualPolicy.drawerSectionSpacing == 12)
        #expect(PlayerHUDVisualPolicy.drawerSectionPadding == 14)
        #expect(PlayerHUDVisualPolicy.drawerSectionCornerRadius == 16)
        #expect(PlayerHUDVisualPolicy.drawerControlCornerRadius == 12)
        #expect(PlayerHUDVisualPolicy.drawerControlMinHeight == 46)
        #expect(PlayerHUDVisualPolicy.drawerSegmentMinHeight == 39)
        #expect(PlayerHUDVisualPolicy.drawerEpisodeMinHeight == 54)
        #expect(PlayerHUDVisualPolicy.drawerGridGap == 9)
        #expect(PlayerHUDVisualPolicy.drawerSpeedColumnCount == 5)
        #expect(PlayerHUDVisualPolicy.drawerSourceColumnCount == 4)
        #expect(PlayerHUDVisualPolicy.drawerEpisodeColumnCount == 4)
        #expect(PlayerHUDVisualPolicy.drawerSwitchWidth == 46)
        #expect(PlayerHUDVisualPolicy.drawerSwitchHeight == 26)
        #expect(PlayerHUDVisualPolicy.drawerStatusCornerRadius == 15)
        #expect(PlayerHUDVisualPolicy.episodePosterWidth == 92)
        #expect(PlayerHUDVisualPolicy.episodePosterHeight == 126)
        #expect(PlayerHUDVisualPolicy.episodePosterCornerRadius == 12)
        #expect(PlayerHUDVisualPolicy.episodePosterGap == 16)
        #expect(PlayerHUDVisualPolicy.skipDialogTitleFontSize == 22)
        #expect(PlayerHUDVisualPolicy.skipDialogCopyFontSize == 14)
        #expect(PlayerHUDVisualPolicy.skipDialogInputFontSize == 25)
    }

    @Test
    func testSVGArcSweepMapsToSwiftUICoordinateConvention() {
        #expect(PlayerHUDVisualPolicy.swiftUIClockwise(forSVGSweepClockwise: true) == false)
        #expect(PlayerHUDVisualPolicy.swiftUIClockwise(forSVGSweepClockwise: false) == true)
    }

    @Test
    func testOpenDesignSVGIconGeometryIsCodified() {
        #expect(PlayerHUDVisualPolicy.rewindArcStartPoint == CGPoint(x: 3.8, y: 8.7))
        #expect(PlayerHUDVisualPolicy.rewindArcEndPoint == CGPoint(x: 5.4, y: 17))
        #expect(PlayerHUDVisualPolicy.forwardArcStartPoint == CGPoint(x: 20.2, y: 8.7))
        #expect(PlayerHUDVisualPolicy.forwardArcEndPoint == CGPoint(x: 18.6, y: 17))
        #expect(PlayerHUDVisualPolicy.tenSecondArcRadius == 8)
        #expect(abs(PlayerHUDVisualPolicy.tenSecondTextSizeRatio - (7.0 / 24.0)) < 0.0001)
        #expect(PlayerHUDVisualPolicy.speedArcStartPoint == CGPoint(x: 5, y: 17))
        #expect(PlayerHUDVisualPolicy.speedArcEndPoint == CGPoint(x: 19, y: 17))
        #expect(PlayerHUDVisualPolicy.speedArcRadius == 8)
        #expect(PlayerHUDVisualPolicy.speedNeedleStartPoint == CGPoint(x: 12, y: 13))
        #expect(PlayerHUDVisualPolicy.speedNeedleEndPoint == CGPoint(x: 16, y: 9))
        #expect(PlayerHUDVisualPolicy.speedBaseStartPoint == CGPoint(x: 8, y: 17))
        #expect(PlayerHUDVisualPolicy.speedBaseEndPoint == CGPoint(x: 16, y: 17))
        #expect(PlayerHUDVisualPolicy.skipArcStartPoint == CGPoint(x: 22.8, y: 25.3))
        #expect(PlayerHUDVisualPolicy.skipArcEndPoint == CGPoint(x: 26.8, y: 12.6))
        #expect(PlayerHUDVisualPolicy.skipArcRadius == 11.3)
        #expect(PlayerHUDVisualPolicy.skipArrowMarkerScale == 0.72)
        #expect(abs(PlayerHUDVisualPolicy.skipArrowTipPoint.x - 28.661632) < 0.000001)
        #expect(abs(PlayerHUDVisualPolicy.skipArrowTipPoint.y - 18.126864) < 0.000001)
        #expect(abs(PlayerHUDVisualPolicy.skipArrowUpperPoint.x - 29.563432) < 0.000001)
        #expect(abs(PlayerHUDVisualPolicy.skipArrowUpperPoint.y - 11.669184) < 0.000001)
        #expect(abs(PlayerHUDVisualPolicy.skipArrowLowerPoint.x - 24.036568) < 0.000001)
        #expect(abs(PlayerHUDVisualPolicy.skipArrowLowerPoint.y - 13.530816) < 0.000001)
    }

    @Test
    func testHUDColorAndTransparencyTokens() {
        #expect(PlayerHUDPalette.backgroundHex == 0x03050F)
        #expect(PlayerHUDPalette.surfaceHex == 0x1B2037)
        #expect(PlayerHUDPalette.accentHex == 0x53D8F3)
        #expect(PlayerHUDPalette.lavenderHex == 0xA69AD8)
        #expect(PlayerHUDPalette.foregroundHex == 0xEFF2F6)
        #expect(PlayerHUDPalette.mutedHex == 0xABB2BD)
        #expect(PlayerHUDVisualPolicy.controlForegroundOpacity == 0.88)
        #expect(PlayerHUDVisualPolicy.controlMutedOpacity == 0.70)
        #expect(PlayerHUDVisualPolicy.disabledControlOpacity == 0.42)
        #expect(PlayerHUDVisualPolicy.activeLavenderBackgroundOpacity == 0.11)
        #expect(PlayerHUDVisualPolicy.activeLavenderBorderOpacity == 0.38)
        #expect(PlayerHUDVisualPolicy.activeLavenderShadowOpacity == 0.18)
        #expect(PlayerHUDVisualPolicy.primaryAccentBackgroundOpacity == 0.17)
        #expect(PlayerHUDVisualPolicy.primaryAccentBorderOpacity == 0.72)
        #expect(PlayerHUDVisualPolicy.primaryAccentShadowOpacity == 0.58)
        #expect(PlayerHUDVisualPolicy.primaryAccentShadowRadius == 34)
        #expect(PlayerHUDVisualPolicy.hudGlassMaterialOpacity == 0.58)
        #expect(PlayerHUDVisualPolicy.hudGlassSurfaceOpacity == 0.08)
        #expect(PlayerHUDVisualPolicy.topBarMaterialOpacity == PlayerHUDVisualPolicy.hudGlassMaterialOpacity)
        #expect(PlayerHUDVisualPolicy.topBarBackgroundOpacity == PlayerHUDVisualPolicy.hudGlassSurfaceOpacity)
        #expect(PlayerHUDVisualPolicy.topBarBorderOpacity == 0.07)
        #expect(PlayerHUDVisualPolicy.topControlBackgroundOpacity == 0.08)
        #expect(PlayerHUDVisualPolicy.topControlBorderOpacity == 0.16)
        #expect(PlayerHUDVisualPolicy.topRouteBorderOpacity == 0.34)
        #expect(PlayerHUDVisualPolicy.glassPanelMaterialOpacity == PlayerHUDVisualPolicy.hudGlassMaterialOpacity)
        #expect(PlayerHUDVisualPolicy.glassPanelSurfaceOpacity == PlayerHUDVisualPolicy.hudGlassSurfaceOpacity)
        #expect(PlayerHUDVisualPolicy.drawerGlassMaterialOpacity == PlayerHUDVisualPolicy.hudGlassMaterialOpacity)
        #expect(PlayerHUDVisualPolicy.drawerGlassSurfaceOpacity == PlayerHUDVisualPolicy.hudGlassSurfaceOpacity)
        #expect(PlayerHUDVisualPolicy.bottomGlassMaterialOpacity == PlayerHUDVisualPolicy.hudGlassMaterialOpacity)
        #expect(PlayerHUDVisualPolicy.bottomGlassSurfaceOpacity == PlayerHUDVisualPolicy.hudGlassSurfaceOpacity)
        #expect(PlayerHUDVisualPolicy.bottomGlassTopHighlightOpacity == 0.06)
        #expect(PlayerHUDVisualPolicy.bottomGlassBottomInsetOpacity == 0.10)
        #expect(PlayerHUDVisualPolicy.bottomGlassShadowOpacity == 0.16)
        #expect(PlayerHUDVisualPolicy.bottomGlassShadowRadius == 48)
        #expect(PlayerHUDVisualPolicy.timelineTrackBaseOpacity == 0.16)
        #expect(PlayerHUDVisualPolicy.timelineTrackBufferOpacity == 0.52)
        #expect(PlayerHUDVisualPolicy.timelineTrackInsetOpacity == 0.20)
        #expect(PlayerHUDVisualPolicy.timelineThumbBorderOpacity == 0.68)
        #expect(PlayerHUDVisualPolicy.timelineThumbShadowOpacity == 0.72)
        #expect(PlayerHUDVisualPolicy.timelineThumbShadowRadius == 24)
        #expect(PlayerHUDVisualPolicy.timelineSkipMarkerOpeningFillOpacity == 0.74)
        #expect(PlayerHUDVisualPolicy.timelineSkipMarkerOpeningLineOpacity == 0.58)
        #expect(PlayerHUDVisualPolicy.timelineSkipMarkerEndingFillOpacity == 0.46)
        #expect(PlayerHUDVisualPolicy.timelineSkipMarkerEndingLineOpacity == 0.60)
    }

    @Test
    func testPlaybackActivityUsesStableCircularHUDAndSharedGlassOpacity() {
        #expect(PlayerPlaybackActivityVisualPolicy.diameter == 196)
        #expect(PlayerPlaybackActivityVisualPolicy.ringInset == 12)
        #expect(PlayerPlaybackActivityVisualPolicy.ringDiameter == 172)
        #expect(PlayerPlaybackActivityVisualPolicy.ringLineWidth == 3)
        #expect(PlayerPlaybackActivityVisualPolicy.contentWidth == 126)
        #expect(PlayerPlaybackActivityVisualPolicy.indeterminateArcFraction == 0.24)
        #expect(PlayerPlaybackActivityVisualPolicy.indeterminateRotationDuration == 1.45)
        #expect(PlayerPlaybackActivityVisualPolicy.materialOpacity == PlayerHUDVisualPolicy.bottomGlassMaterialOpacity)
        #expect(PlayerPlaybackActivityVisualPolicy.surfaceOpacity == PlayerHUDVisualPolicy.bottomGlassSurfaceOpacity)
        #expect(PlayerPlaybackActivityVisualPolicy.rimOpacity == 0.08)
        #expect(PlayerPlaybackActivityVisualPolicy.innerRimOpacity == 0.025)
    }

    @Test
    func testFeatureControlsUseUnifiedPopoverAndCyclicButtonSlots() {
        #expect(PlayerHUDVisualPolicy.unifiedFeatureControlSlots == [
            .subtitles,
            .audio,
            .aspectRatio,
            .speed,
            .volume,
            .settings,
            .fullscreen,
        ])
        #expect(PlayerHUDVisualPolicy.menuControlWidth == 70)
        #expect(PlayerHUDVisualPolicy.menuControlHeight == 92)
        #expect(PlayerHUDVisualPolicy.menuIconBoxSize == 38)
        #expect(PlayerHUDVisualPolicy.menuGlyphSize == 26)
        #expect(PlayerHUDVisualPolicy.menuGlyphStrokeWidth == 1.65)
        #expect(PlayerHUDVisualPolicy.popoverBackedControlSlots == [.subtitles, .audio])
        #expect(PlayerHUDVisualPolicy.cyclicControlSlots == [.aspectRatio, .speed])
        #expect(PlayerHUDVisualPolicy.popoverBackedControlSlots.allSatisfy { PlayerHUDVisualPolicy.unifiedFeatureControlSlots.contains($0) })
        #expect(PlayerHUDVisualPolicy.cyclicControlSlots.allSatisfy { PlayerHUDVisualPolicy.unifiedFeatureControlSlots.contains($0) })
    }

    @Test
    func testTrackPopoverKeepsRowsVisibleAndCapsLongLists() {
        #expect(PlayerHUDVisualPolicy.trackPopoverArrowEdge == .top)
        #expect(PlayerHUDVisualPolicy.trackPopoverListHeight(optionCount: 0) == 36)
        #expect(PlayerHUDVisualPolicy.trackPopoverListHeight(optionCount: 1) == 36)
        #expect(PlayerHUDVisualPolicy.trackPopoverListHeight(optionCount: 2) == 76)
        #expect(PlayerHUDVisualPolicy.trackPopoverListHeight(optionCount: 20) == 280)
    }

    @Test
    func testAudioStatusAddsItsKindOnlyWhenTheTrackNameNeedsIt() {
        let metadataTrack = PlayerTrackInfo(id: "1", kind: .audio, language: "eng", format: "aac")
        let unnamedTrack = PlayerTrackInfo(id: "2", kind: .audio)

        #expect(PlayerHUDVisualPolicy.audioStatusText(for: metadataTrack) == "音轨 ENG · AAC")
        #expect(PlayerHUDVisualPolicy.audioStatusText(for: unnamedTrack) == "音轨 2")
    }

    @Test
    func testHUDLayersKeepTheirViewportEdgeAnchorsAroundCenteredCanvas() {
        let fullscreen16x10 = CGSize(width: 1_280, height: 800)
        let scaledHeight = PlayerHUDLayoutPolicy.scaledSize(for: fullscreen16x10).height
        let unusedHeight = fullscreen16x10.height - scaledHeight
        let centeredOffset = PlayerHUDLayoutPolicy.verticalOffset(for: fullscreen16x10, anchor: .center)
        let bottomOffset = PlayerHUDLayoutPolicy.verticalOffset(for: fullscreen16x10, anchor: .bottom)

        #expect(centeredOffset > 0)
        #expect(PlayerHUDLayoutPolicy.verticalOffset(for: fullscreen16x10, anchor: .top) == 0)
        #expect(abs(bottomOffset - unusedHeight) < 0.0001)
        #expect(bottomOffset > centeredOffset)
        #expect(PlayerHUDLayoutPolicy.verticalOffset(for: PlayerHUDLayoutPolicy.referenceSize, anchor: .center) == 0)
        #expect(PlayerHUDLayoutPolicy.verticalOffset(for: PlayerHUDLayoutPolicy.referenceSize, anchor: .bottom) == 0)

        let wideFullscreen = CGSize(width: 1_920, height: 1_080)
        let backdropSize = PlayerHUDVisualPolicy.topBarBackdropSize(for: wideFullscreen)
        #expect(backdropSize.width == wideFullscreen.width)
        #expect(backdropSize.height == PlayerHUDVisualPolicy.topBarHeight)
        #expect(backdropSize.width > PlayerHUDLayoutPolicy.scaledSize(for: wideFullscreen).width)
    }

    @Test
    func testAspectAndSpeedControlsAdvanceAndWrap() {
        #expect(PlayerHUDInteractionPolicy.nextAspectMode(after: .fit) == .fill)
        #expect(PlayerHUDInteractionPolicy.nextAspectMode(after: .fill) == .wide16x9)
        #expect(PlayerHUDInteractionPolicy.nextAspectMode(after: .wide16x9) == .classic4x3)
        #expect(PlayerHUDInteractionPolicy.nextAspectMode(after: .classic4x3) == .fit)

        #expect(PlayerHUDInteractionPolicy.nextPlaybackSpeed(after: 1.0) == 1.25)
        #expect(PlayerHUDInteractionPolicy.nextPlaybackSpeed(after: 5.0) == 0.5)
        #expect(PlayerHUDInteractionPolicy.nextPlaybackSpeed(after: 1.1) == 1.25)
    }

    @Test @MainActor
    func testPlayerViewObservesInjectedPlayerState() {
        let playerState = PlayerState()
        let view = PlayerView(
            playerState: playerState,
            windowContext: PlayerWindowContext()
        )

        #expect(view.playerState === playerState)
    }

    @Test @MainActor
    func testLivePlayerViewObservesInjectedPlayerState() {
        let playerState = PlayerState()
        let view = LiveStreamView(
            playerState: playerState,
            windowContext: PlayerWindowContext(),
            onExit: {}
        )

        #expect(view.playerState === playerState)
    }

    @Test @MainActor
    func testAppStateBindsDedicatedPlaybackStatesAndKeepsBothWindowsPresented() {
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false)

        #expect(appState.playerState !== appState.livePlayerState)
        #expect(MPVPlayerEngine.vod.playerState === appState.playerState)
        #expect(MPVPlayerEngine.live.playerState === appState.livePlayerState)

        appState.isPlayerPresented = true
        appState.presentLivePlayer()

        #expect(appState.isPlayerPresented)
        #expect(appState.isLivePlayerPresented)
    }

    @Test
    func testControlGridColumnsTrackOpenDesignCSSFractions() {
        let minimumWidth = PlayerHUDVisualPolicy.episodeColumnMinimumWidth
            + PlayerHUDVisualPolicy.jumpColumnMinimumWidth
            + PlayerHUDVisualPolicy.skipColumnMinimumWidth
            + PlayerHUDVisualPolicy.featureColumnMinimumWidth
            + PlayerHUDVisualPolicy.controlGridDividerWidth * 3
            + PlayerHUDVisualPolicy.controlGridGap * 6
        let minimumColumns = PlayerHUDVisualPolicy.controlGridColumns(availableWidth: minimumWidth)
        #expect(minimumColumns.episode == 210)
        #expect(minimumColumns.jump == 136)
        #expect(minimumColumns.skip == 144)
        #expect(minimumColumns.feature == 520)

        let expandedColumns = PlayerHUDVisualPolicy.controlGridColumns(availableWidth: minimumWidth + 214)
        #expect(abs(expandedColumns.episode - 258) < 0.0001)
        #expect(abs(expandedColumns.jump - 168) < 0.0001)
        #expect(abs(expandedColumns.skip - 178) < 0.0001)
        #expect(abs(expandedColumns.feature - 620) < 0.0001)
    }

    @Test
    func testSkipGroupKeepsIntroAndOutroPlaceholdersWhenBothSkipValuesAreZero() {
        #expect(PlayerHUDVisualPolicy.visibleSkipKinds(openingSkip: 0, endingSkip: 0) == [.opening, .ending])
    }

    @Test
    func testSkipGroupAlwaysShowsBothChipsAndBoundaries() {
        #expect(PlayerHUDVisualPolicy.visibleSkipKinds(openingSkip: 30, endingSkip: 0) == [.opening, .ending])
        #expect(PlayerHUDVisualPolicy.visibleSkipKinds(openingSkip: 0, endingSkip: 45) == [.opening, .ending])
        #expect(PlayerHUDVisualPolicy.visibleSkipKinds(openingSkip: 30, endingSkip: 45) == [.opening, .ending])
    }

    @Test
    func testZeroSecondSkipUsesZeroTimeTextAndDisablesSeek() {
        #expect(PlayerHUDVisualPolicy.skipDurationText(seconds: 0) == "00:00")
        #expect(PlayerHUDVisualPolicy.skipDurationText(seconds: 90) == "01:30")
        #expect(PlayerHUDVisualPolicy.skipDurationText(seconds: 3_661) == "1:01:01")
        #expect(PlayerHUDVisualPolicy.isSkipActionEnabled(seconds: 0) == false)
        #expect(PlayerHUDVisualPolicy.isSkipActionEnabled(seconds: 1) == true)
    }

    @Test
    func testSkipSlotKeepsIntroAndOutroControlsStable() {
        #expect(PlayerHUDVisualPolicy.skipAnchorWidth == 144)
        #expect(PlayerHUDVisualPolicy.skipChipWidth == 66)
        #expect(PlayerHUDVisualPolicy.skipAnchorWidth >= PlayerHUDVisualPolicy.skipChipWidth * 2)
    }

    @Test
    func testPlayerKeyboardShortcutsMapPlaybackSeekAndVolumeKeys() {
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 49) == .togglePlayPause)
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 123) == .seekBackward)
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 124) == .seekForward)
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 125) == .volumeDown)
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 126) == .volumeUp)
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 36) == .enterFullScreen)
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 76) == .enterFullScreen)
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 53) == .exitFullScreen)
        #expect(PlayerKeyboardShortcutPolicy.seekInterval == 10)
        #expect(PlayerKeyboardShortcutPolicy.volumeStep == 0.05)
    }

    @Test
    func testPlayerKeyboardShortcutsIgnoreModifiedKeysAndRepeatedSpace() {
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 49, modifierFlags: [.command]) == nil)
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 123, modifierFlags: [.shift]) == nil)
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 126, modifierFlags: [.function]) == .volumeUp)
        #expect(PlayerKeyboardShortcutPolicy.command(forKeyCode: 0) == nil)
        #expect(PlayerKeyboardShortcutPolicy.shouldDispatch(.togglePlayPause, isRepeat: false))
        #expect(!PlayerKeyboardShortcutPolicy.shouldDispatch(.togglePlayPause, isRepeat: true))
        #expect(PlayerKeyboardShortcutPolicy.shouldDispatch(.seekForward, isRepeat: true))
        #expect(PlayerKeyboardShortcutPolicy.shouldDispatch(.enterFullScreen, isRepeat: false))
        #expect(!PlayerKeyboardShortcutPolicy.shouldDispatch(.enterFullScreen, isRepeat: false, isFullScreen: true))
        #expect(!PlayerKeyboardShortcutPolicy.shouldDispatch(.exitFullScreen, isRepeat: false))
        #expect(PlayerKeyboardShortcutPolicy.shouldDispatch(.exitFullScreen, isRepeat: false, isFullScreen: true))
    }

    @Test
    func testPlayerPlaybackToggleAndScrollVolumeCommandsAreDeterministic() {
        let paused = PlayerKeyboardShortcutPolicy.toggledPlaybackState(from: true)
        let resumed = PlayerKeyboardShortcutPolicy.toggledPlaybackState(from: paused)

        #expect(!paused)
        #expect(resumed)
        #expect(PlayerScrollShortcutPolicy.command(forDeltaY: 1) == .volumeUp)
        #expect(PlayerScrollShortcutPolicy.command(forDeltaY: -1) == .volumeDown)
        #expect(PlayerScrollShortcutPolicy.command(forDeltaY: 0) == nil)
        #expect(PlayerScrollShortcutPolicy.deviceDeltaY(
            fromScrollingDeltaY: 4,
            isDirectionInvertedFromDevice: false
        ) == 4)
        #expect(PlayerScrollShortcutPolicy.deviceDeltaY(
            fromScrollingDeltaY: -4,
            isDirectionInvertedFromDevice: true
        ) == 4)
        #expect(PlayerScrollShortcutPolicy.preciseDeltaThreshold == 10)
    }

    @Test
    func testPlayerPointerShortcutsMapSingleClickToPlaybackAndDoubleClickToFullScreen() {
        #expect(PlayerPointerShortcutPolicy.singleClickCount == 1)
        #expect(PlayerPointerShortcutPolicy.fullScreenClickCount == 2)
        #expect(PlayerPointerShortcutPolicy.action(forClickCount: 1) == .togglePlayPause)
        #expect(PlayerPointerShortcutPolicy.action(forClickCount: 2) == .toggleFullScreen)
        #expect(PlayerPointerShortcutPolicy.action(forClickCount: 0) == nil)
        #expect(PlayerPointerShortcutPolicy.action(forClickCount: 3) == nil)
    }

    @Test
    func testPlayerVideoGesturesRequirePlaybackAndNoBlockingUI() {
        #expect(PlayerPointerShortcutPolicy.videoGestureMask(
            hasPlayback: true,
            hasBlockingUI: false
        ) == .all)
        #expect(PlayerPointerShortcutPolicy.videoGestureMask(
            hasPlayback: false,
            hasBlockingUI: false
        ) == .none)
        #expect(PlayerPointerShortcutPolicy.videoGestureMask(
            hasPlayback: true,
            hasBlockingUI: true
        ) == .none)
    }

    @Test
    func testLivePlayerOnlySeeksFiniteRecordedTimelines() {
        #expect(!LivePlayerInteractionPolicy.canSeek(duration: 0))
        #expect(!LivePlayerInteractionPolicy.canSeek(duration: -Double.infinity))
        #expect(!LivePlayerInteractionPolicy.canSeek(duration: Double.infinity))
        #expect(!LivePlayerInteractionPolicy.canSeek(duration: Double.nan))
        #expect(LivePlayerInteractionPolicy.canSeek(duration: 3_600))
    }

    @Test
    func testLivePlayerLeavesEmptyStateControlsInteractive() {
        #expect(LivePlayerInteractionPolicy.videoGestureMask(hasSelectedChannel: false) == .none)
        #expect(LivePlayerInteractionPolicy.videoGestureMask(hasSelectedChannel: true) == .all)
        #expect(LivePlayerInteractionPolicy.videoGestureMask(
            hasSelectedChannel: true,
            hasBlockingUI: true
        ) == .none)
    }

    @Test
    func testLiveGuideUsesReadableTwoColumnLayoutAndPlayerScrollbarTheme() {
        let wideDrawerWidth = LiveGuideLayoutPolicy.drawerWidth(availableWidth: 2_048)
        let wideGroupWidth = LiveGuideLayoutPolicy.groupWidth(drawerWidth: wideDrawerWidth)
        let wideChannelWidth = LiveGuideLayoutPolicy.channelWidth(
            drawerWidth: wideDrawerWidth,
            groupWidth: wideGroupWidth
        )

        #expect(wideDrawerWidth == 860)
        #expect(wideGroupWidth == 260)
        #expect(wideChannelWidth == 566)

        let compactDrawerWidth = LiveGuideLayoutPolicy.drawerWidth(availableWidth: 720)
        let compactGroupWidth = LiveGuideLayoutPolicy.groupWidth(drawerWidth: compactDrawerWidth)
        let compactChannelWidth = LiveGuideLayoutPolicy.channelWidth(
            drawerWidth: compactDrawerWidth,
            groupWidth: compactGroupWidth
        )

        #expect(compactDrawerWidth == 680)
        #expect(compactGroupWidth == 230)
        #expect(compactChannelWidth == 416)

        switch LiveGuideLayoutPolicy.scrollbarTheme {
        case .player:
            break
        default:
            Issue.record("直播频道指南应复用点播播放器滚动条主题")
        }
    }

    @Test @MainActor
    func testLivePlayerWindowRequestsLeaveCurrentSidebarPageIntact() async {
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
        appState.selectedTab = .favorites
        let initialRequestSerial = appState.livePlayerOpenRequestSerial
        let sessionID = UUID()

        #expect(AppState.shouldContinueLivePlayback(
            sessionID: sessionID,
            currentSessionID: sessionID,
            isLivePlayerPresented: true
        ))
        #expect(!AppState.shouldContinueLivePlayback(
            sessionID: sessionID,
            currentSessionID: UUID(),
            isLivePlayerPresented: true
        ))
        #expect(!AppState.shouldContinueLivePlayback(
            sessionID: sessionID,
            currentSessionID: sessionID,
            isLivePlayerPresented: false
        ))

        appState.presentLivePlayer()

        #expect(appState.isLivePlayerPresented)
        #expect(appState.selectedTab == .favorites)
        #expect(appState.livePlayerOpenRequestSerial == initialRequestSerial + 1)

        appState.presentLivePlayer()

        #expect(appState.livePlayerOpenRequestSerial == initialRequestSerial + 2)

        appState.dismissLivePlayer()

        #expect(!appState.isLivePlayerPresented)
        #expect(appState.selectedTab == .favorites)

        let restorationSerial = appState.livePlayerOpenRequestSerial
        await appState.activateLivePlayerWindow()

        #expect(appState.isLivePlayerPresented)
        #expect(appState.livePlayerOpenRequestSerial == restorationSerial)
        #expect(appState.selectedTab == .favorites)
    }

    @Test
    func testTimelineMarkersAlignWithNativeThumbCenter() {
        #expect(PlayerTimelineMarkerPolicy.markerCenterX(value: 50, duration: 100, trackWidth: 100, thumbWidth: 20) == 50)
        #expect(PlayerTimelineMarkerPolicy.markerCenterX(value: 25, duration: 100, trackWidth: 200, thumbWidth: 20) == 55)
        #expect(PlayerTimelineMarkerPolicy.endingMarkerValue(endingSkipSeconds: 30, duration: 100) == 70)
        #expect(PlayerTimelineMarkerPolicy.endingMarkerValue(endingSkipSeconds: 100, duration: 100) == nil)
    }

    @Test
    func testTimelineMarkersHideWhenUnsetOrInvalid() {
        #expect(PlayerTimelineMarkerPolicy.markerCenterX(value: 0, duration: 100, trackWidth: 100, thumbWidth: 20) == nil)
        #expect(PlayerTimelineMarkerPolicy.markerCenterX(value: 30, duration: 0, trackWidth: 100, thumbWidth: 20) == nil)
        #expect(PlayerTimelineMarkerPolicy.markerCenterX(value: 30, duration: 100, trackWidth: 0, thumbWidth: 20) == nil)
        #expect(PlayerTimelineMarkerPolicy.fillWidth(value: 70, duration: 100, trackWidth: 200) == 140)
        #expect(PlayerTimelineMarkerPolicy.fillWidth(value: 120, duration: 100, trackWidth: 200) == 200)
        #expect(PlayerTimelineMarkerPolicy.fillWidth(value: .nan, duration: 100, trackWidth: 200) == 0)
    }

    @Test
    func testSkipEditorPolicyParsesFormatsClampsAndValidates() {
        #expect(PlayerSkipEditorPolicy.parseTimeText("75") == 75)
        #expect(PlayerSkipEditorPolicy.parseTimeText("01:23") == 83)
        #expect(PlayerSkipEditorPolicy.parseTimeText("1:02:03") == 3_723)
        #expect(PlayerSkipEditorPolicy.parseTimeText("1:99") == nil)
        #expect(PlayerSkipEditorPolicy.formatTime(0) == "00:00")
        #expect(PlayerSkipEditorPolicy.formatTime(3_661) == "1:01:01")
        #expect(PlayerSkipEditorPolicy.clamp(-8, duration: 100) == 0)
        #expect(PlayerSkipEditorPolicy.clamp(120, duration: 100) == 100)
        #expect(PlayerSkipEditorPolicy.isValid(target: .opening, value: 30, openingSkip: 0, endingSkip: 0, duration: 100))
        #expect(PlayerSkipEditorPolicy.isValid(target: .ending, value: 35, openingSkip: 30, endingSkip: 0, duration: 100))
        #expect(!PlayerSkipEditorPolicy.isValid(target: .ending, value: 65, openingSkip: 30, endingSkip: 0, duration: 100))
        #expect(!PlayerSkipEditorPolicy.isValid(target: .opening, value: 60, openingSkip: 30, endingSkip: 35, duration: 100))
        #expect(PlayerSkipEditorPolicy.isValid(target: .ending, value: 0, openingSkip: 30, endingSkip: 0, duration: 100))
        #expect(PlayerSkipEditorPolicy.valueAtCurrentPosition(target: .opening, position: 42.8, duration: 100) == 42)
        #expect(PlayerSkipEditorPolicy.valueAtCurrentPosition(target: .ending, position: 72.8, duration: 100) == 27)
    }

    @Test
    func testCursorVisibilityRequiresActiveUnobstructedPlayback() {
        #expect(PlayerCursorVisibilityPolicy.inactivityInterval == 5)
        #expect(PlayerCursorVisibilityPolicy.shouldHide(
            isPlaying: true,
            isPointerInside: true,
            hasBlockingUI: false,
            isLoading: false
        ))
        #expect(!PlayerCursorVisibilityPolicy.shouldHide(
            isPlaying: false,
            isPointerInside: true,
            hasBlockingUI: false,
            isLoading: false
        ))
        #expect(!PlayerCursorVisibilityPolicy.shouldHide(
            isPlaying: true,
            isPointerInside: false,
            hasBlockingUI: false,
            isLoading: false
        ))
        #expect(!PlayerCursorVisibilityPolicy.shouldHide(
            isPlaying: true,
            isPointerInside: true,
            hasBlockingUI: true,
            isLoading: false
        ))
        #expect(!PlayerCursorVisibilityPolicy.shouldHide(
            isPlaying: true,
            isPointerInside: true,
            hasBlockingUI: false,
            isLoading: true
        ))
    }

    @Test
    func testPlaybackActivityPhaseUsesStablePriorityAndBlockingRules() {
        let sourceLoading = PlayerPlaybackActivityPolicy.vodPhase(
            isSourceLoading: true,
            sourceLoadingMessage: "正在解析播放地址",
            isMediaLoading: true,
            isBuffering: true,
            hasBlockingUI: false
        )
        #expect(sourceLoading.kind == .loading)
        #expect(sourceLoading.title == "正在加载视频")
        #expect(sourceLoading.message == "正在解析播放地址")

        let mediaLoading = PlayerPlaybackActivityPolicy.livePhase(
            isSourceLoading: false,
            sourceLoadingMessage: "",
            isMediaLoading: true,
            isBuffering: true,
            hasBlockingUI: false
        )
        #expect(mediaLoading.kind == .loading)
        #expect(mediaLoading.title == "正在连接直播")

        let buffering = PlayerPlaybackActivityPolicy.vodPhase(
            isSourceLoading: false,
            sourceLoadingMessage: "",
            isMediaLoading: false,
            isBuffering: true,
            hasBlockingUI: false
        )
        #expect(buffering.kind == .buffering)
        #expect(buffering.title == "正在缓冲")

        let blocked = PlayerPlaybackActivityPolicy.vodPhase(
            isSourceLoading: true,
            sourceLoadingMessage: "正在解析播放地址",
            isMediaLoading: true,
            isBuffering: true,
            hasBlockingUI: true
        )
        #expect(blocked == .hidden)
    }

    @Test
    func testPlaybackActivityDelayFormattingAndGesturePassThrough() {
        #expect(PlayerPlaybackActivityPolicy.presentationDelay(for: .loading) == 0)
        #expect(PlayerPlaybackActivityPolicy.presentationDelay(for: .buffering) == 0)
        #expect(PlayerPlaybackActivityPolicy.presentationDelay(for: .hidden) == 0)
        #expect(!PlayerPlaybackActivityPolicy.blocksVideoGestures)

        #expect(PlayerPlaybackActivityPolicy.speedText(bytesPerSecond: nil) == nil)
        #expect(PlayerPlaybackActivityPolicy.speedText(bytesPerSecond: 0) == nil)
        #expect(PlayerPlaybackActivityPolicy.speedText(bytesPerSecond: 512) == "512 B/s")
        #expect(PlayerPlaybackActivityPolicy.speedText(bytesPerSecond: 1_536) == "1.5 KB/s")
        #expect(PlayerPlaybackActivityPolicy.speedText(bytesPerSecond: 2_097_152) == "2.0 MB/s")
        #expect(PlayerPlaybackActivityPolicy.progressText(nil) == nil)
        #expect(PlayerPlaybackActivityPolicy.progressText(0) == nil)
        #expect(PlayerPlaybackActivityPolicy.progressText(0.456) == "46%")
        #expect(PlayerPlaybackActivityPolicy.progressText(1.5) == "100%")
        #expect(PlayerPlaybackActivityPolicy.bufferedAheadText(0) == nil)
        #expect(PlayerPlaybackActivityPolicy.bufferedAheadText(4.25) == "已缓冲 4.3 秒")
        #expect(PlayerPlaybackActivityPolicy.bufferedAheadText(12.4) == "已缓冲 12 秒")

        #expect(PlayerPlaybackActivityPolicy.isActive(
            isSourceLoading: false,
            isMediaLoading: false,
            isBuffering: true
        ))
        #expect(!PlayerPlaybackActivityPolicy.isActive(
            isSourceLoading: false,
            isMediaLoading: false,
            isBuffering: false
        ))
    }

    @Test @MainActor
    func testPlayerStateClampsBufferedTimelineProgress() {
        let state = PlayerState()
        state.position = 20
        state.duration = 100
        state.bufferedUntil = 70
        #expect(state.bufferedPosition == 70)
        #expect(state.bufferedProgress == 0.7)
        #expect(state.bufferedAheadDuration == 50)

        state.bufferedUntil = -10
        #expect(state.bufferedPosition == 20)
        #expect(state.bufferedAheadDuration == 0)
        state.bufferedUntil = .nan
        #expect(state.bufferedPosition == 20)
        #expect(state.bufferedAheadDuration == 0)
        state.bufferedUntil = 120
        #expect(state.bufferedPosition == 100)
        #expect(state.bufferedProgress == 1)
    }

    @Test
    func testVideoAspectModeMapsToMPVProperties() {
        #expect(PlayerVideoAspectMode.fit.mpvVideoAspectOverride == "no")
        #expect(PlayerVideoAspectMode.fit.mpvPanscan == 0)
        #expect(PlayerVideoAspectMode.fill.mpvVideoAspectOverride == "no")
        #expect(PlayerVideoAspectMode.fill.mpvPanscan == 1)
        #expect(PlayerVideoAspectMode.wide16x9.mpvVideoAspectOverride == "16:9")
        #expect(PlayerVideoAspectMode.wide16x9.mpvPanscan == 0)
        #expect(PlayerVideoAspectMode.classic4x3.mpvVideoAspectOverride == "4:3")
        #expect(PlayerVideoAspectMode.classic4x3.mpvPanscan == 0)

        let effectiveModes = PlayerVideoAspectMode.allCases.map {
            "\($0.mpvVideoAspectOverride)|\($0.mpvPanscan)"
        }
        #expect(Set(effectiveModes).count == PlayerVideoAspectMode.allCases.count)
        #expect(Set(PlayerVideoAspectMode.allCases.map(\.menuTitle)).count == PlayerVideoAspectMode.allCases.count)
    }

    @Test @MainActor
    func testPlayerAspectModeDefaultsToOriginalFitMode() {
        #expect(PlayerState().videoAspectMode == .fit)
        #expect(PlayerVideoAspectMode.fit.displayName == "原始")
        #expect(PlayerVideoAspectMode.fit.menuTitle == "原始比例（自动适应）")
    }

    @Test
    func testDanmakuOverlayPolicyLimitsVisibleCuesAndClampsFont() {
        let cues = (0..<180).map { index in
            DanmakuCue(id: "cue-\(index)", timeMs: index * 10, text: "弹幕 \(index)")
        }
        let visible = DanmakuOverlayPolicy.visibleCues(cues, positionMs: 2_000, scrollDurationMs: 7_000, fixedDurationMs: 4_000)
        #expect(visible.count == DanmakuOverlayPolicy.maxVisibleCueCount)
        #expect(visible.first?.id == "cue-60")
        #expect(DanmakuOverlayPolicy.effectiveFontSize(8) == DanmakuOverlayPolicy.minFontSize)
        #expect(DanmakuOverlayPolicy.effectiveFontSize(200) == DanmakuOverlayPolicy.maxFontSize)
    }

    @Test
    func testDanmakuOverlayPolicyKeepsLanesInBoundsForLargeFonts() {
        let laneCount = DanmakuOverlayPolicy.laneCount(containerHeight: 180, fontSize: 240)
        #expect(laneCount >= 1)
        let lane = DanmakuOverlayPolicy.stableLane(for: "same-cue", count: laneCount)
        #expect(lane >= 0)
        #expect(lane < laneCount)
    }

    @Test
    func testWebHomeDemoPageKeepsBridgeOperationsVisibleAndLocal() {
        let html = WebHomeDemoPage.html
        for method in ["search", "history.query", "cache.set", "cache.get", "pan.check", "play"] {
            #expect(html.contains("'\(method)'"))
        }
        #expect(!html.contains("<script src="))
        #expect(!html.contains("Authorization"))
        #expect(!html.contains("Cookie"))
        #expect(!html.contains("token="))
    }

    @Test
    func testVisualRegressionCatalogCoversRequiredSafeSurfaces() {
        #expect(VisualRegressionScenarioCatalog.missingRequiredSurfaces().isEmpty)
        #expect(VisualRegressionScenarioCatalog.unsafeScenarios().isEmpty)
        #expect(VisualRegressionScenarioCatalog.requiredScenarios.count == VisualRegressionSurface.allCases.count)
        #expect(VisualRegressionScenarioCatalog.requiredScenarios.contains { $0.surface == .playbackErrorPanel && $0.stateSummary.contains("sampleStatus") })
        let playerScenario = VisualRegressionScenarioCatalog.requiredScenarios.first { $0.surface == .playerHUD }
        #expect(playerScenario?.viewport == "1480x833")
        #expect(playerScenario?.fixtureAssetPath == "docs/design/player-ui/assets/w700d1q75cms.jpg")
        #expect(playerScenario?.captureStates == [
            "normal",
            "settings-drawer",
            "episode-drawer",
            "skip-dialog",
            "warning",
            "error",
            "loading",
            "buffering",
            "hud-hidden",
        ])
        #expect(playerScenario?.responsiveViewports == [
            "1480x833",
            "1200x675",
            "427x240",
            "fullscreen-16:10",
        ])
    }
}
