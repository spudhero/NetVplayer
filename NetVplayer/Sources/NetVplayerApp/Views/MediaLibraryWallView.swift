import SwiftUI
import Models
import Storage
import MediaLibraryEngine

struct MediaLibraryWallView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var state = FileServicesState.shared
    let service: FileServiceConfiguration
    @State private var draft: MediaLibraryConfiguration?
    @State private var matching: MediaRecord?
    @State private var verifying = false
    @State private var addingFolders = false
    @State private var mergingTelevision = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            libraryToolbar
            libraryFilters
            if let id = state.selectedLibraryID, let progress = state.scanProgress[id] {
                HStack {
                    if progress.isRunning { ProgressView().controlSize(.small).tint(palette.accent) }
                    Text(progress.isRunning ? "已扫描 \(progress.files) 个视频 · " + progress.currentPath : progress.message ?? "").font(.caption).lineLimit(1)
                    Spacer()
                    if progress.isRunning { Button("取消") { state.cancelCurrentRefresh() } }
                }
                if !progress.failedDirectories.isEmpty {
                    Text("未完成目录：" + progress.failedDirectories.joined(separator: "、")).font(.caption).foregroundStyle(palette.color(for: .warning)).textSelection(.enabled)
                }
            }
            if state.verificationURL != nil {
                HStack { Text("豆瓣需要网页验证；现有资料和播放可继续使用。").font(.caption); Button("完成验证") { verifying = true } }
            }
            if let id = state.selectedLibraryID, let progress = state.matchProgress[id] {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(progress.message + " · \(progress.completed)/\(progress.total)")
                            .font(.system(size: HomeVisualPolicy.posterMetadataFontSize, weight: .medium))
                            .foregroundStyle(palette.muted).lineLimit(1)
                        Spacer()
                        if progress.isRunning { Button("取消") { state.cancelCurrentRefresh() } }
                    }
                    if progress.isRunning {
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                            .progressViewStyle(.linear).tint(palette.accent)
                    }
                }
            }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(palette.color(for: .danger)) }
            GeometryReader { geometry in
                let layout = HomeVisualPolicy.posterGridLayout(availableWidth: max(0, geometry.size.width - AppScrollbarMetrics.gutterWidth))
                ThemedScrollView(onScrollPositionChange: { offset, remaining in
                    // Ignore transient empty-content measurements during the first layout.
                    // Only scrolling into the final 260 points requests another page.
                    if offset > 1 && remaining < 260 { state.loadNextMediaPage() }
                }) {
                    LazyVStack(alignment: .leading, spacing: HomeVisualPolicy.posterVerticalGap) {
                        ForEach(HomeVisualPolicy.posterRowStarts(itemCount: state.mediaRecords.count, columnCount: layout.columnCount), id: \.self) { start in
                            HStack(alignment: .top, spacing: HomeVisualPolicy.posterHorizontalGap) {
                                ForEach(state.mediaRecords[start..<min(start + layout.columnCount, state.mediaRecords.count)]) { record in
                                    posterCard(record: record, width: layout.itemWidth)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        paginationFooter
                        if state.mediaRecords.isEmpty && !state.mediaLoading && state.mediaError == nil {
                            VStack(spacing: 12) {
                                Image(systemName: "rectangle.stack").font(.largeTitle)
                                if !state.mediaFilter.isEmpty {
                                    Text(L10n.text("没有符合筛选的影片"))
                                    Button(L10n.text("清除筛选")) { state.setMediaFilter(.init()) }
                                } else {
                                    Text(state.libraries.isEmpty ? "为此服务添加电影、剧集或混合媒体库" : "扫描后影片会显示在这里，未识别的视频也能播放")
                                    Button(state.libraries.isEmpty ? "添加媒体库" : "扫描媒体库") {
                                        if state.libraries.isEmpty { addingFolders = true }
                                        else { state.refreshCurrentView() }
                                    }
                                }
                            }.foregroundStyle(palette.muted).padding(40)
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollContentBackground(.hidden).background(Color.clear)
                .id((state.selectedLibraryID?.uuidString ?? "") + String(describing: state.mediaFilter))
            }
        }
        .foregroundStyle(palette.foreground).tint(palette.accent)
        .sheet(item: $draft) { MediaLibraryEditor(library: $0) }
        .sheet(isPresented: $addingFolders) { MediaLibraryBatchEditor(state: state, service: service) }
        .sheet(item: $matching) { MediaMetadataEditor(record: $0) }
        .sheet(isPresented: $mergingTelevision) {
            if let id = state.selectedLibraryID { MediaTelevisionMergeView(state: state, libraryID: id) }
        }
        .sheet(isPresented: $verifying) {
            if let url = state.verificationURL { DoubanVerificationView(url: url) }
        }
        .onAppear { state.loadMedia() }
        .onChange(of: state.selectedLibraryID) { _, _ in state.loadMedia() }
        .onDisappear { state.cancelMediaLoad() }
    }

    private var libraryToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                librarySelection
                Spacer(minLength: 8)
                libraryActions
            }
            VStack(alignment: .leading, spacing: 12) {
                librarySelection
                libraryActions
            }
        }
        .padding(.vertical, 4)
    }

    private var librarySelection: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(state.libraries) { library in
                            Button { state.selectedLibraryID = library.id } label: {
                                if state.selectedLibraryID == library.id { Label(library.name, systemImage: "checkmark") }
                                else { Text(library.name) }
                            }
                        }
                    } label: {
                        Text(state.selectedLibrary?.name ?? L10n.text("媒体库"))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(palette.foreground)
                    }.menuStyle(.borderlessButton).fixedSize().disabled(state.libraries.isEmpty)
                        .accessibilityLabel(L10n.text("媒体库"))
                    Text(L10n.text("已显示 {0} 部", [String(state.mediaRecords.count)]))
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                Label(libraryPath, systemImage: "folder")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
    }

    private var libraryPath: String {
        guard let library = state.selectedLibrary else { return L10n.text("选择文件夹，开始整理影片") }
        let parts = (service.kind == .smb ? [service.share] : [])
            + service.rootPath.split(separator: "/").map(String.init)
            + library.path.split(separator: "/").map(String.init)
        return parts.isEmpty ? L10n.text("连接根目录") : parts.joined(separator: " / ")
    }

    private var libraryFilters: some View {
        HStack(spacing: 10) {
            if state.selectedLibrary?.kind != .television {
                MediaLibraryFilterPicker(title: L10n.text("系列"), icon: "rectangle.stack", options: state.mediaFacets.collections,
                    selected: state.mediaFilter.collection) { key in
                        var filter = state.mediaFilter; filter.collection = key
                        state.setMediaFilter(filter)
                    }
            }
            MediaLibraryFilterPicker(title: L10n.text("主演"), icon: "person.2", options: state.mediaFacets.actors,
                selected: state.mediaFilter.actor) { key in
                    var filter = state.mediaFilter; filter.actor = key
                    state.setMediaFilter(filter)
                }
            MediaLibraryFilterPicker(title: L10n.text("导演"), icon: "video", options: state.mediaFacets.directors,
                selected: state.mediaFilter.director) { key in
                    var filter = state.mediaFilter; filter.director = key
                    state.setMediaFilter(filter)
                }
            if !state.mediaFilter.isEmpty {
                Button(L10n.text("清除筛选")) { state.setMediaFilter(.init()) }.buttonStyle(.plain).foregroundStyle(palette.accent)
            }
            Spacer(minLength: 0)
            if let library = state.selectedLibrary, library.metadataSource != .local {
                Button(L10n.text("补全影片资料")) { Task { await MetadataMatcher.shared.enrichLibraryDetails(library) } }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(palette.accent).disabled(state.isRefreshing)
            }
        }
    }

    private var libraryActions: some View {
        HStack(spacing: 10) {
            FileServiceModePicker(selection: $state.mode)
            Button { addingFolders = true } label: { Label(L10n.text("添加文件夹"), systemImage: "folder.badge.plus") }
                .buttonStyle(.bordered)
            if let library = state.selectedLibrary {
                Menu {
                    Button(L10n.text("编辑媒体库")) { draft = library }
                    Menu(L10n.text("影片资料来源")) {
                        ForEach(MetadataSource.allCases, id: \.self) { source in
                            Button {
                                do { try state.setSource(source, libraryID: library.id) }
                                catch { state.error = error.localizedDescription }
                            } label: {
                                if library.metadataSource == source { Label(L10n.text(source.title), systemImage: "checkmark") }
                                else { Text(L10n.text(source.title)) }
                            }
                        }
                    }
                    Divider()
                    if library.kind != .movies {
                        Button(L10n.text("合并为同一剧集")) { mergingTelevision = true }
                        Divider()
                    }
                    Button(L10n.text("重新匹配影视信息")) {
                        Task { do { try await MetadataMatcher.shared.rematch(library) } catch { state.error = error.localizedDescription } }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 22) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(L10n.text("媒体库选项"))
                .help(L10n.text("媒体库选项"))
            }
        }.fixedSize()
    }

    private var paginationFooter: some View {
        HStack(spacing: 8) {
            Spacer()
            if state.mediaLoading {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在加载影片…"))
            } else if let error = state.mediaError {
                Text(error).lineLimit(2).foregroundStyle(palette.color(for: .danger))
                Button(L10n.text("重试")) { state.retryMediaPage() }
            } else if !state.mediaRecords.isEmpty && !state.mediaHasMore {
                Text(L10n.text("已显示全部 {0} 部", [String(state.mediaRecords.count)]))
            }
            Spacer()
        }
        .font(.system(size: 12)).foregroundStyle(palette.muted).frame(minHeight: 36)
    }

    private func posterCard(record: MediaRecord, width: CGFloat) -> some View {
        let vod = MediaLibraryPresentation.vod(record: record, site: service.site())
        let needsConfirmation = !record.candidates.isEmpty
        let needsArtwork = record.metadata.poster?.isEmpty != false
        return ZStack(alignment: .topTrailing) {
            Button { Task { await appState.selectVod(vod) } } label: {
                VodCard(vod: vod, posterWidth: width)
            }.buttonStyle(.plain)
            if needsConfirmation || needsArtwork {
                Button { matching = record } label: {
                    Label(needsConfirmation ? "待确认" : "查找", systemImage: needsConfirmation ? "checkmark.circle" : "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(AppGlassSurface(cornerRadius: 8, role: .control))
                }
                .buttonStyle(.plain).padding(8)
                .help(needsConfirmation ? "核对候选影片后保存修正" : "搜索正确片名并选择海报")
                .accessibilityLabel((needsConfirmation ? "确认影视信息：" : "查找影视信息：") + vod.vodName)
            }
        }
        .contextMenu { Button("修正影视信息 / 选择海报") { matching = record } }
    }
}
