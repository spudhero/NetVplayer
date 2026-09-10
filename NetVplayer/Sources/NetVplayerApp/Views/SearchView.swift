// NetVplayerApp/Views/SearchView.swift
// Global search workspace with persistent history and streamed multi-source results.

import SwiftUI
#if os(macOS)
import AppKit
#endif
import Models
import ApplicationCore
import Storage

private struct SearchResultRowLayout {
    let isCompact: Bool
    let sidebarWidth: CGFloat
    let posterWidth: CGFloat
    let rowHeight: CGFloat
    let sourceWidth: CGFloat
    let statusWidth: CGFloat
    let columnSpacing: CGFloat
    let horizontalPadding: CGFloat

    init(workspaceWidth: CGFloat) {
        isCompact = workspaceWidth < 1_000
        sidebarWidth = isCompact ? 208 : 238
        posterWidth = isCompact ? 60 : 68
        rowHeight = isCompact ? 106 : 118
        sourceWidth = isCompact ? 0 : 154
        statusWidth = isCompact ? 0 : 190
        columnSpacing = isCompact ? 10 : 14
        horizontalPadding = isCompact ? 12 : 14
    }
}

private enum SearchSourceFilterID: Hashable {
    case all
    case site(String)

    init(siteKey: String?) {
        if let siteKey {
            self = .site(siteKey)
        } else {
            self = .all
        }
    }
}

private enum SearchHeaderMetrics {
    static let controlHeight: CGFloat = 40
    static let iconWidth: CGFloat = 22
    static let emptyStateMinHeight: CGFloat = 320
}

private enum HotSearchLayoutMetrics {
    static let minimumColumnWidth: CGFloat = 190
    static let columnSpacing: CGFloat = 28
    static let rowHeight: CGFloat = 47
}

private struct SearchSuggestion: Identifiable {
    let query: String
    let kind: String

    var id: String { query.lowercased() }
}

private struct SearchHistorySection: Identifiable {
    let title: String
    let entries: [SearchHistoryEntry]

