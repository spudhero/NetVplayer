// NetVplayerApp/Views/VodDetailView.swift
// 视频详情页

import SwiftUI
import ApplicationCore
import Models
import DriveEngine
import PlayerEngine
import Storage

struct VodDetailThemeBackground: View {
    let palette: AppThemePalette
    let artworkURL: String
    let siteHeader: [String: String]?

    var body: some View {
        ZStack {
            AppThemeBackdropLayer(palette: palette)

            if !artworkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                GeometryReader { proxy in
                    WebImage(
                        urlString: artworkURL,
                        siteHeader: siteHeader,
                        showsLoadingIndicator: false
                    )
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .saturation(0.65)
                        .blur(radius: 40)
                        .opacity(0.08)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct VodDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appThemePalette) private var palette
    let vod: Vod
    let layout: VodDetailLayout

    // 当前选中的线路
    @State private var localSelectedFlag: String = ""
    @State private var episodeSortOrder: EpisodeSortOrder = .ascending

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(
                .flexible(
                    minimum: VodDetailLayoutPolicy.episodeItemMinimumWidth,
                    maximum: VodDetailLayoutPolicy.episodeItemMaximumWidth
                ),
                spacing: VodDetailLayoutPolicy.episodeGridSpacing
            ),
            count: layout.episodeColumnCount
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VodDetailThemeBackground(
                palette: palette,
                artworkURL: detail.vodBackground.isEmpty ? detail.vodPic : detail.vodBackground,
                siteHeader: appState.activeSite?.header
            )
                .frame(width: layout.containerSize.width, height: layout.containerSize.height)

            AppGlassSurface(
                cornerRadius: AppSurfaceVisualPolicy.panelCornerRadius,
                role: .raised,
                normalOpacityOverride: 0.18
            )
            .allowsHitTesting(false)

            HStack(spacing: 0) {
                informationPane

                Divider()
                    .overlay(palette.foreground.opacity(0.12))
                    .padding(.horizontal, layout.columnSpacing / 2)
                    .padding(.vertical, layout.contentInset)

                playbackPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                appState.isDetailPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.body.bold())
                    .foregroundStyle(palette.muted)
                    .frame(
                        width: VodDetailLayoutPolicy.closeButtonSize,
                        height: VodDetailLayoutPolicy.closeButtonSize
                    )
                    .background(palette.surface.opacity(0.82))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("关闭详情")
            .accessibilityLabel("关闭")
            .padding(layout.closeButtonInset)
            .zIndex(10)

            if appState.isPlayerLoading {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(palette.accent)
                            
                            Text(appState.playerLoadingMessage)
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            Button(action: {
                                Task {
                                    await appState.cancelLoading()
                                }
                            }) {
                                Text("取消")
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.2))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .frame(width: layout.containerSize.width, height: layout.containerSize.height)
        .clipped()
        .foregroundStyle(palette.foreground)
        .tint(palette.accent)
        .onAppear {
            // 初始化选中线路
            if localSelectedFlag.isEmpty {
                localSelectedFlag = appState.selectedPlayFlag
            }
        }
        .onChange(of: appState.selectedPlayFlag) { _, newValue in
            localSelectedFlag = newValue
        }
        .alert("播放失败", isPresented: $appState.isPlaybackErrorPresented) {
            if appState.playbackErrorAuthProvider != nil {
                Button {
                    appState.openCloudAuthFromPlaybackError()
                } label: {
                    Label("扫码授权", systemImage: "qrcode.viewfinder")
                }
            }
            Button("知道了", role: .cancel) {
                appState.clearPlaybackError()
            }
        } message: {
            Text(appState.playbackErrorMessage ?? "当前集数暂时无法播放")
        }
        .sheet(item: $appState.pendingPlaybackSelection) { request in
            PlaybackSourcePicker(request: request)
                .environmentObject(appState)
        }
    }

    private var informationPane: some View {
        ThemedScrollView {
            VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                ZStack(alignment: .topTrailing) {
                    WebImage(
                        urlString: detail.vodPic,
                        siteHeader: appState.activeSite?.header,
                        fallbackText: detail.vodName
                    )
                        .aspectRatio(PosterMetrics.aspectRatio, contentMode: .fill)
                        .frame(width: layout.posterWidth, height: layout.posterHeight)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: HomeVisualPolicy.posterCornerRadius,
                                style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: HomeVisualPolicy.posterCornerRadius,
                                style: .continuous
                            )
                            .stroke(palette.foreground.opacity(0.12), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)

                    Button {
                        appState.toggleKeep(vod: detail)
                    } label: {
                        Image(systemName: appState.isKept(vodId: detail.vodId) ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(
                                appState.isKept(vodId: detail.vodId)
                                    ? palette.accent
                                    : palette.foreground
                            )
                            .padding(8)
                            .background(palette.surface.opacity(0.72))
                            .clipShape(Circle())
                            .shadow(radius: 3)
                    }
                    .buttonStyle(.plain)
                    .help(appState.isKept(vodId: detail.vodId) ? "取消收藏" : "加入收藏")
                    .padding(10)
                }

                if !detail.vodLogo.isEmpty {
                    WebImage(urlString: detail.vodLogo, siteHeader: appState.activeSite?.header)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: layout.posterWidth, maxHeight: 64, alignment: .leading)
                }

                Text(detail.vodName)
                    .font(.system(size: layout.titleFontSize, weight: .bold))
                    .foregroundStyle(palette.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                if !vod.vodRemarks.isEmpty {
                    Text(vod.vodRemarks)
                        .font(.subheadline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(palette.lavender.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(palette.lavender)
                }

                if let progressText = appState.currentDetailHistoryProgressText() {
                    Label(progressText, systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(palette.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 6) {
                    if !vod.vodDirector.isEmpty {
                        Text("导演：").bold().foregroundColor(palette.muted) + Text(vod.vodDirector)
                    }
                    if !vod.vodActor.isEmpty {
                        Text("主演：").bold().foregroundColor(palette.muted) + Text(vod.vodActor)
                    }
                    if !vod.typeName.isEmpty {
                        Text("类型：").bold().foregroundColor(palette.muted) + Text(vod.typeName)
                    }
                    if !areaAndYearText.isEmpty {
                        Text("地区/年份：").bold().foregroundColor(palette.muted)
                            + Text(areaAndYearText)
                    }
                }
                .font(.body)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("简介")
                        .font(.headline)
                    Text(vodDescription)
                        .font(.body)
                        .foregroundStyle(palette.muted)
                        .lineLimit(layout.overviewLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(layout.contentInset)
        }
        .frame(width: layout.informationPaneWidth)
        .frame(maxHeight: .infinity)
        .background(palette.surface.opacity(0.18))
    }

    @ViewBuilder
    private var playbackPane: some View {
        Group {
            if appState.isDetailLoading && appState.playFlags.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                        .tint(palette.accent)
                    Text("正在加载详情...")
                        .font(.headline)
                    Text("正在获取播放线路与选集")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if appState.playFlags.isEmpty {
                VStack {
                    Spacer()
                    AppUnavailableState(
                        title: "暂无可播放资源",
                        message: "当前来源的播放地址已全部失效或未解析出可播放视频",
                        systemImage: "play.slash.fill"
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                playbackContent
            }
        }
        .padding(.horizontal, layout.contentInset)
        .padding(.top, layout.playbackTopInset)
        .padding(.bottom, layout.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playbackContent: some View {
        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
            if appState.playFlags.count > 1 {
                playbackLineSection
                Divider()
            }

            episodeSection
        }
    }

    private var playbackLineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("播放线路")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(appState.playFlags, id: \.self) { flag in
                        let status = flagStatus(for: flag)
                        Button {
                            localSelectedFlag = flag
                            appState.selectPlayFlag(flag)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: status.icon)
                                    .font(.caption)
                                Text(flag)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                localSelectedFlag == flag
                                    ? palette.lavender.opacity(0.18)
                                    : palette.foreground.opacity(0.06)
                            )
                            .foregroundStyle(localSelectedFlag == flag ? palette.foreground : palette.muted)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(
                                        localSelectedFlag == flag
                                            ? palette.accent.opacity(0.52)
                                            : status.color.opacity(0.35),
                                        lineWidth: 1
                                    )
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(status.tooltip)
                    }
                }
            }
        }
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            episodeToolbar

            if selectedFlagStatus.shouldShowBanner {
                statusBanner
            }

            if appState.episodes.isEmpty {
                VStack {
                    Spacer()
                    AppUnavailableState(
                        title: "暂无集数",
                        message: selectedFlagStatus.description,
                        systemImage: "play.slash.fill"
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ThemedScrollView {
                    episodeCollection
                        .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var episodeToolbar: some View {
        let status = selectedFlagStatus

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                episodeHeading(status: status)
                Spacer(minLength: 12)
                episodeControls(status: status)
            }

            VStack(alignment: .leading, spacing: 8) {
                episodeHeading(status: status)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    episodeControls(status: status)
                }
            }
        }
    }

    private func episodeHeading(status: FlagStatus) -> some View {
        HStack(spacing: 10) {
            Text("播放选集")
                .font(.headline)
            Label(status.label, systemImage: status.icon)
                .font(.caption)
                .foregroundColor(status.color)
        }
    }

    private func episodeControls(status: FlagStatus) -> some View {
        HStack(spacing: 10) {
            EpisodeSortOrderButton(selection: $episodeSortOrder)
                .tint(palette.accent)
            EpisodeDisplayModePicker(selection: $appState.episodeDisplayMode)
                .tint(palette.accent)
            if let provider = status.authProvider {
                Button {
                    appState.requestCloudAuth(provider)
                } label: {
                    Label("扫码授权", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: selectedFlagStatus.icon)
                .foregroundColor(selectedFlagStatus.color)
            Text(selectedFlagStatus.description)
                .font(.caption)
                .foregroundStyle(palette.muted)
                .lineLimit(2)

            Spacer()

            if selectedFlagStatus.isUnsupported,
               let quarkFlag = firstQuarkFlag,
               quarkFlag != localSelectedFlag {
                Button("切换夸克") {
                    localSelectedFlag = quarkFlag
                    appState.selectPlayFlag(quarkFlag)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(selectedFlagStatus.color.opacity(0.08))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selectedFlagStatus.color.opacity(0.2), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var vodDescription: String {
        let content = VodDescriptionPresentation.text(from: detail.vodContent)
        return content.isEmpty ? "暂无简介" : content
    }

    private var areaAndYearText: String {
        [detail.vodArea, detail.vodYear]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }
}

private struct PlaybackSourcePicker: View {
    private struct CandidateGroup: Identifiable {
        let id: String
        let name: String
        var candidates: [PlaybackCandidate]
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.appThemePalette) private var palette
    let request: PlaybackSelectionRequest

    private var groups: [CandidateGroup] {
        var order: [String] = []
        var values: [String: CandidateGroup] = [:]
        for candidate in request.candidates {
            if values[candidate.providerKey] == nil {
                order.append(candidate.providerKey)
                values[candidate.providerKey] = CandidateGroup(
                    id: candidate.providerKey,
                    name: candidate.providerName,
                    candidates: []
                )
            }
            values[candidate.providerKey]?.candidates.append(candidate)
        }
        return order.compactMap { values[$0] }
    }

    private var preferredCandidateID: String? {
        appState.preferredPlaybackCandidateID(for: request)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("选择播放源")
                        .font(.title3.weight(.semibold))
                    Text(request.episode.name)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }

                Spacer()

                Button {
                    appState.dismissPlaybackSelection()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(16)

            Divider()

            ThemedScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(group.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.muted)

                            ForEach(group.candidates) { candidate in
                                candidateButton(candidate)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 620, height: 480)
        .background(.ultraThinMaterial)
        .background(palette.surface.opacity(0.74))
        .foregroundStyle(palette.foreground)
    }

    private func candidateButton(_ candidate: PlaybackCandidate) -> some View {
        let isPreferred = candidate.id == preferredCandidateID
        return Button {
            Task { await appState.selectPlaybackCandidate(candidate) }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: candidate.isPlayable ? "play.circle.fill" : "nosign")
                    .font(.system(size: 18))
                    .foregroundStyle(candidate.isPlayable ? palette.accent : palette.muted)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(candidate.name.isEmpty ? candidate.providerName : candidate.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)

                        if isPreferred {
                            Label("上次选择", systemImage: "bookmark.fill")
                                .font(.caption2)
                                .foregroundStyle(palette.accent)
                        }

                        Spacer(minLength: 0)

                        Text(candidateKindLabel(candidate))
                            .font(.caption2.monospaced())
                            .foregroundStyle(palette.muted)
                    }

                    if !candidate.description.isEmpty {
                        Text(candidate.description)
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .lineLimit(3)
                    }

                    if !candidate.isPlayable {
                        Text(candidate.unavailableReason.isEmpty ? "当前播放方式不可用" : candidate.unavailableReason)
                            .font(.caption)
                            .foregroundStyle(palette.color(for: .warning))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.foreground.opacity(candidate.isPlayable ? 0.055 : 0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isPreferred ? palette.accent.opacity(0.55) : palette.foreground.opacity(0.1),
                        lineWidth: 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!candidate.isPlayable)
    }

    private func candidateKindLabel(_ candidate: PlaybackCandidate) -> String {
        if candidate.kind == .directURL {
            return candidate.format.isEmpty ? "HTTP" : candidate.format.uppercased()
        }
        switch candidate.kind {
        case .externalURL: return "EXTERNAL"
        case .torrent: return "TORRENT"
        case .youtube: return "YOUTUBE"
        case .usenet: return "USENET"
        case .archive: return "ARCHIVE"
        case .unknown: return "UNKNOWN"
        case .directURL: return "HTTP"
        }
    }
}

private extension VodDetailView {
    var detail: Vod {
        appState.detailVod ?? vod
    }

    var selectedFlagStatus: FlagStatus {
        flagStatus(for: localSelectedFlag.isEmpty ? appState.selectedPlayFlag : localSelectedFlag)
    }

    var firstQuarkFlag: String? {
        appState.playFlags.first { flag in
            appState.playbackEpisodes(for: flag).contains {
                DriveFileReference.provider(for: $0.url) == .quark
            }
        }
    }

    func flagStatus(for flagName: String) -> FlagStatus {
        guard appState.playFlags.contains(flagName) else {
            return .empty("当前线路未解析出有效的视频集数")
        }

        let episodes = appState.playbackEpisodes(for: flagName)
        let providers = episodes.map { DriveFileReference.provider(for: $0.url) }
        let sourceStatuses = episodes.map { SourceManager.shared.support(for: $0.url) }
        if !sourceStatuses.isEmpty,
           sourceStatuses.allSatisfy({ $0.status == .unsupported }),
           let reason = sourceStatuses.first?.reason,
           !reason.isEmpty {
            return .unsupported(reason)
        }
        if providers.contains(.quark) {
            let hasCookie = !UserPreferences.shared.quarkCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasCookie
                ? .ready("夸克目录已展开，可尝试播放")
                : .needsAuth(.quark, "夸克目录已展开，完整播放需要扫码授权；Token 用于个人网盘，Cookie 用于分享播放")
        }
        if providers.contains(.uc) {
            let hasCookie = !UserPreferences.shared.ucCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasCookie
                ? .ready("UC 目录已展开，可尝试播放")
                : .needsAuth(.uc, "UC 目录已展开，Wogg 分享播放需要 UC Cookie；扫码 Token 暂不支持分享直链")
        }
        if providers.contains(.ali) {
            let hasToken = !UserPreferences.shared.aliRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !UserPreferences.shared.aliAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !UserPreferences.shared.aliOpenToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasToken
                ? .ready("阿里云盘目录已展开，可尝试播放")
                : .needsAuth(.ali, "阿里云盘目录已展开，完整播放需要 refresh_token / access_token")
        }
        if providers.contains(.p115) {
            let hasCookie = !UserPreferences.shared.p115Cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasCookie
                ? .ready("115 目录已展开，可尝试播放")
                : .needsAuth(.p115, "115 目录已展开，完整播放需要 115 Cookie")
        }
        if providers.contains(.baidu) {
            let hasCookie = !UserPreferences.shared.baiduCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasCookie
                ? .ready("百度网盘目录已展开，可转存原画播放")
                : .needsAuth(.baidu, "百度网盘目录已展开，播放前需要扫码登录")
        }
        if episodes.isEmpty {
            if flagName.contains("网盘") {
                return .empty("未找到可播放视频，已过滤图片、字幕截图、海报等附件")
            }
            return .empty("当前线路未解析出有效的视频集数")
        }
        return .ready("当前线路可尝试播放")
    }

    func episodeSupport(for episode: Episode) -> SourceSupport {
        SourceManager.shared.support(for: episode.url)
    }

    @ViewBuilder
    var episodeCollection: some View {
        let episodes = episodeSortOrder.ordered(appState.episodes)

        switch appState.episodeDisplayMode {
        case .grid:
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(episodes, id: \.url) { episode in
                    episodeButton(episode, displayMode: .grid)
                }
            }
        case .list:
            LazyVStack(spacing: 10) {
                ForEach(episodes, id: \.url) { episode in
                    episodeButton(episode, displayMode: .list)
                }
            }
        }
    }

    func episodeButton(_ episode: Episode, displayMode: EpisodeDisplayMode) -> some View {
        let support = episodeSupport(for: episode)
        let isHistoryEpisode = appState.isHistoryEpisode(episode)

        return Button {
            Task {
                await appState.playEpisode(episode)
            }
        } label: {
            switch displayMode {
            case .grid:
                episodeButtonLabel(
                    episode: episode,
                    isHistoryEpisode: isHistoryEpisode,
                    support: support
                )
            case .list:
                episodeListButtonLabel(
                    episode: episode,
                    isHistoryEpisode: isHistoryEpisode,
                    support: support
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(support.status == .unsupported)
        .help(support.status == .unsupported ? support.reason : episode.name)
    }

    func episodeButtonLabel(episode: Episode, isHistoryEpisode: Bool, support: SourceSupport) -> some View {
        let isUnsupported = support.status == .unsupported
        let foreground: Color = isUnsupported ? palette.muted : (isHistoryEpisode ? palette.accent : palette.foreground)
        let background = episodeBackgroundColor(isHistoryEpisode: isHistoryEpisode, support: support)
        let stroke = episodeStrokeColor(isHistoryEpisode: isHistoryEpisode, support: support)

        return VStack(spacing: 6) {
            if let artwork = episode.artwork, !artwork.isEmpty {
                WebImage(urlString: artwork, siteHeader: appState.activeSite?.header)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 78)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Text(episode.name)
                .font(.subheadline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let overview = episode.overview, !overview.isEmpty {
                Text(overview)
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            if isHistoryEpisode {
                Label("上次", systemImage: "clock")
                    .font(.caption2.weight(.semibold))
                    .labelStyle(.titleAndIcon)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 42)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .foregroundStyle(foreground)
        .background(background.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(stroke.opacity(0.42), lineWidth: isHistoryEpisode ? 1.5 : 1)
        )
        .cornerRadius(8)
    }

    func episodeListButtonLabel(episode: Episode, isHistoryEpisode: Bool, support: SourceSupport) -> some View {
        let isUnsupported = support.status == .unsupported
        let foreground: Color = isUnsupported ? palette.muted : (isHistoryEpisode ? palette.accent : palette.foreground)
        let background = episodeBackgroundColor(isHistoryEpisode: isHistoryEpisode, support: support)
        let stroke = episodeStrokeColor(isHistoryEpisode: isHistoryEpisode, support: support)

        return HStack(alignment: .top, spacing: 12) {
            if let artwork = episode.artwork, !artwork.isEmpty {
                WebImage(urlString: artwork, siteHeader: appState.activeSite?.header)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(width: 104, height: 58)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(episode.name)
                    .font(.subheadline.weight(isHistoryEpisode ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if isHistoryEpisode {
                    Label("上次", systemImage: "clock")
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .foregroundStyle(foreground)
        .background(background.opacity(0.12))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(stroke.opacity(0.42), lineWidth: isHistoryEpisode ? 1.5 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    func episodeBackgroundColor(isHistoryEpisode: Bool, support: SourceSupport) -> Color {
        if support.status == .unsupported { return palette.muted }
        return isHistoryEpisode ? palette.accent : palette.lavender
    }

    func episodeStrokeColor(isHistoryEpisode: Bool, support: SourceSupport) -> Color {
        if support.status == .unsupported { return palette.muted }
        return isHistoryEpisode ? palette.accent : palette.lavender
    }
}

private enum FlagStatus {
    case ready(String)
    case needsAuth(DriveProvider, String)
    case unsupported(String)
    case empty(String)

    var icon: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .needsAuth: return "qrcode.viewfinder"
        case .unsupported: return "exclamationmark.triangle.fill"
        case .empty: return "play.slash.fill"
        }
    }

    var label: String {
        switch self {
        case .ready: return "可展开"
        case .needsAuth: return "需授权"
        case .unsupported: return "暂不支持"
        case .empty: return "无集数"
        }
    }

    var description: String {
        switch self {
        case .ready(let message), .needsAuth(_, let message), .unsupported(let message), .empty(let message):
            return message
        }
    }

    var tooltip: String {
        "\(label)：\(description)"
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .needsAuth: return .orange
        case .unsupported, .empty: return .secondary
        }
    }

    var authProvider: DriveProvider? {
        if case .needsAuth(let provider, _) = self {
            return provider
        }
        return nil
    }

    var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }

    var shouldShowBanner: Bool {
        switch self {
        case .ready:
            return false
        case .needsAuth, .unsupported, .empty:
            return true
        }
    }
}
