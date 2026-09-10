// NetVplayerApp/Views/HomeVisualPolicy.swift
// Shared geometry and color posture for the macOS library home surface.

import SwiftUI

struct HomePosterGridLayout: Equatable {
    let columnCount: Int
    let itemWidth: CGFloat
}

enum HomeVisualPolicy {
    static let sidebarMinWidth: CGFloat = 196
    static let sidebarIdealWidth: CGFloat = 218
    static let sidebarMaxWidth: CGFloat = 244
    static let primarySidebarOuterInset: CGFloat = 8
    static let primarySidebarPaneMinWidth = sidebarMinWidth + primarySidebarOuterInset
    static let primarySidebarPaneIdealWidth = sidebarIdealWidth + primarySidebarOuterInset
    static let primarySidebarPaneMaxWidth = primarySidebarPaneIdealWidth
    static let primarySidebarPanelCornerRadius: CGFloat = 20
    static let primarySidebarShadowRadius: CGFloat = 14
    static let primarySidebarShadowY: CGFloat = 5
    static let primarySidebarLightShadowOpacity: Double = 0.14
    static let primarySidebarDarkShadowOpacity: Double = 0.24
    static let sidebarHorizontalPadding: CGFloat = 14
    static let sidebarNavigationRowHeight: CGFloat = 48
    static let sidebarNavigationGap: CGFloat = 6
    static let sidebarNavigationTopPadding: CGFloat = 10
    static let sidebarBrandIconSize: CGFloat = 36
    static let sidebarBrandIconFieldSize: CGFloat = 41
    static let sidebarBrandIconCornerRadius: CGFloat = 11
    static let sidebarBrandSpacing: CGFloat = 9
    static let sidebarBrandCopySpacing: CGFloat = 3
    static let sidebarBrandContentLeadingPadding: CGFloat = 14
    static let sidebarBrandContentTrailingPadding: CGFloat = 19
    static let sidebarBrandTopPadding: CGFloat = 8
    static let sidebarBrandBottomPadding: CGFloat = 12
    static let sidebarBrandBackdropLeadingInset: CGFloat = 9
    static let sidebarBrandBackdropTrailingInset: CGFloat = 12
    static let sidebarBrandBackdropCornerRadius: CGFloat = 14
    static let sidebarBrandBackdropLavenderOpacity: CGFloat = 0.088
    static let sidebarBrandBackdropSurfaceOpacity: CGFloat = 0.104
    static let sidebarBrandBackdropBottomInset: CGFloat = 4
    static let sidebarBrandBackdropFadeStart: CGFloat = 0.76
    static let sidebarBrandDividerAccentLeadingInset: CGFloat = 36
    static let sidebarBrandDividerAccentWidth: CGFloat = 28
    static let sidebarBrandDividerTrailingInset: CGFloat = 18
    static let sidebarBrandDividerHeight: CGFloat = 0.5
    static let sidebarBrandDividerAccentOpacity: CGFloat = 0.50
    static let sidebarBrandDividerLavenderOpacity: CGFloat = 0.25
    static let sidebarBrandSurfaceOpacity: CGFloat = 0.30
    static let sidebarBrandBorderOpacity: CGFloat = 0.22
    static let sidebarBrandSubtitleOpacity: CGFloat = 0.88
    static let sidebarIconBoxSize: CGFloat = 30
    static let sidebarCornerRadius: CGFloat = 12
    static let sidebarBrandHeaderHeight = sidebarBrandTopPadding
        + sidebarBrandIconFieldSize
        + sidebarBrandBottomPadding

    static let contentHorizontalPadding: CGFloat = 28
    static let contentTopPadding: CGFloat = 29
    static let headerHeight: CGFloat = 48
    static let headerControlHeight: CGFloat = 42
    static let headerControlCornerRadius: CGFloat = 13
    static let headerGap: CGFloat = 14
    static let sitePickerWidth: CGFloat = 288
    static let searchIdealWidth: CGFloat = 360
    static let collapsedHeaderLeadingInset: CGFloat = 184
    static let headerControlTopInset = contentTopPadding
        + (headerHeight - headerControlHeight) / 2
    static let primarySidebarTopInset = headerControlTopInset
    static let primarySidebarNavigationTopDistance = primarySidebarTopInset
        + sidebarBrandHeaderHeight
        + sidebarNavigationTopPadding

    static func isSidebarPresented(detailLeadingEdge: CGFloat) -> Bool {
        detailLeadingEdge >= sidebarMinWidth - 1
    }

    static func headerLeadingInset(isSidebarPresented: Bool) -> CGFloat {
        isSidebarPresented ? 0 : collapsedHeaderLeadingInset
    }

    static let categoryHeight: CGFloat = 34
    static let categoryHorizontalPadding: CGFloat = 16
    static let categoryGap: CGFloat = 10
    static let categoryCornerRadius: CGFloat = 13
    static let categoryBottomPadding: CGFloat = 18

    static let posterMinimumWidth: CGFloat = 148
    static let posterMaximumWidth: CGFloat = 196
    static let posterHorizontalGap: CGFloat = 18
    static let posterVerticalGap: CGFloat = 24
    static let posterCornerRadius: CGFloat = 12
    static let posterTitleFontSize: CGFloat = 14
    static let posterMetadataFontSize: CGFloat = 12

