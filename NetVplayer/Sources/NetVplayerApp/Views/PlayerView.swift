// NetVplayerApp/Views/PlayerView.swift
// 播放器视图

import SwiftUI
import PlayerEngine
import AppKit
import Models
import Storage
import DanmakuEngine

enum PlayerOverlayLayerPolicy {
    static let referenceCanvas: Double = 5
    static let playbackActivity: Double = 6
}

private enum PlayerOverlayPanel: Equatable {
    case none
    case settings
    case episodes
}

enum PlayerCursorVisibilityPolicy {
    static let inactivityInterval: TimeInterval = 5

    static func shouldHide(
        isPlaying: Bool,
        isPointerInside: Bool,
        hasBlockingUI: Bool,
        isLoading: Bool
    ) -> Bool {
        isPlaying && isPointerInside && !hasBlockingUI && !isLoading
    }
}

@MainActor
enum PlayerCursorController {
    static func hideUntilMouseMoves() {
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    static func restore() {
        NSCursor.setHiddenUntilMouseMoves(false)
    }
}

enum PlayerHUDSkipKind: Equatable {
    case opening
    case ending
}

enum PlayerHUDControlSlot: Equatable {
    case previousEpisode
    case nextEpisode
    case episodeGrid
    case rewind10
    case forward10
    case openingSkip
    case endingSkip
    case subtitles
    case audio
    case aspectRatio
    case speed
    case volume
    case settings
    case fullscreen
}

enum PlayerHUDInteractionPolicy {
    static let playbackSpeeds: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0, 3.0, 5.0]

    static func nextPlaybackSpeed(after current: Float) -> Float {
        guard !playbackSpeeds.isEmpty else { return 1.0 }
        guard let currentIndex = playbackSpeeds.firstIndex(where: { abs($0 - current) < 0.01 }) else {
            return playbackSpeeds.first(where: { $0 > current }) ?? playbackSpeeds[0]
        }
        return playbackSpeeds[(currentIndex + 1) % playbackSpeeds.count]
    }

    static func nextAspectMode(after current: PlayerVideoAspectMode) -> PlayerVideoAspectMode {
        let modes = PlayerVideoAspectMode.allCases
        guard let currentIndex = modes.firstIndex(of: current) else { return .fit }
        return modes[(currentIndex + 1) % modes.count]
    }
}

private enum PlayerHUDCommandDispatcher {
    private static let queue = DispatchQueue(
        label: "com.netvplayer.player-hud-controls",
        qos: .userInteractive
    )

    static func setPlaybackSpeed(_ speed: Float) {
        queue.async {
            MPVPlayerEngine.vod.speed = speed
        }
    }

    static func setVideoAspectMode(_ mode: PlayerVideoAspectMode) {
        queue.async {
            MPVPlayerEngine.vod.setVideoAspectMode(mode)
        }
    }
}

enum PlayerSkipEditorTarget: Equatable {
    case opening
    case ending

    var title: String {
        switch self {
        case .opening:
            return "片头"
        case .ending:
            return "片尾"
        }
    }
}

enum PlayerHUDLayoutPolicy {
    static let referenceSize = CGSize(width: 1_480, height: 833)
    static let minimumWindowedScale: CGFloat = 640.0 / 833.0
    static let maximumWindowedScale: CGFloat = 1

    static var minimumWindowedSize: CGSize {
        CGSize(
            width: referenceSize.width * minimumWindowedScale,
            height: referenceSize.height * minimumWindowedScale
        )
    }

    static func scale(for availableSize: CGSize) -> CGFloat {
        guard availableSize.width > 0, availableSize.height > 0 else { return 0 }
        return min(
            maximumWindowedScale,
            availableSize.width / referenceSize.width,
            availableSize.height / referenceSize.height
        )
    }

    static func scaledSize(for availableSize: CGSize) -> CGSize {
        let scale = scale(for: availableSize)
        return CGSize(
            width: referenceSize.width * scale,
            height: referenceSize.height * scale
        )
    }

    static func verticalOffset(
        for availableSize: CGSize,
        anchor: PlayerHUDCanvasVerticalAnchor
    ) -> CGFloat {
        switch anchor {
        case .top:
            return 0
        case .center:
            return max(0, (availableSize.height - scaledSize(for: availableSize).height) / 2)
        case .bottom:
            return max(0, availableSize.height - scaledSize(for: availableSize).height)
        }
    }
}

enum PlayerHUDCanvasVerticalAnchor: Equatable {
    case top
    case center
    case bottom
}

enum PlayerHUDPalette {
    static let backgroundHex: UInt32 = 0x03050F
    static let surfaceHex: UInt32 = 0x1B2037
    static let accentHex: UInt32 = 0x53D8F3
    static let lavenderHex: UInt32 = 0xA69AD8
    static let foregroundHex: UInt32 = 0xEFF2F6
    static let mutedHex: UInt32 = 0xABB2BD

    static var background: Color { color(backgroundHex) }
    static var surface: Color { color(surfaceHex) }
    static var accent: Color { color(accentHex) }
    static var lavender: Color { color(lavenderHex) }
    static var foreground: Color { color(foregroundHex) }
    static var muted: Color { color(mutedHex) }

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum PlayerHUDVisualPolicy {
    struct ControlGridColumns: Equatable {
        let episode: CGFloat
        let jump: CGFloat
        let skip: CGFloat
        let feature: CGFloat
    }

    static let topBarHeight: CGFloat = 42
    static let topBarBackButtonLeadingInset: CGFloat = 156
    static let topBarTrailingInset: CGFloat = 24
    static let topBarVerticalPadding: CGFloat = 0
    static let topTitleGap: CGFloat = 8
    static let topBrandIconSize: CGFloat = 18
    static let topBrandIconGap: CGFloat = 6
    static let topTitleFontSize: CGFloat = 20
    static let topBackFontSize: CGFloat = 12
    static let topRouteFontSize: CGFloat = 11
    static let topBackButtonHeight: CGFloat = 30
    static let topBackButtonHorizontalPadding: CGFloat = 10
    static let topRouteChipHeight: CGFloat = 28
    static let topRouteChipHorizontalPadding: CGFloat = 8
    static let topBackIconSize: CGFloat = 14
    static let topRouteIconSize: CGFloat = 12
    static let topControlCornerRadius: CGFloat = 8
    static let bottomHorizontalInset: CGFloat = 22
    static let bottomBottomInset: CGFloat = 20
    static let bottomCornerRadius: CGFloat = 28
    static let bottomMinHeight: CGFloat = 202
    static let bottomHorizontalPadding: CGFloat = 23
    static let bottomTopPadding: CGFloat = 19
    static let bottomBottomPadding: CGFloat = 18
    static let progressPlayColumnWidth: CGFloat = 58
    static let progressTrackTimeWidth: CGFloat = 82
    static let progressTimeFontSize: CGFloat = 14
    static let progressPlayButtonSize: CGFloat = 48
    static let progressPlayGlyphSize: CGFloat = 26
    static let timelineHeight: CGFloat = 32
    static let timelineTrackHeight: CGFloat = 6
    static let timelineThumbSize: CGFloat = 17
    static let progressRowSpacing: CGFloat = 18
    static let controlGridGap: CGFloat = 12
    static let controlGridDividerWidth: CGFloat = 1
    static let controlClusterGap: CGFloat = 13
    static let skipClusterGap: CGFloat = 13
    static let featureClusterGap: CGFloat = 6
    static let iconControlWidth: CGFloat = 66
    static let iconControlHeight: CGFloat = 92
    static let iconRowHeight: CGFloat = 38
    static let controlLabelFontSize: CGFloat = 13
    static let controlDetailFontSize: CGFloat = 11
    static let controlLabelHeight: CGFloat = 16
    static let controlDetailHeight: CGFloat = 14
    static let menuControlWidth: CGFloat = 70
    static let menuControlHeight: CGFloat = 92
    static let menuIconBoxSize: CGFloat = 38
    static let menuGlyphSize: CGFloat = 26
    static let trackPopoverRowHeight: CGFloat = 36
    static let trackPopoverRowSpacing: CGFloat = 4
    static let trackPopoverMaxListHeight: CGFloat = 280
    static let trackPopoverArrowEdge: Edge = .top
    static let iconGlyphStrokeWidth: CGFloat = 1.7
    static let menuGlyphStrokeWidth: CGFloat = 1.65
    static let primaryGlyphStrokeWidth: CGFloat = 2
    static let openDesignGlyphStrokeWidth: CGFloat = menuGlyphStrokeWidth
    static let skipGlyphViewBoxSize: CGFloat = 32
    static let skipIconBoxSize: CGFloat = 38
    static let skipIconSize: CGFloat = 27
    static let skipIconStrokeWidth: CGFloat = 1.5
    static let skipIconTextSize: CGFloat = 12
    static let skipButtonHeight: CGFloat = 62
    static let statusBadgeBottomOffset: CGFloat = 252
    static let statusBadgeFontSize: CGFloat = 14
    static let statusBadgeMinHeight: CGFloat = 38
    static let statusBadgeHorizontalPadding: CGFloat = 12

    static let drawerWidth: CGFloat = 480
    static let drawerTopInset: CGFloat = 30
    static let drawerBottomInset: CGFloat = 34
    static let drawerHorizontalInset: CGFloat = 22
    static let drawerCornerRadius: CGFloat = 24
    static let drawerContentPadding: CGFloat = 22
    static let drawerTitleFontSize: CGFloat = 24
    static let drawerBodyFontSize: CGFloat = 16
    static let drawerMetaFontSize: CGFloat = 13
    static let drawerDetailFontSize: CGFloat = 12
    static let drawerCloseButtonSize: CGFloat = 42
    static let drawerCloseButtonCornerRadius: CGFloat = 13
    static let drawerHeaderBottomPadding: CGFloat = 14
    static let drawerHeaderBottomSpacing: CGFloat = 16
    static let drawerSectionSpacing: CGFloat = 12
    static let drawerSectionPadding: CGFloat = 14
    static let drawerSectionCornerRadius: CGFloat = 16
    static let drawerControlCornerRadius: CGFloat = 12
    static let drawerControlMinHeight: CGFloat = 46
    static let drawerSegmentMinHeight: CGFloat = 39
    static let drawerEpisodeMinHeight: CGFloat = 54
    static let drawerGridGap: CGFloat = 9
    static let drawerSpeedColumnCount: Int = 5
    static let drawerSourceColumnCount: Int = 4
    static let drawerEpisodeColumnCount: Int = 4
    static let drawerSwitchWidth: CGFloat = 46
    static let drawerSwitchHeight: CGFloat = 26
    static let drawerStatusCornerRadius: CGFloat = 15
    static let episodePosterWidth: CGFloat = 92
    static let episodePosterHeight: CGFloat = 126
    static let episodePosterCornerRadius: CGFloat = 12
    static let episodePosterGap: CGFloat = 16

    static let skipDialogTitleFontSize: CGFloat = 22
    static let skipDialogCopyFontSize: CGFloat = 14
    static let skipDialogInputFontSize: CGFloat = 25

    static let controlForegroundOpacity: CGFloat = 0.88
    static let controlMutedOpacity: CGFloat = 0.70
    static let disabledControlOpacity: CGFloat = 0.42
    static let activeLavenderBackgroundOpacity: CGFloat = 0.11
    static let activeLavenderBorderOpacity: CGFloat = 0.38
    static let activeLavenderShadowOpacity: CGFloat = 0.18
    static let primaryAccentBackgroundOpacity: CGFloat = 0.17
    static let primaryAccentBorderOpacity: CGFloat = 0.72
    static let primaryAccentShadowOpacity: CGFloat = 0.58
    static let primaryAccentShadowRadius: CGFloat = 34
    static let hudGlassMaterialOpacity: CGFloat = 0.58
    static let hudGlassSurfaceOpacity: CGFloat = 0.08
    static let topBarMaterialOpacity = hudGlassMaterialOpacity
    static let topBarBackgroundOpacity = hudGlassSurfaceOpacity
    static let topBarBorderOpacity: CGFloat = 0.07
    static let topControlBackgroundOpacity: CGFloat = 0.08
    static let topControlBorderOpacity: CGFloat = 0.16
    static let topRouteBorderOpacity: CGFloat = 0.34
    static let glassPanelMaterialOpacity = hudGlassMaterialOpacity
    static let glassPanelSurfaceOpacity = hudGlassSurfaceOpacity
    static let drawerGlassMaterialOpacity = hudGlassMaterialOpacity
    static let drawerGlassSurfaceOpacity = hudGlassSurfaceOpacity
    static let bottomGlassMaterialOpacity = hudGlassMaterialOpacity
    static let bottomGlassSurfaceOpacity = hudGlassSurfaceOpacity
    static let bottomGlassTopHighlightOpacity: CGFloat = 0.06
    static let bottomGlassBottomInsetOpacity: CGFloat = 0.10
    static let bottomGlassShadowOpacity: CGFloat = 0.16
    static let bottomGlassShadowRadius: CGFloat = 48
    static let timelineTrackBaseOpacity: CGFloat = 0.16
    static let timelineTrackBufferOpacity: CGFloat = 0.52
    static let timelineTrackInsetOpacity: CGFloat = 0.20
    static let timelineThumbBorderOpacity: CGFloat = 0.68
    static let timelineThumbShadowOpacity: CGFloat = 0.72
    static let timelineThumbShadowRadius: CGFloat = 24
    static let timelineSkipMarkerDotSize: CGFloat = 10
    static let timelineSkipMarkerTickWidth: CGFloat = 2
    static let timelineSkipMarkerTickHeight: CGFloat = 19
    static let timelineSkipMarkerHeight: CGFloat = 30
    static let timelineSkipMarkerOpeningFillOpacity: CGFloat = 0.74
    static let timelineSkipMarkerOpeningLineOpacity: CGFloat = 0.58
    static let timelineSkipMarkerEndingFillOpacity: CGFloat = 0.46
    static let timelineSkipMarkerEndingLineOpacity: CGFloat = 0.60

    static func topBarBackdropSize(for availableSize: CGSize) -> CGSize {
        let width = availableSize.width.isFinite ? max(0, availableSize.width) : 0
        return CGSize(
            width: width,
            height: topBarHeight * PlayerHUDLayoutPolicy.scale(for: availableSize)
        )
    }

    static func trackPopoverListHeight(optionCount: Int) -> CGFloat {
        let visibleRowCount = max(1, optionCount)
        let contentHeight = CGFloat(visibleRowCount) * trackPopoverRowHeight
            + CGFloat(visibleRowCount - 1) * trackPopoverRowSpacing
        return min(contentHeight, trackPopoverMaxListHeight)
    }

    static func audioStatusText(for track: PlayerTrackInfo) -> String {
        let displayName = track.displayName
        return displayName.hasPrefix("音轨 ") ? displayName : "音轨 \(displayName)"
    }

    static func episodeSortSymbolName(descending: Bool) -> String {
        descending ? "arrow.down.to.line.compact" : "arrow.up.to.line.compact"
    }

    static let rewindArcStartPoint = CGPoint(x: 3.8, y: 8.7)
    static let rewindArcEndPoint = CGPoint(x: 5.4, y: 17)
    static let forwardArcStartPoint = CGPoint(x: 20.2, y: 8.7)
    static let forwardArcEndPoint = CGPoint(x: 18.6, y: 17)
    static let tenSecondArcRadius: CGFloat = 8
    static let tenSecondTextSizeRatio: CGFloat = 7.0 / 24.0
    static let speedArcStartPoint = CGPoint(x: 5, y: 17)
    static let speedArcEndPoint = CGPoint(x: 19, y: 17)
    static let speedArcRadius: CGFloat = 8
    static let speedNeedleStartPoint = CGPoint(x: 12, y: 13)
    static let speedNeedleEndPoint = CGPoint(x: 16, y: 9)
    static let speedBaseStartPoint = CGPoint(x: 8, y: 17)
    static let speedBaseEndPoint = CGPoint(x: 16, y: 17)
    static let skipArcStartPoint = CGPoint(x: 22.8, y: 25.3)
    static let skipArcEndPoint = CGPoint(x: 26.8, y: 12.6)
    static let skipArcRadius: CGFloat = 11.3
    // OpenDesign's marker direction follows the arc tangent, but the browser
    // marker scale reads too heavily beside native macOS text rendering.
    static let skipArrowMarkerScale: CGFloat = 0.72
    static let skipArrowAnchorPoint = skipArcEndPoint
    static let skipArrowUnscaledTipPoint = CGPoint(x: 29.3856, y: 20.2762)
    static let skipArrowUnscaledUpperPoint = CGPoint(x: 30.6381, y: 11.3072)
    static let skipArrowUnscaledLowerPoint = CGPoint(x: 22.9619, y: 13.8928)
    static let skipArrowTipPoint = scaledSkipArrowPoint(skipArrowUnscaledTipPoint)
    static let skipArrowUpperPoint = scaledSkipArrowPoint(skipArrowUnscaledUpperPoint)
    static let skipArrowLowerPoint = scaledSkipArrowPoint(skipArrowUnscaledLowerPoint)

    static func swiftUIClockwise(forSVGSweepClockwise sweepClockwise: Bool) -> Bool {
        // SVG evaluates its sweep in a y-down viewport. SwiftUI's arc API uses
        // the opposite boolean convention for the same on-screen direction.
        !sweepClockwise
    }

    private static func scaledSkipArrowPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: skipArrowAnchorPoint.x + (point.x - skipArrowAnchorPoint.x) * skipArrowMarkerScale,
            y: skipArrowAnchorPoint.y + (point.y - skipArrowAnchorPoint.y) * skipArrowMarkerScale
        )
    }

    static let episodeColumnMinimumWidth: CGFloat = 210
    static let jumpColumnMinimumWidth: CGFloat = 136
    static let skipColumnMinimumWidth: CGFloat = 144
    static let featureColumnMinimumWidth: CGFloat = 520
    static let episodeColumnGrow: CGFloat = 0.48
    static let jumpColumnGrow: CGFloat = 0.32
    static let skipColumnGrow: CGFloat = 0.34
    static let featureColumnGrow: CGFloat = 1

    static let bottomControlSlots: [PlayerHUDControlSlot] = [
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
    ]

    static let unifiedFeatureControlSlots: [PlayerHUDControlSlot] = [
        .subtitles,
        .audio,
        .aspectRatio,
        .speed,
        .volume,
        .settings,
        .fullscreen,
    ]

    static let popoverBackedControlSlots: [PlayerHUDControlSlot] = [
        .subtitles,
        .audio,
    ]

    static let cyclicControlSlots: [PlayerHUDControlSlot] = [
        .aspectRatio,
        .speed,
    ]

    static let skipAnchorWidth: CGFloat = 144
    static let skipChipWidth: CGFloat = 66
    static let functionDividerHeight: CGFloat = 82
    static let statusBadgeGapAboveBottomHUD: CGFloat = statusBadgeBottomOffset - bottomMinHeight - bottomBottomInset

    static func controlGridColumns(availableWidth: CGFloat) -> ControlGridColumns {
        let minimumContentWidth = episodeColumnMinimumWidth
            + jumpColumnMinimumWidth
            + skipColumnMinimumWidth
            + featureColumnMinimumWidth
        let fixedChromeWidth = controlGridDividerWidth * 3 + controlGridGap * 6
        let extraWidth = max(0, availableWidth - fixedChromeWidth - minimumContentWidth)
        let growTotal = episodeColumnGrow + jumpColumnGrow + skipColumnGrow + featureColumnGrow

        func grown(_ minimum: CGFloat, _ grow: CGFloat) -> CGFloat {
            minimum + extraWidth * grow / growTotal
        }

        return ControlGridColumns(
            episode: grown(episodeColumnMinimumWidth, episodeColumnGrow),
            jump: grown(jumpColumnMinimumWidth, jumpColumnGrow),
            skip: grown(skipColumnMinimumWidth, skipColumnGrow),
            feature: grown(featureColumnMinimumWidth, featureColumnGrow)
        )
    }

    static func visibleSkipKinds(openingSkip _: Int, endingSkip _: Int) -> [PlayerHUDSkipKind] {
        [.opening, .ending]
    }

    static func isSkipActionEnabled(seconds: Int) -> Bool {
        seconds > 0
    }

    static func skipDurationText(seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let h = safeSeconds / 3600
        let m = safeSeconds % 3600 / 60
        let s = safeSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

}

