// NetVplayerApp/Views/SettingsView.swift
// 系统设置视图

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Models
import Storage
import Networking
import PlayerEngine
import ProviderRuntime
import ProviderSDK
import WebHomeEngine

enum SavedVodConfigSelectionPolicy {
    static func resolvedSelection(savedURLs: [String], activeURL: String) -> String {
        guard let fallbackURL = savedURLs.first else { return "" }

        let normalizedActiveURL = activeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedActiveURL.isEmpty else { return fallbackURL }

        return savedURLs.first {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedActiveURL
        } ?? fallbackURL
    }
}

struct SettingsView: View {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case appearance = "外观"
        case dataSource = "数据源设置"
        case providers = "Provider 运行时"
        case playback = "播放偏好"
        case network = "网络与代理"
        case system = "缓存与系统"
        case feedback = "问题反馈"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .appearance: return "paintpalette"
            case .dataSource: return "link"
            case .providers: return "shippingbox"
            case .playback: return "play.circle"
            case .network: return "network"
            case .system: return "wrench"
            case .feedback: return "exclamationmark.bubble"
            }
        }

        var subtitle: String {
            switch self {
            case .appearance: return "背景、主题与控件色彩"
            case .dataSource: return "站点、授权与源诊断"
            case .providers: return "签名包、运行时与版本状态"
            case .playback: return "画面、字幕与播放行为"
            case .network: return "代理、端口与中继"
            case .system: return "缓存、备份与实验功能"
            case .feedback: return "复现资料、脱敏日志与 Issue"
            }
        }
    }

    private enum CloudProvider: String, CaseIterable, Identifiable, Hashable {
        case quark = "夸克"
        case uc = "UC"
        case ali = "阿里云盘"
        case baidu = "百度网盘"
        case p115 = "115"
        case pikpak = "PikPak"

        var id: String { rawValue }

        var credentialKind: String {
            switch self {
            case .quark: return "Cookie / Token"
            case .uc: return "Cookie"
            case .ali: return "Refresh Token"
            case .p115: return "Cookie / Access Token"
            case .pikpak: return "Access / Refresh Token"
            case .baidu: return "Cookie"
            }
        }

        var driveProvider: DriveProvider {
            switch self {
            case .quark: return .quark
            case .uc: return .uc
            case .ali: return .ali
            case .p115: return .p115
            case .pikpak: return .pikpak
            case .baidu: return .baidu
            }
        }

        var authorizationGuidance: String {
            "\(rawValue)授权凭据仅保存在本机；手动输入只用于授权流程不可用时的高级兜底。敏感凭据不会写入备份文件。"
        }
    }

    @EnvironmentObject var appState: AppState

    @State private var selectedSection: SettingsSection = .appearance
    @State private var hoveredSection: SettingsSection?
    @State private var selectedCloudProvider: CloudProvider = .quark
    @State private var selectedSavedVodConfigURL: String = ""
    @State private var configReportExpanded: Bool = false
    @State private var compatibilityReportExpanded: Bool = false
    @State private var vodConfigUrl: String = ""
    @State private var liveConfigUrl: String = ""
    @State private var isLoadingVod: Bool = false
    @State private var isLoadingLive: Bool = false
    @State private var pendingSavedVodConfigRemoval: Config?
    @State private var quarkCookie: String = ""
    @State private var ucCookie: String = ""
    @State private var baiduCookie: String = ""
    @State private var aliRefreshToken: String = ""
    @State private var aliAccessToken: String = ""
    @State private var aliOpenToken: String = ""
    @State private var aliDefaultDriveID: String = ""
    @State private var p115Cookie: String = ""
    @State private var p115AccessToken: String = ""
    @State private var pikpakAccessToken: String = ""
    @State private var pikpakRefreshToken: String = ""
    @State private var pikpakDeviceID: String = ""
    @State private var cloudCookieSaved: Bool = false
    @State private var isValidatingCloudCookie: Bool = false
    @State private var cloudCookieStatus: String?
    @State private var isManualCloudAuthExpanded: Bool = false
    @State private var cloudAutoDeleteSavedFiles: [CloudProvider: Bool] = [:]
    @State private var backupStatus: String?
    @State private var backupStatusIsError: Bool = false
    @State private var windowPreferenceStatus: String?
    @State private var progressSyncStatus: String?
    @State private var progressSyncStatusIsError: Bool = false

    // 偏好选项本地状态
    @State private var decodeMode: Int = 0
    @State private var subtitleFontSize: Int = SubtitleRenderSettings.defaultFontSize
    @State private var subtitlePosition: Int = SubtitleRenderSettings.defaultPosition
    @State private var subtitleOverrideSourceStyle: Bool = SubtitleRenderSettings.defaultOverrideSourceStyle
    @State private var danmakuEnabled: Bool = false
    @State private var danmakuOpacity: Double = 0.8
    @State private var danmakuFontSize: Int = 36
    @State private var danmakuOffsetMs: Int = 0
    @State private var siteHealthSortingEnabled: Bool = true
    @State private var sourceHygieneExpanded: Bool = false
    @State private var credentialRiskExpanded: Bool = false
    @State private var resourceDiagnosticsExpanded: Bool = false
    @State private var liveLineQualityExpanded: Bool = false
    @State private var isProbingCurrentLiveGroup: Bool = false

    // 缓存大小本地展示
    @State private var displayCacheSize: String = "正在计算..."
    @State private var isShowingCacheConfirmation: Bool = false

    // 网络代理本地状态
    @State private var proxyMode: Int = 0
    @State private var customProxyServer: String = "127.0.0.1"
    @State private var customProxyPort: Int = 7897
    @State private var chunkedRangeRelayEnabled: Bool = false
    @State private var webHomeEnabled: Bool = false
    @State private var webHomeURL: String = ""

    var body: some View {
        HStack(spacing: 0) {
            settingsSectionSidebar
                .background {
                    AppGlassSurface(cornerRadius: 0, role: .chrome)
                }

            Rectangle()
                .fill(palette.foreground.opacity(0.08))
                .frame(width: 1)

            VStack(spacing: 0) {
                settingsContentHeader
                    .padding(.horizontal, AppSurfaceVisualPolicy.pageHorizontalPadding)

                ThemedScrollView {
                    selectedSectionContent
                        .id(selectedSection)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .frame(maxWidth: AppSurfaceVisualPolicy.settingsContentMaxWidth, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, AppSurfaceVisualPolicy.pageHorizontalPadding)
                        .padding(.top, 4)
                        .padding(.bottom, AppSurfaceVisualPolicy.settingsBottomPadding)
                }
                .id(selectedSection)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(palette.foreground)
        .tint(palette.accent)
        .groupBoxStyle(AppGroupBoxStyle())
        .ignoresSafeArea(edges: .top)
        .onAppear {
            loadSettingsState()
            applySettingsNavigationDestination(appState.settingsNavigationDestination)
        }
        .onChange(of: appState.settingsNavigationDestination) { _, destination in
            applySettingsNavigationDestination(destination)
        }
        .onChange(of: appState.cloudAuthRequest) { previousRequest, request in
            guard previousRequest != nil, request == nil else { return }
            loadCloudCredentialState()
        }
        .confirmationDialog(
            "清理所有缓存？",
            isPresented: $isShowingCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认清理", role: .destructive) {
                do {
                    try CacheManager.shared.clearCache()
                    refreshCacheSize()
                } catch {
                    print("[SettingsView] 清理缓存出错: \(error)")
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空爬虫脚本缓存、网页数据与 Cookie。配置、历史和收藏不会被删除。")
        }
        .confirmationDialog(
            "删除已保存配置？",
            isPresented: Binding(
                get: { pendingSavedVodConfigRemoval != nil },
                set: { if !$0 { pendingSavedVodConfigRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除配置", role: .destructive) {
                guard let config = pendingSavedVodConfigRemoval else { return }
                pendingSavedVodConfigRemoval = nil
                guard appState.deleteSavedConfig(config) else { return }

                if vodConfigUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                    == config.url.trimmingCharacters(in: .whitespacesAndNewlines) {
                    vodConfigUrl = ""
                }
                syncSavedVodConfigSelection(
                    appState.savedConfigs.filter { $0.type == .vod }.map(\.url)
                )
            }
            Button("取消", role: .cancel) {
                pendingSavedVodConfigRemoval = nil
            }
        } message: {
            Text("“\(pendingSavedVodConfigRemovalName)”将从本机保存记录中删除。当前已加载内容不会立即切换。")
        }
    }

    private func applySettingsNavigationDestination(_ destination: SettingsNavigationDestination?) {
        guard let destination else { return }
        switch destination {
        case .dataSource:
            selectedSection = .dataSource
        case .providers:
            selectedSection = .providers
        case .playback:
            selectedSection = .playback
        case .network:
            selectedSection = .network
        case .system:
            selectedSection = .system
        case .appearance:
            selectedSection = .appearance
        case .feedback:
            selectedSection = .feedback
        }
        appState.consumeSettingsNavigationDestination(destination)
    }

    private var settingsSectionSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("设置")
                    .font(.system(size: 22, weight: .bold))
                Text("NetVplayer 偏好")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)

            VStack(spacing: AppSurfaceVisualPolicy.localNavigationGap) {
                ForEach(SettingsSection.allCases) { section in
                    settingsSectionButton(section)
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 0)
        }
        .padding(.top, AppSurfaceVisualPolicy.settingsTitleTopPadding)
        .frame(width: AppSurfaceVisualPolicy.localSidebarWidth)
        .frame(maxHeight: .infinity)
    }

    private func settingsSectionButton(_ section: SettingsSection) -> some View {
        let isSelected = selectedSection == section
        let isHovered = hoveredSection == section

        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                selectedSection = section
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    AppNavigationIconBackground(
                        isSelected: isSelected,
                        isHovered: isHovered
                    )
                    Image(systemName: section.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(
                            isSelected ? palette.color(for: .onAccent) : palette.muted
                        )
                }
                .frame(width: HomeVisualPolicy.sidebarIconBoxSize, height: HomeVisualPolicy.sidebarIconBoxSize)

                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? palette.foreground : palette.muted)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: AppSurfaceVisualPolicy.localNavigationRowHeight)
            .background {
                AppNavigationRowBackground(
                    isSelected: isSelected,
                    isHovered: isHovered
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: HomeVisualPolicy.sidebarCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                hoveredSection = hovering ? section : (hoveredSection == section ? nil : hoveredSection)
            }
        }
    }

    private var settingsContentHeader: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedSection.rawValue)
                    .font(.system(size: 24, weight: .bold))
                Text(selectedSection.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.muted)
            }

            Spacer(minLength: 12)

            if selectedSection == .feedback {
                Label("提交前需预览并确认", systemImage: "checkmark.shield")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.muted)
            } else {
                HStack(spacing: 7) {
                    Circle()
                        .fill(palette.color(for: .success))
                        .frame(width: 6, height: 6)
                        .shadow(
                            color: palette.color(for: .success).opacity(0.35),
                            radius: 4
                        )
                    Text("更改将自动保存")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.muted)
                }
            }
        }
        .frame(maxWidth: AppSurfaceVisualPolicy.settingsContentMaxWidth)
        .padding(.top, AppSurfaceVisualPolicy.settingsTitleTopPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: AppSurfaceVisualPolicy.settingsHeaderHeight,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedSection {
        case .appearance:
            appearanceSettings
        case .dataSource:
            dataSourceSettings
        case .providers:
            providerRuntimeSettings
        case .playback:
            playbackSettings
        case .network:
            networkSettings
        case .system:
            cacheAndSystemSettings
        case .feedback:
            FeedbackView()
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: AppSurfaceVisualPolicy.pageSectionGap) {
            SettingsPanelLabel(
                title: "界面主题",
                subtitle: "选择浏览界面的背景与强调色。",
                systemImage: "paintpalette"
            )

            AppearanceThemePicker(selectedThemeID: appState.appearanceThemeID) { id in
                if reduceMotion {
                    appState.selectAppearanceTheme(id)
                } else {
                    withAnimation(.easeOut(duration: 0.16)) {
                        appState.selectAppearanceTheme(id)
                    }
                }
            }
        }
    }

    private var dataSourceSettings: some View {
        VStack(alignment: .leading, spacing: AppSurfaceVisualPolicy.pageSectionGap) {
            GroupBox(label: SettingsPanelLabel(
                title: "视频配置与数据源",
                subtitle: "加载点播与直播配置，地址校验后交由应用解析。",
                systemImage: "link",
                statusText: sourceConfigurationStatus,
                statusColor: sourceConfigurationStatusColor
            )) {
                VStack(spacing: 0) {
                    vodSourceSettings

                    Divider()
                    liveSourceSettings

                    Divider()
                    savedVodConfigs
                }
            }

            searchSourceSettings
            cloudDriveAuthSettings
        }
    }

    private var providerRuntimeSettings: some View {
        VStack(alignment: .leading, spacing: AppSurfaceVisualPolicy.pageSectionGap) {
            GroupBox(label: SettingsPanelLabel(
                title: "Provider 支持包",
                subtitle: "启动时自动同步固定签名目录中的兼容版本。",
                systemImage: "shippingbox",
                statusText: appState.providerRuntimeStatus,
                statusColor: appState.providerRuntimeStatus == "未配置"
                    ? palette.muted
                    : palette.color(for: .success)
            )) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("已安装并激活")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 12)
                        Button {
                            appState.refreshProviderRuntimeCatalog()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(appState.providerRuntimeBusy)
                        .help("立即同步 Provider 支持包")
                        .accessibilityLabel("立即同步 Provider 支持包")
                    }
                    .padding(.bottom, 10)

                    if let progress = appState.providerRuntimeProgress {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(progress.providerID) · \(progress.version)")
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                            if let fraction = progress.fractionCompleted {
                                ProgressView(value: fraction)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .padding(.bottom, 10)
                    }

                    if appState.providerRuntimeInstalled.isEmpty {
                        Text("暂无已安装支持包")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    } else {
                        ForEach(appState.providerRuntimeInstalled, id: \.manifest.providerID) { document in
                            SettingsControlRow(
                                title: document.manifest.providerID,
                                caption: "\(document.manifest.runtime.rawValue) · \(document.manifest.version)"
                            ) {
                                Label("已激活", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(palette.color(for: .success))
                            }
                        }
                    }

                    Divider()
                        .padding(.vertical, 10)

                    Text("签名目录")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.bottom, 8)

                    if appState.providerRuntimeCatalog.isEmpty {
                        Text("当前目录没有可用版本")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    } else {
                        ForEach(appState.providerRuntimeCatalog, id: \.self) { release in
                            let isRetry = appState.providerRuntimeFailedRelease == ProviderVersionReference(
                                providerID: release.providerID,
                                version: release.version
                            )
                            SettingsControlRow(
                                title: release.providerID,
                                caption: "版本 \(release.version)"
                            ) {
                                Button {
                                    appState.installProvider(
                                        providerID: release.providerID,
                                        version: release.version
                                    )
                                } label: {
                                    Label(isRetry ? "重试" : "安装", systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(.bordered)
                                .disabled(appState.providerRuntimeBusy)
                            }
                        }
                    }
                }
            }

            GroupBox(label: SettingsPanelLabel(
                title: "用户自有后端权限",
                subtitle: "WebDAV、AList 与 OpenList 使用独立的网络和凭据授权。",
                systemImage: "externaldrive.badge.shield.checkmark"
            )) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsControlRow(title: "端点与局域网", caption: "未配置端点") {
                        Label("未授权", systemImage: "network.slash")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                    Divider().padding(.vertical, 8)
                    SettingsControlRow(title: "明文 HTTP", caption: "默认拒绝") {
                        Label("未授权", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                    Divider().padding(.vertical, 8)
                    SettingsControlRow(title: "重定向", caption: "跨源响应与凭据转发被拒绝") {
                        Label("仅同源", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.caption)
                            .foregroundStyle(palette.color(for: .success))
                    }
                    Divider().padding(.vertical, 8)
                    SettingsControlRow(title: "凭据", caption: "仅接受 Keychain 引用授权") {
                        Label("未授权", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                }
            }

            Text("运行包依赖随签名 archive 一起交付；壳不会执行配置中的远程脚本，也不会在运行时安装 Python 依赖。")
                .font(.caption)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            appState.refreshProviderRuntimeCatalog()
        }
    }

    private var vodSourceSettings: some View {
        SettingsControlRow(title: "点播源配置", caption: "支持 JSON 配置与 MacCMS JSON/XML 接口") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    TextField("粘贴配置或 MacCMS 地址", text: $vodConfigUrl)
                        .textFieldStyle(.roundedBorder)

                    Button("加载") {
                        isLoadingVod = true
                        Task {
                            await appState.loadConfig(url: vodConfigUrl)
                            isLoadingVod = false
                        }
                    }
                    .disabled(vodConfigUrl.isEmpty || isLoadingVod)
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                }

                if isLoadingVod {
                    Label("正在加载点播源", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(palette.muted)
                        .font(.caption)
                } else if let error = appState.configError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.color(for: .danger))
                        .font(.caption)
                } else if appState.isConfigLoaded {
                    Label("点播源已加载成功", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(palette.color(for: .success))
                        .font(.caption)
                } else {
                    Text("尚未加载点播配置")
                        .foregroundStyle(palette.muted)
                        .font(.caption)
                }

                if let notice = appState.configNotice, !notice.isEmpty {
                    Label(notice, systemImage: "megaphone")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
            }
        }
    }

    private var savedVodConfigs: some View {
        let configs = appState.savedConfigs.filter { $0.type == .vod }

        return SettingsControlRow(title: "已保存配置", caption: "快速切换本机保存的配置") {
            HStack(spacing: 9) {
                Picker("已保存配置", selection: $selectedSavedVodConfigURL) {
                    Text(configs.isEmpty ? "未检测到已保存配置" : "选择一个配置")
                        .tag("")
                    ForEach(configs) { config in
                        Text(config.name.isEmpty ? config.url : config.name)
                            .tag(config.url)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                Button("加载") {
                    guard let config = configs.first(where: { $0.url == selectedSavedVodConfigURL }) else { return }
                    vodConfigUrl = config.url
                    isLoadingVod = true
                    Task {
                        await appState.loadConfig(url: config.url)
                        isLoadingVod = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(selectedSavedVodConfigURL.isEmpty || isLoadingVod)

                Button(role: .destructive) {
                    pendingSavedVodConfigRemoval = configs.first {
                        $0.url == selectedSavedVodConfigURL
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(selectedSavedVodConfigURL.isEmpty || isLoadingVod)
                .help("删除所选配置")
                .accessibilityLabel("删除所选配置")
            }
            .onAppear {
                syncSavedVodConfigSelection(configs.map(\.url))
            }
            .onChange(of: configs.map(\.url)) { _, urls in
                syncSavedVodConfigSelection(urls)
            }
        }
    }

    private var pendingSavedVodConfigRemovalName: String {
        guard let config = pendingSavedVodConfigRemoval else { return "所选配置" }
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? config.url : name
    }

    private var searchSourceSettings: some View {
        GroupBox(label: SettingsPanelLabel(
            title: "搜索站点与诊断",
            subtitle: "控制默认搜索范围，并按站点健康度优化请求顺序。",
            systemImage: "magnifyingglass"
        )) {
            VStack(spacing: 0) {
                compactDefaultSearchSites

                Divider()

                SettingsControlRow(title: "健康度排序", caption: "优先请求近期响应稳定的站点") {
                    Toggle("健康度排序", isOn: Binding(
                        get: { siteHealthSortingEnabled },
                        set: { newValue in
                            siteHealthSortingEnabled = newValue
                            UserPreferences.shared.siteHealthSortingEnabled = newValue
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                Divider()
                configReportDisclosureRow

                if configReportExpanded {
                    Divider()
                    advancedConfigDiagnostics
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private var compactDefaultSearchSites: some View {
        let sites = appState.sites.filter(\.isSearchable)
        let enabledCount = sites.filter { appState.isDefaultSearchSiteEnabled($0) }.count

        return SettingsControlRow(title: "默认搜索站点", caption: "未自定义时使用全部站点") {
            HStack(spacing: 9) {
                Menu {
                    ForEach(sites, id: \.key) { site in
                        Button {
                            appState.setDefaultSearchSite(
                                site,
                                enabled: !appState.isDefaultSearchSiteEnabled(site)
                            )
                        } label: {
                            Label(
                                site.name,
                                systemImage: appState.isDefaultSearchSiteEnabled(site) ? "checkmark" : "circle"
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(enabledCount == sites.count ? "全部站点" : "已选 \(enabledCount) / \(sites.count)")
                            .fontWeight(.semibold)
                        Text(enabledCount == sites.count ? "默认" : "自定义")
                            .foregroundStyle(palette.muted)
                    }
                }
                .menuStyle(.button)

                Button("全部启用") {
                    appState.resetDefaultSearchSites()
                }
                .buttonStyle(.bordered)
                .disabled(sites.isEmpty || enabledCount == sites.count)
            }
        }
    }

    private var configReportDisclosureRow: some View {
        let snapshot = appState.configAggregationSnapshot
        let hasScan = appState.isConfigLoaded || !appState.externalSourceReports.isEmpty

        return SettingsControlRow(title: "配置聚合报告", caption: "兼容性、凭据风险与资源诊断") {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    configReportExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    SettingsStatusTag(
                        label: "外部源",
                        value: hasScan ? "\(snapshot.fetchedSources.count)" : "尚未扫描"
                    )
                    SettingsStatusTag(
                        label: "风险",
                        value: hasScan ? "\(snapshot.credentialRiskCount)" : "尚未扫描"
                    )
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .rotationEffect(.degrees(configReportExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var advancedConfigDiagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !appState.availableDepots.isEmpty {
                DisclosureGroup("配置仓库") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.availableDepots, id: \.url) { depot in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(depot.name.isEmpty ? "未命名配置" : depot.name)
                                        .font(.caption.weight(.medium))
                                    Text(depot.url)
                                        .font(.caption2)
                                        .foregroundStyle(palette.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("加载") {
                                    vodConfigUrl = depot.url
                                    isLoadingVod = true
                                    Task {
                                        await appState.loadDepot(depot)
                                        isLoadingVod = false
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }

            configAggregationReport

            if !appState.externalSourceReports.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $compatibilityReportExpanded) {
                    externalSourceCompatibilityReport
                        .padding(.top, 8)
                } label: {
                    Label("外部源兼容状态", systemImage: "checkmark.shield")
                        .font(.subheadline.weight(.semibold))
                }
            }

            Divider()
            sourceHygieneReport

            Divider()
            credentialRiskReport

            Divider()
            resourceDiagnosticsReport

            if !appState.siteHealthSummaries.isEmpty {
                Divider()
                siteHealthDiagnostics
            }

            Divider()
            liveLineQualityReport
        }
    }

    private var sourceConfigurationStatus: String {
        if isLoadingVod || isLoadingLive { return "正在加载" }
        if appState.configError != nil { return "配置异常" }
        if appState.isConfigLoaded || !appState.channelGroups.isEmpty { return "配置已就绪" }
        return "等待配置"
    }

    private var sourceConfigurationStatusColor: Color {
        if appState.configError != nil { return .red }
        if appState.isConfigLoaded || !appState.channelGroups.isEmpty { return .green }
        return palette.muted
    }

    private func syncSavedVodConfigSelection(_ urls: [String]) {
        selectedSavedVodConfigURL = SavedVodConfigSelectionPolicy.resolvedSelection(
            savedURLs: urls,
            activeURL: UserPreferences.shared.currentVodConfigUrl
        )
    }

    private var externalSourceCompatibilityReport: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("外部源兼容状态").font(.subheadline).bold()
                Spacer()
                Text("\(appState.externalSourceReports.count) 个站点")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(ExternalSourceSupportStatus.allCases, id: \.self) { status in
                    let count = appState.externalSourceReportCount(for: status)
                    if count > 0 {
                        Label("\(compatibilityStatusTitle(status)) \(count)", systemImage: compatibilityStatusIcon(status))
                            .font(.caption)
                            .foregroundColor(compatibilityStatusColor(status))
                    }
                }
            }

            let visibleReports = appState.externalSourceReports
                .filter { $0.status != .cms || !$0.reason.isEmpty }
                .prefix(16)
            ForEach(Array(visibleReports)) { report in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: compatibilityStatusIcon(report.status))
                        .foregroundColor(compatibilityStatusColor(report.status))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.siteName.isEmpty ? report.siteKey : report.siteName)
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("\(compatibilityStatusTitle(report.status)) · \(report.reason)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        if !report.sourceURL.isEmpty {
                            Text("来源：\(report.sourceURL)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        if !report.credentialRequirements.isEmpty {
                            Text("凭据：\(report.credentialRequirements.map(\.provider).joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .lineLimit(1)
                        }
                        if !report.androidRuntimeDiagnostic.isEmpty {
                            Text(report.androidRuntimeDiagnostic)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private var configAggregationReport: some View {
        let snapshot = appState.configAggregationSnapshot
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("配置聚合报告").font(.subheadline).bold()
                Spacer()
                Text("\(snapshot.origins.count) 个条目来源")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                Label("外部源 \(snapshot.fetchedSources.count)", systemImage: "square.and.arrow.down")
                Label("URL 归一化 \(snapshot.normalizedURLCount)", systemImage: "link")
                Label("去重 \(snapshot.duplicateCount)", systemImage: "rectangle.stack.badge.minus")
                Label("凭据 \(snapshot.credentialRequirements.count)", systemImage: "key")
                Label("治理 \(snapshot.blockedByUserCount)", systemImage: "hand.raised")
                Label("风险 \(snapshot.credentialRiskCount)", systemImage: "exclamationmark.shield")
                Label("资源 \(snapshot.resourceDiagnostics.count)", systemImage: "shippingbox")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            ForEach(snapshot.fetchedSources.prefix(6)) { source in
                HStack(spacing: 8) {
                    Image(systemName: source.status == "success" ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundColor(source.status == "success" ? .green : .orange)
                    Text(source.field)
                        .font(.caption)
                        .fontWeight(.medium)
                    Text(source.finalURL.isEmpty ? source.resolvedURL : source.finalURL)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if source.status == "success" {
                        Text("\(source.itemCount)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var sourceHygieneReport: some View {
        DisclosureGroup(isExpanded: $sourceHygieneExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("\(appState.sourceHygieneRules.count) 条本地规则", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        appState.blockActiveSiteByFingerprint()
                    } label: {
                        Label("屏蔽当前站点", systemImage: "hand.raised")
                    }
                    .disabled(appState.activeSite == nil)
                    .buttonStyle(.bordered)

                    Button {
                        appState.clearSourceHygieneRules()
                    } label: {
                        Label("恢复全部", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(appState.sourceHygieneRules.isEmpty)
                    .buttonStyle(.bordered)

                    Button {
                        appState.exportSourceDiagnostics()
                    } label: {
                        Label("导出诊断", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }

                if let status = appState.sourceDiagnosticExportStatus {
                    Text(status)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                ForEach(appState.sourceHygieneRules.prefix(6)) { rule in
                    HStack(spacing: 8) {
                        Image(systemName: rule.isEnabled ? "checkmark.circle" : "pause.circle")
                            .foregroundColor(rule.isEnabled ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.isEmpty ? rule.pattern : rule.name)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("\(sourceHygieneKindTitle(rule.kind)) · \(rule.pattern)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                ForEach(appState.configAggregationSnapshot.hygieneDecisions.prefix(6)) { decision in
                    Label("\(decision.entityName.isEmpty ? decision.entityKey : decision.entityName)：\(decision.reason)", systemImage: "slash.circle")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("源治理", systemImage: "hand.raised")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }

    private var credentialRiskReport: some View {
        DisclosureGroup(isExpanded: $credentialRiskExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                let risks = appState.configAggregationSnapshot.credentialRiskAssessments
                HStack {
                    Label("已扫描 \(risks.count) 个站点", systemImage: "key.viewfinder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Label("需关注 \(appState.configAggregationSnapshot.credentialRiskCount)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                ForEach(risks.filter { $0.riskLevel != .safe }.prefix(8)) { risk in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: credentialRiskIcon(risk.riskLevel))
                            .foregroundColor(credentialRiskColor(risk.riskLevel))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(risk.siteName.isEmpty ? risk.siteKey : risk.siteName)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("\(credentialRiskTitle(risk.riskLevel)) · \(risk.reason)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                            if !risk.thirdPartyDomains.isEmpty {
                                Text("域名：\(risk.thirdPartyDomains.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("凭据风险", systemImage: "exclamationmark.shield")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }

    private var resourceDiagnosticsReport: some View {
        DisclosureGroup(isExpanded: $resourceDiagnosticsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                let diagnostics = appState.configAggregationSnapshot.resourceDiagnostics
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(ExternalResourceDiagnosticStatus.allCases, id: \.self) { status in
                        let count = diagnostics.filter { $0.status == status }.count
                        if count > 0 {
                            Label("\(resourceStatusTitle(status)) \(count)", systemImage: resourceStatusIcon(status))
                                .foregroundColor(resourceStatusColor(status))
                        }
                    }
                }
                .font(.caption)

                ForEach(diagnostics.prefix(8)) { diagnostic in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: resourceStatusIcon(diagnostic.status))
                            .foregroundColor(resourceStatusColor(diagnostic.status))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(diagnostic.ownerName.isEmpty ? diagnostic.ownerKey : diagnostic.ownerName) · \(diagnostic.resourceType.rawValue)")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(diagnostic.url)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Text(diagnostic.reason)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("资源诊断", systemImage: "shippingbox")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }

    private var liveLineQualityReport: some View {
        DisclosureGroup(isExpanded: $liveLineQualityExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("\(appState.liveLineHealthSummaries.count) 条线路记录", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        isProbingCurrentLiveGroup = true
                        Task {
                            await appState.probeCurrentLiveGroup()
                            isProbingCurrentLiveGroup = false
                        }
                    } label: {
                        Label("检测当前分组", systemImage: "waveform.path.ecg")
                    }
                    .disabled(isProbingCurrentLiveGroup || appState.channelGroups.isEmpty)
                    .buttonStyle(.bordered)

                    Button {
                        appState.clearLiveLineHealthRecords()
                    } label: {
                        Label("清理记录", systemImage: "trash")
                    }
                    .disabled(appState.liveLineHealthSummaries.isEmpty)
                    .buttonStyle(.bordered)
                }

                if isProbingCurrentLiveGroup {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                ForEach(appState.liveLineHealthSummaries.prefix(8)) { summary in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: summary.failureCount > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundColor(summary.failureCount > 0 ? .orange : .green)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.channelName)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("成功 \(summary.successCount) · 失败 \(summary.failureCount) · 平均 \(summary.averageTTFBMs)ms · HTTP \(summary.lastStatusCode)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(summary.redactedURL)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("直播线路质量", systemImage: "waveform.path.ecg")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }

    private var siteHealthDiagnostics: some View {
        let summaries = appState.siteHealthSummaries.values
            .sorted { lhs, rhs in
                if lhs.failureCount != rhs.failureCount {
                    return lhs.failureCount > rhs.failureCount
                }
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                return lhs.averageDurationMs > rhs.averageDurationMs
            }
            .prefix(6)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("站点健康诊断").font(.subheadline).bold()
                Spacer()
                Button {
                    appState.clearSiteHealthRecords()
                } label: {
                    Label("清理健康记录", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }

            ForEach(Array(summaries), id: \.siteKey) { summary in
                HStack(spacing: 10) {
                    Image(systemName: summary.failureCount > 0 ? "waveform.path.ecg" : "checkmark.circle")
                        .foregroundColor(summary.failureCount > 0 ? .orange : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.siteName.isEmpty ? summary.siteKey : summary.siteName)
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(siteHealthDetailText(summary))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(summary.displayPercent)%")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(siteHealthColor(summary))
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private func siteHealthDetailText(_ summary: SiteHealthSummary) -> String {
        var parts = [
            "失败 \(summary.failureCount)",
            "平均 \(summary.averageDurationMs)ms"
        ]
        if let category = summary.lastFailureCategory {
            parts.append("最后 \(category.rawValue)")
        }
        return parts.joined(separator: " · ")
    }

    private func siteHealthColor(_ summary: SiteHealthSummary) -> Color {
        if summary.score >= 0.8 { return .green }
        if summary.score >= 0.5 { return .orange }
        return .red
    }

    private func sourceHygieneKindTitle(_ kind: SourceHygieneRuleKind) -> String {
        switch kind {
        case .siteFingerprint: return "站点指纹"
        case .siteNameRegex: return "名称正则"
        case .parseURL: return "解析 URL"
        case .liveURL: return "直播 URL"
        }
    }

    private func credentialRiskTitle(_ level: CredentialRiskLevel) -> String {
        switch level {
        case .safe: return "安全"
        case .low: return "低风险"
        case .high: return "高风险"
        case .unaudited: return "待审计"
        }
    }

    private func credentialRiskIcon(_ level: CredentialRiskLevel) -> String {
        switch level {
        case .safe: return "checkmark.shield"
        case .low: return "exclamationmark.shield"
        case .high: return "xmark.shield"
        case .unaudited: return "questionmark.diamond"
        }
    }

    private func credentialRiskColor(_ level: CredentialRiskLevel) -> Color {
        switch level {
        case .safe: return .green
        case .low: return .orange
        case .high: return .red
        case .unaudited: return .secondary
        }
    }

    private func resourceStatusTitle(_ status: ExternalResourceDiagnosticStatus) -> String {
        switch status {
        case .recorded: return "可诊断"
        case .blocked: return "已拒绝"
        case .androidRuntimeOnly: return "Android"
        case .unsupportedType: return "未知"
        }
    }

    private func resourceStatusIcon(_ status: ExternalResourceDiagnosticStatus) -> String {
        switch status {
        case .recorded: return "checkmark.circle"
        case .blocked: return "nosign"
        case .androidRuntimeOnly: return "exclamationmark.triangle"
        case .unsupportedType: return "questionmark.circle"
        }
    }

    private func resourceStatusColor(_ status: ExternalResourceDiagnosticStatus) -> Color {
        switch status {
        case .recorded: return .green
        case .blocked: return .red
        case .androidRuntimeOnly: return .orange
        case .unsupportedType: return .secondary
        }
    }

    private func compatibilityStatusTitle(_ status: ExternalSourceSupportStatus) -> String {
        switch status {
        case .native: return "已接管"
        case .nativePartial: return "部分接管"
        case .js: return "JS"
        case .cms: return "CMS"
        case .pendingGuardCapture: return "待抓包"
        case .upstreamUnavailable: return "上游失效"
        case .invalidConfiguration: return "配置无效"
        case .unsupportedAndroidCsp: return "Android"
        case .unsupportedBinary: return "二进制"
        }
    }

    private func compatibilityStatusIcon(_ status: ExternalSourceSupportStatus) -> String {
        switch status {
        case .native: return "arrow.triangle.branch"
        case .nativePartial: return "circle.lefthalf.filled"
        case .js: return "curlybraces"
        case .cms: return "link"
        case .pendingGuardCapture: return "rectangle.and.text.magnifyingglass"
        case .upstreamUnavailable: return "bolt.slash"
        case .invalidConfiguration: return "exclamationmark.octagon"
        case .unsupportedAndroidCsp: return "exclamationmark.triangle"
        case .unsupportedBinary: return "xmark.octagon"
        }
    }

    private func compatibilityStatusColor(_ status: ExternalSourceSupportStatus) -> Color {
        switch status {
        case .native: return .blue
        case .nativePartial: return .orange
        case .js, .cms: return .blue
        case .pendingGuardCapture: return .orange
        case .upstreamUnavailable: return .red
        case .invalidConfiguration: return .red
        case .unsupportedAndroidCsp: return .yellow
        case .unsupportedBinary: return .orange
        }
    }

    private var liveSourceSettings: some View {
        SettingsControlRow(title: "直播源配置", caption: "支持 M3U 或 TXT 地址") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    TextField("粘贴 M3U / TXT 地址", text: $liveConfigUrl)
                        .textFieldStyle(.roundedBorder)

                    Button("加载直播") {
                        isLoadingLive = true
                        Task {
                            UserPreferences.shared.currentLiveConfigUrl = liveConfigUrl
                            if let live = appState.activeLive {
                                var updatedLive = live
                                updatedLive.url = liveConfigUrl
                                await appState.changeLive(updatedLive)
                            } else {
                                let live = Models.Live(name: "自定义直播", url: liveConfigUrl)
                                await appState.changeLive(live)
                            }
                            isLoadingLive = false
                        }
                    }
                    .disabled(liveConfigUrl.isEmpty || isLoadingLive)
                    .buttonStyle(.bordered)
                }

                if isLoadingLive {
                    Label("正在加载直播配置", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(palette.muted)
                        .font(.caption)
                } else if !appState.channelGroups.isEmpty {
                    Label("直播配置已解析成功", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(palette.color(for: .success))
                        .font(.caption)
                } else {
                    Text("尚未加载直播配置")
                        .foregroundStyle(palette.muted)
                        .font(.caption)
                }
            }
        }
    }

    private var cloudDriveAuthSettings: some View {
        GroupBox(label: SettingsPanelLabel(
            title: "网盘源授权",
            subtitle: "扫码为主要路径；手动凭据只作为高级兜底并保存在本机。",
            systemImage: "externaldrive.badge.person.crop"
        )) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("网盘服务", selection: $selectedCloudProvider) {
                    ForEach(CloudProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: selectedCloudProvider) { _, provider in
                    cloudCookieSaved = false
                    cloudCookieStatus = nil
                    isManualCloudAuthExpanded = !CloudAuthSettingsPolicy.supportsPrimaryQRCodeLogin(
                        provider.driveProvider
                    )
                }
                .disabled(isValidatingCloudCookie)

                HStack(spacing: 7) {
                    Circle()
                        .fill(
                            selectedCloudProviderHasCredential
                                ? palette.color(for: .success)
                                : palette.muted
                        )
                        .frame(width: 7, height: 7)
                    Text(selectedCloudProviderStatus)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                    Spacer(minLength: 0)
                    Text(selectedCloudProvider.credentialKind)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.muted)
                }

                Divider()

                HStack(spacing: 10) {
                    if CloudAuthSettingsPolicy.supportsPrimaryQRCodeLogin(selectedCloudProvider.driveProvider) {
                        Button {
                            appState.requestCloudAuthFromSettings(selectedCloudProvider.driveProvider)
                        } label: {
                            Label("扫码登录", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isValidatingCloudCookie || appState.cloudAuthRequest != nil)
                    } else {
                        Label("暂不支持扫码授权", systemImage: "key.horizontal")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }

                    Button {
                        clearSelectedCloudProvider()
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)

                    if cloudCookieSaved {
                        Label(
                            selectedCloudProviderHasCredential ? "已保存" : "已清空",
                            systemImage: "checkmark.circle.fill"
                        )
                            .foregroundColor(.green)
                            .font(.caption)
                    }

                    if isValidatingCloudCookie {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }

                DisclosureGroup(isExpanded: $isManualCloudAuthExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        selectedCloudProviderFields

                        Button {
                            saveCloudCookiesFromSettings()
                        } label: {
                            Label(
                                isValidatingCloudCookie ? "保存中..." : "验证并保存手动凭据",
                                systemImage: "checkmark.circle"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(isValidatingCloudCookie || !selectedCloudProviderHasCredential)
                    }
                    .padding(.top, 8)
                } label: {
                    Label(
                        CloudAuthSettingsPolicy.supportsPrimaryQRCodeLogin(selectedCloudProvider.driveProvider)
                            ? "手动登录（备选）"
                            : "手动授权",
                        systemImage: "key.horizontal"
                    )
                    .font(.system(size: 12, weight: .medium))
                }

                if let cloudCookieStatus {
                    Text(cloudCookieStatus)
                        .font(.caption)
                        .foregroundColor(cloudCookieSaved ? .green : .red)
                }

                Divider()

                SettingsControlRow(
                    title: "\(selectedCloudProvider.rawValue)播放后自动清理",
                    caption: "删除\(selectedCloudProvider.rawValue)播放链路创建的临时转存文件；未创建转存时不会删除任何内容"
                ) {
                    Toggle(
                        "\(selectedCloudProvider.rawValue)播放后自动清理",
                        isOn: selectedCloudAutoDeleteBinding
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                Text(selectedCloudProvider.authorizationGuidance)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
        }
    }

    private var selectedCloudAutoDeleteBinding: Binding<Bool> {
        let provider = selectedCloudProvider
        return Binding(
            get: {
                cloudAutoDeleteSavedFiles[provider] ?? false
            },
            set: { newValue in
                cloudAutoDeleteSavedFiles[provider] = newValue
                UserPreferences.shared.setCloudDriveAutoDeleteSavedFiles(
                    newValue,
                    providerID: provider.driveProvider.rawValue
                )
            }
        )
    }

    @ViewBuilder
    private var selectedCloudProviderFields: some View {
        switch selectedCloudProvider {
        case .quark:
            cloudSecureField("夸克 Cookie", placeholder: "粘贴 pan.quark.cn Cookie", text: $quarkCookie)
        case .uc:
            cloudSecureField("UC Cookie", placeholder: "粘贴 drive.uc.cn Cookie", text: $ucCookie)
        case .ali:
            cloudSecureField("Refresh Token", placeholder: "粘贴阿里云盘 refresh_token", text: $aliRefreshToken)
            cloudSecureField("Access Token", placeholder: "可选", text: $aliAccessToken)
            cloudSecureField("Open Token", placeholder: "可选", text: $aliOpenToken)
            cloudTextField("Default Drive ID", placeholder: "转存到个人盘时使用", text: $aliDefaultDriveID)
        case .p115:
            cloudSecureField("115 Cookie", placeholder: "粘贴 115.com Cookie", text: $p115Cookie)
            cloudSecureField("Open API Token", placeholder: "可选", text: $p115AccessToken)
        case .pikpak:
            cloudSecureField("Access Token", placeholder: "粘贴 PikPak access_token", text: $pikpakAccessToken)
            cloudSecureField("Refresh Token", placeholder: "可选", text: $pikpakRefreshToken)
            cloudTextField("Device ID", placeholder: "可选", text: $pikpakDeviceID)
        case .baidu:
            cloudSecureField("百度 Cookie", placeholder: "扫码登录，或粘贴 BDUSS/STOKEN", text: $baiduCookie)
        }
    }

    private func cloudSecureField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        SettingsControlRow(title: title, caption: "输入后仅保存在本机") {
            SecureField(placeholder, text: trackedCloudCredential(text))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func cloudTextField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        SettingsControlRow(title: title, caption: "非敏感标识") {
            TextField(placeholder, text: trackedCloudCredential(text))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func trackedCloudCredential(_ value: Binding<String>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue },
            set: { newValue in
                value.wrappedValue = newValue
                markCloudCredentialsDirty()
            }
        )
    }

    private var selectedCloudProviderHasCredential: Bool {
        let values: [String]
        switch selectedCloudProvider {
        case .quark: values = [quarkCookie]
        case .uc: values = [ucCookie]
        case .ali: values = [aliRefreshToken, aliAccessToken, aliOpenToken]
        case .p115: values = [p115Cookie, p115AccessToken]
        case .pikpak: values = [pikpakAccessToken, pikpakRefreshToken]
        case .baidu: values = [baiduCookie]
        }
        return values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var selectedCloudProviderStatus: String {
        if let cloudCookieStatus, !cloudCookieStatus.isEmpty {
            return cloudCookieStatus
        }
        return selectedCloudProviderHasCredential
            ? "\(selectedCloudProvider.rawValue)凭据已填写"
            : "\(selectedCloudProvider.rawValue)未连接"
    }

    private func markCloudCredentialsDirty() {
        cloudCookieSaved = false
        cloudCookieStatus = nil
    }

    private var playbackSettings: some View {
        VStack(alignment: .leading, spacing: AppSurfaceVisualPolicy.pageSectionGap) {
            GroupBox(label: SettingsPanelLabel(
                title: "播放行为",
                subtitle: "为新播放会话选择默认解码策略。",
                systemImage: "play.circle"
            )) {
                VStack(spacing: 0) {
                    SettingsControlRow(title: "解码方式", caption: "自动模式沿用 mpv 默认策略") {
                        Picker("解码方式", selection: $decodeMode) {
                            Text("自动").tag(0)
                            Text("硬件加速").tag(1)
                            Text("软解优先").tag(2)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 330)
                        .onChange(of: decodeMode) { _, newValue in
                            UserPreferences.shared.defaultDecodeMode = newValue
                        }
                    }

                    Divider()

                    SettingsControlRow(
                        title: "播放器窗口",
                        caption: windowPreferenceStatus ?? "分别记住点播与直播普通窗口的位置和大小"
                    ) {
                        Button {
                            PlayerWindowPreferenceStore.main.reset()
                            PlayerWindowPreferenceStore.live.reset()
                            windowPreferenceStatus = "已重置，下次打开窗口时生效"
                        } label: {
                            Label("重置窗口位置", systemImage: "rectangle.badge.xmark")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            GroupBox(label: SettingsPanelLabel(
                title: "字幕",
                subtitle: "播放器即时刷新字幕样式，不需要重启视频。",
                systemImage: "captions.bubble"
            )) {
                VStack(spacing: 0) {
                    HStack {
                        Spacer(minLength: 0)
                        Button("恢复默认") {
                            UserPreferences.shared.resetSubtitlePreferences()
                            subtitleFontSize = UserPreferences.shared.subtitleFontSize
                            subtitlePosition = UserPreferences.shared.subtitlePosition
                            subtitleOverrideSourceStyle = UserPreferences.shared.subtitleOverrideSourceStyle
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.bottom, 6)

                    SettingsControlRow(
                        title: "忽略片源字幕样式",
                        caption: "避免异常字号和位置覆盖本地偏好"
                    ) {
                        Toggle("忽略片源字幕样式", isOn: $subtitleOverrideSourceStyle)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: subtitleOverrideSourceStyle) { _, newValue in
                                UserPreferences.shared.subtitleOverrideSourceStyle = newValue
                            }
                    }

                    Divider()

                    SettingsControlRow(title: "字幕大小", caption: "范围 16 至 72") {
                        SettingsSlider(value: Binding(
                            get: { Double(subtitleFontSize) },
                            set: { newValue in
                                subtitleFontSize = Int(newValue.rounded())
                                UserPreferences.shared.subtitleFontSize = subtitleFontSize
                            }
                        ), range: 16...72, step: 1, valueText: "\(subtitleFontSize)")
                    }

                    Divider()

                    SettingsControlRow(title: "字幕位置", caption: "100 最靠近画面底部") {
                        SettingsSlider(value: Binding(
                            get: { Double(subtitlePosition) },
                            set: { newValue in
                                subtitlePosition = Int(newValue.rounded())
                                UserPreferences.shared.subtitlePosition = subtitlePosition
                            }
                        ), range: 80...100, step: 1, valueText: "\(subtitlePosition)")
                    }
                }
            }

            GroupBox(label: SettingsPanelLabel(
                title: "弹幕手动入口",
                subtitle: "只在播放器中手动搜索并命中缓存后附加。",
                systemImage: "text.bubble"
            )) {
                VStack(spacing: 0) {
                    SettingsControlRow(title: "启用弹幕入口", caption: "不会自动请求外部弹幕源") {
                        Toggle("启用弹幕手动入口", isOn: Binding(
                            get: { danmakuEnabled },
                            set: { newValue in
                                danmakuEnabled = newValue
                                UserPreferences.shared.danmakuEnabled = newValue
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsControlRow(title: "透明度", caption: "控制弹幕覆盖强度") {
                        SettingsSlider(value: Binding(
                            get: { danmakuOpacity },
                            set: { newValue in
                                danmakuOpacity = min(1, max(0, newValue))
                                UserPreferences.shared.danmakuOpacity = danmakuOpacity
                            }
                        ), range: 0.2...1.0, step: 0.05, valueText: String(format: "%.0f%%", danmakuOpacity * 100))
                    }
                    .disabled(!danmakuEnabled)
                    .opacity(danmakuEnabled ? 1 : 0.48)

                    Divider()

                    SettingsControlRow(title: "字号", caption: "范围 18 至 72") {
                        SettingsSlider(value: Binding(
                            get: { Double(danmakuFontSize) },
                            set: { newValue in
                                danmakuFontSize = Int(newValue.rounded())
                                UserPreferences.shared.danmakuFontSize = danmakuFontSize
                            }
                        ), range: 18...72, step: 1, valueText: "\(danmakuFontSize)")
                    }
                    .disabled(!danmakuEnabled)
                    .opacity(danmakuEnabled ? 1 : 0.48)

                    Divider()

                    SettingsControlRow(title: "时间偏移", caption: "负值提前，正值延后") {
                        SettingsSlider(value: Binding(
                            get: { Double(danmakuOffsetMs) / 1000.0 },
                            set: { newValue in
                                danmakuOffsetMs = Int((newValue * 1000).rounded())
                                UserPreferences.shared.danmakuOffsetMs = danmakuOffsetMs
                            }
                        ), range: -30...30, step: 0.5, valueText: String(format: "%.1fs", Double(danmakuOffsetMs) / 1000.0))
                    }
                    .disabled(!danmakuEnabled)
                    .opacity(danmakuEnabled ? 1 : 0.48)
                }
            }
        }
    }

    private var networkSettings: some View {
        VStack(alignment: .leading, spacing: AppSurfaceVisualPolicy.pageSectionGap) {
            GroupBox(label: SettingsPanelLabel(
                title: "网络与代理",
                subtitle: "自动探测适合多数环境，自定义模式可指定本机端口。",
                systemImage: "network"
            )) {
                VStack(spacing: 0) {
                    SettingsControlRow(title: "代理模式", caption: "变更后应用到后续网络请求") {
                        Picker("代理模式", selection: $proxyMode) {
                            Text("自动探测").tag(0)
                            Text("直连").tag(1)
                            Text("自定义").tag(2)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 330)
                        .onChange(of: proxyMode) { _, newValue in
                            UserPreferences.shared.proxyMode = newValue
                            applyProxyChange()
                        }
                    }

                    Divider()

                    SettingsControlRow(title: "自定义代理", caption: "仅在自定义模式下启用") {
                        HStack(spacing: 8) {
                            TextField("127.0.0.1", text: $customProxyServer)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                                .onChange(of: customProxyServer) { _, newValue in
                                    UserPreferences.shared.customProxyServer = newValue
                                    applyProxyChange()
                                }

                            TextField("7897", value: $customProxyPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 84)
                                .onChange(of: customProxyPort) { _, newValue in
                                    UserPreferences.shared.customProxyPort = newValue
                                    applyProxyChange()
                                }
                        }
                        .disabled(proxyMode != 2)
                    }

                    Divider()

                    SettingsControlRow(title: "分片 Range Relay", caption: "实验性分片中继，默认关闭") {
                        Toggle("分片 Range Relay", isOn: Binding(
                            get: { chunkedRangeRelayEnabled },
                            set: { newValue in
                                chunkedRangeRelayEnabled = newValue
                                UserPreferences.shared.chunkedRangeRelayEnabled = newValue
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsControlRow(title: "连接诊断", caption: "刷新代理探测与网络会话") {
                        Button {
                            applyProxyChange()
                        } label: {
                            Label("重新探测", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            GroupBox(label: SettingsPanelLabel(
                title: "模式说明",
                subtitle: "选择与当前网络环境最匹配的请求路径。",
                systemImage: "info.circle"
            )) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        Text("模式")
                        Text("适用场景")
                        Text("本地字段")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.muted)

                    Divider().gridCellColumns(3)
                    proxyModeDescriptionRow("自动探测", scenario: "系统代理或常见本机客户端", fields: "自动")
                    proxyModeDescriptionRow("直连", scenario: "明确不经过任何代理", fields: "忽略")
                    proxyModeDescriptionRow("自定义", scenario: "指定服务器与端口", fields: "必填")
                }
            }
        }
    }

    private func proxyModeDescriptionRow(_ mode: String, scenario: String, fields: String) -> some View {
        GridRow {
            Text(mode).fontWeight(.medium)
            Text(scenario).foregroundStyle(palette.muted)
            Text(fields)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.muted)
        }
        .font(.system(size: 12))
    }

    private var cacheAndSystemSettings: some View {
        VStack(alignment: .leading, spacing: AppSurfaceVisualPolicy.pageSectionGap) {
            GroupBox(label: SettingsPanelLabel(
                title: "缓存管理",
                subtitle: "清理爬虫脚本、WKWebView 网页数据与 Cookie。",
                systemImage: "trash"
            )) {
                SettingsControlRow(title: "临时嗅探与 JS 缓存", caption: "应用启动后异步计算") {
                    HStack(spacing: 12) {
                        Text(displayCacheSize)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.lavender)

                        Button(role: .destructive) {
                            isShowingCacheConfirmation = true
                        } label: {
                            Label("清理所有缓存", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            GroupBox(label: SettingsPanelLabel(
                title: "WebHome 实验入口",
                subtitle: "启用后在主侧栏加入 WebHome。",
                systemImage: "house"
            )) {
                VStack(spacing: 0) {
                    SettingsControlRow(title: "启用 WebHome", caption: "默认关闭") {
                        Toggle("启用 WebHome 实验入口", isOn: Binding(
                            get: { webHomeEnabled },
                            set: { newValue in
                                webHomeEnabled = newValue
                                UserPreferences.shared.webHomeEnabled = newValue
                                if !newValue, appState.selectedTab == .webHome {
                                    appState.selectedTab = .vodHome
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsControlRow(title: "WebHome URL", caption: webHomeURLStatusText) {
                        TextField("留空使用内置本地 demo", text: Binding(
                            get: { webHomeURL },
                            set: { newValue in
                                webHomeURL = newValue
                                UserPreferences.shared.webHomeURL = newValue
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!webHomeEnabled)
                    }
                }
            }

            GroupBox(label: SettingsPanelLabel(
                title: "备份与迁移",
                subtitle: "Cookie 与 Token 不会写入备份文件。",
                systemImage: "arrow.up.arrow.down.square"
            )) {
                VStack(spacing: 0) {
                    SettingsControlRow(
                        title: "应用数据",
                        caption: "配置源、历史、收藏和非敏感偏好"
                    ) {
                        HStack(spacing: 8) {
                            Button { exportBackup() } label: {
                                Label("导出备份", systemImage: "square.and.arrow.up")
                            }
                            Button { importBackup() } label: {
                                Label("导入备份", systemImage: "square.and.arrow.down")
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    if let backupStatus {
                        Text(backupStatus)
                            .font(.caption)
                            .foregroundColor(backupStatusIsError ? .red : .green)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.bottom, 8)
                    }

                    Divider()

                    SettingsControlRow(
                        title: "播放进度",
                        caption: "不包含播放 URL 或敏感凭据"
                    ) {
                        HStack(spacing: 8) {
                            Button { exportPlaybackProgress() } label: {
                                Label("导出进度", systemImage: "clock.arrow.circlepath")
                            }
                            Button { importPlaybackProgress() } label: {
                                Label("导入进度", systemImage: "tray.and.arrow.down")
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    if let progressSyncStatus {
                        Text(progressSyncStatus)
                            .font(.caption)
                            .foregroundColor(progressSyncStatusIsError ? .red : .green)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.bottom, 8)
                    }
                }
            }

            GroupBox(label: SettingsPanelLabel(
                title: "关于 NetVplayer",
                subtitle: "macOS 媒体中心 · \(AppVersionDisplay.label())",
                systemImage: "gearshape"
            )) {
                HStack {
                    Label("原生 SwiftUI / mpv", systemImage: "macwindow")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                    Spacer(minLength: 0)
                    Text("NetVplayer")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
        }
    }

    private func loadSettingsState() {
        vodConfigUrl = UserPreferences.shared.currentVodConfigUrl
        liveConfigUrl = UserPreferences.shared.currentLiveConfigUrl
        loadCloudCredentialState()
        cloudAutoDeleteSavedFiles = Dictionary(uniqueKeysWithValues: CloudProvider.allCases.map { provider in
            (
                provider,
                UserPreferences.shared.cloudDriveAutoDeleteSavedFiles(providerID: provider.driveProvider.rawValue)
            )
        })
        cloudCookieSaved = false
        cloudCookieStatus = nil

        decodeMode = UserPreferences.shared.defaultDecodeMode
        subtitleFontSize = UserPreferences.shared.subtitleFontSize
        subtitlePosition = UserPreferences.shared.subtitlePosition
        subtitleOverrideSourceStyle = UserPreferences.shared.subtitleOverrideSourceStyle
        danmakuEnabled = UserPreferences.shared.danmakuEnabled
        danmakuOpacity = UserPreferences.shared.danmakuOpacity
        danmakuFontSize = UserPreferences.shared.danmakuFontSize
        danmakuOffsetMs = UserPreferences.shared.danmakuOffsetMs
        siteHealthSortingEnabled = UserPreferences.shared.siteHealthSortingEnabled

        proxyMode = UserPreferences.shared.proxyMode
        customProxyServer = UserPreferences.shared.customProxyServer
        customProxyPort = UserPreferences.shared.customProxyPort
        chunkedRangeRelayEnabled = UserPreferences.shared.chunkedRangeRelayEnabled
        webHomeEnabled = UserPreferences.shared.webHomeEnabled
        webHomeURL = UserPreferences.shared.webHomeURL

        appState.reloadSavedConfigs()
        refreshCacheSize()
    }

    private func loadCloudCredentialState() {
        quarkCookie = UserPreferences.shared.quarkCookie
        ucCookie = UserPreferences.shared.ucCookie
        baiduCookie = UserPreferences.shared.baiduCookie
        aliRefreshToken = UserPreferences.shared.aliRefreshToken
        aliAccessToken = UserPreferences.shared.aliAccessToken
        aliOpenToken = UserPreferences.shared.aliOpenToken
        aliDefaultDriveID = UserPreferences.shared.aliDefaultDriveID
        p115Cookie = UserPreferences.shared.p115Cookie
        p115AccessToken = UserPreferences.shared.p115AccessToken
        pikpakAccessToken = UserPreferences.shared.pikpakAccessToken
        pikpakRefreshToken = UserPreferences.shared.pikpakRefreshToken
        pikpakDeviceID = UserPreferences.shared.pikpakDeviceID
    }

    private var webHomeURLStatusText: String {
        let trimmed = webHomeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "默认关闭；开启后空 URL 加载内置本地 demo。远程页面只能通过白名单 bridge 和 /webResource 访问资源，不暴露网盘凭据。"
        }
        do {
            _ = try WebHomeDestination.resolve(trimmed)
            return "URL 校验通过；加载时仍会走白名单 bridge 和响应脱敏。"
        } catch {
            return "URL 校验失败：\(error.localizedDescription)"
        }
    }

    private func refreshCacheSize() {
        let size = CacheManager.shared.cacheSize()
        if size == 0 {
            displayCacheSize = "0 KB"
        } else if size < 1024 * 1024 {
            displayCacheSize = String(format: "%.1f KB", Double(size) / 1024.0)
        } else {
            displayCacheSize = String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
        }
    }

    private func applyProxyChange() {
        ProxyDetector.shared.clearCache()
        HTTPClient.shared.clearProxySessions()

        Task {
            await ProxyDetector.shared.detectActiveProxy()
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "NetVplayer-Backup-\(backupDateString()).json"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.exportBackup(to: url)
            backupStatusIsError = false
            backupStatus = "备份已导出"
        } catch {
            backupStatusIsError = true
            backupStatus = error.localizedDescription
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preview = try appState.inspectBackup(from: url)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "确认导入备份？"
            let legacyNote = preview.isLegacy ? "\n这是旧版备份，历史播放引用会先迁移和清洗。" : ""
            alert.informativeText = "将覆盖当前的 \(preview.configCount) 个配置、\(preview.historyCount) 条历史、\(preview.keepCount) 个收藏和 \(preview.trackCount) 条轨道偏好。\(legacyNote)"
            alert.addButton(withTitle: "导入")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let backup = try appState.importBackup(from: url)
            backupStatusIsError = false
            backupStatus = "已导入 \(backup.configs.count) 个配置、\(backup.history.count) 条历史、\(backup.keeps.count) 个收藏"
            vodConfigUrl = UserPreferences.shared.currentVodConfigUrl
            liveConfigUrl = UserPreferences.shared.currentLiveConfigUrl
            decodeMode = UserPreferences.shared.defaultDecodeMode
            subtitleFontSize = UserPreferences.shared.subtitleFontSize
            subtitlePosition = UserPreferences.shared.subtitlePosition
            subtitleOverrideSourceStyle = UserPreferences.shared.subtitleOverrideSourceStyle
        } catch {
            backupStatusIsError = true
            backupStatus = error.localizedDescription
        }
    }

    private func exportPlaybackProgress() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "NetVplayer-Progress-\(backupDateString()).json"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.exportPlaybackProgress(to: url)
            progressSyncStatusIsError = false
            progressSyncStatus = "播放进度已导出"
        } catch {
            progressSyncStatusIsError = true
            progressSyncStatus = error.localizedDescription
        }
    }

    private func importPlaybackProgress() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let progress = try appState.importPlaybackProgress(from: url)
            progressSyncStatusIsError = false
            progressSyncStatus = "已导入 \(progress.records.count) 条播放进度"
        } catch {
            progressSyncStatusIsError = true
            progressSyncStatus = error.localizedDescription
        }
    }

    private func backupDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func saveCloudCookiesFromSettings() {
        let provider = selectedCloudProvider
        isValidatingCloudCookie = true
        cloudCookieSaved = false
        cloudCookieStatus = nil

        Task {
            do {
                switch provider {
                case .quark:
                    try await appState.validateAndSaveCloudCookie(
                        provider: .quark,
                        cookie: quarkCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                case .uc:
                    try await appState.validateAndSaveCloudCookie(
                        provider: .uc,
                        cookie: ucCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                case .ali:
                    UserPreferences.shared.aliRefreshToken = aliRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserPreferences.shared.aliAccessToken = aliAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserPreferences.shared.aliOpenToken = aliOpenToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserPreferences.shared.aliDefaultDriveID = aliDefaultDriveID.trimmingCharacters(in: .whitespacesAndNewlines)
                case .p115:
                    UserPreferences.shared.p115Cookie = p115Cookie.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserPreferences.shared.p115AccessToken = p115AccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
                case .pikpak:
                    UserPreferences.shared.pikpakAccessToken = pikpakAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserPreferences.shared.pikpakRefreshToken = pikpakRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserPreferences.shared.pikpakDeviceID = pikpakDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
                case .baidu:
                    try await appState.validateAndSaveCloudCookie(
                        provider: .baidu,
                        cookie: baiduCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }

                await MainActor.run {
                    cloudCookieSaved = true
                    cloudCookieStatus = provider == .quark || provider == .uc || provider == .baidu
                        ? "\(provider.rawValue)凭据已验证并保存"
                        : "\(provider.rawValue)凭据已保存，将在播放时校验"
                    quarkCookie = UserPreferences.shared.quarkCookie
                    ucCookie = UserPreferences.shared.ucCookie
                    baiduCookie = UserPreferences.shared.baiduCookie
                    aliRefreshToken = UserPreferences.shared.aliRefreshToken
                    aliAccessToken = UserPreferences.shared.aliAccessToken
                    aliOpenToken = UserPreferences.shared.aliOpenToken
                    aliDefaultDriveID = UserPreferences.shared.aliDefaultDriveID
                    p115Cookie = UserPreferences.shared.p115Cookie
                    p115AccessToken = UserPreferences.shared.p115AccessToken
                    pikpakAccessToken = UserPreferences.shared.pikpakAccessToken
                    pikpakRefreshToken = UserPreferences.shared.pikpakRefreshToken
                    pikpakDeviceID = UserPreferences.shared.pikpakDeviceID
                    isValidatingCloudCookie = false
                }
            } catch {
                await MainActor.run {
                    cloudCookieSaved = false
                    cloudCookieStatus = error.localizedDescription
                    isValidatingCloudCookie = false
                }
            }
        }
    }

    private func clearSelectedCloudProvider() {
        switch selectedCloudProvider {
        case .quark:
            quarkCookie = ""
            UserPreferences.shared.quarkCookie = ""
            UserPreferences.shared.quarkTVDeviceID = ""
            UserPreferences.shared.quarkTVQueryToken = ""
            UserPreferences.shared.quarkTVRefreshToken = ""
            UserPreferences.shared.quarkTVAccessToken = ""
        case .uc:
            ucCookie = ""
            UserPreferences.shared.ucCookie = ""
            UserPreferences.shared.ucTVDeviceID = ""
            UserPreferences.shared.ucTVQueryToken = ""
            UserPreferences.shared.ucTVRefreshToken = ""
            UserPreferences.shared.ucTVAccessToken = ""
            UserPreferences.shared.ucFongMiAccountToken = ""
            UserPreferences.shared.ucFongMiPlaybackToken = ""
            UserPreferences.shared.ucFongMiAccountExpiresAt = ""
            UserPreferences.shared.ucFongMiPlaybackExpiresAt = ""
            UserPreferences.shared.ucFongMiFixtureID = ""
            UserPreferences.shared.ucFongMiEvidenceStatus = ""
        case .ali:
            aliRefreshToken = ""
            aliAccessToken = ""
            aliOpenToken = ""
            aliDefaultDriveID = ""
            UserPreferences.shared.aliRefreshToken = ""
            UserPreferences.shared.aliAccessToken = ""
            UserPreferences.shared.aliOpenToken = ""
            UserPreferences.shared.aliDefaultDriveID = ""
            UserPreferences.shared.aliAuthDomain = ""
            UserPreferences.shared.aliUserID = ""
        case .p115:
            p115Cookie = ""
            p115AccessToken = ""
            UserPreferences.shared.p115Cookie = ""
            UserPreferences.shared.p115AccessToken = ""
        case .pikpak:
            pikpakAccessToken = ""
            pikpakRefreshToken = ""
            pikpakDeviceID = ""
            UserPreferences.shared.pikpakAccessToken = ""
            UserPreferences.shared.pikpakRefreshToken = ""
            UserPreferences.shared.pikpakDeviceID = ""
        case .baidu:
            baiduCookie = ""
            UserPreferences.shared.baiduCookie = ""
        }

        cloudCookieSaved = true
        cloudCookieStatus = "已清空\(selectedCloudProvider.rawValue)授权"
    }
}

struct SettingsPanelLabel: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    let subtitle: String
    let systemImage: String
    let statusText: String?
    let statusColor: Color?

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        statusText: String? = nil,
        statusColor: Color? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.statusText = statusText
        self.statusColor = statusColor
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.muted)
                .frame(width: 18, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if let statusText {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor ?? palette.muted)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.muted)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsStatusTag: View {
    @Environment(\.appThemePalette) private var palette
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(palette.muted)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(palette.foreground)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background {
            Capsule()
                .fill(palette.background.opacity(0.32))
                .overlay {
                    Capsule()
                        .stroke(palette.foreground.opacity(0.14), lineWidth: 1)
                }
        }
    }
}

struct SettingsControlRow<Control: View>: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    let caption: String
    let control: Control

    init(
        title: String,
        caption: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 22) {
                label
                    .frame(width: 240, alignment: .leading)
                control
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 9) {
                label
                control
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 10)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.foreground)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $value, in: range, step: step)
                .frame(minWidth: 180, maxWidth: 300)
            Text(valueText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 58, alignment: .trailing)
        }
    }
}