    static func posterAvailableWidth(containerWidth: CGFloat) -> CGFloat {
        max(
            0,
            containerWidth
                - (contentHorizontalPadding * 2)
                - AppScrollbarMetrics.gutterWidth
        )
    }

    static func posterGridLayout(availableWidth: CGFloat) -> HomePosterGridLayout {
        let width = availableWidth.isFinite ? max(0, availableWidth) : 0
        let columnCount = max(
            1,
            Int((width + posterHorizontalGap) / (posterMinimumWidth + posterHorizontalGap))
        )
        let totalGap = CGFloat(columnCount - 1) * posterHorizontalGap
        let fittedWidth = max(0, (width - totalGap) / CGFloat(columnCount))
        return HomePosterGridLayout(
            columnCount: columnCount,
            itemWidth: min(fittedWidth, posterMaximumWidth)
        )
    }

    static func posterRowStarts(itemCount: Int, columnCount: Int) -> [Int] {
        guard itemCount > 0 else { return [] }
        return Array(stride(from: 0, to: itemCount, by: max(1, columnCount)))
    }

    static let selectedBackgroundOpacity: CGFloat = 0.16
    static let selectedBorderOpacity: CGFloat = 0.46
    static let hoverBorderOpacity: CGFloat = 0.64
    static let hoverShadowOpacity: CGFloat = 0.20
    static let mutedTextOpacity: CGFloat = 0.72

    static func sidebarTabs(webHomeEnabled: Bool) -> [SidebarTab] {
        var tabs: [SidebarTab] = [.vodHome, .liveStream, .history, .favorites]
        if webHomeEnabled {
            tabs.append(.webHome)
        }
        tabs.append(.settings)
        return tabs
    }
}

enum AppSurfaceVisualPolicy {
    static let pageBackgroundSurfaceOpacity: CGFloat = 0.72
    static let pageHorizontalPadding: CGFloat = 28
    static let pageHeaderHeight: CGFloat = 64
    static let settingsHeaderHeight: CGFloat = 86
    static let settingsTitleTopPadding: CGFloat = HomeVisualPolicy.contentTopPadding
    static let settingsContentMaxWidth: CGFloat = 920
    static let settingsBottomPadding: CGFloat = 32
    static let pageSectionGap: CGFloat = 18
    static let panelCornerRadius: CGFloat = 16
    static let localSidebarWidth: CGFloat = 218
    static let localNavigationRowHeight: CGFloat = 46
    static let localNavigationGap: CGFloat = 6
}

struct AppGlassSurface: View {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    var role: AppSurfaceRole = .panel
    var normalOpacityOverride: Double? = nil
    var usesSystemMaterial: Bool = true
    var reduceTransparencyOverride: Bool? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let normalOpacity = normalOpacityOverride ?? palette.surfaceOpacity(for: role)
        let shouldReduceTransparency = reduceTransparencyOverride ?? reduceTransparency

        Group {
            if shouldReduceTransparency {
                shape.fill(
                    palette.surface.opacity(
                        palette.surfaceOpacity(
                            for: role,
                            reduceTransparency: true
                        )
                    )
                )
            } else if role == .chrome || !usesSystemMaterial {
                shape.fill(
                    palette.surface.opacity(normalOpacity)
                )
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill(
                            palette.surface.opacity(normalOpacity)
                        )
                    }
            }
        }
            .overlay {
                shape.stroke(
                    palette.foreground.opacity(
                        shouldReduceTransparency ? 0.22 : palette.surfaceTokens.borderOpacity
                    ),
                    lineWidth: 1
                )
            }
            .shadow(
                color: .black.opacity(
                    shouldReduceTransparency ? 0 : palette.surfaceTokens.shadowOpacity
                ),
                radius: role == .raised ? 12 : 0,
                y: role == .raised ? 6 : 0
            )
    }
}

struct AppNavigationRowBackground: View {
    @Environment(\.appThemePalette) private var palette
    let isSelected: Bool
    let isHovered: Bool
    var cornerRadius: CGFloat = HomeVisualPolicy.sidebarCornerRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        shape
            .fill(
                isSelected
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                palette.accent.opacity(
                                    palette.surfaceTokens.selectionPrimaryOpacity
                                ),
                                palette.lavender.opacity(
                                    palette.surfaceTokens.selectionSecondaryOpacity
                                ),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    : AnyShapeStyle(
                        palette.foreground.opacity(isHovered ? 0.06 : 0)
                    )
            )
            .overlay {
                shape.stroke(
                    isSelected
                        ? palette.accent.opacity(
                            palette.surfaceTokens.selectionBorderOpacity
                        )
                        : .clear,
                    lineWidth: 1
                )
            }
    }
}

struct AppNavigationIconBackground: View {
    @Environment(\.appThemePalette) private var palette
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
                isSelected
                    ? palette.accent
                    : palette.foreground.opacity(isHovered ? 0.09 : 0.045)
            )
    }
}

struct AppGroupBoxStyle: GroupBoxStyle {
    @Environment(\.appThemePalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.foreground)

            configuration.content
                .foregroundStyle(palette.foreground)
        }
        .padding(16)
        .background {
            AppGlassSurface(
                cornerRadius: AppSurfaceVisualPolicy.panelCornerRadius,
                role: .panel
            )
        }
    }
}

struct AppUnavailableState: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(palette.lavender.opacity(0.12))
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.color(for: .onAccent))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