private struct PlayerDrawerSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .foregroundStyle(PlayerHUDPalette.foreground.opacity(0.84))
            Spacer(minLength: 12)
            Button {
                configuration.isOn.toggle()
            } label: {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? PlayerHUDPalette.lavender.opacity(0.52) : Color.white.opacity(0.16))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.13), lineWidth: 1)
                    }
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(PlayerHUDPalette.foreground)
                            .frame(width: 18, height: 18)
                            .padding(3)
                    }
                    .frame(
                        width: PlayerHUDVisualPolicy.drawerSwitchWidth,
                        height: PlayerHUDVisualPolicy.drawerSwitchHeight
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 42)
    }
}

enum PlayerTimelineMarkerPolicy {
    static let defaultThumbWidth: CGFloat = 19

    static func markerCenterX(value: Int, duration: Double, trackWidth: CGFloat, thumbWidth: CGFloat = defaultThumbWidth) -> CGFloat? {
        guard value > 0,
              duration.isFinite,
              duration > 0,
              trackWidth > 0 else {
            return nil
        }
        let ratio = min(1, max(0, Double(value) / duration))
        let usableWidth = max(0, trackWidth - thumbWidth)
        return thumbWidth / 2 + usableWidth * CGFloat(ratio)
    }

    static func fillWidth(value: Double, duration: Double, trackWidth: CGFloat) -> CGFloat {
        guard value.isFinite,
              duration.isFinite,
              duration > 0,
              trackWidth > 0 else {
            return 0
        }
        let ratio = min(1, max(0, value / duration))
        return trackWidth * CGFloat(ratio)
    }

    static func endingMarkerValue(endingSkipSeconds: Int, duration: Double) -> Int? {
        guard endingSkipSeconds > 0, duration.isFinite, duration > 0 else { return nil }
        let marker = Int(duration.rounded(.down)) - endingSkipSeconds
        return marker > 0 ? marker : nil
    }
}

enum PlayerSkipEditorPolicy {
    static func parseTimeText(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.allSatisfy(\.isNumber) {
            return Int(value)
        }

        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }

        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        let h: Int
        let m: Int
        let s: Int
        if numbers.count == 3 {
            h = numbers[0]
            m = numbers[1]
            s = numbers[2]
        } else {
            h = 0
            m = numbers[0]
            s = numbers[1]
        }
        guard m <= 59, s <= 59 else { return nil }
        return h * 3600 + m * 60 + s
    }

    static func formatTime(_ seconds: Int) -> String {
        PlayerHUDVisualPolicy.skipDurationText(seconds: seconds)
    }

    static func clamp(_ seconds: Int, duration: Double) -> Int {
        let upperBound = duration.isFinite && duration > 0 ? Int(duration.rounded(.down)) : max(0, seconds)
        return min(max(0, seconds), upperBound)
    }

    static func isValid(
        target: PlayerSkipEditorTarget,
        value: Int,
        openingSkip: Int,
        endingSkip: Int,
        duration: Double
    ) -> Bool {
        validationMessage(
            target: target,
            value: value,
            openingSkip: openingSkip,
            endingSkip: endingSkip,
            duration: duration
        ) == nil
    }

    static func validationMessage(
        target: PlayerSkipEditorTarget,
        value: Int,
        openingSkip: Int,
        endingSkip: Int,
        duration: Double
    ) -> String? {
        let nextOpening = target == .opening ? value : openingSkip
        let nextEnding = target == .ending ? value : endingSkip
        if nextEnding > 0,
           duration.isFinite,
           duration > 0,
           Double(nextOpening + nextEnding + 10) > duration {
            return "片头与片尾之间至少保留 10 秒。"
        }
        return nil
    }

    static func valueAtCurrentPosition(
        target: PlayerSkipEditorTarget,
        position: Double,
        duration: Double
    ) -> Int {
        guard position.isFinite else { return 0 }
        switch target {
        case .opening:
            return clamp(Int(max(0, position).rounded(.down)), duration: duration)
        case .ending:
            guard duration.isFinite, duration > 0 else { return 0 }
            return clamp(Int(max(0, duration - position).rounded(.down)), duration: duration)
        }
    }
}

enum PlayerHUDGlyphKind: CaseIterable, Equatable {
    case backArrow
    case routeBolt
    case previousEpisode
    case rewind10
    case play
    case pause
    case forward10
    case nextEpisode
    case episodeGrid
    case subtitles
    case audio
    case aspectRatio
    case speed
    case settings
    case fullscreen
    case volume
}

enum DanmakuOverlayPolicy {
    static let maxVisibleCueCount = 120
    static let minFontSize = 18
    static let maxFontSize = 72

    static func effectiveFontSize(_ value: Int) -> Int {
        min(maxFontSize, max(minFontSize, value))
    }

    static func laneCount(containerHeight: CGFloat, fontSize: Int) -> Int {
        let effectiveFont = effectiveFontSize(fontSize)
        let laneHeight = CGFloat(effectiveFont + 10)
        return max(1, Int(max(1, containerHeight * 0.55) / max(1, laneHeight)))
    }

    static func stableLane(for id: String, count: Int) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return Int(hash % UInt64(max(1, count)))
    }

    static func visibleCues(_ cues: [DanmakuCue], positionMs: Int, scrollDurationMs: Int, fixedDurationMs: Int) -> [DanmakuCue] {
        Array(cues.filter { cue in
            let elapsed = positionMs - cue.timeMs
            guard elapsed >= 0 else { return false }
            let duration = cue.mode == .scroll ? scrollDurationMs : fixedDurationMs
            return elapsed <= duration
        }.suffix(maxVisibleCueCount))
    }
}

private struct PlayerReferenceCanvas<Content: View>: View {
    let availableSize: CGSize
    let verticalAnchor: PlayerHUDCanvasVerticalAnchor
    private let content: Content

    init(
        availableSize: CGSize,
        verticalAnchor: PlayerHUDCanvasVerticalAnchor = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.availableSize = availableSize
        self.verticalAnchor = verticalAnchor
        self.content = content()
    }

    var body: some View {
        let referenceSize = PlayerHUDLayoutPolicy.referenceSize
        let scale = PlayerHUDLayoutPolicy.scale(for: availableSize)
        let scaledSize = PlayerHUDLayoutPolicy.scaledSize(for: availableSize)

        content
            .frame(width: referenceSize.width, height: referenceSize.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: scaledSize.width, height: scaledSize.height, alignment: .topLeading)
            .offset(y: PlayerHUDLayoutPolicy.verticalOffset(for: availableSize, anchor: verticalAnchor))
            .frame(width: availableSize.width, height: availableSize.height, alignment: .top)
    }
}

