// NetVplayerApp/Views/SidebarView.swift
// Immersive library navigation for the macOS main window.

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appThemePalette) private var palette
    @Binding var selectedTab: SidebarTab
    @AppStorage("webHomeEnabled") private var webHomeEnabled: Bool = false
    @State private var hoveredTab: SidebarTab?

    var body: some View {
        let panelShape = RoundedRectangle(
            cornerRadius: HomeVisualPolicy.primarySidebarPanelCornerRadius,
            style: .continuous
        )

        VStack(alignment: .leading, spacing: 0) {
            brandHeader

            VStack(spacing: HomeVisualPolicy.sidebarNavigationGap) {
                ForEach(HomeVisualPolicy.sidebarTabs(webHomeEnabled: webHomeEnabled)) { tab in
                    navigationButton(for: tab)
                }
            }
            .padding(.horizontal, HomeVisualPolicy.sidebarHorizontalPadding)
            .padding(.top, HomeVisualPolicy.sidebarNavigationTopPadding)

            Spacer(minLength: 24)

            aboutLabel
                .padding(.horizontal, HomeVisualPolicy.sidebarHorizontalPadding)
                .padding(.bottom, 14)
        }
        .foregroundStyle(palette.foreground)
        .clipShape(panelShape)
        .background {
            AppGlassSurface(
                cornerRadius: HomeVisualPolicy.primarySidebarPanelCornerRadius,
                role: .chrome,
                normalOpacityOverride: palette.surfaceTokens.primarySidebarChromeOpacity
            )
        }
        .shadow(
            color: .black.opacity(
                palette.tone == .light
                    ? HomeVisualPolicy.primarySidebarLightShadowOpacity
                    : HomeVisualPolicy.primarySidebarDarkShadowOpacity
            ),
            radius: HomeVisualPolicy.primarySidebarShadowRadius,
            y: HomeVisualPolicy.primarySidebarShadowY
        )
        .onAppear(perform: normalizeSelection)
        .onChange(of: webHomeEnabled) { _, _ in
            normalizeSelection()
        }
    }

    private var brandHeader: some View {
        HStack(spacing: HomeVisualPolicy.sidebarBrandSpacing) {
            brandIconField

            VStack(alignment: .leading, spacing: HomeVisualPolicy.sidebarBrandCopySpacing) {
                Text("NetVplayer")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("媒体中心")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        palette.muted.opacity(HomeVisualPolicy.sidebarBrandSubtitleOpacity)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, HomeVisualPolicy.sidebarBrandContentLeadingPadding)
        .padding(.trailing, HomeVisualPolicy.sidebarBrandContentTrailingPadding)
        .padding(.top, HomeVisualPolicy.sidebarBrandTopPadding)
        .padding(.bottom, HomeVisualPolicy.sidebarBrandBottomPadding)
        .background {
            LinearGradient(
                stops: [
                    .init(
                        color: palette.lavender.opacity(
                            HomeVisualPolicy.sidebarBrandBackdropLavenderOpacity
                        ),
                        location: 0
                    ),
                    .init(
                        color: palette.surface.opacity(
                            HomeVisualPolicy.sidebarBrandBackdropSurfaceOpacity
                        ),
                        location: 0.62
                    ),
                    .init(color: .clear, location: 0.94),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: HomeVisualPolicy.sidebarBrandBackdropCornerRadius,
                    style: .continuous
                )
            )
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(
                            color: .black,
                            location: HomeVisualPolicy.sidebarBrandBackdropFadeStart
                        ),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .padding(.leading, HomeVisualPolicy.sidebarBrandBackdropLeadingInset)
            .padding(.trailing, HomeVisualPolicy.sidebarBrandBackdropTrailingInset)
            .padding(.bottom, HomeVisualPolicy.sidebarBrandBackdropBottomInset)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: HomeVisualPolicy.sidebarBrandDividerAccentLeadingInset)

                Rectangle()
                    .fill(
                        palette.accent.opacity(
                            HomeVisualPolicy.sidebarBrandDividerAccentOpacity
                        )
                    )
                    .frame(width: HomeVisualPolicy.sidebarBrandDividerAccentWidth)

                Rectangle()
                    .fill(
                        palette.lavender.opacity(
                            HomeVisualPolicy.sidebarBrandDividerLavenderOpacity
                        )
                    )
                    .frame(maxWidth: .infinity)
            }
            .frame(height: HomeVisualPolicy.sidebarBrandDividerHeight)
            .padding(.trailing, HomeVisualPolicy.sidebarBrandDividerTrailingInset)
        }
        .accessibilityElement(children: .combine)
    }

    private var brandIconField: some View {
        ZStack {
            AppGlassSurface(
                cornerRadius: HomeVisualPolicy.sidebarBrandIconCornerRadius,
                role: .raised,
                normalOpacityOverride: HomeVisualPolicy.sidebarBrandSurfaceOpacity,
                usesSystemMaterial: false
            )

            AppBrandIcon(size: HomeVisualPolicy.sidebarBrandIconSize)
        }
        .frame(
            width: HomeVisualPolicy.sidebarBrandIconFieldSize,
            height: HomeVisualPolicy.sidebarBrandIconFieldSize
        )
    }

    private func navigationButton(for tab: SidebarTab) -> some View {
        let isSelected = selectedTab == tab
        let isHovered = hoveredTab == tab

        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                if tab == .liveStream {
                    appState.presentLivePlayer()
                } else {
                    selectedTab = tab
                }
            }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    AppNavigationIconBackground(
                        isSelected: isSelected,
                        isHovered: isHovered
                    )

                    Image(systemName: tab.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(
                            isSelected ? palette.color(for: .onAccent) : palette.muted
                        )
                }
                .frame(width: HomeVisualPolicy.sidebarIconBoxSize, height: HomeVisualPolicy.sidebarIconBoxSize)

                Text(tab.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? palette.foreground : palette.muted)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: HomeVisualPolicy.sidebarNavigationRowHeight)
            .background {
                AppNavigationRowBackground(
                    isSelected: isSelected,
                    isHovered: isHovered
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: HomeVisualPolicy.sidebarCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
            }
        }
    }

    private var aboutLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle")
            Text("关于 \(AppVersionDisplay.label())")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(palette.muted.opacity(HomeVisualPolicy.mutedTextOpacity))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .help("关于 NetVplayer")
    }

    private func normalizeSelection() {
        guard SidebarTab.visibleTabs.contains(selectedTab) else {
            selectedTab = .vodHome
            return
        }
    }

}
