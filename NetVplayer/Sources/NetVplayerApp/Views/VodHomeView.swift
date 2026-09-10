// NetVplayerApp/Views/VodHomeView.swift
// Cinematic point-of-entry for browsing VOD content.

import AppKit
import SwiftUI
import Models

struct SitePickerMenuItem: Equatable, Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let help: String

    static func displayTitle(siteName: String, statusText: String?) -> String {
        guard let statusText, !statusText.isEmpty else { return siteName }
        return "\(siteName) · \(statusText)"
    }

    static func statusPresentation(
        for status: ExternalSourceSupportStatus
    ) -> (text: String?, icon: String, detail: String) {
        switch status {
        case .native:
            return (nil, "arrow.triangle.branch", "已注册 Swift 替代实现；不代表已通过当前网络播放验证")
        case .nativePartial:
            return ("部分接管", "circle.lefthalf.filled", "仅部分功能已有 Swift 实现，详情以兼容性报告为准")
        case .unsupportedBinary:
            return ("二进制不可用", "xmark.octagon", "依赖未打包的二进制或外部组件")
        case .unsupportedAndroidCsp:
            return ("Android 不可用", "exclamationmark.triangle", "Android csp_ 源无法在 macOS 运行")
        case .pendingGuardCapture:
            return ("待抓包", "rectangle.and.text.magnifyingglass", "需要补齐请求行为后再原生化")
        case .upstreamUnavailable:
            return ("上游失效", "bolt.slash", "Fongmi 当前上游也无法返回目录")
        case .invalidConfiguration:
            return ("配置无效", "exclamationmark.octagon", "远端条目缺少可加载实现或必要规则，无法构造内容源")
        case .js:
            return ("JS", "curlybraces", "由 JavaScriptCore 运行时加载")
        case .cms:
            return ("CMS", "link", "直接请求 CMS 或 HTTP API")
        }
    }
}

struct SitePickerMenuControl: NSViewRepresentable {
    let title: String
    var items: [SitePickerMenuItem] = []
    var onSelect: (String) -> Void = { _ in }

    var accessibilityLabel: String {
        title.isEmpty ? "未命名站点" : title
    }

    var accessibilityTitle: String {
        "当前站点：\(accessibilityLabel)"
    }

