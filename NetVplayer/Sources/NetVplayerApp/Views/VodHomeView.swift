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

    static func isSelectable(status: ExternalSourceSupportStatus?) -> Bool {
        status != .invalidConfiguration
    }

    static func statusPresentation(
        for status: ExternalSourceSupportStatus
    ) -> (text: String?, icon: String, detail: String) {
        switch status {
        case .native:
            return (nil, "checkmark.circle", status.userFacingDetail)
        case .nativePartial:
            return (status.userFacingTitle, "circle.lefthalf.filled", status.userFacingDetail)
        case .unsupportedBinary:
            return (status.userFacingTitle, "xmark.octagon", status.userFacingDetail)
        case .unsupportedAndroidCsp:
            return (status.userFacingTitle, "exclamationmark.triangle", status.userFacingDetail)
        case .pendingGuardCapture:
            return (status.userFacingTitle, "clock.arrow.circlepath", status.userFacingDetail)
        case .upstreamUnavailable:
            return (status.userFacingTitle, "bolt.slash", status.userFacingDetail)
        case .invalidConfiguration:
            return (status.userFacingTitle, "exclamationmark.octagon", status.userFacingDetail)
        case .js:
            return (nil, "link", status.userFacingDetail)
        case .cms:
            return (nil, "link", status.userFacingDetail)
        }
    }
}

struct SitePickerMenuControl: NSViewRepresentable {
    let title: String
    var items: [SitePickerMenuItem] = []
    var onSelect: (String) -> Void = { _ in }

    var accessibilityLabel: String {
        title.isEmpty ? L10n.text("未命名站点") : title
    }

    var accessibilityTitle: String {
        L10n.text("当前站点：{0}", ["\(accessibilityLabel)"])
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
                if item.id.hasPrefix("__group:") {
                    if !menu.items.isEmpty { menu.addItem(.separator()) }
                    let heading = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                    heading.isEnabled = false; menu.addItem(heading); continue
                }
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
    @ObservedObject var fileServices = FileServicesState.shared
    @Environment(\.appThemePalette) private var palette
    @State private var scrollTargetID = "recommend"
    @State private var categoryDragSelectionGate = HorizontalMouseDragSelectionGate()
    @State private var isPushPlaybackPresented = false
    @State private var pushPlaybackInput = ""
    @State private var isOpeningPushPlayback = false
    @FocusState private var isPushPlaybackFieldFocused: Bool

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
        .themedConfirmation(
            cloudCredentialClearTitle,
            isPresented: Binding(
                get: { appState.cloudCredentialClearRequest != nil },
                set: { if !$0 { appState.cancelCloudCredentialClear() } }
            ),
            confirmTitle: L10n.text("确认清除"), message: cloudCredentialClearMessage
        ) {
            appState.confirmCloudCredentialClear()
        }
        .sheet(isPresented: $isPushPlaybackPresented) {
            pushPlaybackSheet.themedPresentation()
        }
    }

    private var cloudCredentialClearTitle: String {
        guard let request = appState.cloudCredentialClearRequest else { return L10n.text("清除网盘授权？") }
        return L10n.text("清除{0}授权？", ["\(request.provider.localizedDisplayName)"])
    }

    private var cloudCredentialClearMessage: String {
        guard let request = appState.cloudCredentialClearRequest else { return "" }
        return L10n.text("将删除本机保存的{0} Cookie、token 和相关设备信息。此操作不会删除网盘文件。", ["\(request.provider.localizedDisplayName)"])
    }

    private func homeContent(isSidebarPresented: Bool, posterLayout: HomePosterGridLayout) -> some View {
        ZStack {
            VStack(spacing: 0) {
                header(isSidebarPresented: isSidebarPresented)

                if let service = fileServices.catalog.services.first(where: { $0.siteKey == appState.activeSite?.key }) {
                    FileServiceBrowserView(state: fileServices, service: service)
                } else if appState.isConfigLoaded {
                    categoryStrip
                    categoryFilterStrip
                    libraryContent(posterLayout: posterLayout)
                } else {
                    switch appState.savedConfigStartupPhase {
                    case .unconfigured:
                        configurationEmptyState
                    case .preparingExtension:
                        savedConfigLoadingState(message: L10n.text("正在准备播放扩展"))
                    case .loading, .ready:
                        savedConfigLoadingState(message: L10n.text("正在加载数据源"))
                    case .failed(let message):
                        AppUnavailableState(
                            title: L10n.text("数据源暂未加载"),
                            message: message,
                            systemImage: "exclamationmark.triangle",
                            actionTitle: appState.availableDepots.isEmpty ? L10n.text("重试") : L10n.text("打开设置")
                        ) {
                            if appState.availableDepots.isEmpty {
                                appState.retrySavedConfigStartup()
                            } else {
                                appState.selectedTab = .settings
                            }
                        }
                    }
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
            HStack(spacing: 8) {
                sitePicker
                catalogRefreshButton
            }
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
                    Text(L10n.text("搜索电影、剧集、综艺"))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
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
            .help(L10n.text("搜索影视"))
        }
        .frame(height: HomeVisualPolicy.headerHeight)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.20), value: isSidebarPresented)
    }