    var id: String { title }
}

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appThemePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool

    @State private var localSearchText = ""
    @State private var searchHistory: [SearchHistoryEntry] = SearchHistoryStore.shared.load()
    @State private var showsHistory = true
    @State private var selectedSourceKey: String?
    @State private var hoveredSourceFilterID: SearchSourceFilterID?
    @State private var openingResultID: String?
    @State private var selectedSuggestionIndex: Int?
    @State private var showsClearHistoryConfirmation = false
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    @State private var hotSearchTask: Task<Void, Never>?
    @State private var hotSearches: [HotSearchItem] = []
    @State private var isRefreshingHotSearches = false
    @State private var hotSearchLoadFailed = false
    @State private var presentationSnapshot = SearchResultPresentationSnapshot.empty
    @State private var presentationUpdateTask: Task<Void, Never>?

    private var successfulResults: [SearchResult] {
        presentationSnapshot.successfulResults
    }

    private var trimmedSearchText: String {
        localSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestions: [SearchSuggestion] {
        let query = trimmedSearchText
        guard !query.isEmpty else { return [] }

        var candidates = [SearchSuggestion(query: query, kind: "精确搜索")]
        let knownQueries = searchHistory.map { ($0.query, "历史") }
            + hotSearches.map { ($0.title, "热搜") }

        for candidate in knownQueries where candidate.0.localizedCaseInsensitiveContains(query) {
            candidates.append(SearchSuggestion(query: candidate.0, kind: candidate.1))
        }

        if !query.contains("://") {
            candidates.append(contentsOf: [
                SearchSuggestion(query: "\(query) 电影", kind: "影视"),
                SearchSuggestion(query: "\(query) 电视剧", kind: "剧集"),
                SearchSuggestion(query: "\(query) 4K", kind: "高清"),
                SearchSuggestion(query: "\(query) 纪录片", kind: "纪录片")
            ])
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.query.lowercased()).inserted }.prefix(5).map { $0 }
    }

    private var historySections: [SearchHistorySection] {
        let calendar = Calendar.current
        let today = searchHistory.filter { calendar.isDateInToday($0.searchedAt) }
        let yesterday = searchHistory.filter { calendar.isDateInYesterday($0.searchedAt) }
        let earlier = searchHistory.filter {
            !calendar.isDateInToday($0.searchedAt) && !calendar.isDateInYesterday($0.searchedAt)
        }

        return [
            SearchHistorySection(title: "今天", entries: today),
            SearchHistorySection(title: "昨天", entries: yesterday),
            SearchHistorySection(title: "更早", entries: earlier)
        ].filter { !$0.entries.isEmpty }
    }

    private var sourceOptions: [SearchSourceOption] {
        presentationSnapshot.sourceOptions
    }

    private var exactDisplayItems: [SearchDisplayItem] {
        presentationSnapshot.exactItems(sourceKey: selectedSourceKey)
    }

    private var relatedDisplayItems: [SearchDisplayItem] {
        presentationSnapshot.relatedItems(sourceKey: selectedSourceKey)
    }

    private var displayedResultCount: Int {
        presentationSnapshot.itemCount(sourceKey: selectedSourceKey)
    }

    private var presentationRevision: SearchResultPresentationRevision {
        SearchResultPresentationRevision(state: appState.contentSearchState)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                searchHeader

                Group {
                    if showsHistory {
                        historyView
                    } else {
                        resultsView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background(AppGlassSurface(cornerRadius: 10, role: .raised))
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(200)
            }
        }
        .confirmationDialog(
            "清空全部搜索记录？",
            isPresented: $showsClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空记录", role: .destructive) {
                SearchHistoryStore.shared.clear()
                searchHistory = []
                showToast("搜索历史已清空")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会移除当前显示的 \(searchHistory.count) 条历史搜索，不会影响播放历史或收藏。")
        }
        .onAppear {
            searchHistory = SearchHistoryStore.shared.load()
            localSearchText = appState.searchKeyword
            showsHistory = appState.searchKeyword.isEmpty && appState.searchResults.isEmpty
            refreshPresentationSnapshot(immediate: true)
            loadHotSearches()
        }
        .onChange(of: presentationRevision) { _, revision in
            refreshPresentationSnapshot(immediate: !revision.isLoading)
        }
        .onDisappear {
            toastDismissTask?.cancel()
            hotSearchTask?.cancel()
            presentationUpdateTask?.cancel()
            resetSearchWorkspace(focusSearchField: false)
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            searchField

            Button(action: pasteFromClipboard) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: SearchHeaderMetrics.controlHeight, height: SearchHeaderMetrics.controlHeight)
            .foregroundStyle(palette.muted)
            .background(controlBackground)
            .buttonStyle(.plain)
            .help("粘贴分享文本")

            Button(action: submitSearch) {
                Label("搜索", systemImage: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 84, height: SearchHeaderMetrics.controlHeight)
            .foregroundStyle(palette.color(for: .onAccent))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(palette.accent.opacity(canSubmitSearch ? 1 : 0.42))
            )
            .buttonStyle(.plain)
            .disabled(!canSubmitSearch)

            ViewThatFits(in: .horizontal) {
                Label(
                    "\(appState.sites.filter(\.isSearchable).count) 个搜索源",
                    systemImage: "dot.radiowaves.left.and.right"
                )
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.muted)
                .frame(minWidth: 112, alignment: .trailing)

                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(palette.muted)
                    .frame(width: 30, height: 30)
                    .help("\(appState.sites.filter(\.isSearchable).count) 个搜索源可用")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .background(palette.background.opacity(0.76))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
        .zIndex(100)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.muted)
                .frame(width: SearchHeaderMetrics.iconWidth)

            TextField("搜索电影、剧集、演员或粘贴网盘分享", text: $localSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(palette.foreground)
                .focused($isSearchFocused)
                .onSubmit(submitSearch)
                .onKeyPress(.downArrow) {
                    moveSuggestionSelection(by: 1)
                }
                .onKeyPress(.upArrow) {
                    moveSuggestionSelection(by: -1)
                }
                .onKeyPress(.escape) {
                    selectedSuggestionIndex = nil
                    isSearchFocused = false
                    return .handled
                }

            Button {
                resetSearchWorkspace(focusSearchField: true)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.muted)
            .opacity(trimmedSearchText.isEmpty ? 0 : 1)
            .allowsHitTesting(!trimmedSearchText.isEmpty)
            .help("清空输入")
        }
        .padding(.horizontal, 14)
        .frame(height: SearchHeaderMetrics.controlHeight)
        .background(controlBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isSearchFocused ? palette.accent.opacity(0.72) : palette.foreground.opacity(0.13),
                    lineWidth: 1
                )
        }
        .shadow(color: isSearchFocused ? palette.accent.opacity(0.12) : .clear, radius: 8)
        .overlay(alignment: .topLeading) {
            if isSearchFocused && !trimmedSearchText.isEmpty {
                suggestionPanel
                    .offset(y: SearchHeaderMetrics.controlHeight + 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: localSearchText) { _, _ in
            selectedSuggestionIndex = nil
            if trimmedSearchText.isEmpty,
               !appState.searchKeyword.isEmpty || !appState.searchResults.isEmpty || appState.isSearching {
                resetSearchWorkspace(focusSearchField: isSearchFocused)
            }
        }
        .zIndex(110)
    }

    private var suggestionPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("搜索联想")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 14)
                .frame(height: 36)

            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    triggerSearch(suggestion.query)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(palette.muted)
                            .frame(width: 20)
                        Text(suggestion.query)
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        Spacer()
                        Text(suggestion.kind)
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                    .background(
                        selectedSuggestionIndex == index
                            ? palette.lavender.opacity(0.14)
                            : Color.clear
                    )
                }
                .buttonStyle(.plain)

                if index < suggestions.count - 1 {
                    Divider().opacity(0.42)
                }
            }
        }
        .background(AppGlassSurface(cornerRadius: 14, role: .raised))
        .shadow(color: .black.opacity(0.5), radius: 28, y: 12)
    }

    private var historyView: some View {
        ThemedScrollView {
            VStack(alignment: .leading, spacing: 0) {
                historyContent
                hotSearchPanel
                    .padding(.top, 24)
                    .overlay(alignment: .top) {
                        Divider().opacity(0.55)
                    }
                    .padding(.top, 30)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("历史搜索")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(palette.foreground)
                    Text("\(searchHistory.count) 条记录，点击即可再次搜索。")
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                }

                Spacer()

                Button {
                    showsClearHistoryConfirmation = true
                } label: {
                    Label("清空", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.muted)
                .disabled(searchHistory.isEmpty)
            }

            if historySections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28, weight: .light))
                    Text("暂无历史搜索")
                        .font(.headline)
                        .foregroundStyle(palette.foreground)
                    Text("从下方热搜榜选择一个关键词开始。")
                        .font(.subheadline)
                }
                .foregroundStyle(palette.muted)
                .frame(maxWidth: .infinity, minHeight: 180)
                .overlay(alignment: .top) { Divider().opacity(0.45) }
            } else {
                ForEach(historySections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(section.title) · \(section.entries.count) 条")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(palette.muted)

                        SearchFlowLayout(spacing: 9) {
                            ForEach(section.entries) { entry in
                                SearchHistoryChip(
                                    entry: entry,
                                    onSelect: { triggerSearch(entry.query) },
                                    onRemove: { removeHistoryEntry(entry) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var hotSearchPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在热搜")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(palette.foreground)
                    Text("360 视频榜单 · 自动更新")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }

                Spacer()

                Button(action: refreshHotSearches) {
                    Group {
                        if isRefreshingHotSearches {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.muted)
                .disabled(isRefreshingHotSearches)
                .help("刷新热搜")
            }
            .padding(.bottom, 16)

            if hotSearches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: hotSearchLoadFailed ? "wifi.exclamationmark" : "chart.line.uptrend.xyaxis")
                        .font(.system(size: 22, weight: .light))
                    Text(hotSearchLoadFailed ? "暂时无法加载热搜" : "正在获取热搜")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.foreground)
                }
                .foregroundStyle(palette.muted)
                .frame(maxWidth: .infinity, minHeight: 132)
                .overlay(alignment: .top) { Divider().opacity(0.45) }
            } else {
                HotSearchGridLayout(
                    minimumColumnWidth: HotSearchLayoutMetrics.minimumColumnWidth,
                    columnSpacing: HotSearchLayoutMetrics.columnSpacing,
                    rowHeight: HotSearchLayoutMetrics.rowHeight,
                    maximumColumns: 4
                ) {
                    ForEach(Array(hotSearches.enumerated()), id: \.element.id) { index, item in
                        Button {
                            triggerSearch(item.title)
                        } label: {
                            HStack(spacing: 10) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(
                                        index < 3
                                            ? palette.lavender.opacity(0.88)
                                            : palette.muted
                                    )
                                    .frame(width: 24, alignment: .leading)
                                Text(item.title)
                                    .foregroundStyle(palette.foreground)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(palette.muted.opacity(0.72))
                            }
                            .frame(maxWidth: .infinity, minHeight: HotSearchLayoutMetrics.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(item.title)
                        .overlay(alignment: .top) {
                            Divider().opacity(0.45)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    Divider().opacity(0.45)
                }
            }
        }
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            resultsToolbar

            GeometryReader { geometry in
                let layout = SearchResultRowLayout(workspaceWidth: geometry.size.width)

                HStack(spacing: 0) {
                    sourceSidebar(layout: layout)
                    Divider().opacity(0.58)
                    resultPane(layout: layout)
                }
            }
        }
    }

    private var resultsToolbar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                showsHistory = true
                selectedSourceKey = nil
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.muted)
            .help("返回历史搜索")

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("“\(appState.searchKeyword)”")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    Text("\(displayedResultCount) 条结果")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.muted)
                        .fixedSize()
                }

                HStack(spacing: 7) {
                    if appState.isSearching {
                        ProgressView().controlSize(.mini)
                    } else {
                    Circle()
                        .fill(palette.color(for: .success))
                        .frame(width: 6, height: 6)
                    }
                    Text(resultStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: retrySearch) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.muted)
            .disabled(appState.isSearching)
            .help("重新搜索全部来源")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(palette.surface.opacity(0.2))
        .overlay(alignment: .bottom) { Divider().opacity(0.48) }
    }

    private func sourceSidebar(layout: SearchResultRowLayout) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("来源")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.muted)
                Spacer()
                Text("\(sourceOptions.count) 个来源")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.muted.opacity(0.74))
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Divider().opacity(0.44) }

            ThemedScrollView(theme: .subtle) {
                LazyVStack(spacing: 2) {
                    sourceFilterButton(
                        siteKey: nil,
                        title: "全部来源",
                        count: presentationSnapshot.itemCount(sourceKey: nil),
                        isDriveOnly: false
                    )

                    ForEach(sourceOptions) { option in
                        sourceFilterButton(
                            siteKey: option.siteKey,
                            title: option.siteName,
                            count: option.count,
                            isDriveOnly: option.isDriveOnly
                        )
                    }
                }
                .padding(8)
            }
        }
        .frame(width: layout.sidebarWidth)
        .background(palette.surface.opacity(0.14))
    }

    private func sourceFilterButton(
        siteKey: String?,
        title: String,
        count: Int,
        isDriveOnly: Bool
    ) -> some View {
        let isSelected = selectedSourceKey == siteKey
        let filterID = SearchSourceFilterID(siteKey: siteKey)
        let isHovered = hoveredSourceFilterID == filterID
        let isHighlighted = isSelected || isHovered
        let dotColor: Color = if siteKey == nil {
            palette.accent
        } else if isDriveOnly {
            palette.lavender
        } else {
            .green
        }

        return Button {
            selectedSourceKey = siteKey
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isHighlighted ? palette.foreground : palette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.muted)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? palette.surface.opacity(0.66)
                            : isHovered
                                ? palette.surface.opacity(0.38)
                                : Color.clear
                    )
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(palette.accent)
                    .frame(width: 3)
                    .opacity(isSelected ? 1 : isHovered ? 0.42 : 0)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isHighlighted)
        .onHover { hovering in
            if hovering {
                hoveredSourceFilterID = filterID
            } else if hoveredSourceFilterID == filterID {
                hoveredSourceFilterID = nil
            }
        }
        .help(title)
    }

    private func resultPane(layout: SearchResultRowLayout) -> some View {
        VStack(spacing: 0) {
            resultColumnHeader(layout: layout)

            ScrollViewReader { proxy in
                ThemedScrollView(theme: .subtle) {
                    Color.clear.frame(height: 1).id("searchTop")
                    resultContent(layout: layout)
                }
                .onChange(of: appState.searchKeyword) { _, _ in
                    proxy.scrollTo("searchTop", anchor: .top)
                }
                .onChange(of: selectedSourceKey) { _, _ in
                    proxy.scrollTo("searchTop", anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultContent(layout: SearchResultRowLayout) -> some View {
        if appState.isSearching && successfulResults.isEmpty {
            SearchSkeletonView(reduceMotion: reduceMotion, layout: layout)
        } else if appState.searchResults.isEmpty {
            centeredEmptyState {
                ContentUnavailableView(
                    "没有搜索到结果",
                    systemImage: "magnifyingglass",
                    description: Text("换个关键词，或检查已启用的搜索站点。")
                )
            }
        } else if displayedResultCount == 0 {
            centeredEmptyState {
                ContentUnavailableView(
                    selectedSourceKey == nil ? "没有可显示的结果" : "此来源暂无结果",
                    systemImage: "magnifyingglass",
                    description: Text(selectedSourceKey == nil ? "已返回的来源没有匹配内容。" : "切换其它来源继续查看。")
                )
            }
        } else {
            matchingResultsList(layout: layout)

            if appState.isSearching {
                HStack(spacing: 10) {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("正在拉取剩余站点…")
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                    Spacer()
                }
                .padding(.vertical, 16)
            }
        }
    }

    private func resultColumnHeader(layout: SearchResultRowLayout) -> some View {
        HStack(spacing: layout.columnSpacing) {
            Text(selectedSourceKey == nil ? "结果" : selectedSourceTitle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !layout.isCompact {
                Text("来源 / 类型")
                    .frame(width: layout.sourceWidth, alignment: .leading)
                Text("更新 / 状态")
                    .frame(width: layout.statusWidth, alignment: .leading)
            }

            Color.clear.frame(width: 16)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(palette.muted.opacity(0.78))
        .padding(.horizontal, layout.horizontalPadding)
        .frame(height: 38)
        .background(palette.surface.opacity(0.16))
        .overlay(alignment: .bottom) { Divider().opacity(0.44) }
    }

    private func matchingResultsList(layout: SearchResultRowLayout) -> some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            if !exactDisplayItems.isEmpty {
                Section {
                    searchResultRows(exactDisplayItems, layout: layout, exact: true)
                } header: {
                    resultSectionHeader("精确匹配", count: exactDisplayItems.count)
                }
            }

            if !relatedDisplayItems.isEmpty {
                Section {
                    searchResultRows(relatedDisplayItems, layout: layout, exact: false)
                } header: {
                    resultSectionHeader("相关结果", count: relatedDisplayItems.count)
                }
            }
        }
    }

    @ViewBuilder
    private func searchResultRows(
        _ items: [SearchDisplayItem],
        layout: SearchResultRowLayout,
        exact: Bool
    ) -> some View {
        ForEach(items) { item in
            Button {
                open(item)
            } label: {
                SearchResultRow(
                    vod: item.vod,
                    siteHeader: appState.sites.first(where: { $0.key == item.result.siteKey })?.header,
                    badge: item.badge,
                    isDrive: item.isDrive,
                    isExactMatch: exact,
                    isOpening: openingResultID == item.id,
                    layout: layout
                )
            }
            .buttonStyle(.plain)
            .help(openingResultID == item.id ? "正在打开 \(item.vod.vodName)" : "打开 \(item.vod.vodName)")
        }
    }

    private func resultSectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.muted)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.muted.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(palette.surface)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    private var selectedSourceTitle: String {
        guard let selectedSourceKey,
              let option = sourceOptions.first(where: { $0.siteKey == selectedSourceKey })
        else { return "全部来源" }
        return option.siteName
    }

    private var controlBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(palette.surface.opacity(0.62))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(palette.foreground.opacity(0.13), lineWidth: 1)
            }
    }

    private var canSubmitSearch: Bool {
        !trimmedSearchText.isEmpty && !appState.isSearching
    }

    private var resultStatusText: String {
        if appState.isSearching {
            return appState.searchResults.isEmpty
                ? "正在向多个站点发起搜索"
                : "已返回 \(appState.searchResults.count) 个来源，继续加载中"
        }
        return "已完成 \(appState.searchResults.count) 个来源的搜索"
    }

    private func submitSearch() {
        if let selectedSuggestionIndex,
           suggestions.indices.contains(selectedSuggestionIndex) {
            triggerSearch(suggestions[selectedSuggestionIndex].query)
        } else {
            triggerSearch(localSearchText)
        }
    }

    private func triggerSearch(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !appState.isSearching else { return }

        localSearchText = query
        isSearchFocused = false
        selectedSuggestionIndex = nil
        selectedSourceKey = nil
        clearPresentationSnapshot()
        showsHistory = false
        searchHistory = SearchHistoryStore.shared.record(query)

        searchTask?.cancel()
        searchTask = Task {
            await appState.search(keyword: query)
        }
    }

    private func retrySearch() {
        let query = appState.searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !appState.isSearching else { return }

        selectedSourceKey = nil
        clearPresentationSnapshot()
        searchTask?.cancel()
        searchTask = Task {
            await appState.search(keyword: query)
        }
    }

    private func resetSearchWorkspace(focusSearchField: Bool) {
        searchTask?.cancel()
        searchTask = nil
        appState.resetSearchState()
        localSearchText = ""
        selectedSuggestionIndex = nil
        selectedSourceKey = nil
        clearPresentationSnapshot()
        showsHistory = true
        isSearchFocused = focusSearchField
    }

    private func loadHotSearches() {
        let cachedItems = HotSearchService.shared.cachedItems()
        if !cachedItems.isEmpty {
            hotSearches = cachedItems
        }
        refreshHotSearches()
    }

    private func refreshHotSearches() {
        hotSearchTask?.cancel()
        isRefreshingHotSearches = true
        hotSearchLoadFailed = false

        hotSearchTask = Task {
            do {
                let refreshedItems = try await HotSearchService.shared.refresh()
                guard !Task.isCancelled else { return }
                hotSearches = refreshedItems
            } catch {
                guard !Task.isCancelled else { return }
                hotSearchLoadFailed = hotSearches.isEmpty
            }

            isRefreshingHotSearches = false
        }
    }

    private func moveSuggestionSelection(by offset: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let current = selectedSuggestionIndex ?? (offset > 0 ? -1 : 0)
        selectedSuggestionIndex = (current + offset + suggestions.count) % suggestions.count
        return .handled
    }

    private func refreshPresentationSnapshot(immediate: Bool) {
        let results = appState.searchResults
        let keyword = appState.searchKeyword

        presentationUpdateTask?.cancel()
        presentationUpdateTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
            }

            let snapshot = await Task.detached(priority: .userInitiated) {
                SearchResultPresentationSnapshot(results: results, keyword: keyword)
            }.value
            guard !Task.isCancelled else { return }

            presentationSnapshot = snapshot
        }
    }

    private func clearPresentationSnapshot() {
        presentationUpdateTask?.cancel()
        presentationUpdateTask = nil
        presentationSnapshot = .empty
    }

    private func pasteFromClipboard() {
        #if os(macOS)
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            showToast("剪贴板中没有可搜索的文本")
            return
        }
        localSearchText = text
        isSearchFocused = true
        #endif
    }

    private func removeHistoryEntry(_ entry: SearchHistoryEntry) {
        searchHistory = SearchHistoryStore.shared.remove(id: entry.id)
        showToast("已删除“\(entry.query)”")
    }

    private func open(_ item: SearchDisplayItem) {
        guard openingResultID == nil else { return }
        openingResultID = item.id

        Task {
            defer { openingResultID = nil }

            if item.result.siteKey == AppState.driveShareImportSiteKey {
                await appState.openImportedDriveShare(item.vod)
            } else {
                if let matchingSite = appState.sites.first(where: { $0.key == item.result.siteKey }) {
                    await appState.openSearchResultVod(item.vod, from: matchingSite)
                } else {
                    await appState.selectVod(item.vod)
                }
            }
        }
    }

    private func centeredEmptyState<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .multilineTextAlignment(.center)
            .frame(
                maxWidth: .infinity,
                minHeight: SearchHeaderMetrics.emptyStateMinHeight,
                alignment: .center
            )
    }

    private func showToast(_ message: String) {
        toastDismissTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            toastMessage = message
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.18)) {
                toastMessage = nil
            }
        }
    }
}

