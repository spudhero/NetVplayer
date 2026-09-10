// NetVplayerApp/Views/FavoritesView.swift
// Saved VOD and live items in the shared cinematic library system.

import SwiftUI
import Models

struct FavoritesView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appThemePalette) private var palette

    private let columns = [
        GridItem(
            .adaptive(
                minimum: HomeVisualPolicy.posterMinimumWidth,
                maximum: HomeVisualPolicy.posterMaximumWidth
            ),
            spacing: HomeVisualPolicy.posterHorizontalGap,
            alignment: .topLeading
        )
    ]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                pageHeader

                if appState.keepItems.isEmpty {
                    AppUnavailableState(
                        title: "暂无收藏",
                        message: "收藏的点播内容和直播频道会集中显示在这里。",
                        systemImage: "star.slash"
                    )
                } else {
                    ThemedScrollView {
                        LazyVGrid(columns: columns, spacing: HomeVisualPolicy.posterVerticalGap) {
                            ForEach(appState.keepItems) { item in
                                FavoritePosterCard(
                                    item: item,
                                    onOpen: {
                                        Task {
                                            await appState.openKeep(item)
                                        }
                                    },
                                    onRemove: {
                                        appState.removeKeep(item)
                                    }
                                )
                            }
                        }
                        .padding(.bottom, 32)
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            }
            .padding(.horizontal, AppSurfaceVisualPolicy.pageHorizontalPadding)
            .padding(.top, HomeVisualPolicy.contentTopPadding)
        }
        .foregroundStyle(palette.foreground)
        .tint(palette.accent)
        .ignoresSafeArea(edges: .top)
    }

    private var pageHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("我的收藏")
                    .font(.system(size: 22, weight: .bold))
                Text(appState.keepItems.isEmpty ? "把常看的内容留在手边" : "共 \(appState.keepItems.count) 个收藏")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.muted)
            }
            Spacer(minLength: 0)
        }
        .frame(height: AppSurfaceVisualPolicy.pageHeaderHeight)
        .padding(.bottom, 16)
    }
}

private struct FavoritePosterCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appThemePalette) private var palette
    let item: Keep
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onOpen) {
                cardContent
            }
            .buttonStyle(.plain)

            if isHovered {
                removeButton
                    .padding(7)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
            }
        }
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("取消收藏", systemImage: "trash")
            }
        }
        .scaleEffect(isHovered ? 1.018 : 1)
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                cover

                VStack(alignment: .trailing, spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.accent)
                        .frame(width: 30, height: 30)
                        .background(AppGlassSurface(cornerRadius: 15, role: .panel))

                    if item.hasUpdate {
                        Text("有更新")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(palette.color(for: .onAccent))
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(palette.accent, in: Capsule())
                    }
                }
                .padding(7)
            }
            .aspectRatio(PosterMetrics.aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: HomeVisualPolicy.posterCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HomeVisualPolicy.posterCornerRadius, style: .continuous)
                    .stroke(
                        isHovered
                            ? palette.lavender.opacity(HomeVisualPolicy.hoverBorderOpacity)
                            : palette.foreground.opacity(0.10),
                        lineWidth: isHovered ? 1.5 : 1
                    )
            }
            .shadow(
                color: isHovered
                    ? palette.lavender.opacity(HomeVisualPolicy.hoverShadowOpacity)
                    : Color.black.opacity(0.22),
                radius: isHovered ? 18 : 8,
                y: isHovered ? 8 : 4
            )

            Text(item.vodName)
                .font(.system(size: HomeVisualPolicy.posterTitleFontSize, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(item.type == .live ? "直播" : "点播")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(item.type == .live ? palette.accent : palette.lavender)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(
                        (item.type == .live ? palette.accent : palette.lavender)
                            .opacity(0.12),
                        in: Capsule()
                    )

                Text(item.hasUpdate ? (item.latestRemarks.isEmpty ? item.siteName : item.latestRemarks) : item.siteName)
                    .font(.system(size: HomeVisualPolicy.posterMetadataFontSize, weight: .medium))
                    .foregroundStyle(palette.muted.opacity(HomeVisualPolicy.mutedTextOpacity))
                    .lineLimit(1)
            }
        }
    }

    private var removeButton: some View {
        Button(role: .destructive, action: onRemove) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(palette.color(for: .danger).opacity(0.90))
                .frame(width: 30, height: 30)
                .background(AppGlassSurface(cornerRadius: 15, role: .panel))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help("取消收藏 \(item.vodName)")
        .accessibilityLabel("取消收藏 \(item.vodName)")
    }

    @ViewBuilder
    private var cover: some View {
        if item.type == .live && item.vodPic.isEmpty {
            RoundedRectangle(cornerRadius: HomeVisualPolicy.posterCornerRadius, style: .continuous)
                .fill(palette.surface.opacity(0.58))
                .overlay {
                    Image(systemName: "tv.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
        } else {
            WebImage(urlString: item.vodPic, siteHeader: siteHeader, fallbackText: item.vodName)
                .aspectRatio(PosterMetrics.aspectRatio, contentMode: .fill)
        }
    }

    private var siteHeader: [String: String]? {
        guard item.type == .vod else { return nil }
        let identity = PlaybackLinkage.vodIdentity(from: item.key)
        return appState.sites.first(where: { $0.key == identity.siteKey })?.header
    }
}