    var controlSize: CGSize {
        CGSize(
            width: HomeVisualPolicy.sitePickerWidth,
            height: HomeVisualPolicy.headerControlHeight
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items, onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setAccessibilityRole(.popUpButton)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        context.coordinator.onSelect = onSelect
        button.toolTip = accessibilityTitle
        button.setAccessibilityLabel(accessibilityTitle)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSButton,
        context: Context
    ) -> CGSize? {
        controlSize
    }

    final class Coordinator: NSObject {
        var items: [SitePickerMenuItem]
        var onSelect: (String) -> Void
        private var presentedMenu: NSMenu?

        init(items: [SitePickerMenuItem], onSelect: @escaping (String) -> Void) {
            self.items = items
            self.onSelect = onSelect
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false

            for item in items {
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(selectItem(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = item.id
                menuItem.toolTip = item.help
                menuItem.image = NSImage(
                    systemSymbolName: item.systemImage,
                    accessibilityDescription: nil
                )
                menu.addItem(menuItem)
            }

            presentedMenu = menu
            menu.popUp(positioning: nil, at: .zero, in: sender)
            presentedMenu = nil
        }

        @objc private func selectItem(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            onSelect(id)
        }
    }
}

struct VodHomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appThemePalette) private var palette
    @State private var scrollTargetID = "recommend"
    @State private var categoryDragSelectionGate = HorizontalMouseDragSelectionGate()

    var body: some View {
        GeometryReader { geometry in
            homeContent(
                isSidebarPresented: HomeVisualPolicy.isSidebarPresented(
                    detailLeadingEdge: geometry.frame(in: .global).minX
                ),
                posterLayout: HomeVisualPolicy.posterGridLayout(
                    availableWidth: HomeVisualPolicy.posterAvailableWidth(
                        containerWidth: geometry.size.width
                    )
                )
            )
        }
        .confirmationDialog(
            cloudCredentialClearTitle,
            isPresented: Binding(
                get: { appState.cloudCredentialClearRequest != nil },
                set: { if !$0 { appState.cancelCloudCredentialClear() } }
            ),
            titleVisibility: .visible
        ) {
            Button("确认清除", role: .destructive) {
                appState.confirmCloudCredentialClear()
            }
            Button("取消", role: .cancel) {
                appState.cancelCloudCredentialClear()
            }
        } message: {
            Text(cloudCredentialClearMessage)
        }
    }

    private var cloudCredentialClearTitle: String {
        guard let request = appState.cloudCredentialClearRequest else { return "清除网盘授权？" }
        return "清除\(request.provider.displayName)授权？"
    }

    private var cloudCredentialClearMessage: String {
        guard let request = appState.cloudCredentialClearRequest else { return "" }
        return "将删除本机保存的\(request.provider.displayName) Cookie、token 和相关设备信息。此操作不会删除网盘文件。"
    }

    private func homeContent(isSidebarPresented: Bool, posterLayout: HomePosterGridLayout) -> some View {
        ZStack {
            VStack(spacing: 0) {
                header(isSidebarPresented: isSidebarPresented)

                if appState.isConfigLoaded {
                    categoryStrip
                    categoryFilterStrip
                    libraryContent(posterLayout: posterLayout)
                } else {
                    configurationEmptyState
                }
            }
            .padding(.horizontal, HomeVisualPolicy.contentHorizontalPadding)
            .padding(.top, HomeVisualPolicy.contentTopPadding)
        }
        .foregroundStyle(palette.foreground)
        .tint(palette.accent)
        .ignoresSafeArea(edges: .top)
    }

    private func header(isSidebarPresented: Bool) -> some View {
        HStack(spacing: HomeVisualPolicy.headerGap) {
            sitePicker
                .offset(
                    x: HomeVisualPolicy.headerLeadingInset(
                        isSidebarPresented: isSidebarPresented
                    )
                )
                .padding(
                    .trailing,
                    HomeVisualPolicy.headerLeadingInset(
                        isSidebarPresented: isSidebarPresented
                    )
                )

            Spacer(minLength: 20)

            Button {
                appState.selectedTab = .search
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                    Text("搜索电影、剧集、综艺")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 12)
                }
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 14)
                .frame(maxWidth: HomeVisualPolicy.searchIdealWidth, minHeight: HomeVisualPolicy.headerControlHeight)
                .background(AppGlassSurface(cornerRadius: HomeVisualPolicy.headerControlCornerRadius, role: .control))
                .contentShape(RoundedRectangle(cornerRadius: HomeVisualPolicy.headerControlCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help("搜索影视")
        }
        .frame(height: HomeVisualPolicy.headerHeight)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.20), value: isSidebarPresented)
    }

    @ViewBuilder
    private var sitePicker: some View {
        if appState.sites.isEmpty {
            sitePickerLabel(title: appState.currentSiteName)
                .frame(width: HomeVisualPolicy.sitePickerWidth)
        } else {
            let menuItems = appState.sites.map { site in
                let status = siteMenuStatus(for: site)
                return SitePickerMenuItem(
                    id: site.key,
                    title: SitePickerMenuItem.displayTitle(
                        siteName: site.name,
                        statusText: status.text
                    ),
                    systemImage: status.icon,
                    help: status.detail
                )
            }

            ZStack(alignment: .leading) {
                sitePickerLabel(title: appState.currentSiteName)
                    .frame(
                        width: HomeVisualPolicy.sitePickerWidth,
                        height: HomeVisualPolicy.headerControlHeight,
                        alignment: .leading
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                SitePickerMenuControl(
                    title: appState.currentSiteName,
                    items: menuItems
                ) { siteKey in
                    guard let site = appState.sites.first(where: { $0.key == siteKey }) else {
                        return
                    }
                    Task { @MainActor in
                        await appState.changeSite(site: site)
                    }
                }
                .frame(
                    width: HomeVisualPolicy.sitePickerWidth,
                    height: HomeVisualPolicy.headerControlHeight
                )
            }
            .frame(
                width: HomeVisualPolicy.sitePickerWidth,
                height: HomeVisualPolicy.headerControlHeight,
                alignment: .leading
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: HomeVisualPolicy.headerControlCornerRadius,
                    style: .continuous
                )
            )
            .help("当前站点：\(appState.currentSiteName)")
        }
    }

    private func sitePickerLabel(title: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(palette.lavender.opacity(0.16))
                Image(systemName: "play.tv")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: 30, height: 30)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 8)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: HomeVisualPolicy.headerControlHeight)
        .background(AppGlassSurface(cornerRadius: HomeVisualPolicy.headerControlCornerRadius, role: .control))
        .contentShape(RoundedRectangle(cornerRadius: HomeVisualPolicy.headerControlCornerRadius, style: .continuous))
    }

    private var categoryStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HomeVisualPolicy.categoryGap) {
                    if appState.activeSite?.showsSyntheticRecommendation != false {
                        categoryButton(
                            title: "推荐",
                            id: "recommend",
                            isSelected: appState.selectedCategory == nil
                        ) {
                            scrollTargetID = "recommend"
                            Task {
                                await appState.loadHomeContent()
                                appState.selectedCategory = nil
                            }
                        }
                    }

                    ForEach(appState.categories) { category in
                        categoryButton(
                            title: category.typeName,
                            id: category.typeId,
                            isSelected: appState.selectedCategory?.typeId == category.typeId
                        ) {
                            scrollTargetID = category.typeId
                            Task {
                                await appState.selectCategory(category)
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
                .background(
                    HorizontalMouseDragScrollProbe(selectionGate: categoryDragSelectionGate)
                )
            }
            .onChange(of: appState.selectedCategory) { _, newValue in
                let targetID = newValue?.typeId ?? "recommend"
                scrollTargetID = targetID
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            }
        }
        .padding(.bottom, HomeVisualPolicy.categoryBottomPadding)
    }

    private func categoryButton(
        title: String,
        id: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard !categoryDragSelectionGate.shouldSuppressSelection() else { return }
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? palette.foreground : palette.muted)
                .padding(.horizontal, HomeVisualPolicy.categoryHorizontalPadding)
                .frame(height: HomeVisualPolicy.categoryHeight)
                .background {
                    RoundedRectangle(cornerRadius: HomeVisualPolicy.categoryCornerRadius, style: .continuous)
                        .fill(
                            isSelected
                                ? palette.lavender.opacity(HomeVisualPolicy.selectedBackgroundOpacity)
                                : palette.foreground.opacity(0.055)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: HomeVisualPolicy.categoryCornerRadius, style: .continuous)
                                .stroke(
                                    isSelected
                                        ? palette.accent.opacity(HomeVisualPolicy.selectedBorderOpacity)
                                        : palette.foreground.opacity(0.08),
                                    lineWidth: 1
                                )
                        }
                }
                .contentShape(RoundedRectangle(cornerRadius: HomeVisualPolicy.categoryCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .id(id)
    }

    @ViewBuilder
    private var categoryFilterStrip: some View {
        if appState.selectedCategory != nil, !appState.categoryFilters.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.muted)
                    .accessibilityHidden(true)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(appState.categoryFilters.indices, id: \.self) { index in
                            categoryFilterControl(appState.categoryFilters[index])
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            .frame(height: 34)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func categoryFilterControl(_ filter: Filter) -> some View {
        if filter.inputKind == .text {
            categoryTextFilter(filter)
        } else {
            categoryFilterMenu(filter)
        }
    }

    private func categoryTextFilter(_ filter: Filter) -> some View {
        let value = appState.selectedCategoryFilterValues[filter.key] ?? ""
        let normalized = CategoryFilterTextPolicy.normalized(value)
        let canApply = normalized != nil && (!filter.isRequired || normalized?.isEmpty == false)

        return HStack(spacing: 7) {
            Text(filter.name + (filter.isRequired ? " *" : ""))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.muted)

            TextField(filter.name, text: Binding(
                get: { appState.selectedCategoryFilterValues[filter.key] ?? "" },
                set: { appState.updateCategoryTextFilterDraft(filter, value: $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .frame(width: 130)
            .onSubmit {
                guard canApply, !appState.isLoadingVod else { return }
                Task { await appState.applyCategoryTextFilter(filter) }
            }

            Button {
                Task { await appState.applyCategoryTextFilter(filter) }
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(!canApply || appState.isLoadingVod)
            .help("应用\(filter.name)筛选")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.foreground.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            filter.isRequired && normalized?.isEmpty != false
                                ? palette.color(for: .warning).opacity(0.55)
                                : palette.foreground.opacity(0.09),
                            lineWidth: 1
                        )
                }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func categoryFilterMenu(_ filter: Filter) -> some View {
        let selectedName = appState.selectedCategoryFilterName(for: filter)
        return Menu {
            ForEach(filter.values.indices, id: \.self) { index in
                let value = filter.values[index]
                Button {
                    Task {
                        await appState.selectCategoryFilter(filter, value: value)
                    }
                } label: {
                    if appState.selectedCategoryFilterValues[filter.key] == value.value {
                        Label(value.name, systemImage: "checkmark")
                    } else {
                        Text(value.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(filter.name)
                    .foregroundStyle(palette.muted)
                Text(selectedName)
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.muted)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(palette.foreground.opacity(0.055))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(palette.foreground.opacity(0.09), lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(appState.isLoadingVod)
        .help("\(filter.name)：\(selectedName)")
    }

    @ViewBuilder
    private func libraryContent(posterLayout: HomePosterGridLayout) -> some View {
        if appState.isLoadingVod {
            ThemedScrollView {
                LazyVStack(alignment: .leading, spacing: HomeVisualPolicy.posterVerticalGap) {
                    ForEach(
                        HomeVisualPolicy.posterRowStarts(itemCount: 18, columnCount: posterLayout.columnCount),
                        id: \.self
                    ) { rowStart in
                        HStack(alignment: .top, spacing: HomeVisualPolicy.posterHorizontalGap) {
                            ForEach(rowStart..<min(rowStart + posterLayout.columnCount, 18), id: \.self) { _ in
                                VodCardSkeleton(posterWidth: posterLayout.itemWidth)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        } else if let errorMessage = appState.vodError {
            AppUnavailableState(
                title: "视频源暂时不可用",
                message: errorMessage,
                systemImage: "exclamationmark.triangle",
                actionTitle: "重试"
            ) {
                Task {
                    if let category = appState.selectedCategory {
                        await appState.selectCategory(category)
                    } else {
                        await appState.loadHomeContent()
                    }
                }
            }
        } else if appState.vods.isEmpty {
            let empty = emptyVodState
            AppUnavailableState(
                title: empty.title,
                message: empty.description,
                systemImage: empty.systemImage,
                actionTitle: empty.showsSearchButton ? "去搜索" : nil
            ) {
                appState.selectedTab = .search
            }
        } else {
            ThemedScrollView {
                LazyVStack(alignment: .leading, spacing: HomeVisualPolicy.posterVerticalGap) {
                    ForEach(
                        HomeVisualPolicy.posterRowStarts(
                            itemCount: appState.vods.count,
                            columnCount: posterLayout.columnCount
                        ),
                        id: \.self
                    ) { rowStart in
                        HStack(alignment: .top, spacing: HomeVisualPolicy.posterHorizontalGap) {
                            ForEach(
                                appState.vods[rowStart..<min(rowStart + posterLayout.columnCount, appState.vods.count)]
                            ) { vod in
                                Button {
                                    Task {
                                        await appState.openVodCard(vod)
                                    }
                                } label: {
                                    VodCard(vod: vod, posterWidth: posterLayout.itemWidth)
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    Task {
                                        await appState.loadMoreCategoryContentIfNeeded(currentVod: vod)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    if appState.isLoadingMoreVods {
                        ProgressView()
                            .tint(palette.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    private var configurationEmptyState: some View {
        AppUnavailableState(
            title: "请先配置视频源",
            message: "前往设置添加配置 URL，加载后即可浏览影片。",
            systemImage: "tv.slash",
            actionTitle: "打开设置"
        ) {
            appState.selectedTab = .settings
        }
    }

    private var emptyVodState: (title: String, systemImage: String, description: String, showsSearchButton: Bool) {
        guard let site = appState.activeSite else {
            return ("该分类暂无视频", "film.stack", "当前没有可显示的点播内容。", false)
        }

        if isPanSearchStyleSite(site) {
            return (
                "\(site.name)等待搜索",
                "magnifyingglass",
                "该源主要提供网盘搜索结果，请在搜索页输入片名。",
                true
            )
        }

        return (
            "该分类暂无视频",
            "film.stack",
            "可尝试切换分类、站点或搜索片名。",
            true
        )
    }

    private func isPanSearchStyleSite(_ site: Site) -> Bool {
        let key = site.key.lowercased()
        let api = site.api.lowercased()
        return key == "zpan"
            || key == "seed"
            || api.contains("s_zpsguard")
            || api.contains("seedhubguard")
            || site.name.contains("聚盘搜")
            || site.name.contains("聚剧剧")
    }

    private func siteMenuStatus(for site: Site) -> (text: String?, icon: String, detail: String) {
        if let status = appState.externalSourceReport(for: site)?.status {
            return SitePickerMenuItem.statusPresentation(for: status)
        }
        if appState.nativeReplacementSiteKeys.contains(site.key) {
            return (nil, "arrow.triangle.branch", "已注册 Swift 替代实现；尚无运行可用性结论")
        }
        if site.isWoggCrawlerSource {
            return (nil, "arrow.triangle.branch", "已注册 Swift WoGG 替代实现；尚无运行可用性结论")
        }
        if site.isAndroidCrawlerSource {
            return ("Android 不可用", "exclamationmark.triangle", "Android csp_ 源暂不支持")
        }
        if site.isSpider {
            return ("JS", "curlybraces", "JS、drpy 或远程脚本源")
        }
        return ("CMS", "link", "CMS、XPath 或 HTTP API 源")
    }
}

struct VodCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appThemePalette) private var palette
    let vod: Vod
    let posterWidth: CGFloat
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PosterAspectContainer(width: posterWidth) {
                WebImage(
                    urlString: vod.vodPic,
                    siteHeader: appState.activeSite?.header,
                    fallbackText: vod.vodName
                )
            }
            .overlay {
                LinearGradient(
                    colors: [.clear, palette.background.opacity(0.24)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
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

            Text(vod.vodName)
                .font(.system(size: HomeVisualPolicy.posterTitleFontSize, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)

            Text(vod.vodRemarks.isEmpty ? vod.vodYear : vod.vodRemarks)
                .font(.system(size: HomeVisualPolicy.posterMetadataFontSize, weight: .medium))
                .foregroundStyle(palette.muted.opacity(HomeVisualPolicy.mutedTextOpacity))
                .lineLimit(1)
                .frame(minHeight: 14)
        }
        .frame(width: posterWidth, alignment: .leading)
        .scaleEffect(isHovered ? 1.018 : 1)
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

struct VodCardSkeleton: View {
    @Environment(\.appThemePalette) private var palette
    let posterWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PosterAspectContainer(width: posterWidth) {
                RoundedRectangle(cornerRadius: HomeVisualPolicy.posterCornerRadius, style: .continuous)
                    .fill(palette.surface.opacity(0.46))
                    .overlay {
                        Image(systemName: "film")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(palette.muted.opacity(0.24))
                    }
            }

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(palette.muted.opacity(0.18))
                .frame(height: 12)
                .padding(.trailing, 24)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(palette.muted.opacity(0.10))
                .frame(width: 74, height: 9)
        }
        .frame(width: posterWidth, alignment: .leading)
    }
}
