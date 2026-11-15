import SwiftUI
import Models
import Storage
import MediaLibraryEngine

/// NAS details retain the existing player's selection, history and error presentation.
struct NASMediaDetailView: View {
    @EnvironmentObject private var appState: AppState
    let vod: Vod
    let size: CGSize
    @StateObject private var model = NASMediaDetailModel()
    @State private var editing = false
    @State private var didLoadInitialSelection = false

    var body: some View {
        NASMediaDetailContent(vod: vod, size: size, metadata: model.record?.metadata ?? fallbackMetadata,
            files: model.files, serviceName: model.serviceName, libraryName: model.libraryName,
            isRefreshing: model.isRefreshing, detailsUnavailable: model.detailsUnavailable,
            canEdit: model.record != nil, onEdit: { editing = true }, onRetry: { Task { await load() } },
            onCollection: { browse(.init(collection: MediaLibraryIdentity.collectionKey($0))) },
            onActor: { browse(.init(actor: MediaLibraryIdentity.actorKey($0))) },
            onDirector: { browse(.init(director: MediaLibraryIdentity.directorKey($0))) })
            .task(id: vod.vodId) { didLoadInitialSelection = false; await load() }
            .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
                if let record = model.record { MediaMetadataEditor(record: record) }
            }
    }

    private var fallbackMetadata: MediaMetadata {
        .init(title: vod.vodName, year: Int(vod.vodYear), plot: vod.vodContent,
              poster: vod.vodPic, fanart: vod.vodBackground)
    }
    private func browse(_ filter: MediaLibraryFilter) {
        guard let reference = model.record?.reference, let libraryID = reference.libraryID else { return }
        let state = FileServicesState.shared
        state.selectedLibraryID = libraryID; state.mode = .library
        state.setMediaFilter(filter)
        appState.detailVod = nil
        appState.isDetailPresented = false
    }
    private func load() async {
        guard let reference = FileResourceReference(locator: vod.vodId) else { return }
        await model.load(reference: reference)
        guard !Task.isCancelled, appState.detailVod?.vodId == reference.locator,
              !appState.isDetailLoading, let record = model.record, let site = appState.activeSite else { return }
        let refreshed = MediaLibraryPresentation.vod(record: record, group: model.files, site: site)
        var selectedFlag = appState.selectedPlayFlag
        appState.detailVod = refreshed
        if !didLoadInitialSelection, let history = appState.currentDetailHistory(),
           let flag = refreshed.parseFlags().first(where: { $0.episodes.contains { $0.url == history.episodeUrl } }) {
            selectedFlag = flag.name
        }
        didLoadInitialSelection = true
        appState.applyPlaybackAvailability(for: refreshed, preferredFlag: selectedFlag)
    }
}