struct PlayerView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var playerState: PlayerState
    @ObservedObject var windowContext: PlayerWindowContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var showHUD: Bool = true
    @State private var isPointerInsidePlayer: Bool = false
    @State private var overlayPanel: PlayerOverlayPanel = .none
    @State private var hideHUDTimer: Timer?
    @State private var progressSaveTimer: Timer?
    @State private var isSeeking: Bool = false
    @State private var pendingSeekPosition: Double = 0
    @State private var subtitleFontSize: Int = UserPreferences.shared.subtitleFontSize
    @State private var subtitlePosition: Int = UserPreferences.shared.subtitlePosition
    @State private var subtitleOverrideSourceStyle: Bool = UserPreferences.shared.subtitleOverrideSourceStyle
    @State private var openingSkip: Int = 0
    @State private var endingSkip: Int = 0
    @State private var danmakuEnabled: Bool = UserPreferences.shared.danmakuEnabled
    @State private var danmakuOpacity: Double = UserPreferences.shared.danmakuOpacity
    @State private var danmakuFontSize: Int = UserPreferences.shared.danmakuFontSize
    @State private var danmakuOffsetMs: Int = UserPreferences.shared.danmakuOffsetMs
    @State private var episodeSortDescending: Bool = true
    @State private var isSkipEditorPresented: Bool = false
    @State private var skipEditorTarget: PlayerSkipEditorTarget = .opening
    @State private var skipDraftText: String = "00:00"
    @State private var skipDraftSeconds: Int = 0
    @State private var skipEditorHint: String = ""
    @State private var skipEditorError: String?
    @State private var isVolumePopoverPresented: Bool = false
    @State private var isSubtitlePopoverPresented: Bool = false
    @State private var isAudioPopoverPresented: Bool = false
    @State private var lastNonZeroVolume: Float = 1.0

    private let visualRegressionConfiguration: PlayerVisualRegressionConfiguration?

    private let hudIconDiameter: CGFloat = PlayerHUDVisualPolicy.iconRowHeight
    private let hudPrimaryDiameter: CGFloat = 64

    private var currentVodSkipIdentity: VodSkipSettingsIdentity? {
        if let vod = appState.detailVod,
           let identity = VodSkipSettingsIdentity(
               siteKey: vod.siteKey.isEmpty ? (appState.activeSite?.key ?? "") : vod.siteKey,
               vodID: vod.vodId
           ) {
            return identity
        }
        return VodSkipSettingsIdentity(
            playbackMetadata: appState.playerState.currentSpec?.metadata ?? [:]
        )
    }

    init(
        playerState: PlayerState,
        windowContext: PlayerWindowContext,
        visualRegressionConfiguration: PlayerVisualRegressionConfiguration? = nil
    ) {
        _playerState = ObservedObject(wrappedValue: playerState)
        _windowContext = ObservedObject(wrappedValue: windowContext)
        self.visualRegressionConfiguration = visualRegressionConfiguration

        let state = visualRegressionConfiguration?.state
        let initialOverlayPanel: PlayerOverlayPanel
        switch state {
        case .settingsDrawer:
            initialOverlayPanel = .settings
        case .episodeDrawer:
            initialOverlayPanel = .episodes
        default:
            initialOverlayPanel = .none
        }
        _showHUD = State(initialValue: state != .hudHidden)
        _overlayPanel = State(initialValue: initialOverlayPanel)
        _isSkipEditorPresented = State(initialValue: state == .skipDialog)
    }

    var body: some View {
        GeometryReader { proxy in
            let usesCompactControls = CompactPlayerLayoutPolicy.isCompact(
                contentSize: windowContext.contentSize == .zero
                    ? proxy.size
                    : windowContext.contentSize
            )

            ZStack {
                videoLayer

                videoInteractionLayer
                    .zIndex(0.5)

                if usesCompactControls {
                    CompactPlayerStatusOverlay(
                        isLoading: isPlaybackActivityActive,
                        errorMessage: playerState.errorMessage ?? appState.playbackWarningMessage
                    )
                    .zIndex(2)

                    CompactPlayerControls(
                        kind: .vod,
                        isPlaying: playerState.isPlaying,
                        isPlaybackEnabled: playerState.currentSpec != nil,
                        position: playerState.position,
                        duration: playerState.duration,
                        isAlwaysOnTop: windowContext.isAlwaysOnTop,
                        isVisible: compactControlsAreVisible,
                        onTogglePlayback: togglePlayPause,
                        onSeek: { target in
                            MPVPlayerEngine.vod.seek(to: Int64(target * 1_000))
                        },
                        onToggleAlwaysOnTop: {
                            _ = windowContext.toggleAlwaysOnTop()
                        },
                        onRestoreWindow: {
                            _ = windowContext.restoreRegularWindow()
                        },
                        onClose: exitPlayer
                    )
                    .zIndex(3)
                } else {
                    PlayerReferenceCanvas(availableSize: proxy.size) {
                        playerOverlayCanvas
                    }
                    .zIndex(PlayerOverlayLayerPolicy.referenceCanvas)

                    PlayerPlaybackActivityView(
                        phase: playbackActivityPhase,
                        progress: playerState.cacheBufferingProgress,
                        speedBytesPerSecond: playerState.cacheSpeedBytesPerSecond,
                        bufferedAheadDuration: playbackActivityBufferedAheadDuration,
                        showsImmediately: visualRegressionConfiguration?.state == .loading
                            || visualRegressionConfiguration?.state == .buffering
                    )
                    .zIndex(PlayerOverlayLayerPolicy.playbackActivity)

                    if isPrimaryHUDVisible {
                        topHUDBackdrop(availableSize: proxy.size)
                            .transition(.opacity)
                            .zIndex(2)

                        PlayerReferenceCanvas(availableSize: proxy.size, verticalAnchor: .bottom) {
                            bottomHUDLayer
                        }
                        .transition(.opacity)
                        .zIndex(3)

                        PlayerReferenceCanvas(availableSize: proxy.size, verticalAnchor: .top) {
                            topHUDLayer
                        }
                        .transition(.opacity)
                        .zIndex(4)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color.black)
            .onContinuousHover { phase in
                guard visualRegressionConfiguration == nil else { return }
                switch phase {
                case .active:
                    isPointerInsidePlayer = true
                    showHUDTemporarily()
                case .ended:
                    isPointerInsidePlayer = false
                    hideHUDTimer?.invalidate()
                    restorePlayerCursor()
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showHUD)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: overlayPanel)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSkipEditorPresented)
            .onChange(of: usesCompactControls) { _, isCompact in
                handleCompactModeChange(isCompact)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .background {
            PlayerShortcutMonitor(
                isPlaybackControlEnabled: !isSkipEditorPresented,
                isScrollVolumeEnabled: overlayPanel == .none
                    && !isSkipEditorPresented
                    && !isVolumePopoverPresented
                    && !isSubtitlePopoverPresented
                    && !isAudioPopoverPresented
            ) { command, _ in
                handleKeyboardShortcut(command)
            }
            .frame(width: 0, height: 0)
        }
        .onAppear {
            if visualRegressionConfiguration == nil {
                syncSettingsState()
            } else {
                applyVisualRegressionSettingsState()
            }
            lastNonZeroVolume = max(0.01, appState.playerState.volume)
            if visualRegressionConfiguration == nil {
                startProgressSaveTimer()
                resetHUDTimer()
            }
        }
        .onDisappear {
            hideHUDTimer?.invalidate()
            progressSaveTimer?.invalidate()
            isPointerInsidePlayer = false
            restorePlayerCursor()
            appState.cleanupDrivePlaybackIfNeeded(spec: appState.playerState.currentSpec)
        }
        .onChange(of: currentVodSkipIdentity) { _, _ in
            guard visualRegressionConfiguration == nil else { return }
            syncVodSkipState()
        }
        .onChange(of: appState.playerState.isPlaying) { _, isPlaying in
            if isPlaying {
                resetHUDTimer()
            } else {
                hideHUDTimer?.invalidate()
                restorePlayerCursor()
                showHUDTemporarily()
            }
        }
        .onChange(of: overlayPanel) { _, panel in
            showHUD = true
            isVolumePopoverPresented = false
            isSubtitlePopoverPresented = false
            isAudioPopoverPresented = false
            if panel == .none {
                resetHUDTimer()
            } else {
                hideHUDTimer?.invalidate()
                restorePlayerCursor()
            }
        }
        .onChange(of: isSkipEditorPresented) { _, isPresented in
            if isPresented {
                hideHUDTimer?.invalidate()
                restorePlayerCursor()
            } else {
                resetHUDTimer()
            }
        }
        .onChange(of: isSubtitlePopoverPresented) { _, isPresented in
            updateTrackPopoverTimer(isPresented: isPresented)
        }
        .onChange(of: isAudioPopoverPresented) { _, isPresented in
            updateTrackPopoverTimer(isPresented: isPresented)
        }
        .onChange(of: isPlaybackActivityActive) { _, isActive in
            if isActive {
                hideHUDTimer?.invalidate()
                restorePlayerCursor()
                withPlayerAnimation {
                    showHUD = true
                }
            } else {
                resetHUDTimer()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                resetHUDTimer()
            } else {
                if !windowContext.isCompact {
                    isPointerInsidePlayer = false
                }
                hideHUDTimer?.invalidate()
                restorePlayerCursor()
            }
        }
    }

    private var isPrimaryHUDVisible: Bool {
        showHUD && overlayPanel == .none && !isSkipEditorPresented
    }

    private var compactControlsAreVisible: Bool {
        guard let visualRegressionConfiguration else { return isPointerInsidePlayer }
        return visualRegressionConfiguration.state != .hudHidden
    }

    private func handleCompactModeChange(_ isCompact: Bool) {
        if isCompact {
            hideHUDTimer?.invalidate()
            overlayPanel = .none
            isSkipEditorPresented = false
            isVolumePopoverPresented = false
            isSubtitlePopoverPresented = false
            isAudioPopoverPresented = false
            restorePlayerCursor()
        } else {
            showHUDTemporarily()
        }
    }

    private var playerOverlayCanvas: some View {
        ZStack {
            if overlayPanel != .none {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closeOverlayPanel()
                    }
                    .zIndex(3)
            }

            if overlayPanel == .episodes {
                episodeDrawer(size: PlayerHUDLayoutPolicy.referenceSize)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(4)
            }

            if overlayPanel == .settings {
                settingsDrawer(size: PlayerHUDLayoutPolicy.referenceSize)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(4)
            }

            if isSkipEditorPresented {
                skipEditorDialog
                    .transition(.opacity)
                    .zIndex(9)
            }

            playbackMessageBanners
                .zIndex(7)

            playbackErrorOverlay
                .zIndex(8)
        }
        .frame(width: PlayerHUDLayoutPolicy.referenceSize.width, height: PlayerHUDLayoutPolicy.referenceSize.height)
    }

    private var videoLayer: some View {
        ZStack {
            Color.black
            if let fixtureURL = visualRegressionConfiguration?.fixtureURL,
               let fixtureImage = NSImage(contentsOf: fixtureURL) {
                Image(nsImage: fixtureImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                MPVVideoView(engine: MPVPlayerEngine.vod, surface: .vod)
            }
            if shouldRenderDanmaku {
                DanmakuOverlayView(
                    cues: appState.currentDanmakuCues,
                    positionMs: Int((appState.playerState.position * 1000).rounded()) + danmakuOffsetMs,
                    opacity: danmakuOpacity,
                    fontSize: danmakuFontSize
                )
                .allowsHitTesting(false)
                .zIndex(1)
            }
        }
        .ignoresSafeArea()
    }

    private var videoInteractionLayer: some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
        .gesture(
            TapGesture(count: PlayerPointerShortcutPolicy.fullScreenClickCount)
                .exclusively(
                    before: TapGesture(count: PlayerPointerShortcutPolicy.singleClickCount)
                )
                .onEnded { result in
                    switch result {
                    case .first:
                        handleVideoPointerShortcut(
                            clickCount: PlayerPointerShortcutPolicy.fullScreenClickCount
                        )
                    case .second:
                        handleVideoPointerShortcut(
                            clickCount: PlayerPointerShortcutPolicy.singleClickCount
                        )
                    }
                },
            including: PlayerPointerShortcutPolicy.videoGestureMask(
                hasPlayback: true,
                hasBlockingUI: hasBlockingPlayerUI
            )
        )
        .ignoresSafeArea()
    }

    private var topHUDLayer: some View {
        VStack(spacing: 0) {
            topGlassBar
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func topHUDBackdrop(availableSize: CGSize) -> some View {
        let backdropSize = PlayerHUDVisualPolicy.topBarBackdropSize(for: availableSize)

        return VStack(spacing: 0) {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(PlayerHUDVisualPolicy.topBarMaterialOpacity)
                Rectangle()
                    .fill(PlayerHUDPalette.background.opacity(PlayerHUDVisualPolicy.topBarBackgroundOpacity))
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(PlayerHUDVisualPolicy.topBarBorderOpacity))
                    .frame(height: 1)
            }
            .frame(height: backdropSize.height)

            Spacer(minLength: 0)
        }
        .frame(width: backdropSize.width, height: availableSize.height, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(false)
    }

    private var bottomHUDLayer: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if playbackBadgesAvailable {
                statusBadges
                    .padding(.horizontal, PlayerHUDVisualPolicy.bottomHorizontalInset + 6)
                    .padding(.bottom, max(0, PlayerHUDVisualPolicy.statusBadgeGapAboveBottomHUD))
            }
            bottomHUD
                .padding(.horizontal, PlayerHUDVisualPolicy.bottomHorizontalInset)
                .padding(.bottom, PlayerHUDVisualPolicy.bottomBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var topGlassBar: some View {
        ZStack {
            HStack {
                Button {
                    exitPlayer()
                } label: {
                    HStack(spacing: 8) {
                        PlayerHUDGlyph(kind: .backArrow, size: PlayerHUDVisualPolicy.topBackIconSize, baseStrokeWidth: PlayerHUDVisualPolicy.menuGlyphStrokeWidth)
                        Text("返回详情")
                    }
                    .font(.system(size: PlayerHUDVisualPolicy.topBackFontSize, weight: .semibold))
                    .frame(minHeight: PlayerHUDVisualPolicy.topBackButtonHeight)
                    .padding(.horizontal, PlayerHUDVisualPolicy.topBackButtonHorizontalPadding)
                    .foregroundStyle(PlayerHUDPalette.foreground.opacity(0.92))
                    .background(Color.white.opacity(PlayerHUDVisualPolicy.topControlBackgroundOpacity), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.topControlCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.topControlCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(PlayerHUDVisualPolicy.topControlBorderOpacity), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .help("保存进度并返回详情")

                Spacer()
            }

            HStack(spacing: PlayerHUDVisualPolicy.topTitleGap) {
                HStack(spacing: PlayerHUDVisualPolicy.topBrandIconGap) {
                    AppBrandIcon(size: PlayerHUDVisualPolicy.topBrandIconSize)

                    Text(currentPlayerTitle)
                        .font(.system(size: PlayerHUDVisualPolicy.topTitleFontSize, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(PlayerHUDPalette.foreground.opacity(0.94))
                        .shadow(color: .black.opacity(0.45), radius: 6)
                }

                if !activeLineLabel.isEmpty {
                    HStack(spacing: 7) {
                        PlayerHUDGlyph(kind: .routeBolt, size: PlayerHUDVisualPolicy.topRouteIconSize, baseStrokeWidth: PlayerHUDVisualPolicy.menuGlyphStrokeWidth)
                        Text("线路：\(activeLineLabel)")
                    }
                    .font(.system(size: PlayerHUDVisualPolicy.topRouteFontSize, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, PlayerHUDVisualPolicy.topRouteChipHorizontalPadding)
                    .frame(minHeight: PlayerHUDVisualPolicy.topRouteChipHeight)
                    .foregroundStyle(PlayerHUDPalette.foreground.opacity(0.92))
                    .background(Color.white.opacity(PlayerHUDVisualPolicy.topControlBackgroundOpacity), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.topControlCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.topControlCornerRadius, style: .continuous)
                            .stroke(lavender.opacity(PlayerHUDVisualPolicy.topRouteBorderOpacity), lineWidth: 1)
                    }
                }
            }
            .frame(maxWidth: min(620, NSScreen.main?.frame.width ?? 620))
        }
        .padding(EdgeInsets(
            top: PlayerHUDVisualPolicy.topBarVerticalPadding,
            leading: PlayerHUDVisualPolicy.topBarBackButtonLeadingInset,
            bottom: PlayerHUDVisualPolicy.topBarVerticalPadding,
            trailing: PlayerHUDVisualPolicy.topBarTrailingInset
        ))
        .frame(height: PlayerHUDVisualPolicy.topBarHeight)
        .frame(maxWidth: .infinity)
    }

    private var bottomHUD: some View {
        VStack(spacing: PlayerHUDVisualPolicy.progressRowSpacing) {
            progressRow
            transportControlsRow
        }
        .padding(.horizontal, PlayerHUDVisualPolicy.bottomHorizontalPadding)
        .padding(.top, PlayerHUDVisualPolicy.bottomTopPadding)
        .padding(.bottom, PlayerHUDVisualPolicy.bottomBottomPadding)
        .frame(minHeight: PlayerHUDVisualPolicy.bottomMinHeight)
        .background(bottomHUDGlassPanel(cornerRadius: PlayerHUDVisualPolicy.bottomCornerRadius))
    }

    private var progressRow: some View {
        HStack(spacing: PlayerHUDVisualPolicy.progressRowSpacing) {
            progressPlayButton
                .frame(width: PlayerHUDVisualPolicy.progressPlayColumnWidth)

            HStack(spacing: PlayerHUDVisualPolicy.progressRowSpacing) {
                Text(formatClock(displayedPosition))
                    .font(.system(size: PlayerHUDVisualPolicy.progressTimeFontSize, design: .monospaced))
                    .foregroundStyle(PlayerHUDPalette.foreground.opacity(0.88))
                    .frame(width: PlayerHUDVisualPolicy.progressTrackTimeWidth, alignment: .leading)

                timelineSlider

                Text(formatClock(appState.playerState.duration))
                    .font(.system(size: PlayerHUDVisualPolicy.progressTimeFontSize, design: .monospaced))
                    .foregroundStyle(PlayerHUDPalette.foreground.opacity(0.88))
                    .frame(width: PlayerHUDVisualPolicy.progressTrackTimeWidth, alignment: .trailing)
            }
        }
        .frame(height: PlayerHUDVisualPolicy.progressPlayButtonSize, alignment: .center)
    }

    private var progressPlayButton: some View {
        Button {
            togglePlayPause()
            showHUDTemporarily()
        } label: {
            PlayerHUDGlyph(kind: appState.playerState.isPlaying ? .pause : .play, size: PlayerHUDVisualPolicy.progressPlayGlyphSize, emphasized: true)
                .frame(width: PlayerHUDVisualPolicy.progressPlayButtonSize, height: PlayerHUDVisualPolicy.progressPlayButtonSize)
                .background(controlIconBackground(isActive: false, isPrimary: true))
                .foregroundStyle(.white)
                .accessibilityLabel(appState.playerState.isPlaying ? "暂停" : "播放")
        }
        .buttonStyle(.plain)
        .help(appState.playerState.isPlaying ? "暂停" : "播放")
    }

    private var timelineSlider: some View {
        GeometryReader { timelineProxy in
            let width = timelineProxy.size.width
            let thumbX = PlayerTimelineMarkerPolicy.markerCenterX(
                value: Int(displayedPosition.rounded()),
                duration: appState.playerState.duration,
                trackWidth: width
            ) ?? PlayerHUDVisualPolicy.timelineThumbSize / 2
            let bufferedWidth = PlayerTimelineMarkerPolicy.fillWidth(
                value: appState.playerState.bufferedPosition,
                duration: appState.playerState.duration,
                trackWidth: width
            )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(PlayerHUDVisualPolicy.timelineTrackBaseOpacity))
                    .frame(height: PlayerHUDVisualPolicy.timelineTrackHeight)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(lavender.opacity(PlayerHUDVisualPolicy.timelineTrackBufferOpacity))
                            .frame(width: bufferedWidth, height: PlayerHUDVisualPolicy.timelineTrackHeight)
                    }
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(seaBlue)
                            .frame(width: max(0, min(width, thumbX)), height: PlayerHUDVisualPolicy.timelineTrackHeight)
                    }
                    .shadow(color: .white.opacity(PlayerHUDVisualPolicy.timelineTrackInsetOpacity), radius: 0, x: 0, y: -0.5)

                timelineSkipMarker(kind: .opening, seconds: openingSkip, width: timelineProxy.size.width)
                if let endingMarker = PlayerTimelineMarkerPolicy.endingMarkerValue(
                    endingSkipSeconds: endingSkip,
                    duration: appState.playerState.duration
                ) {
                    timelineSkipMarker(kind: .ending, seconds: endingMarker, width: timelineProxy.size.width)
                }

                Circle()
                    .fill(Color.white.opacity(canSeek ? 0.98 : 0.45))
                    .frame(width: PlayerHUDVisualPolicy.timelineThumbSize, height: PlayerHUDVisualPolicy.timelineThumbSize)
                    .overlay {
                        Circle()
                            .stroke(seaBlue.opacity(canSeek ? PlayerHUDVisualPolicy.timelineThumbBorderOpacity : PlayerHUDVisualPolicy.activeLavenderShadowOpacity), lineWidth: 2)
                    }
                    .shadow(color: seaBlue.opacity(canSeek ? PlayerHUDVisualPolicy.timelineThumbShadowOpacity : 0), radius: PlayerHUDVisualPolicy.timelineThumbShadowRadius)
                    .position(x: thumbX, y: PlayerHUDVisualPolicy.timelineHeight / 2)
            }
            .frame(width: width, height: PlayerHUDVisualPolicy.timelineHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateTimelineSeek(locationX: value.location.x, trackWidth: width, commit: false)
                    }
                    .onEnded { value in
                        updateTimelineSeek(locationX: value.location.x, trackWidth: width, commit: true)
                    }
            )
        }
        .frame(height: PlayerHUDVisualPolicy.timelineHeight)
    }

    @ViewBuilder
    private func timelineSkipMarker(kind: PlayerHUDSkipKind, seconds: Int, width: CGFloat) -> some View {
        if let x = PlayerTimelineMarkerPolicy.markerCenterX(
            value: seconds,
            duration: appState.playerState.duration,
            trackWidth: width
        ) {
            VStack(spacing: 0) {
                Circle()
                    .fill(kind == .ending ? lavender.opacity(PlayerHUDVisualPolicy.timelineSkipMarkerEndingFillOpacity) : Color.white.opacity(PlayerHUDVisualPolicy.timelineSkipMarkerOpeningFillOpacity))
                    .frame(width: PlayerHUDVisualPolicy.timelineSkipMarkerDotSize, height: PlayerHUDVisualPolicy.timelineSkipMarkerDotSize)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.34), lineWidth: 1)
                    }
                    .shadow(color: lavender.opacity(0.34), radius: 8)
                Rectangle()
                    .fill((kind == .ending ? lavender.opacity(PlayerHUDVisualPolicy.timelineSkipMarkerEndingLineOpacity) : Color.white.opacity(PlayerHUDVisualPolicy.timelineSkipMarkerOpeningLineOpacity)))
                    .frame(width: PlayerHUDVisualPolicy.timelineSkipMarkerTickWidth, height: PlayerHUDVisualPolicy.timelineSkipMarkerTickHeight)
                    .clipShape(Capsule())
            }
            .position(x: x, y: PlayerHUDVisualPolicy.timelineHeight / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var transportControlsRow: some View {
        GeometryReader { proxy in
            let columns = PlayerHUDVisualPolicy.controlGridColumns(availableWidth: proxy.size.width)
            HStack(alignment: .top, spacing: PlayerHUDVisualPolicy.controlGridGap) {
                episodeControlsCluster
                    .frame(width: columns.episode, height: PlayerHUDVisualPolicy.menuControlHeight, alignment: .top)

                hudDivider

                jumpControlsCluster
                    .frame(width: columns.jump, height: PlayerHUDVisualPolicy.menuControlHeight, alignment: .top)

                hudDivider

                skipCluster
                    .frame(width: columns.skip, height: PlayerHUDVisualPolicy.menuControlHeight, alignment: .top)

                hudDivider

                rightFeatureControls
                    .frame(width: columns.feature, height: PlayerHUDVisualPolicy.menuControlHeight, alignment: .top)
            }
            .frame(width: proxy.size.width, height: PlayerHUDVisualPolicy.menuControlHeight, alignment: .top)
        }
        .frame(height: PlayerHUDVisualPolicy.menuControlHeight)
    }

    private var episodeControlsCluster: some View {
        let context = appState.playbackEpisodeContext()
        return HStack(alignment: .top, spacing: PlayerHUDVisualPolicy.controlClusterGap) {
            hudControlButton(title: "上一集", glyph: .previousEpisode, disabled: !context.hasPrevious || appState.isPlayerLoading) {
                playRelativeEpisode(-1)
            }

            hudControlButton(title: "下一集", glyph: .nextEpisode, disabled: !context.hasNext || appState.isPlayerLoading) {
                playRelativeEpisode(1)
            }

            hudControlButton(title: "选集", glyph: .episodeGrid, isActive: overlayPanel == .episodes) {
                toggleOverlayPanel(.episodes)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var jumpControlsCluster: some View {
        HStack(alignment: .top, spacing: PlayerHUDVisualPolicy.controlClusterGap) {
            hudControlButton(title: "后退10秒", glyph: .rewind10, disabled: !canSeek) {
                seekBy(-10)
            }

            hudControlButton(title: "前进10秒", glyph: .forward10, disabled: !canSeek) {
                seekBy(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var skipSlotView: some View {
        HStack(spacing: PlayerHUDVisualPolicy.skipClusterGap) {
            ForEach(PlayerHUDVisualPolicy.visibleSkipKinds(openingSkip: openingSkip, endingSkip: endingSkip), id: \.self) { kind in
                switch kind {
                case .opening:
                    skipControlButton(label: "首", seconds: openingSkip, target: .opening, missingSide: .leading) {
                        openSkipEditor(.opening)
                    }
                case .ending:
                    skipControlButton(label: "尾", seconds: endingSkip, target: .ending, missingSide: .trailing) {
                        openSkipEditor(.ending)
                    }
                }
            }
        }
        .frame(width: PlayerHUDVisualPolicy.skipAnchorWidth)
    }

    private var skipCluster: some View {
        skipSlotView
            .frame(width: PlayerHUDVisualPolicy.skipAnchorWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var rightFeatureControls: some View {
        HStack(alignment: .top, spacing: PlayerHUDVisualPolicy.featureClusterGap) {
            subtitleControl
            audioControl
            aspectRatioControl
            speedControl
            volumeControl
            featureControlButton(title: "设置", glyph: .settings, isActive: overlayPanel == .settings) {
                toggleOverlayPanel(.settings)
            }
            featureControlButton(title: "全屏", glyph: .fullscreen) {
                toggleFullScreen()
            }
        }
    }

    private var aspectRatioControl: some View {
        featureControlButton(
            title: "比例",
            glyph: .aspectRatio,
            detail: playerState.videoAspectMode.displayName,
            isActive: playerState.videoAspectMode != .fit
        ) {
            cycleVideoAspectMode()
        }
    }

    private var volumeControl: some View {
        ZStack(alignment: .top) {
            Button {
                isVolumePopoverPresented.toggle()
                showHUDTemporarily()
            } label: {
                featureControlLabel(
                    title: appState.playerState.volume <= 0 ? "静音" : "音量",
                    glyph: .volume,
                    detail: volumePercentText,
                    isActive: isVolumePopoverPresented || appState.playerState.volume <= 0
                )
            }
            .buttonStyle(.plain)
            .frame(width: PlayerHUDVisualPolicy.menuControlWidth, height: PlayerHUDVisualPolicy.menuControlHeight)
            .contentShape(Rectangle())
            .help("音量，点击展开调节条，双击静音")
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                toggleMute()
            })

            if isVolumePopoverPresented {
                verticalVolumePopover
                    .offset(y: -154)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                    .zIndex(3)
            }
        }
        .frame(width: PlayerHUDVisualPolicy.menuControlWidth, height: PlayerHUDVisualPolicy.menuControlHeight, alignment: .top)
    }

    private var verticalVolumePopover: some View {
        ZStack {
            Slider(
                value: Binding(
                    get: { appState.playerState.volume },
                    set: { setVolume($0) }
                ),
                in: 0...1.0
            )
            .tint(lavender)
            .frame(width: 106)
            .rotationEffect(.degrees(-90))
        }
        .frame(width: 52, height: 146)
        .background(glassPanel(cornerRadius: 14, strokeOpacity: 0.26))
        .overlay(alignment: .bottom) {
            Diamond()
                .fill(.ultraThinMaterial)
                .opacity(PlayerHUDVisualPolicy.glassPanelMaterialOpacity)
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(45))
                .offset(y: 5)
                .overlay {
                    Diamond()
                        .fill(PlayerHUDPalette.surface.opacity(PlayerHUDVisualPolicy.glassPanelSurfaceOpacity))
                        .rotationEffect(.degrees(45))
                        .offset(y: 5)
                }
                .overlay {
                    Diamond()
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                        .rotationEffect(.degrees(45))
                        .offset(y: 5)
                }
        }
    }

    private var hudDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: PlayerHUDVisualPolicy.functionDividerHeight)
            .frame(height: PlayerHUDVisualPolicy.menuControlHeight, alignment: .center)
    }

    private var statusBadges: some View {
        HStack(spacing: 12) {
            if let text = appState.playerState.drivePlaybackStatus {
                playbackBadge(text, icon: "film")
            }
            if let text = appState.playerState.subtitleStatus {
                playbackBadge(text, icon: "captions.bubble")
            }
            if let text = audioStatusText {
                playbackBadge(text, icon: "waveform")
            }
            if let text = appState.playerState.drmStatus {
                playbackBadge(text, icon: "lock.shield")
            }
            if let text = appState.playerState.danmakuStatus {
                playbackBadge(text, icon: "text.bubble")
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitleControl: some View {
        featurePopoverControl(
            title: "字幕",
            glyph: .subtitles,
            isActive: playerState.selectedSubtitleTrackID != nil,
            isUnavailable: playerState.subtitleTracks.isEmpty,
            isPresented: $isSubtitlePopoverPresented
        ) {
            subtitleTrackPopover
        }
    }

    private var audioControl: some View {
        featurePopoverControl(
            title: "音轨",
            glyph: .audio,
            detail: playerState.selectedAudioTrackID == nil ? nil : "已选",
            isActive: playerState.selectedAudioTrackID != nil,
            isUnavailable: playerState.audioTracks.isEmpty,
            isPresented: $isAudioPopoverPresented
        ) {
            audioTrackPopover
        }
    }

    private var subtitleTrackPopover: some View {
        trackSelectionPopover(
            title: "字幕",
            optionCount: playerState.subtitleTracks.isEmpty ? 0 : playerState.subtitleTracks.count + 1
        ) {
            if playerState.subtitleTracks.isEmpty {
                trackPopoverEmptyState("暂无可选字幕")
            } else {
                trackOptionButton(title: "关闭字幕", isSelected: playerState.selectedSubtitleTrackID == nil) {
                    MPVPlayerEngine.vod.disableSubtitle()
                    appState.saveTrackPreference(
                        type: .subtitle,
                        id: PlaybackLinkage.disabledSubtitleTrackID,
                        name: "关闭字幕",
                        format: ""
                    )
                    isSubtitlePopoverPresented = false
                }

                ForEach(playerState.subtitleTracks) { track in
                    trackOptionButton(title: track.displayName, isSelected: playerState.selectedSubtitleTrackID == track.id) {
                        if track.isExternal,
                           let sub = playerState.currentSpec?.subs.first(where: { "external:\($0.id)" == track.id }) {
                            MPVPlayerEngine.vod.loadExternalSubtitle(sub, select: true)
                        } else {
                            MPVPlayerEngine.vod.selectSubtitleTrack(id: track.id)
                        }
                        appState.saveTrackPreference(type: .subtitle, id: track.id, name: track.displayName, format: track.format)
                        isSubtitlePopoverPresented = false
                    }
                }
            }
        }
    }

    private var audioTrackPopover: some View {
        trackSelectionPopover(title: "音轨", optionCount: playerState.audioTracks.count) {
            if playerState.audioTracks.isEmpty {
                trackPopoverEmptyState("暂无可选音轨")
            } else {
                ForEach(playerState.audioTracks) { track in
                    trackOptionButton(title: track.displayName, isSelected: playerState.selectedAudioTrackID == track.id) {
                        MPVPlayerEngine.vod.selectAudioTrack(id: track.id)
                        appState.saveTrackPreference(type: .audio, id: track.id, name: track.displayName, format: track.format)
                        isAudioPopoverPresented = false
                    }
                }
            }
        }
    }

    private var speedControl: some View {
        featureControlButton(
            title: "倍速",
            glyph: .speed,
            detail: speedLabel(playerState.speed),
            isActive: abs(playerState.speed - 1.0) > 0.01
        ) {
            cyclePlaybackSpeed()
        }
    }

    private func settingsDrawer(size _: CGSize) -> some View {
        return HStack {
            Spacer(minLength: 0)
            ThemedScrollView(theme: .player) {
                VStack(alignment: .leading, spacing: PlayerHUDVisualPolicy.drawerSectionSpacing) {
                    drawerHeader("播放设置", followingSpacing: PlayerHUDVisualPolicy.drawerSectionSpacing)

                    settingsSection("倍速") {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: 8),
                                count: PlayerHUDVisualPolicy.drawerSpeedColumnCount
                            ),
                            spacing: 8
                        ) {
                            ForEach(PlayerHUDInteractionPolicy.playbackSpeeds, id: \.self) { speed in
                                settingsChip(speedLabel(speed), isSelected: abs(appState.playerState.speed - speed) < 0.01) {
                                    setPlaybackSpeed(speed)
                                }
                            }
                        }
                    }

                    settingsSection("字幕") {
                        settingsStepperRow(title: "大小", value: subtitleFontSize, range: 16...72) {
                            updateSubtitleFontSize($0)
                        }

                        settingsStepperRow(title: "位置", value: subtitlePosition, range: 0...100) {
                            updateSubtitlePosition($0)
                        }

                        Toggle("忽略片源样式", isOn: Binding(
                            get: { subtitleOverrideSourceStyle },
                            set: { updateSubtitleOverride($0) }
                        ))
                        .toggleStyle(PlayerDrawerSwitchToggleStyle())
                    }

                    settingsSection("跳过") {
                        settingActionRow(title: "片头", value: skipPreferenceLabel(openingSkip)) {
                            openSkipEditor(.opening)
                        }

                        settingActionRow(title: "片尾", value: skipPreferenceLabel(endingSkip)) {
                            openSkipEditor(.ending)
                        }
                    }

                    settingsSection("弹幕") {
                        Toggle("弹幕渲染", isOn: Binding(
                            get: { danmakuEnabled },
                            set: { updateDanmakuEnabled($0) }
                        ))
                        .toggleStyle(PlayerDrawerSwitchToggleStyle())

                        settingInlineActionRow(title: "手动搜索当前标题", actionTitle: "搜索", disabled: !danmakuEnabled) {
                            Task {
                                await appState.manualSearchDanmakuForCurrentPlayback()
                            }
                        }
                    }

                    settingsSection("状态") {
                        VStack(alignment: .leading, spacing: 8) {
                            settingStatusCard(
                                appState.playerState.drivePlaybackStatus ?? "网盘路线：普通播放",
                                detail: appState.playerState.drivePlaybackStatus == nil ? "当前源无需转码代理" : "播放器实时路线状态"
                            )
                            settingStatusCard(
                                appState.playerState.drmStatus ?? "DRM：未识别",
                                detail: appState.playerState.drmStatus == nil ? "保持原生 mpv 会话" : "播放器实时 DRM 状态"
                            )
                        }
                    }
                }
                .padding(PlayerHUDVisualPolicy.drawerContentPadding)
            }
            .frame(width: PlayerHUDVisualPolicy.drawerWidth)
            .clipShape(RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerCornerRadius, style: .continuous))
            .background(drawerGlassPanel)
            .padding(.top, PlayerHUDVisualPolicy.drawerTopInset)
            .padding(.bottom, PlayerHUDVisualPolicy.drawerBottomInset)
            .padding(.trailing, PlayerHUDVisualPolicy.drawerHorizontalInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func episodeDrawer(size _: CGSize) -> some View {
        let currentEpisode = appState.episodeForCurrentPlayback(in: appState.episodes)
        let context = appState.playbackEpisodeContext(in: appState.episodes)
        let sortedEpisodes = episodeSortDescending ? Array(appState.episodes.reversed()) : appState.episodes
        let sourceColumns = Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: PlayerHUDVisualPolicy.drawerSourceColumnCount
        )
        let episodeColumns = Array(
            repeating: GridItem(.flexible(), spacing: PlayerHUDVisualPolicy.drawerGridGap),
            count: PlayerHUDVisualPolicy.drawerEpisodeColumnCount
        )
        return HStack {
            ThemedScrollView(theme: .player) {
                VStack(alignment: .leading, spacing: 16) {
                    drawerHeader("选集与线路", followingSpacing: 16)

                    HStack(alignment: .top, spacing: PlayerHUDVisualPolicy.episodePosterGap) {
                        RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.episodePosterCornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [lavender.opacity(0.25), PlayerHUDPalette.surface.opacity(0.86), Color.black.opacity(0.46)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay {
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.16))
                                    .frame(width: 32, height: 92)
                                    .offset(y: 22)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.episodePosterCornerRadius, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.episodePosterCornerRadius, style: .continuous))
                            .frame(width: PlayerHUDVisualPolicy.episodePosterWidth, height: PlayerHUDVisualPolicy.episodePosterHeight)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(appState.detailVod?.vodName ?? "正在播放")
                                .font(.system(size: PlayerHUDVisualPolicy.drawerTitleFontSize, weight: .semibold))
                                .foregroundStyle(PlayerHUDPalette.foreground)
                                .lineLimit(2)

                            if !context.currentEpisodeName.isEmpty {
                                Text(context.currentEpisodeName)
                                    .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, weight: .semibold))
                                    .foregroundStyle(PlayerHUDPalette.foreground.opacity(0.9))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(lavender.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(lavender.opacity(0.34), lineWidth: 1)
                                    }
                            }

                            if let progressText = context.progressText {
                                Text(progressText)
                                    .font(.system(size: PlayerHUDVisualPolicy.drawerMetaFontSize))
                                    .foregroundStyle(PlayerHUDPalette.muted.opacity(0.9))
                            }

                            if appState.playerState.duration > 0 {
                                ProgressView(value: appState.playerState.progress)
                                    .tint(lavender)
                            }
                        }
                    }

                    Button {
                        episodeSortDescending.toggle()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: PlayerHUDVisualPolicy.episodeSortSymbolName(descending: episodeSortDescending))
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 16, height: 16)
                            Text(episodeSortDescending ? "倒序" : "正序")
                        }
                        .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: PlayerHUDVisualPolicy.drawerControlMinHeight)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(episodeSortDescending ? "倒序" : "正序")
                    }
                    .buttonStyle(.plain)
                    .help(episodeSortDescending ? "当前倒序，点击切换正序" : "当前正序，点击切换倒序")

                    currentPlaybackRouteSection

                    if !appState.playFlags.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            drawerSectionLabel("播放源")

                            LazyVGrid(columns: sourceColumns, spacing: 8) {
                                ForEach(appState.playFlags, id: \.self) { flag in
                                    sourcePill(flag, isSelected: flag == appState.selectedPlayFlag) {
                                        appState.selectPlayFlag(flag)
                                        showHUDTemporarily()
                                    }
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        drawerSectionLabel("剧集")
                        Spacer(minLength: 0)
                        EpisodeDisplayModePicker(selection: $appState.episodeDisplayMode)
                            .tint(lavender)
                    }

                    switch appState.episodeDisplayMode {
                    case .grid:
                        LazyVGrid(columns: episodeColumns, spacing: PlayerHUDVisualPolicy.drawerGridGap) {
                            ForEach(sortedEpisodes) { episode in
                                episodeGridButton(
                                    episode,
                                    isCurrent: currentEpisode?.url == episode.url && currentEpisode?.name == episode.name,
                                    isHistory: appState.isHistoryEpisode(episode)
                                )
                            }
                        }
                    case .list:
                        LazyVStack(spacing: PlayerHUDVisualPolicy.drawerGridGap) {
                            ForEach(sortedEpisodes) { episode in
                                episodeListButton(
                                    episode,
                                    isCurrent: currentEpisode?.url == episode.url && currentEpisode?.name == episode.name,
                                    isHistory: appState.isHistoryEpisode(episode)
                                )
                            }
                        }
                    }
                }
                .padding(PlayerHUDVisualPolicy.drawerContentPadding)
            }
            .frame(width: PlayerHUDVisualPolicy.drawerWidth)
            .clipShape(RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerCornerRadius, style: .continuous))
            .background(drawerGlassPanel)
            .padding(.leading, PlayerHUDVisualPolicy.drawerHorizontalInset)
            .padding(.top, PlayerHUDVisualPolicy.drawerTopInset)
            .padding(.bottom, PlayerHUDVisualPolicy.drawerBottomInset)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var skipEditorDialog: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()
                .onTapGesture {
                    closeSkipEditor()
                }

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("设置跳过\(skipEditorTarget.title)")
                            .font(.system(size: PlayerHUDVisualPolicy.skipDialogTitleFontSize, weight: .semibold))
                            .foregroundStyle(PlayerHUDPalette.foreground)
                        Text(skipEditorTarget == .opening ? "片头结束点" : "片尾开始点")
                            .font(.system(size: PlayerHUDVisualPolicy.skipDialogCopyFontSize))
                            .foregroundStyle(PlayerHUDPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    skipEditorCloseButton
                }

                HStack {
                    Text("当前位置 \(formatClock(appState.playerState.position))")
                    Spacer()
                    Text("已保存 \(formatSkipDuration(savedSkipSeconds(for: skipEditorTarget)))")
                }
                .font(.system(size: PlayerHUDVisualPolicy.drawerMetaFontSize, design: .monospaced))
                .foregroundStyle(PlayerHUDPalette.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        adjustSkipDraft(by: -1)
                    } label: {
                        Text("-")
                            .font(.title2.weight(.bold))
                            .frame(width: 48, height: 44)
                    }
                    .buttonStyle(.plain)
                    .background(glassPanel(cornerRadius: 13, strokeOpacity: 0.18))

                    TextField("00:00", text: $skipDraftText)
                        .textFieldStyle(.plain)
                        .font(.system(size: PlayerHUDVisualPolicy.skipDialogInputFontSize, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(height: 56)
                        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke((skipEditorError == nil ? lavender : Color.red).opacity(0.45), lineWidth: 1)
                        }
                        .onChange(of: skipDraftText) { _, value in
                            syncSkipDraftFromText(value)
                        }

                    Button {
                        adjustSkipDraft(by: 1)
                    } label: {
                        Text("+")
                            .font(.title2.weight(.bold))
                            .frame(width: 48, height: 44)
                    }
                    .buttonStyle(.plain)
                    .background(glassPanel(cornerRadius: 13, strokeOpacity: 0.18))
                }

                Text(skipEditorError ?? skipEditorHint)
                    .font(.caption)
                    .foregroundStyle(skipEditorError == nil ? .white.opacity(0.62) : Color.red.opacity(0.9))
                    .frame(minHeight: 20, alignment: .leading)

                HStack(spacing: 10) {
                    skipEditorActionButton("设为当前位置") {
                        setSkipDraft(seconds: PlayerSkipEditorPolicy.valueAtCurrentPosition(
                            target: skipEditorTarget,
                            position: appState.playerState.position,
                            duration: appState.playerState.duration
                        ))
                    }
                    skipEditorActionButton("清零") {
                        setSkipDraft(seconds: 0)
                    }
                    skipEditorActionButton("保存", prominent: true) {
                        saveSkipEditor()
                    }
                    .disabled(skipEditorError != nil)
                }
            }
            .padding(20)
            .frame(width: min(448, max(320, NSScreen.main?.frame.width ?? 448)))
            .background(glassPanel(cornerRadius: 22, strokeOpacity: 0.34))
            .padding(24)
        }
    }

    private func skipEditorActionButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(.white)
                .background(prominent ? seaBlue.opacity(0.28) : Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(prominent ? seaBlue.opacity(0.58) : Color.white.opacity(0.13), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var playbackMessageBanners: some View {
        if appState.playbackDowngradeMessage != nil || appState.playbackWarningMessage != nil {
            VStack(spacing: 10) {
                if let message = appState.playbackDowngradeMessage {
                    playbackDowngradeBanner(message: message)
                }
                if let message = appState.playbackWarningMessage {
                    playbackWarningBanner(message: message)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 18)
            .padding(.horizontal, 18)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func playbackDowngradeBanner(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(seaBlue)

            VStack(alignment: .leading, spacing: 3) {
                Text("已自动降低清晰度")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button {
                appState.dismissPlaybackDowngradeNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 720)
        .background(glassPanel(cornerRadius: 10, strokeOpacity: 0.3))
    }

    private func playbackWarningBanner(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 3) {
                Text("UC 备用转码不可用")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if appState.playbackErrorAuthProvider != nil {
                Button {
                    appState.openCloudAuthFromPlaybackError()
                } label: {
                    Label("重新授权", systemImage: "person.badge.key")
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                appState.dismissPlaybackWarning()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 720)
        .background(glassPanel(cornerRadius: 10, strokeOpacity: 0.3))
    }

    @ViewBuilder
    private var playbackErrorOverlay: some View {
        if let message = appState.playerState.errorMessage,
           !message.contains("已切换到兼容播放器") {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundColor(.yellow)

                Text("播放失败")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)

                Text(message)
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 460)

                if let spec = appState.playerState.currentSpec,
                   !appState.playbackDiagnosticLines(for: spec).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.playbackDiagnosticLines(for: spec), id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                }

                HStack(spacing: 12) {
                    if appState.playbackErrorAuthProvider != nil {
                        Button {
                            appState.openCloudAuthFromPlaybackError()
                        } label: {
                            Label("重新授权", systemImage: "person.badge.key")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let spec = appState.playerState.currentSpec {
                        Button {
                            Task {
                                await MPVPlayerEngine.vod.play(spec: spec)
                            }
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        appState.cleanupDrivePlaybackIfNeeded(spec: appState.playerState.currentSpec)
                        MPVPlayerEngine.vod.stop()
                        appState.isPlayerPresented = false
                    } label: {
                        Label("关闭", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
                .tint(.white)
            }
            .padding(24)
            .background(glassPanel(cornerRadius: 14, strokeOpacity: 0.32))
            .padding()
            .transition(.opacity)
        }
    }

    private var canSeek: Bool {
        appState.playerState.duration > 0
    }

    private var displayedPosition: Double {
        isSeeking ? pendingSeekPosition : appState.playerState.position
    }

    private var playbackBadgesAvailable: Bool {
        appState.playerState.drivePlaybackStatus != nil ||
            appState.playerState.subtitleStatus != nil ||
            audioStatusText != nil ||
            appState.playerState.drmStatus != nil ||
            appState.playerState.danmakuStatus != nil
    }

    private var shouldRenderDanmaku: Bool {
        danmakuEnabled &&
            appState.playerState.currentSpec?.danmakuAttachment != nil &&
            !appState.currentDanmakuCues.isEmpty
    }

    private var currentPlayerTitle: String {
        if let spec = appState.playerState.currentSpec, !spec.title.isEmpty {
            return spec.title
        }
        return appState.detailVod?.vodName ?? "正在播放"
    }

    private var activeLineLabel: String {
        if let route = appState.activeDrivePlaybackRouteLabel, !route.isEmpty {
            return route
        }
        if let flag = appState.playerState.currentSpec?.flag, !flag.isEmpty {
            return flag
        }
        return appState.selectedPlayFlag
    }

    private var audioStatusText: String? {
        guard !appState.playerState.audioTracks.isEmpty else { return nil }
        if let selectedID = appState.playerState.selectedAudioTrackID,
           let track = appState.playerState.audioTracks.first(where: { $0.id == selectedID }) {
            return PlayerHUDVisualPolicy.audioStatusText(for: track)
        }
        return "音轨 \(appState.playerState.audioTracks.count) 条"
    }

    private var activeDrivePlaybackRoute: DrivePlaybackRouteOption? {
        guard let routeID = appState.selectedDrivePlaybackRouteID else { return nil }
        return appState.drivePlaybackRoutes.first(where: { $0.id == routeID })
    }

    private var currentPlaybackState: (title: String, detail: String, color: Color, isError: Bool) {
        let label = activeLineLabel.isEmpty ? "当前源" : activeLineLabel
        if appState.isPlayerLoading {
            return ("\(label) 正在缓冲", "正在准备播放会话", lavender, false)
        }
        if appState.playerState.errorMessage != nil {
            return ("\(label) 连接失败", "可重试或切回其它线路", Color.red, true)
        }
        let detail = activeDrivePlaybackRoute.map { "连接正常 · \($0.detail)" } ?? "连接正常 · 原生播放"
        return ("\(label) 已就绪", detail, seaBlue, false)
    }

    private var seaBlue: Color {
        PlayerHUDPalette.accent
    }

    private var lavender: Color {
        PlayerHUDPalette.lavender
    }

    private var closePanelButton: some View {
        Button {
            closeOverlayPanel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: PlayerHUDVisualPolicy.drawerCloseButtonSize, height: PlayerHUDVisualPolicy.drawerCloseButtonSize)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerCloseButtonCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerCloseButtonCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help("关闭面板")
    }

    private var skipEditorCloseButton: some View {
        Button {
            closeSkipEditor()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: PlayerHUDVisualPolicy.drawerCloseButtonSize, height: PlayerHUDVisualPolicy.drawerCloseButtonSize)
                .background(glassPanel(cornerRadius: PlayerHUDVisualPolicy.drawerCloseButtonCornerRadius, strokeOpacity: 0.22))
        }
        .buttonStyle(.plain)
        .help("关闭跳过时间设置")
    }

    private func hudControlButton(
        title: String,
        glyph: PlayerHUDGlyphKind,
        detail: String? = nil,
        isActive: Bool = false,
        isPrimary: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            showHUDTemporarily()
        } label: {
            VStack(spacing: 7) {
                PlayerHUDGlyph(
                    kind: glyph,
                    size: isPrimary ? 34 : PlayerHUDVisualPolicy.menuGlyphSize,
                    emphasized: isPrimary,
                    baseStrokeWidth: PlayerHUDVisualPolicy.iconGlyphStrokeWidth
                )
                    .frame(
                        width: isPrimary ? hudPrimaryDiameter : hudIconDiameter,
                        height: isPrimary ? hudPrimaryDiameter : hudIconDiameter
                    )
                    .background {
                        if isPrimary || isActive {
                            controlIconBackground(isActive: isActive, isPrimary: isPrimary)
                        }
                    }
                Text(title)
                    .font(.system(size: PlayerHUDVisualPolicy.controlLabelFontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(height: PlayerHUDVisualPolicy.controlLabelHeight)
                if let detail {
                    Text(detail)
                        .font(.system(size: PlayerHUDVisualPolicy.controlDetailFontSize, design: .monospaced))
                        .foregroundStyle(disabled ? PlayerHUDPalette.foreground.opacity(PlayerHUDVisualPolicy.disabledControlOpacity) : PlayerHUDPalette.muted.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(height: PlayerHUDVisualPolicy.controlDetailHeight)
                } else {
                    Text(" ")
                        .font(.system(size: PlayerHUDVisualPolicy.controlDetailFontSize, design: .monospaced))
                        .frame(height: PlayerHUDVisualPolicy.controlDetailHeight)
                        .opacity(0)
                }
            }
            .foregroundStyle(disabled ? PlayerHUDPalette.foreground.opacity(PlayerHUDVisualPolicy.disabledControlOpacity) : PlayerHUDPalette.foreground.opacity(PlayerHUDVisualPolicy.controlForegroundOpacity))
            .frame(
                width: isPrimary ? 78 : PlayerHUDVisualPolicy.iconControlWidth,
                height: isPrimary ? PlayerHUDVisualPolicy.iconControlHeight : PlayerHUDVisualPolicy.iconControlHeight,
                alignment: .top
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(
            width: isPrimary ? 78 : PlayerHUDVisualPolicy.iconControlWidth,
            height: PlayerHUDVisualPolicy.iconControlHeight
        )
        .contentShape(Rectangle())
        .disabled(disabled)
        .help(title)
    }

    private func featureControlButton(
        title: String,
        glyph: PlayerHUDGlyphKind,
        detail: String? = nil,
        isActive: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            showHUDTemporarily()
        } label: {
            featureControlLabel(title: title, glyph: glyph, detail: detail, isActive: isActive, disabled: disabled)
        }
        .buttonStyle(.plain)
        .frame(width: PlayerHUDVisualPolicy.menuControlWidth, height: PlayerHUDVisualPolicy.menuControlHeight)
        .contentShape(Rectangle())
        .disabled(disabled)
        .help(title)
    }

    private func featurePopoverControl<Content: View>(
        title: String,
        glyph: PlayerHUDGlyphKind,
        detail: String? = nil,
        isActive: Bool = false,
        isUnavailable: Bool = false,
        isPresented: Binding<Bool>,
        @ViewBuilder popoverContent: @escaping () -> Content
    ) -> some View {
        Button {
            isPresented.wrappedValue.toggle()
            showHUDTemporarily()
        } label: {
            featureControlLabel(title: title, glyph: glyph, detail: detail, isActive: isActive, disabled: isUnavailable)
                .opacity(isUnavailable ? PlayerHUDVisualPolicy.disabledControlOpacity : 1)
        }
        .buttonStyle(.plain)
        .frame(width: PlayerHUDVisualPolicy.menuControlWidth, height: PlayerHUDVisualPolicy.menuControlHeight, alignment: .top)
        .contentShape(Rectangle())
        .popover(isPresented: isPresented, arrowEdge: PlayerHUDVisualPolicy.trackPopoverArrowEdge) {
            popoverContent()
        }
        .help(title)
    }

    private func trackSelectionPopover<Content: View>(
        title: String,
        optionCount: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Divider()
            ThemedScrollView(theme: .player) {
                VStack(alignment: .leading, spacing: PlayerHUDVisualPolicy.trackPopoverRowSpacing) {
                    content()
                }
            }
            .frame(height: PlayerHUDVisualPolicy.trackPopoverListHeight(optionCount: optionCount))
        }
        .padding(12)
        .frame(width: 240)
    }

    private func trackOptionButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: PlayerHUDVisualPolicy.trackPopoverRowHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func trackPopoverEmptyState(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(
                maxWidth: .infinity,
                minHeight: PlayerHUDVisualPolicy.trackPopoverRowHeight,
                alignment: .leading
            )
    }

    private func featureControlLabel(
        title: String,
        glyph: PlayerHUDGlyphKind,
        detail: String? = nil,
        isActive: Bool = false,
        disabled: Bool = false
    ) -> some View {
        VStack(spacing: 6) {
            PlayerHUDGlyph(
                kind: glyph,
                size: PlayerHUDVisualPolicy.menuGlyphSize,
                emphasized: false,
                baseStrokeWidth: PlayerHUDVisualPolicy.menuGlyphStrokeWidth
            )
                .frame(width: PlayerHUDVisualPolicy.menuIconBoxSize, height: PlayerHUDVisualPolicy.menuIconBoxSize)
                .foregroundStyle(disabled ? .white.opacity(PlayerHUDVisualPolicy.disabledControlOpacity) : (isActive ? lavender.opacity(0.96) : .white.opacity(PlayerHUDVisualPolicy.controlForegroundOpacity)))
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(lavender.opacity(PlayerHUDVisualPolicy.activeLavenderBackgroundOpacity))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(lavender.opacity(PlayerHUDVisualPolicy.activeLavenderBorderOpacity), lineWidth: 1)
                            }
                            .shadow(color: lavender.opacity(PlayerHUDVisualPolicy.activeLavenderShadowOpacity), radius: 22)
                    }
                }

            Text(title)
                .font(.system(size: PlayerHUDVisualPolicy.controlLabelFontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: PlayerHUDVisualPolicy.controlLabelHeight)

            Text(detail ?? " ")
                .font(.system(size: PlayerHUDVisualPolicy.controlDetailFontSize, design: .monospaced))
                .foregroundStyle(disabled ? PlayerHUDPalette.foreground.opacity(PlayerHUDVisualPolicy.disabledControlOpacity) : PlayerHUDPalette.muted.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(height: PlayerHUDVisualPolicy.controlDetailHeight)
                .opacity(detail == nil ? 0 : 1)
        }
        .foregroundStyle(disabled ? PlayerHUDPalette.foreground.opacity(PlayerHUDVisualPolicy.disabledControlOpacity) : PlayerHUDPalette.foreground.opacity(PlayerHUDVisualPolicy.controlForegroundOpacity))
        .frame(width: PlayerHUDVisualPolicy.menuControlWidth, height: PlayerHUDVisualPolicy.menuControlHeight, alignment: .top)
        .contentShape(Rectangle())
    }

    private func controlIconBackground(isActive: Bool, isPrimary: Bool) -> some View {
        Circle()
            .fill(isPrimary ? seaBlue.opacity(PlayerHUDVisualPolicy.primaryAccentBackgroundOpacity) : (isActive ? lavender.opacity(PlayerHUDVisualPolicy.activeLavenderBackgroundOpacity) : Color.white.opacity(0.035)))
            .overlay {
                Circle()
                    .stroke(isPrimary ? seaBlue.opacity(PlayerHUDVisualPolicy.primaryAccentBorderOpacity) : (isActive ? lavender.opacity(PlayerHUDVisualPolicy.activeLavenderBorderOpacity) : Color.white.opacity(0.12)), lineWidth: isPrimary ? 1.6 : 1)
            }
            .shadow(color: isPrimary ? seaBlue.opacity(PlayerHUDVisualPolicy.primaryAccentShadowOpacity) : lavender.opacity(isActive ? PlayerHUDVisualPolicy.activeLavenderShadowOpacity : 0), radius: isPrimary ? PlayerHUDVisualPolicy.primaryAccentShadowRadius : 22)
    }

    private func skipControlButton(
        label: String,
        seconds: Int,
        target: PlayerSkipEditorTarget,
        missingSide: HorizontalEdge,
        action: @escaping () -> Void
    ) -> some View {
        let isEnabled = PlayerHUDVisualPolicy.isSkipActionEnabled(seconds: seconds)
        return Button {
            action()
            showHUDTemporarily()
        } label: {
            VStack(spacing: 6) {
                SkipMarkerIcon(label: label, missingSide: missingSide, accent: isEnabled ? lavender : Color.white.opacity(PlayerHUDVisualPolicy.controlForegroundOpacity))
                    .frame(width: PlayerHUDVisualPolicy.skipIconBoxSize, height: PlayerHUDVisualPolicy.skipIconBoxSize)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isEnabled ? lavender.opacity(PlayerHUDVisualPolicy.activeLavenderBackgroundOpacity) : Color.clear)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(isEnabled ? lavender.opacity(PlayerHUDVisualPolicy.activeLavenderBorderOpacity) : Color.clear, lineWidth: 1)
                            }
                    }
                Text(formatSkipDuration(seconds))
                    .font(.system(size: PlayerHUDVisualPolicy.controlDetailFontSize, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(isEnabled ? 0.9 : PlayerHUDVisualPolicy.controlMutedOpacity))
            .frame(width: PlayerHUDVisualPolicy.skipChipWidth, height: PlayerHUDVisualPolicy.skipButtonHeight, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: PlayerHUDVisualPolicy.skipChipWidth, height: PlayerHUDVisualPolicy.skipButtonHeight)
        .contentShape(Rectangle())
        .help("设置跳过\(target.title)")
    }

    private func playbackBadge(_ text: String, icon _: String) -> some View {
        Text(text)
            .font(.system(size: PlayerHUDVisualPolicy.statusBadgeFontSize, weight: .medium))
            .foregroundColor(PlayerHUDPalette.foreground.opacity(0.86))
            .lineLimit(1)
            .padding(.horizontal, PlayerHUDVisualPolicy.statusBadgeHorizontalPadding)
            .frame(minHeight: PlayerHUDVisualPolicy.statusBadgeMinHeight)
            .background(glassPanel(cornerRadius: 13, strokeOpacity: 0.22))
    }

    private func drawerHeader(_ title: String, followingSpacing: CGFloat) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: PlayerHUDVisualPolicy.drawerTitleFontSize, weight: .semibold))
                .foregroundStyle(PlayerHUDPalette.foreground)
            Spacer(minLength: 16)
            closePanelButton
        }
        .padding(.bottom, PlayerHUDVisualPolicy.drawerHeaderBottomPadding)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
        .padding(.bottom, max(0, PlayerHUDVisualPolicy.drawerHeaderBottomSpacing - followingSpacing))
    }

    private func drawerSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, weight: .semibold))
            .foregroundStyle(PlayerHUDPalette.foreground.opacity(0.92))
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, weight: .semibold))
                .foregroundStyle(PlayerHUDPalette.foreground.opacity(0.92))
            content()
        }
        .padding(PlayerHUDVisualPolicy.drawerSectionPadding)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerSectionCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerSectionCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
        }
    }

    private func settingsChip(_ text: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(text)
                .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(isSelected ? .white : .white.opacity(0.82))
                .frame(maxWidth: .infinity, minHeight: PlayerHUDVisualPolicy.drawerSegmentMinHeight)
                .background(isSelected ? lavender.opacity(0.20) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous)
                        .stroke(isSelected ? lavender.opacity(0.66) : Color.white.opacity(0.13), lineWidth: 1)
                        .shadow(color: isSelected ? lavender.opacity(0.20) : .clear, radius: 11)
                }
        }
        .buttonStyle(.plain)
    }

    private func sourcePill(_ text: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(isSelected ? .white : .white.opacity(0.82))
                .frame(maxWidth: .infinity, minHeight: PlayerHUDVisualPolicy.drawerControlMinHeight)
                .background(isSelected ? lavender.opacity(0.20) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous)
                        .stroke(isSelected ? lavender.opacity(0.60) : Color.white.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "当前播放源" : "切换播放源")
    }

    private var currentPlaybackRouteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            drawerSectionLabel("当前播放线路")
            currentPlaybackStatusCard

            if appState.drivePlaybackRoutes.count > 1 {
                VStack(spacing: 8) {
                    ForEach(appState.drivePlaybackRoutes) { route in
                        driveRouteButton(route)
                    }
                }
            }
        }
    }

    private var currentPlaybackStatusCard: some View {
        let state = currentPlaybackState

        return HStack(alignment: .center, spacing: 9) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
                .shadow(color: state.color.opacity(0.42), radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.system(size: PlayerHUDVisualPolicy.drawerMetaFontSize, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(state.detail)
                    .font(.system(size: PlayerHUDVisualPolicy.drawerDetailFontSize))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(state.color.opacity(state.isError ? 0.42 : 0.16), lineWidth: 1)
        }
    }

    private func driveRouteButton(_ route: DrivePlaybackRouteOption) -> some View {
        let isSelected = route.id == appState.selectedDrivePlaybackRouteID
        let isPending = route.id == appState.pendingDrivePlaybackRouteID

        return Button {
            showHUDTemporarily()
            Task {
                await appState.selectDrivePlaybackRoute(route)
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: route.kind == .original ? "externaldrive" : "play.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? lavender : .white.opacity(0.72))
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(route.title)
                        .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(route.detail)
                        .font(.system(size: PlayerHUDVisualPolicy.drawerDetailFontSize))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Group {
                    if isPending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(lavender)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(lavender)
                            .opacity(isSelected ? 1 : 0)
                    }
                }
                .frame(width: 18, height: 18)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: PlayerHUDVisualPolicy.drawerControlMinHeight)
            .background(isSelected ? lavender.opacity(0.16) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous)
                    .stroke(isSelected ? lavender.opacity(0.52) : Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(appState.pendingDrivePlaybackRouteID != nil)
        .help("\(route.title)：\(route.detail)")
    }

    private func settingsStepperRow(
        title: String,
        value: Int,
        range: ClosedRange<Int>,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.white.opacity(0.84))
            Spacer(minLength: 12)
            HStack(spacing: 0) {
                Button {
                    onChange(max(range.lowerBound, value - 1))
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 34, height: 32)
                }
                .disabled(value <= range.lowerBound)

                Text("\(value)")
                    .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, design: .monospaced))
                    .frame(minWidth: 54)

                Button {
                    onChange(min(range.upperBound, value + 1))
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 34, height: 32)
                }
                .disabled(value >= range.upperBound)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.13), lineWidth: 1)
            }
        }
        .frame(minHeight: 42)
    }

    private func settingActionRow(title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(value)
                    .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func settingInlineActionRow(
        title: String,
        actionTitle: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.white.opacity(0.84))
            Spacer(minLength: 12)
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
                .disabled(disabled)
                .opacity(disabled ? PlayerHUDVisualPolicy.disabledControlOpacity : 1)
        }
        .frame(minHeight: 42)
    }

    private func settingStatusCard(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PlayerHUDPalette.foreground.opacity(0.9))
            Text(detail)
                .font(.system(size: PlayerHUDVisualPolicy.drawerMetaFontSize))
                .foregroundStyle(PlayerHUDPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerStatusCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerStatusCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func episodeGridButton(_ episode: Episode, isCurrent: Bool, isHistory: Bool) -> some View {
        Button {
            Task {
                appState.saveCurrentPlaybackProgress()
                closeOverlayPanel()
                await appState.playEpisode(episode)
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Text(episode.name)
                    .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isHistory && !isCurrent {
                    Text("✓")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(lavender)
                        .padding(.trailing, 9)
                        .padding(.bottom, 6)
                }
            }
            .foregroundStyle(isCurrent ? .white : .white.opacity(0.82))
            .frame(maxWidth: .infinity, minHeight: PlayerHUDVisualPolicy.drawerEpisodeMinHeight)
            .background(isCurrent ? lavender.opacity(0.22) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous)
                    .stroke(isCurrent ? lavender.opacity(0.68) : Color.white.opacity(0.13), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(appState.isPlayerLoading)
    }

    private func episodeListButton(_ episode: Episode, isCurrent: Bool, isHistory: Bool) -> some View {
        Button {
            Task {
                appState.saveCurrentPlaybackProgress()
                closeOverlayPanel()
                await appState.playEpisode(episode)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(episode.name)
                    .font(.system(size: PlayerHUDVisualPolicy.drawerBodyFontSize, weight: isCurrent ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isHistory && !isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(lavender)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("播放历史")
                }
            }
            .foregroundStyle(isCurrent ? .white : .white.opacity(0.82))
            .frame(maxWidth: .infinity, minHeight: PlayerHUDVisualPolicy.drawerEpisodeMinHeight, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isCurrent ? lavender.opacity(0.22) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerControlCornerRadius, style: .continuous)
                    .stroke(isCurrent ? lavender.opacity(0.68) : Color.white.opacity(0.13), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(appState.isPlayerLoading)
        .accessibilityLabel(
            isCurrent
                ? "\(episode.name)，当前播放"
                : (isHistory ? "\(episode.name)，播放历史" : episode.name)
        )
    }

    private var drawerGlassPanel: some View {
        RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerCornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(PlayerHUDVisualPolicy.drawerGlassMaterialOpacity)
            .overlay {
                RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerCornerRadius, style: .continuous)
                    .fill(PlayerHUDPalette.surface.opacity(PlayerHUDVisualPolicy.drawerGlassSurfaceOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: PlayerHUDVisualPolicy.drawerCornerRadius, style: .continuous)
                    .stroke(lavender.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.42), radius: 30, x: 0, y: 18)
    }

    private func glassPanel(cornerRadius: CGFloat, strokeOpacity: Double = 0.28) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(PlayerHUDVisualPolicy.glassPanelMaterialOpacity)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PlayerHUDPalette.surface.opacity(PlayerHUDVisualPolicy.glassPanelSurfaceOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [lavender.opacity(strokeOpacity), seaBlue.opacity(strokeOpacity * 0.75), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: seaBlue.opacity(0.12), radius: 18, x: 0, y: 8)
    }

    private func bottomHUDGlassPanel(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(PlayerHUDVisualPolicy.bottomGlassMaterialOpacity)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PlayerHUDPalette.surface.opacity(PlayerHUDVisualPolicy.bottomGlassSurfaceOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                lavender.opacity(0.25),
                                seaBlue.opacity(0.12),
                                Color.white.opacity(0.06),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(PlayerHUDVisualPolicy.bottomGlassTopHighlightOpacity),
                                lavender.opacity(0.03),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(PlayerHUDVisualPolicy.bottomGlassBottomInsetOpacity), lineWidth: 1)
            }
            .shadow(color: .black.opacity(PlayerHUDVisualPolicy.bottomGlassShadowOpacity), radius: PlayerHUDVisualPolicy.bottomGlassShadowRadius, x: 0, y: 18)
    }

    private func clampedSeekPosition(_ position: Double) -> Double {
        min(max(0, position), appState.playerState.duration)
    }

    private func timelineSeekPosition(locationX: CGFloat, trackWidth: CGFloat) -> Double {
        guard appState.playerState.duration.isFinite,
              appState.playerState.duration > 0,
              trackWidth > 0 else {
            return 0
        }
        let thumbWidth = PlayerHUDVisualPolicy.timelineThumbSize
        let usableWidth = max(1, trackWidth - thumbWidth)
        let clampedX = min(max(thumbWidth / 2, locationX), trackWidth - thumbWidth / 2)
        let ratio = Double((clampedX - thumbWidth / 2) / usableWidth)
        return clampedSeekPosition(appState.playerState.duration * ratio)
    }

    private func updateTimelineSeek(locationX: CGFloat, trackWidth: CGFloat, commit: Bool) {
        guard canSeek else { return }
        hideHUDTimer?.invalidate()
        let target = timelineSeekPosition(locationX: locationX, trackWidth: trackWidth)
        pendingSeekPosition = target
        isSeeking = !commit
        if commit {
            MPVPlayerEngine.vod.seek(to: Int64(target * 1000))
            resetHUDTimer()
        }
    }

    private func formatSkipDuration(_ seconds: Int) -> String {
        PlayerHUDVisualPolicy.skipDurationText(seconds: seconds)
    }

    private func skipPreferenceLabel(_ seconds: Int) -> String {
        seconds == 0 ? "00:00" : PlayerSkipEditorPolicy.formatTime(seconds)
    }

    private func speedLabel(_ speed: Float) -> String {
        var text = String(format: "%.2f", speed)
        while text.contains(".") && text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return "\(text)x"
    }

    private var volumePercentText: String {
        "\(Int((appState.playerState.volume * 100).rounded()))%"
    }

    private func formatClock(_ seconds: Double) -> String {
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let h = Int(safeSeconds) / 3600
        let m = Int(safeSeconds) % 3600 / 60
        let s = Int(safeSeconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func withPlayerAnimation(_ changes: @escaping () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.easeInOut(duration: 0.2), changes)
        }
    }

    private func togglePlayPause() {
        let shouldPlay = PlayerKeyboardShortcutPolicy.toggledPlaybackState(
            from: appState.playerState.isPlaying
        )
        appState.playerState.isPlaying = shouldPlay
        if shouldPlay {
            MPVPlayerEngine.vod.resume()
        } else {
            MPVPlayerEngine.vod.pause()
        }
    }

    private func handleKeyboardShortcut(_ command: PlayerShortcutCommand) {
        switch command {
        case .togglePlayPause:
            togglePlayPause()
        case .seekBackward:
            seekBy(-PlayerKeyboardShortcutPolicy.seekInterval)
        case .seekForward:
            seekBy(PlayerKeyboardShortcutPolicy.seekInterval)
        case .volumeUp:
            setVolume(appState.playerState.volume + PlayerKeyboardShortcutPolicy.volumeStep)
        case .volumeDown:
            setVolume(appState.playerState.volume - PlayerKeyboardShortcutPolicy.volumeStep)
        case .enterFullScreen:
            enterFullScreen()
        case .exitFullScreen:
            exitFullScreen()
        }
        showHUDTemporarily()
    }

    private func seekBy(_ offset: Double) {
        let newPosition = clampedSeekPosition(appState.playerState.position + offset)
        MPVPlayerEngine.vod.seek(to: Int64(newPosition * 1000))
    }

    private func setPlaybackSpeed(_ speed: Float) {
        playerState.speed = speed
        PlayerHUDCommandDispatcher.setPlaybackSpeed(speed)
    }

    private func cyclePlaybackSpeed() {
        setPlaybackSpeed(PlayerHUDInteractionPolicy.nextPlaybackSpeed(after: playerState.speed))
    }

    private func cycleVideoAspectMode() {
        setVideoAspectMode(PlayerHUDInteractionPolicy.nextAspectMode(after: playerState.videoAspectMode))
    }

    private func setVideoAspectMode(_ mode: PlayerVideoAspectMode) {
        if playerState.videoAspectMode != mode {
            playerState.videoAspectMode = mode
            PlayerHUDCommandDispatcher.setVideoAspectMode(mode)
        }
    }

    private func setVolume(_ volume: Float) {
        let clamped = min(1, max(0, volume))
        if clamped > 0 {
            lastNonZeroVolume = clamped
        }
        appState.playerState.volume = clamped
        MPVPlayerEngine.vod.setVolume(clamped)
    }

    private func toggleMute() {
        if appState.playerState.volume > 0 {
            lastNonZeroVolume = appState.playerState.volume
            MPVPlayerEngine.vod.setVolume(0)
        } else {
            MPVPlayerEngine.vod.setVolume(max(0.01, lastNonZeroVolume))
        }
        isVolumePopoverPresented = false
        showHUDTemporarily()
    }

    private func playRelativeEpisode(_ offset: Int) {
        Task {
            appState.saveCurrentPlaybackProgress()
            closeOverlayPanel()
            await appState.playRelativeEpisode(offset: offset)
        }
    }

    private func openSkipEditor(_ target: PlayerSkipEditorTarget) {
        skipEditorTarget = target
        let currentValue = PlayerSkipEditorPolicy.valueAtCurrentPosition(
            target: target,
            position: appState.playerState.position,
            duration: appState.playerState.duration
        )
        let savedSeconds = savedSkipSeconds(for: target)
        setSkipDraft(seconds: PlayerSkipEditorPolicy.clamp(savedSeconds > 0 ? savedSeconds : currentValue, duration: appState.playerState.duration))
        skipEditorHint = ""
        withPlayerAnimation {
            isSkipEditorPresented = true
            isVolumePopoverPresented = false
        }
        hideHUDTimer?.invalidate()
    }

    private func closeSkipEditor() {
        withPlayerAnimation {
            isSkipEditorPresented = false
            showHUD = true
        }
        resetHUDTimer()
    }

    private func savedSkipSeconds(for target: PlayerSkipEditorTarget) -> Int {
        target == .opening ? openingSkip : endingSkip
    }

    private func setSkipDraft(seconds: Int) {
        skipDraftSeconds = PlayerSkipEditorPolicy.clamp(seconds, duration: appState.playerState.duration)
        skipDraftText = PlayerSkipEditorPolicy.formatTime(skipDraftSeconds)
        validateSkipDraft(skipDraftSeconds)
    }

    private func adjustSkipDraft(by delta: Int) {
        let parsed = PlayerSkipEditorPolicy.parseTimeText(skipDraftText) ?? skipDraftSeconds
        setSkipDraft(seconds: parsed + delta)
    }

    private func syncSkipDraftFromText(_ text: String) {
        guard let parsed = PlayerSkipEditorPolicy.parseTimeText(text) else {
            skipEditorError = "请输入有效时间，例如 01:23 或 1:02:03。"
            return
        }
        skipDraftSeconds = PlayerSkipEditorPolicy.clamp(parsed, duration: appState.playerState.duration)
        validateSkipDraft(skipDraftSeconds)
    }

    private func validateSkipDraft(_ seconds: Int) {
        skipEditorError = PlayerSkipEditorPolicy.validationMessage(
            target: skipEditorTarget,
            value: seconds,
            openingSkip: openingSkip,
            endingSkip: endingSkip,
            duration: appState.playerState.duration
        )
    }

    private func saveSkipEditor() {
        guard let parsed = PlayerSkipEditorPolicy.parseTimeText(skipDraftText) else {
            skipEditorError = "请输入有效时间，例如 01:23 或 1:02:03。"
            return
        }
        let clamped = PlayerSkipEditorPolicy.clamp(parsed, duration: appState.playerState.duration)
        guard PlayerSkipEditorPolicy.isValid(
            target: skipEditorTarget,
            value: clamped,
            openingSkip: openingSkip,
            endingSkip: endingSkip,
            duration: appState.playerState.duration
        ) else {
            validateSkipDraft(clamped)
            return
        }
        switch skipEditorTarget {
        case .opening:
            updateOpeningSkip(clamped)
        case .ending:
            updateEndingSkip(clamped)
        }
        closeSkipEditor()
    }

    private func toggleOverlayPanel(_ panel: PlayerOverlayPanel) {
        if overlayPanel == panel {
            closeOverlayPanel()
            return
        }
        if panel == .settings {
            syncSettingsState()
        }
        withPlayerAnimation {
            overlayPanel = panel
            showHUD = true
            isVolumePopoverPresented = false
        }
    }

    private func closeOverlayPanel() {
        withPlayerAnimation {
            overlayPanel = .none
            showHUD = true
        }
    }

    private func handleVideoPointerShortcut(clickCount: Int) {
        guard let action = PlayerPointerShortcutPolicy.action(forClickCount: clickCount) else { return }
        isPointerInsidePlayer = true
        switch action {
        case .togglePlayPause:
            togglePlayPause()
        case .toggleFullScreen:
            toggleFullScreen()
        }
    }

    private func showHUDTemporarily() {
        restorePlayerCursor()
        withPlayerAnimation {
            showHUD = true
        }
        resetHUDTimer()
    }

    private func updateTrackPopoverTimer(isPresented: Bool) {
        showHUD = true
        if isPresented {
            hideHUDTimer?.invalidate()
            restorePlayerCursor()
        } else if !isSubtitlePopoverPresented && !isAudioPopoverPresented {
            resetHUDTimer()
        }
    }

    private func resetHUDTimer() {
        hideHUDTimer?.invalidate()
        guard visualRegressionConfiguration == nil else { return }
        guard shouldAutoHidePlayerChrome else {
            restorePlayerCursor()
            return
        }

        hideHUDTimer = Timer.scheduledTimer(withTimeInterval: PlayerCursorVisibilityPolicy.inactivityInterval, repeats: false) { _ in
            Task { @MainActor in
                guard shouldAutoHidePlayerChrome else {
                    restorePlayerCursor()
                    return
                }
                hidePlayerChrome()
            }
        }
    }

    private var hasBlockingPlayerUI: Bool {
        overlayPanel != .none
            || isSkipEditorPresented
            || isVolumePopoverPresented
            || isSubtitlePopoverPresented
            || isAudioPopoverPresented
    }

    private var hasBlockingPlaybackActivityUI: Bool {
        hasBlockingPlayerUI
            || appState.playbackWarningMessage != nil
            || playerState.errorMessage != nil
    }

    private var isPlaybackActivityActive: Bool {
        if let state = visualRegressionConfiguration?.state {
            return state == .loading || state == .buffering
        }
        return PlayerPlaybackActivityPolicy.isActive(
            isSourceLoading: appState.isPlayerLoading,
            isMediaLoading: playerState.isMediaLoading,
            isBuffering: playerState.isBuffering
        )
    }

    private var playbackActivityPhase: PlayerPlaybackActivityPhase {
        if let state = visualRegressionConfiguration?.state {
            switch state {
            case .loading:
                return PlayerPlaybackActivityPhase(
                    kind: .loading,
                    title: "正在加载视频",
                    message: "正在解析高清播放地址..."
                )
            case .buffering:
                return PlayerPlaybackActivityPhase(
                    kind: .buffering,
                    title: "正在缓冲",
                    message: "网络速度较慢，正在补充播放缓存。"
                )
            default:
                break
            }
        }
        return PlayerPlaybackActivityPolicy.vodPhase(
            isSourceLoading: appState.isPlayerLoading,
            sourceLoadingMessage: appState.playerLoadingMessage,
            isMediaLoading: playerState.isMediaLoading,
            isBuffering: playerState.isBuffering,
            hasBlockingUI: hasBlockingPlaybackActivityUI
        )
    }

    private var playbackActivityBufferedAheadDuration: Double {
        switch visualRegressionConfiguration?.state {
        case .loading:
            return 0
        case .buffering:
            return 42
        default:
            return playerState.bufferedAheadDuration
        }
    }

    private var shouldAutoHidePlayerChrome: Bool {
        PlayerCursorVisibilityPolicy.shouldHide(
            isPlaying: appState.playerState.isPlaying,
            isPointerInside: isPointerInsidePlayer,
            hasBlockingUI: hasBlockingPlayerUI,
            isLoading: isPlaybackActivityActive
        )
    }

    private func hidePlayerChrome() {
        withPlayerAnimation {
            showHUD = false
            isVolumePopoverPresented = false
        }
        PlayerCursorController.hideUntilMouseMoves()
    }

    private func restorePlayerCursor() {
        PlayerCursorController.restore()
    }

    private func startProgressSaveTimer() {
        progressSaveTimer?.invalidate()
        progressSaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                if appState.playerState.isPlaying {
                    appState.saveCurrentPlaybackProgress()
                }
            }
        }
    }

    private func exitPlayer() {
        appState.saveCurrentPlaybackProgress()
        appState.cleanupDrivePlaybackIfNeeded(spec: appState.playerState.currentSpec)
        MPVPlayerEngine.vod.stop()
        appState.beginPlayerDismissalReturningToDetail()
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func enterFullScreen() {
        guard let window = NSApp.keyWindow,
              !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    private func exitFullScreen() {
        guard let window = NSApp.keyWindow,
              window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    private func syncSettingsState() {
        subtitleFontSize = UserPreferences.shared.subtitleFontSize
        subtitlePosition = UserPreferences.shared.subtitlePosition
        subtitleOverrideSourceStyle = UserPreferences.shared.subtitleOverrideSourceStyle
        syncVodSkipState()
        danmakuEnabled = UserPreferences.shared.danmakuEnabled
        danmakuOpacity = UserPreferences.shared.danmakuOpacity
        danmakuFontSize = UserPreferences.shared.danmakuFontSize
        danmakuOffsetMs = UserPreferences.shared.danmakuOffsetMs
    }

    private func syncVodSkipState() {
        let settings = VodSkipSettingsStore.shared.settings(for: currentVodSkipIdentity)
        openingSkip = settings.openingSeconds
        endingSkip = settings.endingSeconds
    }

    private func applyVisualRegressionSettingsState() {
        subtitleFontSize = 44
        subtitlePosition = 95
        subtitleOverrideSourceStyle = true
        openingSkip = 0
        endingSkip = 0
        danmakuEnabled = true
        danmakuOpacity = 0.8
        danmakuFontSize = 28
        danmakuOffsetMs = 0
    }

    private func updateSubtitleFontSize(_ value: Int) {
        subtitleFontSize = min(72, max(16, value))
        UserPreferences.shared.subtitleFontSize = subtitleFontSize
        MPVPlayerEngine.vod.refreshSubtitleStyle()
    }

    private func updateSubtitlePosition(_ value: Int) {
        subtitlePosition = min(100, max(0, value))
        UserPreferences.shared.subtitlePosition = subtitlePosition
        MPVPlayerEngine.vod.refreshSubtitleStyle()
    }

    private func updateSubtitleOverride(_ enabled: Bool) {
        subtitleOverrideSourceStyle = enabled
        UserPreferences.shared.subtitleOverrideSourceStyle = enabled
        MPVPlayerEngine.vod.refreshSubtitleStyle()
    }

    private func updateOpeningSkip(_ value: Int) {
        guard let currentVodSkipIdentity else { return }
        let settings = VodSkipSettingsStore.shared.save(
            openingSeconds: value,
            endingSeconds: endingSkip,
            for: currentVodSkipIdentity
        )
        openingSkip = settings.openingSeconds
    }

    private func updateEndingSkip(_ value: Int) {
        guard let currentVodSkipIdentity else { return }
        let settings = VodSkipSettingsStore.shared.save(
            openingSeconds: openingSkip,
            endingSeconds: value,
            for: currentVodSkipIdentity
        )
        endingSkip = settings.endingSeconds
    }

    private func updateDanmakuEnabled(_ enabled: Bool) {
        danmakuEnabled = enabled
        UserPreferences.shared.danmakuEnabled = enabled
        appState.playerState.danmakuStatus = enabled ? "弹幕已启用，等待手动搜索" : "弹幕已关闭"
    }
}

private struct SkipMarkerIcon: View {
    let label: String
    let missingSide: HorizontalEdge
    let accent: Color

    var body: some View {
        ZStack {
            ZStack {
                SkipArc()
                    .stroke(accent.opacity(0.85), style: StrokeStyle(lineWidth: PlayerHUDVisualPolicy.skipIconStrokeWidth, lineCap: .round, lineJoin: .round))
                SkipArcHead()
                    .stroke(accent.opacity(0.9), style: StrokeStyle(lineWidth: PlayerHUDVisualPolicy.skipIconStrokeWidth, lineCap: .round, lineJoin: .round))
            }
            .rotationEffect(.degrees(missingSide == .leading ? 180 : 0))
            Text(label)
                .font(.system(size: PlayerHUDVisualPolicy.skipIconTextSize, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: PlayerHUDVisualPolicy.skipIconSize, height: PlayerHUDVisualPolicy.skipIconSize)
    }
}

private struct PlayerHUDGlyph: View {
    let kind: PlayerHUDGlyphKind
    let size: CGFloat
    var emphasized: Bool = false
    var baseStrokeWidth: CGFloat = PlayerHUDVisualPolicy.iconGlyphStrokeWidth

    private var lineWidth: CGFloat {
        emphasized ? PlayerHUDVisualPolicy.primaryGlyphStrokeWidth : baseStrokeWidth
    }

    var body: some View {
        ZStack {
            switch kind {
            case .backArrow:
                backArrowGlyph
            case .routeBolt:
                routeBoltGlyph
            case .previousEpisode:
                episodeStepGlyph(pointsLeft: true)
            case .nextEpisode:
                episodeStepGlyph(pointsLeft: false)
            case .rewind10:
                tenSecondGlyph(pointsLeft: true)
            case .forward10:
                tenSecondGlyph(pointsLeft: false)
            case .play:
                playPauseGlyph(paused: false)
            case .pause:
                playPauseGlyph(paused: true)
            case .episodeGrid:
                gridGlyph
            case .subtitles:
                subtitlesGlyph
            case .audio:
                audioGlyph
            case .aspectRatio:
                aspectRatioGlyph
            case .speed:
                speedGlyph
            case .settings:
                gearGlyph
            case .fullscreen:
                fullscreenGlyph
            case .volume:
                volumeGlyph
            }
        }
        .frame(width: size, height: size)
    }

    private var backArrowGlyph: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path { path in
                path.move(to: point(15, 5, in: rect))
                path.addLine(to: point(8, 12, in: rect))
                path.addLine(to: point(15, 19, in: rect))
                path.move(to: point(9, 12, in: rect))
                path.addLine(to: point(20, 12, in: rect))
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private var routeBoltGlyph: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path { path in
                path.move(to: point(13, 2, in: rect))
                path.addLine(to: point(4, 14, in: rect))
                path.addLine(to: point(11, 14, in: rect))
                path.addLine(to: point(10, 22, in: rect))
                path.addLine(to: point(20, 9, in: rect))
                path.addLine(to: point(13, 9, in: rect))
                path.closeSubpath()
            }
            .fill()
        }
    }

    private func episodeStepGlyph(pointsLeft: Bool) -> some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path { path in
                if pointsLeft {
                    path.move(to: point(6, 5, in: rect))
                    path.addLine(to: point(6, 19, in: rect))
                    path.move(to: point(19, 6, in: rect))
                    path.addLine(to: point(10, 12, in: rect))
                    path.addLine(to: point(19, 18, in: rect))
                    path.closeSubpath()
                } else {
                    path.move(to: point(18, 5, in: rect))
                    path.addLine(to: point(18, 19, in: rect))
                    path.move(to: point(5, 6, in: rect))
                    path.addLine(to: point(14, 12, in: rect))
                    path.addLine(to: point(5, 18, in: rect))
                    path.closeSubpath()
                }
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private func tenSecondGlyph(pointsLeft: Bool) -> some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            ZStack {
                Path { path in
                    if pointsLeft {
                        path.move(to: point(7, 8, in: rect))
                        path.addLine(to: point(3, 8, in: rect))
                        path.addLine(to: point(3, 4, in: rect))
                    } else {
                        path.move(to: point(17, 8, in: rect))
                        path.addLine(to: point(21, 8, in: rect))
                        path.addLine(to: point(21, 4, in: rect))
                    }
                }
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                TenSecondArc(pointsLeft: pointsLeft)
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                Text("10")
                    .font(.system(size: size * PlayerHUDVisualPolicy.tenSecondTextSizeRatio, weight: .medium))
                    .monospacedDigit()
                    .position(point(12, 13.3, in: rect))
            }
        }
    }

    private func playPauseGlyph(paused: Bool) -> some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            if paused {
                Path { path in
                    path.addRect(rectFor(x: 7, y: 5, width: 4, height: 14, in: rect))
                    path.addRect(rectFor(x: 13, y: 5, width: 4, height: 14, in: rect))
                }
                .fill()
            } else {
                Path { path in
                    path.move(to: point(8, 5, in: rect))
                    path.addLine(to: point(8, 19, in: rect))
                    path.addLine(to: point(19, 12, in: rect))
                    path.closeSubpath()
                }
                .fill()
            }
        }
    }

    private var gridGlyph: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path { path in
                path.addRect(rectFor(x: 4, y: 5, width: 6, height: 6, in: rect))
                path.addRect(rectFor(x: 14, y: 5, width: 6, height: 6, in: rect))
                path.addRect(rectFor(x: 4, y: 15, width: 6, height: 4, in: rect))
                path.addRect(rectFor(x: 14, y: 15, width: 6, height: 4, in: rect))
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private var subtitlesGlyph: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path { path in
                path.addRoundedRect(in: rectFor(x: 4, y: 6, width: 16, height: 12, in: rect), cornerSize: CGSize(width: 2, height: 2))
                path.move(to: point(7, 11, in: rect))
                path.addLine(to: point(11, 11, in: rect))
                path.move(to: point(13, 11, in: rect))
                path.addLine(to: point(17, 11, in: rect))
                path.move(to: point(7, 15, in: rect))
                path.addLine(to: point(14, 15, in: rect))
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private var audioGlyph: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path { path in
                path.move(to: point(4, 8, in: rect))
                path.addLine(to: point(8, 8, in: rect))
                path.addLine(to: point(10, 5, in: rect))
                path.addLine(to: point(13, 13, in: rect))
                path.addLine(to: point(15, 8, in: rect))
                path.addLine(to: point(20, 8, in: rect))
                path.move(to: point(4, 16, in: rect))
                path.addLine(to: point(9, 16, in: rect))
                path.addLine(to: point(11, 13, in: rect))
                path.addLine(to: point(13, 18, in: rect))
                path.addLine(to: point(15, 16, in: rect))
                path.addLine(to: point(20, 16, in: rect))
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private var aspectRatioGlyph: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path { path in
                path.addRoundedRect(in: rectFor(x: 4, y: 6, width: 16, height: 12, in: rect), cornerSize: CGSize(width: 2, height: 2))
                path.move(to: point(8, 10, in: rect))
                path.addLine(to: point(16, 10, in: rect))
                path.move(to: point(8, 14, in: rect))
                path.addLine(to: point(16, 14, in: rect))
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private var speedGlyph: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path { path in
                path.addOpenDesignSVGArc(
                    from: point(PlayerHUDVisualPolicy.speedArcStartPoint.x, PlayerHUDVisualPolicy.speedArcStartPoint.y, in: rect),
                    to: point(PlayerHUDVisualPolicy.speedArcEndPoint.x, PlayerHUDVisualPolicy.speedArcEndPoint.y, in: rect),
                    radius: radius(PlayerHUDVisualPolicy.speedArcRadius, in: rect),
                    largeArc: true,
                    sweepClockwise: true
                )
                path.move(to: point(PlayerHUDVisualPolicy.speedNeedleStartPoint.x, PlayerHUDVisualPolicy.speedNeedleStartPoint.y, in: rect))
                path.addLine(to: point(PlayerHUDVisualPolicy.speedNeedleEndPoint.x, PlayerHUDVisualPolicy.speedNeedleEndPoint.y, in: rect))
                path.move(to: point(PlayerHUDVisualPolicy.speedBaseStartPoint.x, PlayerHUDVisualPolicy.speedBaseStartPoint.y, in: rect))
                path.addLine(to: point(PlayerHUDVisualPolicy.speedBaseEndPoint.x, PlayerHUDVisualPolicy.speedBaseEndPoint.y, in: rect))
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private var gearGlyph: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path { path in
                path.addEllipse(in: rectFor(x: 8, y: 8, width: 8, height: 8, in: rect))
                path.move(to: point(4, 12, in: rect))
                path.addLine(to: point(6, 12, in: rect))
                path.move(to: point(18, 12, in: rect))
                path.addLine(to: point(20, 12, in: rect))
                path.move(to: point(12, 4, in: rect))
                path.addLine(to: point(12, 6, in: rect))
                path.move(to: point(12, 18, in: rect))
                path.addLine(to: point(12, 20, in: rect))
                path.move(to: point(6.3, 6.3, in: rect))
                path.addLine(to: point(7.7, 7.7, in: rect))
                path.move(to: point(16.3, 16.3, in: rect))
                path.addLine(to: point(17.7, 17.7, in: rect))
                path.move(to: point(17.7, 6.3, in: rect))
                path.addLine(to: point(16.3, 7.7, in: rect))
                path.move(to: point(7.7, 16.3, in: rect))
                path.addLine(to: point(6.3, 17.7, in: rect))
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private var fullscreenGlyph: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path { path in
                path.move(to: point(8, 4, in: rect))
                path.addLine(to: point(4, 4, in: rect))
                path.addLine(to: point(4, 8, in: rect))
                path.move(to: point(16, 4, in: rect))
                path.addLine(to: point(20, 4, in: rect))
                path.addLine(to: point(20, 8, in: rect))
                path.move(to: point(8, 20, in: rect))
                path.addLine(to: point(4, 20, in: rect))
                path.addLine(to: point(4, 16, in: rect))
                path.move(to: point(16, 20, in: rect))
                path.addLine(to: point(20, 20, in: rect))
                path.addLine(to: point(20, 16, in: rect))
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private var volumeGlyph: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            Path { path in
                path.move(to: point(4, 10, in: rect))
                path.addLine(to: point(4, 14, in: rect))
                path.addLine(to: point(8, 14, in: rect))
                path.addLine(to: point(13, 18, in: rect))
                path.addLine(to: point(13, 6, in: rect))
                path.addLine(to: point(8, 10, in: rect))
                path.addLine(to: point(4, 10, in: rect))
                path.closeSubpath()
                path.move(to: point(16, 9, in: rect))
                path.addCurve(
                    to: point(16, 15, in: rect),
                    control1: point(17.2, 10.6, in: rect),
                    control2: point(17.2, 13.4, in: rect)
                )
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect, box: CGFloat = 24) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x / box, y: rect.minY + rect.height * y / box)
    }

    private func rectFor(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, in rect: CGRect, box: CGFloat = 24) -> CGRect {
        CGRect(
            x: rect.minX + rect.width * x / box,
            y: rect.minY + rect.height * y / box,
            width: rect.width * width / box,
            height: rect.height * height / box
        )
    }

    private func radius(_ value: CGFloat, in rect: CGRect, box: CGFloat = 24) -> CGFloat {
        min(rect.width, rect.height) * value / box
    }
}

private struct TenSecondArc: Shape {
    let pointsLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = pointsLeft ? PlayerHUDVisualPolicy.rewindArcStartPoint : PlayerHUDVisualPolicy.forwardArcStartPoint
        let end = pointsLeft ? PlayerHUDVisualPolicy.rewindArcEndPoint : PlayerHUDVisualPolicy.forwardArcEndPoint
        path.addOpenDesignSVGArc(
            from: point(start.x, start.y, in: rect),
            to: point(end.x, end.y, in: rect),
            radius: radius(PlayerHUDVisualPolicy.tenSecondArcRadius, in: rect),
            largeArc: true,
            sweepClockwise: pointsLeft
        )
        return path
    }

    private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect, box: CGFloat = 24) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x / box, y: rect.minY + rect.height * y / box)
    }

    private func radius(_ value: CGFloat, in rect: CGRect, box: CGFloat = 24) -> CGFloat {
        min(rect.width, rect.height) * value / box
    }
}

private extension Path {
    mutating func addOpenDesignSVGArc(from start: CGPoint, to end: CGPoint, radius: CGFloat, largeArc: Bool, sweepClockwise: Bool) {
        guard radius > 0 else {
            move(to: start)
            addLine(to: end)
            return
        }

        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = max(0.0001, hypot(dx, dy))
        let adjustedRadius = max(radius, distance / 2)
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let halfChord = distance / 2
        let centerDistance = sqrt(max(0, adjustedRadius * adjustedRadius - halfChord * halfChord))
        let normal = CGPoint(x: -dy / distance, y: dx / distance)
        let candidateA = CGPoint(x: midpoint.x + normal.x * centerDistance, y: midpoint.y + normal.y * centerDistance)
        let candidateB = CGPoint(x: midpoint.x - normal.x * centerDistance, y: midpoint.y - normal.y * centerDistance)

        func sweepDelta(center: CGPoint, clockwise: Bool) -> CGFloat {
            let startAngle = atan2(start.y - center.y, start.x - center.x)
            let endAngle = atan2(end.y - center.y, end.x - center.x)
            var delta = endAngle - startAngle
            if clockwise {
                if delta < 0 { delta += .pi * 2 }
            } else if delta > 0 {
                delta -= .pi * 2
            }
            return abs(delta)
        }

        let deltaA = sweepDelta(center: candidateA, clockwise: sweepClockwise)
        let deltaB = sweepDelta(center: candidateB, clockwise: sweepClockwise)
        let wantsLarge = largeArc
        let center: CGPoint
        if (deltaA > .pi) == wantsLarge {
            center = candidateA
        } else if (deltaB > .pi) == wantsLarge {
            center = candidateB
        } else {
            center = deltaA >= deltaB ? candidateA : candidateB
        }

        addArc(
            center: center,
            radius: adjustedRadius,
            startAngle: .radians(Double(atan2(start.y - center.y, start.x - center.x))),
            endAngle: .radians(Double(atan2(end.y - center.y, end.x - center.x))),
            clockwise: PlayerHUDVisualPolicy.swiftUIClockwise(forSVGSweepClockwise: sweepClockwise)
        )
    }
}

private struct SkipArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addOpenDesignSVGArc(
            from: point(PlayerHUDVisualPolicy.skipArcStartPoint.x, PlayerHUDVisualPolicy.skipArcStartPoint.y, in: rect),
            to: point(PlayerHUDVisualPolicy.skipArcEndPoint.x, PlayerHUDVisualPolicy.skipArcEndPoint.y, in: rect),
            radius: radius(PlayerHUDVisualPolicy.skipArcRadius, in: rect),
            largeArc: true,
            sweepClockwise: true
        )
        return path
    }
}

private struct SkipArcHead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(PlayerHUDVisualPolicy.skipArrowUpperPoint.x, PlayerHUDVisualPolicy.skipArrowUpperPoint.y, in: rect))
        path.addLine(to: point(PlayerHUDVisualPolicy.skipArrowTipPoint.x, PlayerHUDVisualPolicy.skipArrowTipPoint.y, in: rect))
        path.addLine(to: point(PlayerHUDVisualPolicy.skipArrowLowerPoint.x, PlayerHUDVisualPolicy.skipArrowLowerPoint.y, in: rect))
        return path
    }
}