private struct SearchHistoryChip: View {
    @Environment(\.appThemePalette) private var palette
    let entry: SearchHistoryEntry
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 2) {
            Button(entry.query, action: onSelect)
                .buttonStyle(.plain)
                .foregroundStyle(palette.foreground.opacity(0.9))
                .padding(.leading, 13)
                .padding(.trailing, 4)
                .frame(height: 36)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.muted)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .help("删除 \(entry.query)")
        }
        .background(
            Capsule()
                .fill(palette.surface.opacity(isHovered ? 0.72 : 0.48))
                .overlay {
                    Capsule()
                        .stroke(
                            isHovered
                                ? palette.lavender.opacity(0.42)
                                : palette.foreground.opacity(0.14),
                            lineWidth: 1
                        )
                }
        )
        .onHover { isHovered = $0 }
    }
}

private struct SearchResultRow: View {
    @Environment(\.appThemePalette) private var palette
    let vod: Vod
    let siteHeader: [String: String]?
    let badge: String
    let isDrive: Bool
    let isExactMatch: Bool
    let isOpening: Bool
    let layout: SearchResultRowLayout

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: layout.columnSpacing) {
            resultMain
                .frame(maxWidth: .infinity, alignment: .leading)

            if !layout.isCompact {
                sourceCell
                    .frame(width: layout.sourceWidth, alignment: .leading)
                statusCell
                    .frame(width: layout.statusWidth, alignment: .leading)
            }

            Group {
                if isOpening {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .offset(x: isHovered ? 2 : 0)
                }
            }
            .foregroundStyle(isHighlighted ? palette.accent : palette.muted.opacity(0.62))
            .frame(width: 16, height: 16)
        }
        .padding(.horizontal, layout.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: layout.rowHeight, alignment: .leading)
        .background(palette.surface.opacity(isHighlighted ? 0.72 : 0))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.accent)
                .frame(width: 3)
                .opacity(isHighlighted ? 1 : 0)
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.34) }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.14), value: isHighlighted)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(vod.vodName)，来源 \(badge)，\(remarkText)")
    }

    private var isHighlighted: Bool {
        isHovered || isOpening
    }

    private var resultMain: some View {
        HStack(spacing: layout.isCompact ? 11 : 14) {
            PosterAspectContainer(width: layout.posterWidth) {
                WebImage(
                    urlString: vod.vodPic,
                    siteHeader: siteHeader,
                    showsLoadingIndicator: false,
                    fallbackText: vod.vodName,
                    fallbackIconFont: .title3
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        isHighlighted
                            ? palette.accent.opacity(0.52)
                            : palette.foreground.opacity(0.1),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(isHovered ? 0.28 : 0.16), radius: isHovered ? 10 : 5, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(vod.vodName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    if isExactMatch {
                        Text("精确匹配")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.lavender)
                            .fixedSize()
                    }
                }

                Text(supportingText)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)

                Spacer(minLength: 2)

                Text(metadataText)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.muted.opacity(0.76))
                    .lineLimit(1)

                if layout.isCompact {
                    compactSourceAndStatus
                }
            }
            .padding(.vertical, layout.isCompact ? 8 : 9)
        }
    }

    private var sourceCell: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: isDrive ? "externaldrive.fill" : "film")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isDrive ? palette.lavender : palette.muted)
                Text(badge)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
            }
            Text(isDrive ? "网盘资源" : "站点影视")
                .font(.system(size: 10))
                .foregroundStyle(palette.muted.opacity(0.72))
        }
    }

    private var statusCell: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(remarkText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle()
                    .fill(
                        isDrive ? palette.lavender : palette.color(for: .success)
                    )
                    .frame(width: 6, height: 6)
                Text(isDrive ? "打开查看网盘资源" : "打开查看详情")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.muted.opacity(0.72))
                    .lineLimit(1)
            }
        }
    }

    private var compactSourceAndStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: isDrive ? "externaldrive.fill" : "film")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isDrive ? palette.lavender : palette.muted)
            Text(badge)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(remarkText)
                .foregroundStyle(vod.vodRemarks.isEmpty ? palette.muted : palette.lavender)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(palette.muted)
    }

    private var supportingText: String {
        if !vod.vodActor.isEmpty { return vod.vodActor }
        if !vod.vodDirector.isEmpty { return "导演：\(vod.vodDirector)" }
        return "暂无演职员信息"
    }

    private var metadataText: String {
        let values = [vod.vodYear, vod.vodArea, vod.typeName].filter { !$0.isEmpty }
        return values.isEmpty ? "暂无年代与地区信息" : values.joined(separator: " · ")
    }

    private var remarkText: String {
        vod.vodRemarks.isEmpty ? "暂无更新信息" : vod.vodRemarks
    }
}

