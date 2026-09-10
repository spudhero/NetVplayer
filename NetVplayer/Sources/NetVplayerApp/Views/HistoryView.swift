// NetVplayerApp/Views/HistoryView.swift
// Playback history in the shared cinematic library system.

import SwiftUI
import Models

struct HistoryView: View {
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

                if appState.historyItems.isEmpty {
                    AppUnavailableState(
                        title: "无播放历史",
                        message: "观看过的影片会按最近播放时间显示在这里。",
                        systemImage: "clock.badge.questionmark"
                    )
                } else {
                    ThemedScrollView {
                        LazyVGrid(columns: columns, spacing: HomeVisualPolicy.posterVerticalGap) {
                            ForEach(appState.historyItems) { item in
                                HistoryPosterCard(
                                    item: item,
                                    onOpen: {
                                        Task {
                                            await appState.playHistory(item)
                                        }
                                    },
                                    onRemove: {
                                        appState.removeHistory(item)
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
                Text("播放历史")
                    .font(.system(size: 22, weight: .bold))
                Text(appState.historyItems.isEmpty ? "最近观看的内容会出现在这里" : "共 \(appState.historyItems.count) 条记录")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.muted)
            }

            Spacer(minLength: 0)

            if !appState.historyItems.isEmpty {
                Button(role: .destructive) {
                    appState.clearHistory()
                } label: {
                    Label("清空历史", systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .frame(height: 36)
                        .background(AppGlassSurface(cornerRadius: 11, role: .control))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.color(for: .danger).opacity(0.86))
            }
        }
        .frame(height: AppSurfaceVisualPolicy.pageHeaderHeight)
        .padding(.bottom, 16)
    }
}

private struct HistoryPosterCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appThemePalette) private var palette
    let item: History
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
                Label("从播放历史中删除", systemImage: "trash")
            }
        }
        .scaleEffect(isHovered ? 1.018 : 1)
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                WebImage(
                    urlString: item.vodPic,
                    siteHeader: appState.sites.first(where: { $0.key == item.siteKey })?.header,
                    fallbackText: item.vodName
                )
                .aspectRatio(PosterMetrics.aspectRatio, contentMode: .fill)
                .overlay {
                    if isHovered {
                        ZStack {
                            Circle()
                                .fill(palette.background.opacity(0.62))
                                .overlay {
                                    Circle()
                                        .stroke(palette.foreground.opacity(0.24), lineWidth: 1)
                                }
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(palette.accent)
                                .offset(x: 1)
                        }
                        .frame(width: 42, height: 42)
                        .transition(.scale(scale: 0.86).combined(with: .opacity))
                    }
                }

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(palette.background.opacity(0.58))
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(palette.accent)
                            .frame(width: geometry.size.width * min(1, max(0, item.progress)))
                    }
                }
                .frame(height: 4)
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

            Text("已观看 \(Int(item.progress * 100))%")
                .font(.system(size: HomeVisualPolicy.posterMetadataFontSize, weight: .semibold))
                .foregroundStyle(palette.accent)
                .lineLimit(1)

            Text(item.createTime.formatted(date: .numeric, time: .shortened))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.muted.opacity(HomeVisualPolicy.mutedTextOpacity))
                .lineLimit(1)
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
        .help("从播放历史中删除 \(item.vodName)")
        .accessibilityLabel("从播放历史中删除 \(item.vodName)")
    }
}
