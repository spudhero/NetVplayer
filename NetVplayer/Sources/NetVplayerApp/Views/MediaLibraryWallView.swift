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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("媒体库", selection: $state.selectedLibraryID) {
                    if state.libraries.isEmpty { Text("尚未添加媒体库").tag(Optional<UUID>.none) }
                    ForEach(state.libraries) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 250).onChange(of: state.selectedLibraryID) { _, _ in state.mediaRecords = []; state.loadMedia() }
                Button { draft = .init(serviceID: service.id, name: "", metadataSource: state.catalog.defaultMetadataSource) } label: { Image(systemName: "plus") }.help("添加媒体库")
                if let library = state.selectedLibrary {
                    Button("编辑库") { draft = library }
                    Spacer()
                    Menu {
                        ForEach(MetadataSource.allCases, id: \.self) { source in
                            Button { do { try state.setSource(source, libraryID: library.id) } catch { state.error = error.localizedDescription } } label: {
                                if library.metadataSource == source { Label(source.title, systemImage: "checkmark") } else { Text(source.title) }
                            }
                        }
                        Divider()
                        Button("重新匹配影视信息") { Task { do { try await MetadataMatcher.shared.rematch(library) } catch { state.error = error.localizedDescription } } }
                    } label: {
                        HStack(spacing: 8) {
                            Text("信息来源：" + library.metadataSource.title)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(AppGlassSurface(cornerRadius: 8, role: .control))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
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
                ThemedScrollView {
                    LazyVStack(alignment: .leading, spacing: HomeVisualPolicy.posterVerticalGap) {
                        ForEach(HomeVisualPolicy.posterRowStarts(itemCount: state.mediaRecords.count, columnCount: layout.columnCount), id: \.self) { start in
                            HStack(alignment: .top, spacing: HomeVisualPolicy.posterHorizontalGap) {
                                ForEach(state.mediaRecords[start..<min(start + layout.columnCount, state.mediaRecords.count)]) { record in
                                    posterCard(record: record, width: layout.itemWidth)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        if state.mediaHasMore { Button("加载更多") { state.loadMedia(append: true) }.disabled(state.mediaLoading).padding() }
                        if state.mediaRecords.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "rectangle.stack").font(.largeTitle)
                                Text(state.libraries.isEmpty ? "为此服务添加电影、剧集或混合媒体库" : "扫描后影片会显示在这里，未识别的视频也能播放")
                                Button(state.libraries.isEmpty ? "添加媒体库" : "扫描媒体库") {
                                    if state.libraries.isEmpty { draft = .init(serviceID: service.id, name: "", metadataSource: state.catalog.defaultMetadataSource) }
                                    else { state.refreshCurrentView() }
                                }
                            }.foregroundStyle(palette.muted).padding(40)
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollContentBackground(.hidden).background(Color.clear)
            }
        }
        .foregroundStyle(palette.foreground).tint(palette.accent)
        .sheet(item: $draft) { MediaLibraryEditor(library: $0) }
        .sheet(item: $matching) { MediaMetadataEditor(record: $0) }
        .sheet(isPresented: $verifying) {
            if let url = state.verificationURL { DoubanVerificationView(url: url) }
        }
        .onAppear { state.loadMedia() }
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