struct NASMediaDetailContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appThemePalette) private var palette
    let vod: Vod
    let size: CGSize
    let metadata: MediaMetadata
    let files: [MediaRecord]
    let serviceName: String
    let libraryName: String
    var isRefreshing = false
    var detailsUnavailable = false
    var canEdit = false
    var onEdit: () -> Void = {}
    var onRetry: () -> Void = {}
    var onCollection: (MediaCollection) -> Void = { _ in }
    var onActor: (MediaCastMember) -> Void = { _ in }
    var onDirector: (String) -> Void = { _ in }
    var serverDetail: MediaServerDetail?
    @State private var expandedOverview = false
    @State private var expandedFiles = Set<String>()
    @State private var selectedEpisodeURL: String?
    @State private var explicitServerSourceID: String?
    @State private var expandedSeasons = Set<String>()

    private var isTV: Bool { metadata.kind == .television }
    private var isServer: Bool { MediaServerReference(locator: vod.vodId) != nil }
    private var title: String { NASMediaDetailPresentation.title(metadata: metadata, fallback: vod.vodName) }
    private var episodes: [Episode] { appState.playbackEpisodes(for: appState.selectedPlayFlag) }
    private var history: History? { appState.currentDetailHistory() }
    private var primaryEpisode: Episode? {
        NASMediaDetailPresentation.primaryEpisode(episodes: episodes, history: history, selectedURL: selectedEpisodeURL)
    }
    private var serverFiles: [MediaServerFileDetail] {
        MediaServerVersionSelection.files(serverDetail?.files ?? [], for: primaryEpisode?.url)
    }
    private var selectedServerSourceID: String? {
        MediaServerVersionSelection.preferredSourceID(explicit: explicitServerSourceID,
            historyURL: history?.episodeUrl, episodeURL: primaryEpisode?.url)
    }
    private var playbackEpisode: Episode? {
        primaryEpisode.map { isServer ? MediaServerVersionSelection.episode($0, sourceID: selectedServerSourceID) : $0 }
    }
    private var sourceFormats: [DolbySourceFormat] {
        if isServer {
            let selected = selectedServerSourceID.flatMap { id in serverFiles.first { $0.sourceID == id } }
                ?? (serverFiles.count == 1 ? serverFiles.first : nil)
            return selected.map(DolbySourceFormat.serverFile) ?? []
        }
        guard let episode = primaryEpisode, let record = files.first(where: { $0.id == episode.url }) else { return [] }
        return DolbySourceFormat.filename(record.entry.name)
    }
    private var canResume: Bool { history.map { $0.position > 0 && $0.episodeUrl == playbackEpisode?.url } ?? false }
    private var inset: CGFloat { size.width < 1100 ? 28 : 42 }
    private var surface: Color { palette.background.opacity(0.98) }
    private var plot: String { VodDescriptionPresentation.text(from: metadata.plot ?? "") }

    var body: some View {
        ThemedScrollView(theme: .subtle, scrollbarPlacement: .overlay) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 28) {
                    if isTV { episodesSection }
                    if let episode = playbackEpisode {
                        PlaybackSummaryView(store: appState.playerState.playbackSummaries,
                            identity: appState.playbackSummaryIdentity(vodID: vod.vodId,
                                line: appState.selectedPlayFlag, episodeURL: episode.url), episodeName: episode.name)
                    }
                    if !plot.isEmpty || !facts.isEmpty { overviewAndFacts }
                    if let cast = metadata.cast, !cast.isEmpty { castSection(cast) }
                    if isServer {
                        MediaServerFilesSection(files: serverFiles, selectedSourceID: selectedServerSourceID,
                            select: { explicitServerSourceID = $0 }, play: { sourceID in
                                explicitServerSourceID = sourceID
                                if let episode = primaryEpisode {
                                    play(MediaServerVersionSelection.episode(episode, sourceID: sourceID))
                                }
                            })
                    } else { filesSection }
                    attribution
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, inset).padding(.top, 24).padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { AppThemeBackdropLayer(palette: palette) }
        .foregroundStyle(palette.foreground)
        .tint(palette.accent)
        .frame(width: size.width, height: size.height)
        .onChange(of: primaryEpisode?.url) { _, _ in explicitServerSourceID = nil }
        .onChange(of: vod.vodId) { _, _ in explicitServerSourceID = nil }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                if let fanart = metadata.fanart, !fanart.isEmpty {
                    WebImage(urlString: fanart, showsLoadingIndicator: false, maxPixelSize: 2000)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width * 0.75, height: proxy.size.height, alignment: .top).clipped()
                        .saturation(0.65).opacity(0.7)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.3)], startPoint: .leading, endPoint: .trailing))
                        .offset(x: proxy.size.width * 0.25)
                }
                if metadata.fanart?.isEmpty == false {
                    LinearGradient(colors: [surface.opacity(0.82), surface.opacity(0.15)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.clear, surface.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                }
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 22) {
                Label([serviceName, libraryName].filter { !$0.isEmpty }.joined(separator: " / "), systemImage: isServer ? "server.rack" : "externaldrive.connected.to.line.below")
                    .font(.callout).foregroundStyle(palette.muted).padding(.trailing, 54)
                HStack(alignment: .bottom, spacing: 34) {
                    if let poster = metadata.poster, !poster.isEmpty {
                        WebImage(urlString: poster, showsLoadingIndicator: false, maxPixelSize: 500)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size.width < 1100 ? 148 : 168, height: size.width < 1100 ? 222 : 252, alignment: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.4), radius: 15, y: 8)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title).font(.system(size: size.width < 1100 ? 30 : 38, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                        if let original = metadata.originalTitle, original != title, !original.isEmpty {
                            Text(original).font(.title3).foregroundStyle(palette.muted)
                        }
                        Text(summary).font(.callout).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                        if !isTV, let collection = metadata.collection {
                            Button { onCollection(collection) } label: {
                                Label(collection.name, systemImage: "rectangle.stack")
                            }.buttonStyle(.plain).font(.callout).foregroundStyle(palette.accent)
                                .help(L10n.text("查看此系列的影片"))
                        }
                        HStack(spacing: 10) {
                            if let rating = serverDetail?.rating, rating > 0 { ratingBadge(L10n.text("服务器评分"), rating) }
                            if let rating = metadata.tmdbRating, rating > 0 { ratingBadge("TMDB", rating) }
                            if let rating = metadata.doubanRating, rating > 0 { ratingBadge(L10n.text("豆瓣"), rating) }
                        }
                        if let tagline = metadata.tagline, !tagline.isEmpty {
                            Text(tagline).font(.callout).italic().foregroundStyle(palette.muted).lineLimit(2)
                        }
                        if isTV, let episode = primaryEpisode {
                            Text(appState.selectedPlayFlag + " · " + episode.name).font(.callout).foregroundStyle(palette.muted)
                        }
                        if isServer, serverFiles.count > 1 || selectedServerSourceID != nil { serverVersionPicker }
                          if !sourceFormats.isEmpty {
                              VStack(alignment: .leading, spacing: 6) {
                                  Text(L10n.text("片源格式")).font(.caption).foregroundStyle(palette.muted)
                                  DolbySourceBadges(formats: sourceFormats)
                              }
                          }
                        playbackActions.padding(.top, 6)
                        if canResume, let history {
                            HStack(spacing: 10) {
                                if history.duration > 0 {
                                    ProgressView(value: min(Double(history.position) / Double(history.duration), 1))
                                        .frame(width: 110)
                                }
                                Text(PlaybackLinkage.progressText(for: history) ?? "").font(.caption).foregroundStyle(palette.muted)
                                Button(L10n.text("从头播放")) {
                                    if let episode = playbackEpisode { play(episode, restart: true) }
                                }.buttonStyle(.plain).font(.caption).foregroundStyle(palette.accent)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.horizontal, inset).padding(.top, 28).padding(.bottom, 28)
        }
    }

    private var summary: String {
        var values = [metadata.year.map(String.init), isTV ? L10n.text("剧集") : L10n.text("电影")].compactMap { $0 }
        values += metadata.genres ?? []
        if let minutes = metadata.runtimeMinutes, minutes > 0 {
            values.append(L10n.text(isTV ? "每集约 {0} 分钟" : "{0} 分钟", [String(minutes)]))
        }
        return values.joined(separator: " · ")
    }

    private func ratingBadge(_ name: String, _ rating: Double) -> some View {
        HStack(spacing: 6) { Text(name).font(.caption.bold()); Text(rating.formatted(.number.precision(.fractionLength(1)))).font(.callout.bold()) }
            .padding(.horizontal, 10).padding(.vertical, 5).background(palette.foreground.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
    }

    private var playbackActions: some View {
        HStack(spacing: 10) {
            Button { if let episode = playbackEpisode { play(episode) } } label: {
                Label(L10n.text(canResume ? "继续观看" : "立即播放"), systemImage: "play.fill")
                    .font(.headline).padding(.horizontal, 18).padding(.vertical, 10)
            }.buttonStyle(.borderedProminent).disabled(primaryEpisode == nil || appState.isDetailLoading)
            Button { appState.toggleKeep(vod: appState.detailVod ?? vod) } label: {
                Image(systemName: appState.isKept(vodId: vod.vodId) ? "star.fill" : "star")
                    .font(.title3).frame(width: 28, height: 32)
            }.buttonStyle(.bordered).help(L10n.text(appState.isKept(vodId: vod.vodId) ? "取消收藏" : "加入收藏"))
                .accessibilityLabel(L10n.text("个人收藏"))
            if canEdit { Button(action: onEdit) { Label(L10n.text("修正资料"), systemImage: "pencil") }.buttonStyle(.bordered) }
            if appState.isDetailLoading { ProgressView().controlSize(.small) }
        }
    }

    private var serverVersionPicker: some View {
        let playable = serverFiles.filter { $0.playbackLocator != nil }
        let available = playable.compactMap(\.sourceID)
        let missing = selectedServerSourceID.map { available.contains($0) ? [] : [$0] } ?? []
        return HStack(spacing: 12) {
            Text(L10n.text("播放版本")).font(.callout).fixedSize()
            SettingsChoicePicker(title: L10n.text("播放版本"), selection: Binding(
                get: { selectedServerSourceID ?? "" }, set: { explicitServerSourceID = $0 }
            ), choices: [""] + available + missing) { sourceID in
                if sourceID.isEmpty { return L10n.text("自动选择") }
                return playable.first { $0.sourceID == sourceID }?.name ?? L10n.text("所选版本（当前不可用）")
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .help(L10n.text("选择要播放的文件版本，也可在下方逐项查看。"))
    }

    private var overviewAndFacts: some View {
        let layout = size.width >= 900 ? AnyLayout(HStackLayout(alignment: .top, spacing: 36)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
        return layout {
            if !plot.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading(L10n.text("简介"))
                    Text(plot)
                        .font(.system(size: 14)).lineSpacing(5).foregroundStyle(palette.muted)
                        .lineLimit(expandedOverview ? nil : 4).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if plot.count > 150 {
                        Button(L10n.text(expandedOverview ? "收起简介" : "展开简介")) { expandedOverview.toggle() }
                            .buttonStyle(.plain).foregroundStyle(palette.accent).font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !facts.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    ForEach(facts, id: \.0) { label, value in
                        GridRow {
                            Text(label).foregroundStyle(palette.muted)
                            if label == L10n.text("导演"), !isServer {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(metadata.directors ?? [], id: \.self) { director in
                                        Button { onDirector(director) } label: {
                                            Text(director).fixedSize(horizontal: false, vertical: true)
                                        }.buttonStyle(.plain).foregroundStyle(palette.accent)
                                            .help(L10n.text("查看 {0} 执导的影片", [director]))
                                    }
                                }
                            } else {
                                Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }.font(.callout).frame(width: size.width >= 900 && !plot.isEmpty ? min(420, size.width * 0.28) : nil, alignment: .leading)
            }
        }
    }

    private var facts: [(String, String)] {
        let values: [(String, String?)] = [(L10n.text("导演"), metadata.directors?.joined(separator: " / ")),
         (L10n.text("编剧"), metadata.writers?.joined(separator: " / ")),
         (L10n.text("上映日期"), metadata.releaseDate),
         (L10n.text("国家 / 地区"), metadata.countries?.joined(separator: " / ")),
         (L10n.text("语言"), metadata.languages?.joined(separator: " / ")),
         (L10n.text("制作公司"), metadata.studios?.joined(separator: " / ")),
         (L10n.text("分级"), serverDetail?.officialRating)]
        return values.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading(L10n.text("剧集"))
                Text(L10n.text("{0} 集可播放", [String(episodes.count)])).font(.caption).foregroundStyle(palette.muted)
                Spacer()
                if !appState.playFlags.isEmpty {
                    Menu {
                        ForEach(appState.playFlags, id: \.self) { flag in
                            Button(flag) { appState.selectPlayFlag(flag) }
                        }
                    } label: {
                        Text(appState.selectedPlayFlag).font(.callout).foregroundStyle(palette.foreground)
                    }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 12).padding(.vertical, 7)
                        .background(palette.foreground.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(L10n.text("季"))
                }
            }
            if episodes.isEmpty {
                Text(L10n.text(appState.isDetailLoading ? "正在读取播放文件…" : "暂无可播放文件"))
                    .font(.callout).foregroundStyle(palette.muted)
            }
            let expanded = expandedSeasons.contains(appState.selectedPlayFlag)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(episodes.prefix(expanded ? episodes.count : 6)), id: \.url) { episode in
                    episodeCard(episode)
                }
            }
            if episodes.count > 6 {
                Button(L10n.text(expanded ? "收起剧集" : "显示全部 {0} 集", [String(episodes.count)])) {
                    if expanded { expandedSeasons.remove(appState.selectedPlayFlag) }
                    else { expandedSeasons.insert(appState.selectedPlayFlag) }
                }.buttonStyle(.plain).foregroundStyle(palette.accent).font(.callout)
            }
        }
    }

    private func episodeCard(_ episode: Episode) -> some View {
        let selected = primaryEpisode?.url == episode.url
        let record = files.first { $0.id == episode.url }
        return Button { selectedEpisodeURL = episode.url } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(episode.name).font(.callout.bold()).lineLimit(1)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent) }
                }
                Text(episode.overview ?? record?.localMetadata.plot ?? record?.entry.name ?? episode.name)
                    .font(.caption).foregroundStyle(palette.muted).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                Text(episode.released ?? NASMediaDetailPresentation.fileSummary(record)).font(.caption).foregroundStyle(palette.muted)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.foreground.opacity(selected ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? palette.accent.opacity(0.7) : palette.foreground.opacity(0.1)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading(L10n.text("文件与版本"))
                if !isTV { Text(L10n.text("{0} 个文件", [String(episodes.count)])).font(.caption).foregroundStyle(palette.muted) }
            }
            if episodes.isEmpty {
                Text(L10n.text(appState.isDetailLoading ? "正在读取播放文件…" : "暂无可播放文件"))
                    .font(.callout).foregroundStyle(palette.muted)
            }
            LazyVStack(spacing: 8) {
                ForEach(isTV ? primaryEpisode.map { [$0] } ?? [] : episodes, id: \.url) { episode in fileRow(episode) }
            }
        }
    }

    private func fileRow(_ episode: Episode) -> some View {
        let record = files.first { $0.id == episode.url }
        let expanded = expandedFiles.contains(episode.url)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                if !isTV, episodes.count > 1 {
                    Button { play(episode) } label: {
                        Image(systemName: "play.fill").font(.headline).frame(width: 32, height: 32)
                    }.buttonStyle(.bordered).accessibilityLabel(L10n.text("播放 {0}", [episode.name]))
                }
                Button {
                    if expanded { expandedFiles.remove(episode.url) } else { expandedFiles.insert(episode.url) }
                } label: {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record?.entry.name ?? episode.name).font(.callout.bold()).lineLimit(2)
                            HStack(spacing: 8) {
                                Text(NASMediaDetailPresentation.fileSummary(record)).foregroundStyle(palette.muted)
                                if history?.episodeUrl == episode.url { Text(L10n.text("上次观看")).foregroundStyle(palette.accent) }
                            }.font(.caption)
                              if let record { DolbySourceBadges(formats: DolbySourceFormat.filename(record.entry.name)) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Label(L10n.text("文件信息"), systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(palette.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityValue(expanded ? L10n.text("已展开") : L10n.text("已折叠"))
            }
            if expanded {
                Divider().opacity(0.3)
                VStack(alignment: .leading, spacing: 8) {
                    if let record, isTV, let plot = record.localMetadata.plot, !plot.isEmpty { Text(plot).font(.callout).lineLimit(5) }
                    if let date = record?.entry.modifiedAt { Text(L10n.text("修改时间：{0}", [date.formatted(date: .abbreviated, time: .shortened)])) }
                    if let path = record?.entry.path ?? FileResourceReference(locator: episode.url)?.path {
                        Text(path).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }.font(.caption).foregroundStyle(palette.muted)
            }
        }
        .padding(14).background(palette.foreground.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.foreground.opacity(0.08), lineWidth: 1))
    }

    private func castSection(_ cast: [MediaCastMember]) -> some View {
        let prefetch = PosterImagePrefetchRequest(urls: cast.compactMap(\.portrait), maxPixelSize: 200)
        return VStack(alignment: .leading, spacing: 16) {
            sectionHeading(L10n.text("演职员"))
            ThemedHorizontalScrollView(theme: .subtle) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
                        Group {
                            if isServer { personCard(person) }
                            else { Button { onActor(person) } label: { personCard(person) }
                                .buttonStyle(.plain).help(L10n.text("查看 {0} 参演的影片", [person.name])) }
                        }
                    }
                }.padding(.bottom, 6)
            }.frame(height: 200)
        }
        .task(id: prefetch) { await ImageLoader.prefetch(prefetch) }
    }

    private func personCard(_ person: MediaCastMember) -> some View {
        VStack(spacing: 8) {
            WebImage(urlString: person.portrait ?? "", showsLoadingIndicator: false, fallbackSystemImage: "person.fill", maxPixelSize: 200)
                .aspectRatio(contentMode: .fit).frame(width: 80, height: 104, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(person.name).font(.callout.weight(.medium)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let role = person.role, !role.isEmpty {
                Text(role).font(.caption).foregroundStyle(palette.muted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(width: 96)
    }

    private var attribution: some View {
        HStack(spacing: 12) {
            if isRefreshing {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在补全影片资料…"))
            } else if detailsUnavailable {
                Text(L10n.text("暂时无法补全资料，已保留现有信息"))
                Button(L10n.text("重试"), action: onRetry).buttonStyle(.plain).foregroundStyle(palette.accent)
            } else {
                if isServer { Text(L10n.text("资料来自服务器；未显示的字段尚未提供。")) }
                if let id = metadata.tmdbID { Text("TMDB · " + id) }
                if let id = metadata.doubanID { Text(L10n.text("豆瓣") + " · " + id) }
            }
            Spacer()
        }.font(.caption).foregroundStyle(palette.muted)
    }

    private func sectionHeading(_ title: String) -> some View { Text(title).font(.headline) }
    private func play(_ episode: Episode, restart: Bool = false) {
        let resume = history.flatMap { $0.episodeUrl == episode.url && $0.position > 0 ? $0 : nil }
        Task {
            await appState.playEpisode(episode, resumePosition: restart ? 0 : resume?.position,
                resumeDuration: resume?.duration, restartFromBeginning: restart)
        }
    }
}