private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect, box: CGFloat = 32) -> CGPoint {
    CGPoint(x: rect.minX + rect.width * x / box, y: rect.minY + rect.height * y / box)
}

private func radius(_ value: CGFloat, in rect: CGRect, box: CGFloat = 32) -> CGFloat {
    min(rect.width, rect.height) * value / box
}

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

struct MPVVideoView: NSViewRepresentable {
    let engine: MPVPlayerEngine
    let surface: MPVVideoSurface
    var attachmentRevision: Int = 0

    func makeNSView(context: Context) -> MPVOpenGLVideoView {
        let view = MPVOpenGLVideoView(engine: engine, surface: surface)!
        let generation = view.activatePlaybackSurface()
        Task { @MainActor in
            guard view.acceptsPlaybackSurfaceAttachment(generation: generation) else { return }
            engine.attach(to: view, surface: surface)
        }
        return view
    }

    func updateNSView(_ nsView: MPVOpenGLVideoView, context: Context) {
        let generation = nsView.activatePlaybackSurface()
        Task { @MainActor in
            guard nsView.acceptsPlaybackSurfaceAttachment(generation: generation) else { return }
            engine.attach(to: nsView, surface: surface)
        }
    }

    static func dismantleNSView(_ nsView: MPVOpenGLVideoView, coordinator: ()) {
        nsView.deactivatePlaybackSurface()
        Task { @MainActor in
            nsView.detachFromPlayerEngine()
        }
    }
}