private struct SearchSkeletonView: View {
    @Environment(\.appThemePalette) private var palette
    let reduceMotion: Bool
    let layout: SearchResultRowLayout
    @State private var isBright = false

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: layout.columnSpacing) {
                    HStack(spacing: layout.isCompact ? 11 : 14) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.foreground.opacity(0.07))
                            .frame(width: layout.posterWidth, height: layout.posterWidth / PosterMetrics.aspectRatio)

                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(palette.foreground.opacity(0.1))
                                .frame(width: 170, height: 13)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(palette.foreground.opacity(0.07))
                                .frame(width: 230, height: 10)
                            Spacer()
                            RoundedRectangle(cornerRadius: 3)
                                .fill(palette.foreground.opacity(0.06))
                                .frame(width: 130, height: 9)
                        }
                        .padding(.vertical, 10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !layout.isCompact {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(palette.foreground.opacity(0.07))
                            .frame(width: layout.sourceWidth * 0.72, height: 11)
                            .frame(width: layout.sourceWidth, alignment: .leading)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(palette.foreground.opacity(0.07))
                            .frame(width: layout.statusWidth * 0.72, height: 11)
                            .frame(width: layout.statusWidth, alignment: .leading)
                    }

                    Color.clear.frame(width: 16)
                }
                .padding(.horizontal, layout.horizontalPadding)
                .frame(maxWidth: .infinity, minHeight: layout.rowHeight)
                .overlay(alignment: .bottom) { Divider().opacity(0.3) }
            }
        }
        .opacity(isBright ? 0.92 : 0.5)
        .onAppear {
            guard !reduceMotion else {
                isBright = true
                return
            }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                isBright = true
            }
        }
    }
}