    private var catalogRefreshButton: some View {
        Button {
            if appState.activeSite?.api.hasPrefix("netvplayer-files://") == true && fileServices.isRefreshing {
                fileServices.cancelCurrentRefresh()
            } else { Task { await appState.refreshCurrentCatalog() } }
        } label: {
            Group {
                if appState.activeSite?.api.hasPrefix("netvplayer-files://") == true && fileServices.isRefreshing {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                } else if appState.isCatalogRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .frame(width: 18, height: 18)
            .foregroundStyle(palette.muted)
            .frame(
                width: HomeVisualPolicy.headerControlHeight,
                height: HomeVisualPolicy.headerControlHeight
            )
            .background(AppGlassSurface(cornerRadius: HomeVisualPolicy.headerControlCornerRadius, role: .control))
            .contentShape(RoundedRectangle(cornerRadius: HomeVisualPolicy.headerControlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.isCatalogRefreshing || appState.activeSite == nil)
        .accessibilityLabel(fileServices.isRefreshing ? "取消刷新" : "刷新当前列表")
        .help(fileServices.isRefreshing ? "取消刷新" : "刷新当前列表")
    }

    @ViewBuilder
    private var sitePicker: some View {
        if appState.sites.isEmpty {
            sitePickerLabel(title: appState.currentSiteName)
                .frame(width: HomeVisualPolicy.sitePickerWidth)
        } else {
            let selectableSites = appState.sites.filter { site in
                SitePickerMenuItem.isSelectable(
                    status: appState.externalSourceReport(for: site)?.status
                )
            }
            let sourceItems = selectableSites.map { site in
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

            let regular = sourceItems.filter { !$0.id.hasPrefix("files-") }
            let files = sourceItems.filter { $0.id.hasPrefix("files-") }
            let menuItems = regular + (files.isEmpty ? [] : [SitePickerMenuItem(id: "__group:files", title: "文件服务", systemImage: "folder", help: "浏览自己的服务器和本地目录")] + files)
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
                    guard let site = selectableSites.first(where: { $0.key == siteKey }) else {
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
            .help(L10n.text("当前站点：{0}", ["\(appState.currentSiteName)"]))
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
                            title: L10n.text("推荐"),
                            id: "recommend",
                            isSelected: appState.selectedCategory == nil
                        ) {
                            scrollTargetID = "recommend"
                            Task {
                                await appState.loadHomeContent()
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
            .help(L10n.text("应用{0}筛选", ["\(filter.name)"]))
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
                title: L10n.text("视频源暂时不可用"),
                message: errorMessage,
                systemImage: "exclamationmark.triangle",
                actionTitle: L10n.text("重试")
            ) {
                Task {
                    await appState.refreshCurrentCatalog()
                }
            }
        } else if appState.vods.isEmpty {
            if isPushPlaybackSite {
                AppUnavailableState(
                    title: L10n.text("推送播放"),
                    message: L10n.text("输入媒体地址，或选择本地媒体文件。"),
                    systemImage: "link",
                    actionTitle: L10n.text("打开媒体")
                ) {
                    isPushPlaybackPresented = true
                }
            } else {
                let empty = emptyVodState
                AppUnavailableState(
                    title: empty.title,
                    message: empty.description,
                    systemImage: empty.systemImage,
                    actionTitle: empty.showsSearchButton ? L10n.text("去搜索") : nil
                ) {
                    appState.selectedTab = .search
                }
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
                                .onChange(of: appState.contentCatalogState.generation) { _, _ in
                                    // Refresh can reuse visible cards, so onAppear alone
                                    // does not restart pagination for the restored list.
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

    private var pushPlaybackSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("播放媒体"))
                        .font(.title2.bold())
                    Text(L10n.text("支持网络媒体地址和本地媒体文件"))
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
            }

            TextField(L10n.text("请输入地址…"), text: $pushPlaybackInput)
                .textFieldStyle(.roundedBorder)
                .focused($isPushPlaybackFieldFocused)
                .onSubmit {
                    openPushPlaybackIfReady()
                }

            Divider()

            HStack(spacing: 10) {
                Button {
                    choosePushPlaybackFile()
                } label: {
                    Label(L10n.text("选择文件"), systemImage: "folder")
                }

                Spacer()

                Button(L10n.text("取消"), role: .cancel) {
                    isPushPlaybackPresented = false
                }

                Button {
                    openPushPlaybackIfReady()
                } label: {
                    if isOpeningPushPlayback {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 56)
                    } else {
                        Text(L10n.text("确定"))
                            .frame(width: 56)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pushPlaybackInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isOpeningPushPlayback)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            DispatchQueue.main.async {
                isPushPlaybackFieldFocused = true
            }
        }
    }

    private var isPushPlaybackSite: Bool {
        guard let site = appState.activeSite else { return false }
        let api = site.api.lowercased()
        return site.key == "push_agent"
            || api == "csp_push"
            || api == "push"
            || api == "csp_pushshare"
            || api == "pushshare"
            || api == "csp_pushguard"
            || api == "pushguard"
    }

    private func openPushPlaybackIfReady() {
        let trimmed = pushPlaybackInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isOpeningPushPlayback else { return }

        let mediaAddress = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed).absoluteString
            : trimmed
        let title = pushPlaybackDisplayName(for: mediaAddress)
        isOpeningPushPlayback = true

        Task {
            await appState.openVodCard(
                Vod(
                    vodId: mediaAddress,
                    vodName: title,
                    vodPic: "video",
                    siteKey: appState.activeSite?.key ?? ""
                )
            )
            isOpeningPushPlayback = false
            isPushPlaybackPresented = false
            pushPlaybackInput = ""
        }
    }

    private func choosePushPlaybackFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = L10n.text("选择")
        panel.message = L10n.text("选择要播放的媒体文件")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        pushPlaybackInput = url.absoluteString
        isPushPlaybackFieldFocused = true
    }

    private func pushPlaybackDisplayName(for address: String) -> String {
        guard let url = URL(string: address) else { return L10n.text("推送媒体") }
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return name.isEmpty ? L10n.text("推送媒体") : name
    }

    private var configurationEmptyState: some View {
        AppUnavailableState(
            title: L10n.text("请先配置视频源"),
            message: L10n.text("前往设置添加配置 URL，加载后即可浏览影片。"),
            systemImage: "tv.slash",
            actionTitle: L10n.text("打开设置")
        ) {
            appState.selectedTab = .settings
        }
    }

    private func savedConfigLoadingState(message: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyVodState: (title: String, systemImage: String, description: String, showsSearchButton: Bool) {
        guard let site = appState.activeSite else {
            return (L10n.text("该分类暂无视频"), "film.stack", L10n.text("当前没有可显示的点播内容。"), false)
        }

        if isPanSearchStyleSite(site) {
            return (
                L10n.text("{0}等待搜索", ["\(site.name)"]),
                "magnifyingglass",
                L10n.text("该源主要提供网盘搜索结果，请在搜索页输入片名。"),
                true
            )
        }

        return (
            L10n.text("该分类暂无视频"),
            "film.stack",
            L10n.text("可尝试切换分类、站点或搜索片名。"),
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
            return (nil, "checkmark.circle", L10n.text("已提供当前系统可用的兼容实现，实际可用性取决于源站和网络。"))
        }
        if site.isWoggCrawlerSource {
            return (nil, "checkmark.circle", L10n.text("已提供当前系统可用的兼容实现，实际可用性取决于源站和网络。"))
        }
        if site.isAndroidCrawlerSource {
            return (L10n.text("暂不支持"), "exclamationmark.triangle", L10n.text("该来源使用的格式当前无法加载，请选择其他视频源。"))
        }
        if site.isSpider {
            return (nil, "link", L10n.text("该来源可直接尝试加载。"))
        }
        return (nil, "link", L10n.text("该来源可直接尝试加载。"))
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
                    fallbackText: vod.vodName,
                    maxPixelSize: posterWidth * 2
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
        .onHover { hovering in
            isHovered = hovering
            appState.updateDetailPrefetch(vod: vod, site: appState.activeSite, hovering: hovering)
        }
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