private struct DanmakuOverlayView: View {
    let cues: [DanmakuCue]
    let positionMs: Int
    let opacity: Double
    let fontSize: Int

    private let scrollDurationMs = 7_000
    private let fixedDurationMs = 4_000

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(visibleCues) { cue in
                    cueView(cue)
                        .position(position(for: cue, in: proxy.size))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }

    private var visibleCues: [DanmakuCue] {
        DanmakuOverlayPolicy.visibleCues(
            cues,
            positionMs: positionMs,
            scrollDurationMs: scrollDurationMs,
            fixedDurationMs: fixedDurationMs
        )
    }

    private func cueView(_ cue: DanmakuCue) -> some View {
        Text(cue.text)
            .font(.system(size: CGFloat(DanmakuOverlayPolicy.effectiveFontSize(fontSize)), weight: .semibold))
            .foregroundStyle(color(for: cue.color).opacity(opacity))
            .lineLimit(1)
            .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func position(for cue: DanmakuCue, in size: CGSize) -> CGPoint {
        let effectiveFontSize = DanmakuOverlayPolicy.effectiveFontSize(fontSize)
        let laneHeight = CGFloat(effectiveFontSize + 10)
        let laneCount = DanmakuOverlayPolicy.laneCount(containerHeight: size.height, fontSize: effectiveFontSize)
        let lane = DanmakuOverlayPolicy.stableLane(for: cue.id, count: laneCount)
        let y = CGFloat(lane) * laneHeight + laneHeight
        switch cue.mode {
        case .scroll:
            let progress = min(1, max(0, Double(positionMs - cue.timeMs) / Double(scrollDurationMs)))
            let x = size.width + 240 - CGFloat(progress) * (size.width + 480)
            return CGPoint(x: x, y: y)
        case .top:
            return CGPoint(x: size.width / 2, y: y)
        case .bottom:
            return CGPoint(x: size.width / 2, y: max(laneHeight, size.height - y))
        }
    }

    private func color(for hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return .white
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