private struct SearchFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: proposal.width ?? max(0, x - spacing), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct HotSearchGridLayout: Layout {
    let minimumColumnWidth: CGFloat
    let columnSpacing: CGFloat
    let rowHeight: CGFloat
    let maximumColumns: Int

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let naturalColumns = min(maximumColumns, subviews.count)
        let naturalWidth = CGFloat(naturalColumns) * minimumColumnWidth
            + CGFloat(max(0, naturalColumns - 1)) * columnSpacing
        let availableWidth = proposal.width ?? naturalWidth
        let columns = columnCount(availableWidth: availableWidth, itemCount: subviews.count)
        let rows = (subviews.count + columns - 1) / columns

        return CGSize(width: availableWidth, height: CGFloat(rows) * rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }

        let columns = columnCount(availableWidth: bounds.width, itemCount: subviews.count)
        let itemWidth = max(
            0,
            (bounds.width - CGFloat(columns - 1) * columnSpacing) / CGFloat(columns)
        )

        for (index, subview) in subviews.enumerated() {
            let column = index % columns
            let row = index / columns
            let origin = CGPoint(
                x: bounds.minX + CGFloat(column) * (itemWidth + columnSpacing),
                y: bounds.minY + CGFloat(row) * rowHeight
            )
            subview.place(
                at: origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: itemWidth, height: rowHeight)
            )
        }
    }

    private func columnCount(availableWidth: CGFloat, itemCount: Int) -> Int {
        let fittingColumns = Int(
            floor((availableWidth + columnSpacing) / (minimumColumnWidth + columnSpacing))
        )
        return max(1, min(maximumColumns, itemCount, fittingColumns))
    }
}
