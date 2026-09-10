// NetVplayerApp/AppState.swift
// 全局应用状态

import SwiftUI
import Models
import ApplicationCore
import DriveEngine
import ConfigEngine
import NodeBundleRuntime
import PlayerEngine
import LiveEngine
import SearchEngine
import Storage
import Networking
import SpiderEngine
import ParseEngine
import ProxyServer
import DanmakuEngine
import WebHomeEngine
import ProviderRuntime
import ProviderSDK

private struct SourceDiagnosticsExport: Encodable {
    var schemaVersion: Int = 1
    var exportedAt: Date = Date()
    var configURL: String
    var snapshot: ConfigAggregationSnapshot
    var reports: [ExternalSourceReport]
    var liveLineHealth: [LiveLineHealthSummary]
    var rules: [SourceHygieneRule]
}

/// 侧边栏导航标签
enum SidebarTab: String, CaseIterable, Identifiable {
    case vodHome = "点播"
    case search = "搜索"
    case liveStream = "直播"
    case history = "历史"
    case favorites = "收藏"
    case webHome = "WebHome"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .vodHome: return "play.tv"
        case .search: return "magnifyingglass"
        case .liveStream: return "antenna.radiowaves.left.and.right"
        case .history: return "clock"
        case .favorites: return "star"
        case .webHome: return "globe"
        case .settings: return "gearshape"
        }
    }

    var title: String { rawValue }

    static var visibleTabs: [SidebarTab] {
        allCases.filter { tab in
            tab != .webHome || UserPreferences.shared.webHomeEnabled
        }
    }
}

struct CloudAuthRequest: Identifiable, Equatable {
    let provider: DriveProvider
    let pendingEpisodeURL: String?

    init(provider: DriveProvider, pendingEpisodeURL: String? = nil) {
        self.provider = provider
        self.pendingEpisodeURL = pendingEpisodeURL
    }

    var id: String {
        [provider.rawValue, pendingEpisodeURL ?? "manual"].joined(separator: ":")
    }
}

enum SettingsNavigationDestination: Equatable {
    case dataSource
    case providers
    case playback
    case network
    case system
    case appearance
    case feedback
}

struct CloudCredentialClearRequest: Identifiable, Equatable {
    let provider: DriveProvider

    var id: String { provider.rawValue }
}

struct CloudAuthCompletion: Equatable {
    let message: String?
    let shouldDismiss: Bool

    static func dismiss(_ message: String? = nil) -> CloudAuthCompletion {
        CloudAuthCompletion(message: message, shouldDismiss: true)
    }

    static func stay(_ message: String) -> CloudAuthCompletion {
        CloudAuthCompletion(message: message, shouldDismiss: false)
    }
}

private struct PendingPlaybackStart: Equatable {
    let episodeURL: String
    let resumePosition: Int64?
    let openingSkipSeconds: Int

    var logID: String {
        String(episodeURL.hashValue)
    }
}

private enum LivePlaybackAttemptResult: Equatable {
    case started
    case failed
    case expiredAddress
}

/// 全局应用状态
@MainActor
final class AppState: ObservableObject {
    static let driveShareImportSiteKey = "__drive_share_import__"
    private static let biliPlaybackCacheMetadataKey = "bili.cache.videoPath"
    private static let biliAudioCacheMetadataKey = "bili.cache.audioPath"
    private static let biliPlaybackCacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NetVplayer/BiliPlayback", isDirectory: true)
    @Published var selectedTab: SidebarTab = .vodHome
    @Published private(set) var appearanceThemeID = AppAppearanceDefaults.releaseDefaultThemeID
    var appearancePalette: AppThemePalette { AppThemeCatalog.palette(for: appearanceThemeID) }
    @Published var isConfigLoaded: Bool = false
    @Published var configError: String?
    @Published var currentSiteName: String = "未加载"
    @Published var vodError: String? = nil
    var savedConfigs: [Config] {
        get { applicationLibraryState.configs }
        set { applicationLibraryState.configs = newValue }
    }
    @Published var availableDepots: [Depot] = []
    @Published var configNotice: String?
    @Published var selectedSearchSiteKeys: [String] = []
    @Published var externalSourceReports: [ExternalSourceReport] = []
    @Published var configAggregationSnapshot = ConfigAggregationSnapshot()
    @Published var siteHealthSummaries: [String: SiteHealthSummary] = [:]
    @Published var liveLineHealthSummaries: [LiveLineHealthSummary] = []
    @Published var sourceHygieneRules: [SourceHygieneRule] = []
    @Published var sourceDiagnosticExportStatus: String?
    @Published private(set) var currentVodInputFingerprint: String?
    @Published private(set) var currentVodInputKind: VodInputKind?
    @Published private(set) var currentVodProviderID: String?
    @Published private(set) var lastFeedbackFailureStage: String?
    @Published private(set) var lastFeedbackFailureCategory: AppFailureCategory?
    @Published var nativeReplacementSiteKeys: Set<String> = []
    @Published private(set) var providerRuntimeCatalog: [ProviderRelease] = []
    @Published private(set) var providerRuntimeInstalled: [SignedProviderManifest] = []
    @Published private(set) var providerRuntimeStatus: String = "未配置"
    @Published private(set) var providerRuntimeBusy = false
    @Published private(set) var providerRuntimeProgress: ProviderInstallProgress?
    @Published private(set) var providerRuntimeFailedRelease: ProviderVersionReference?
    @Published var webHomeChromeTitle: String = "WebHome"
    @Published var lastWebHomeBridgeMethod: String?
    @Published var webHomeSessionDiagnostic = WebHomeSessionDiagnostic()
    @Published var lastDanmakuRenderStatus: String?
    @Published var lastDanmakuParseDiagnostic: DanmakuPayloadParseDiagnostic?
    @Published var lastDriveFixtureDiagnostic: String?
    private let driveShareExpander: DriveShareExpander
    private let storageManager: StorageManager
    private let applicationLibraryPersistence: any ApplicationLibraryPersistence
    private let configResolver: ConfigResolver
    private let userPreferences: UserPreferences
    private let providerRuntimeBootstrap: ProviderRuntimeBootstrap?
    private var providerRuntimeStartupTask: Task<Void, Never>?
    private var preferredVodHomeSiteKey: String?

    // 子状态
    @Published var playerState = PlayerState()
    @Published var livePlayerState = PlayerState()
    @Published var currentDanmakuCues: [DanmakuCue] = []

    // 点播业务数据
    @Published var sites: [Site] = []
    @Published var activeSite: Site?
    @Published private(set) var contentCatalogState = ContentCatalogState()
    var vods: [Vod] {
        get { contentCatalogState.vods }
        set { contentCatalogState.vods = newValue }
    }
    var categories: [VodClass] {
        get { contentCatalogState.categories }
        set { contentCatalogState.categories = newValue }
    }
    var selectedCategory: VodClass? {
        get { contentCatalogState.selectedCategory }
        set { contentCatalogState.selectedCategory = newValue }
    }
    var categoryFilters: [Filter] {
        get { contentCatalogState.categoryFilters }
        set { contentCatalogState.categoryFilters = newValue }
    }
    var selectedCategoryFilterValues: [String: String] {
        get { contentCatalogState.selectedFilterValues }
        set { contentCatalogState.selectedFilterValues = newValue }
    }
    var isLoadingVod: Bool {
        get { contentCatalogState.isLoading }
        set { contentCatalogState.isLoading = newValue }
    }
    var isLoadingMoreVods: Bool {
        get { contentCatalogState.isLoadingMore }
        set { contentCatalogState.isLoadingMore = newValue }
    }
    
    // 详情页业务数据
    @Published var detailVod: Vod?
    @Published var playFlags: [String] = []
    @Published var selectedPlayFlag: String = ""
    @Published var episodes: [Episode] = []
    private var availablePlaybackLines: [VodPlaybackLine] = []
    @Published var episodeDisplayMode: EpisodeDisplayMode = .grid
    @Published var isDetailPresented: Bool = false
    @Published var isDetailLoading: Bool = false
    @Published var isPlayerPresented: Bool = false
    private(set) var isDetailReturnPendingAfterPlayerExit: Bool = false
    @Published var isLivePlayerPresented: Bool = false
    @Published private(set) var livePlayerOpenRequestSerial: Int = 0
    @Published var isPlayerLoading: Bool = false
    @Published var playerLoadingMessage: String = "正在解析视频，请稍候..."
    @Published var isPlaybackErrorPresented: Bool = false
    @Published var playbackErrorMessage: String?
    @Published var playbackErrorAuthProvider: DriveProvider?
    @Published var playbackWarningMessage: String?
    @Published var playbackDowngradeMessage: String?
    @Published private(set) var drivePlaybackRoutes: [DrivePlaybackRouteOption] = []
    @Published private(set) var selectedDrivePlaybackRouteID: String?
    @Published private(set) var pendingDrivePlaybackRouteID: String?
    @Published private(set) var playbackSessionState = PlaybackSessionState()
    var pendingPlaybackSelection: PlaybackSelectionRequest? {
        get { playbackSessionState.selection }
        set {
            guard newValue == nil else { return }
            playbackSessionState = PlaybackSessionCore.dismissSelection(playbackSessionState)
        }
    }

    func beginPlayerDismissalReturningToDetail() {
        playerDismissalDetailTask?.cancel()
        isDetailReturnPendingAfterPlayerExit = detailVod != nil
        isDetailPresented = false
        isPlayerPresented = false
        playerDismissalDetailTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.completePlayerDismissalPresentation()
        }
    }

    func completePlayerDismissalPresentation() {
        guard isDetailReturnPendingAfterPlayerExit else { return }
        playerDismissalDetailTask?.cancel()
        playerDismissalDetailTask = nil
        isDetailReturnPendingAfterPlayerExit = false
        guard !isPlayerPresented, detailVod != nil else { return }
        isDetailPresented = true
    }

    @Published var cloudAuthRequest: CloudAuthRequest?
    @Published private(set) var settingsNavigationDestination: SettingsNavigationDestination?
    @Published var cloudCredentialClearRequest: CloudCredentialClearRequest?
    private var pendingAuthEpisode: Episode?
    private var driveCleanupInFlight = Set<String>()
    private var pendingPlaybackStart: PendingPlaybackStart?
    private var pendingPlaybackStartTask: Task<Void, Never>?
    private var playerDismissalDetailTask: Task<Void, Never>?
    private var historySaveTask: Task<Void, Never>?
    private var libraryHomeRefreshTask: Task<Void, Never>?
    private var vodLineFallbackGeneration: UInt64?
    private var vodLineFallbackTask: Task<Void, Never>?
    private var drivePlaybackStallGeneration: UInt64 = 0
    private var drivePlaybackStallTask: Task<Void, Never>?
    private var drivePlaybackStallSpecURL: String?
    private var pendingDrivePlaybackSuccessMessage: String?
    private let drivePlaybackSessionController = DrivePlaybackSessionController()

    // 直播业务数据
    @Published var lives: [Live] = []
    @Published var activeLive: Live?
    @Published var channelGroups: [ChannelGroup] = []
    @Published var selectedGroup: ChannelGroup?
    @Published var selectedChannel: Channel?
    @Published var isLoadingLive: Bool = false
    @Published private(set) var isLivePlaybackLoading: Bool = false
    @Published private(set) var livePlaybackLoadingMessage: String = "正在检查当前频道线路，请稍候。"
    @Published var currentChannelUrlIndex: Int = 0
    @Published var liveError: String?
    @Published var liveEpgData: EpgData?
    @Published var isLoadingLiveEpg: Bool = false
    @Published var liveEpgError: String?
    private var liveEpgRequestKey = ""
    private var liveEpgTask: Task<EpgData, Never>?
    private var livePlaybackSessionID = UUID()
    private var livePlaybackLoadingID: UUID?
    private var liveFallbackAttempts: [LivePlaybackAttempt] = []
    private var liveFallbackNextIndex: Int = 0
    private var liveFallbackTask: Task<Void, Never>?
    private var livePendingFailureTask: Task<Void, Never>?
    private var liveContentLoadedAt: Date?
    private var liveExpiredAddressRefreshSessionID: UUID?
    private let liveHTTPClient: HTTPClient
    private let livePlaybackProbe: LivePlaybackProbe
    var playSpecHandler: ((PlaySpec) async -> Void)?
    var drivePlaybackSourceRefreshHandler: ((PlaySpec, String) async throws -> PlaySpec)?

    // 配置、历史与收藏数据
    @Published private(set) var applicationLibraryState = ApplicationLibraryState()
    var historyItems: [History] {
        get { applicationLibraryState.history }
        set { applicationLibraryState.history = newValue }
    }
    var keepItems: [Keep] {
        get { applicationLibraryState.keeps }
        set { applicationLibraryState.keeps = newValue }
    }
    @Published var trackItems: [Track] = []

    // 搜索数据
    @Published private(set) var contentSearchState = ContentSearchState()
    var searchKeyword: String {
        get { contentSearchState.keyword }
        set { contentSearchState.keyword = newValue }
    }
    var searchResults: [SearchResult] {
        get { contentSearchState.results }
        set { contentSearchState.results = newValue }
    }
    var isSearching: Bool {
        get { contentSearchState.isLoading }
        set { contentSearchState.isLoading = newValue }
    }

    private(set) var initialConfigTask: Task<Void, Never>?

    init(
        loadDefaultConfig: Bool = true,
        startProxyServer: Bool = true,
        driveShareExpander: DriveShareExpander = .shared,
        liveHTTPClient: HTTPClient = .shared,
        configResolver: ConfigResolver = .shared,
        storageManager: StorageManager = .shared,
        applicationLibraryPersistence: (any ApplicationLibraryPersistence)? = nil,
        userPreferences: UserPreferences = .shared
    ) {
        let resolvedLibraryPersistence = applicationLibraryPersistence ?? storageManager
        self.driveShareExpander = driveShareExpander
        self.liveHTTPClient = liveHTTPClient
        self.livePlaybackProbe = LivePlaybackProbe(httpClient: liveHTTPClient)
        self.configResolver = configResolver
        self.storageManager = storageManager
        self.applicationLibraryPersistence = resolvedLibraryPersistence
        self.userPreferences = userPreferences
        self.providerRuntimeBootstrap = ProviderRuntimeBootstrap.makeDefault()
        let storedVodSiteKey = userPreferences.currentVodSiteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredVodHomeSiteKey = storedVodSiteKey.isEmpty ? nil : storedVodSiteKey
        let migratedPreferenceCount = UserPreferences.shared.migrateLegacyPreferenceDomainsIfNeeded()
        if migratedPreferenceCount > 0 {
            print("[PREFERENCES_MIGRATION] restored \(migratedPreferenceCount) values from legacy app domains")
        }
        UserPreferences.shared.migrateSubtitleDefaultsIfNeeded()
        self.appearanceThemeID = AppAppearanceDefaults.resolvedThemeID(
            storedRawValue: UserPreferences.shared.appearanceThemeID
        )

        // 清理缓存以确保拉取到最新的 JS 依赖库，避免历史脏缓存干扰
        URLCache.shared.removeAllCachedResponses()
        
        configurePlayerEngine(MPVPlayerEngine.vod, playerState: playerState)
        configurePlayerEngine(MPVPlayerEngine.live, playerState: livePlayerState)
        
        // 绑定网络库的代理设置提供器
        ProxyDetector.shared.proxySettingsProvider = {
            return (UserPreferences.shared.proxyMode, UserPreferences.shared.customProxyPort)
        }
        
        // 提前在后台异步探测一次代理可用性，缓存可用端口
        if startProxyServer {
            Task {
                await ProxyDetector.shared.detectActiveProxy()
            }
        }
        
        // 启动本地代理服务器并绑定通用防盗链代理处理器
        if startProxyServer {
            do {
                try ProxyServer.shared.start()
                let playbackHandlers = ProxyPlaybackHandler.makeHandlers()
                ProxyServer.shared.proxyHandler = playbackHandlers.buffered
                ProxyServer.shared.streamingProxyHandler = playbackHandlers.streaming
                RemoteProviderProxyBridge.install(on: ProxyServer.shared)
            } catch {
                print("[AppState] 本地代理服务器启动失败: \(error)")
            }
        }
        
        // 从持久化端口加载配置、历史和收藏
        self.applicationLibraryState = resolvedLibraryPersistence.loadApplicationLibrary()
        self.trackItems = storageManager.loadTracks()
        self.siteHealthSummaries = SiteHealthStore.shared.summaries()
        self.liveLineHealthSummaries = LiveLineHealthStore.shared.summaries()
        self.sourceHygieneRules = SourceHygieneStore.shared.loadRules()
        self.selectedSearchSiteKeys = UserPreferences.shared.defaultSearchSiteKeys

        if let providerRuntimeBootstrap {
            providerRuntimeBusy = true
            providerRuntimeStatus = "正在检查 Provider 支持包"
            providerRuntimeStartupTask = Task { @MainActor [weak self] in
                await self?.synchronizeProviderRuntime(using: providerRuntimeBootstrap)
            }
        }

        // 仅恢复用户保存的配置；首次启动保持空壳，不内置或发现视频源。
        if loadDefaultConfig {
            let savedURL = userPreferences.currentVodConfigUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !savedURL.isEmpty {
                let startupTask = providerRuntimeStartupTask
                initialConfigTask = Task { @MainActor [weak self] in
                    await startupTask?.value
                    await self?.loadConfig(url: savedURL)
                }
            }
        }
    }

    func selectAppearanceTheme(_ id: AppAppearanceThemeID) {
        guard appearanceThemeID != id else { return }
        UserPreferences.shared.appearanceThemeID = id.rawValue
        appearanceThemeID = id
    }

    func refreshProviderRuntimeCatalog() {
        guard let bootstrap = providerRuntimeBootstrap else {
            providerRuntimeStatus = "当前构建未配置签名分发"
            return
        }
        guard !providerRuntimeBusy else { return }
        providerRuntimeBusy = true
        Task { @MainActor [weak self] in
            await self?.synchronizeProviderRuntime(using: bootstrap)
        }
    }

    private func synchronizeProviderRuntime(using bootstrap: ProviderRuntimeBootstrap) async {
        providerRuntimeFailedRelease = nil
        do {
            let result = try await bootstrap.synchronizeAvailableProviders { [weak self] progress in
                await self?.applyProviderRuntimeProgress(progress)
            }
            providerRuntimeCatalog = result.catalog
            providerRuntimeInstalled = result.installed
            providerRuntimeFailedRelease = result.failures.last?.release
            if !result.failures.isEmpty {
                providerRuntimeStatus = result.installedOrUpdated.isEmpty
                    ? "Provider 支持包同步失败 \(result.failures.count) 个"
                    : "已更新 \(result.installedOrUpdated.count) 个，失败 \(result.failures.count) 个"
            } else if result.catalog.isEmpty {
                providerRuntimeStatus = "暂无可用的 Provider 支持包"
            } else if result.installedOrUpdated.isEmpty {
                providerRuntimeStatus = "Provider 支持包已是最新"
            } else {
                providerRuntimeStatus = "已自动安装或更新 \(result.installedOrUpdated.count) 个支持包"
            }
        } catch {
            providerRuntimeInstalled = await bootstrap.installedManifests()
            providerRuntimeStatus = providerRuntimeInstalled.isEmpty
                ? "自动同步失败：\(error.localizedDescription)"
                : "自动同步失败，继续使用已安装支持包"
        }
        providerRuntimeProgress = nil
        providerRuntimeBusy = false
    }

    func installProvider(providerID: String, version: String) {
        guard let bootstrap = providerRuntimeBootstrap else {
            providerRuntimeStatus = "当前构建未配置签名分发"
            return
        }
        providerRuntimeBusy = true
        providerRuntimeProgress = nil
        providerRuntimeFailedRelease = nil
        Task { @MainActor [weak self] in
            do {
                try await bootstrap.install(providerID: providerID, version: version) { [weak self] progress in
                    await self?.applyProviderRuntimeProgress(progress)
                }
                self?.providerRuntimeInstalled = await bootstrap.installedManifests()
                self?.providerRuntimeStatus = "已安装 \(providerID) \(version)"
            } catch {
                self?.providerRuntimeFailedRelease = ProviderVersionReference(
                    providerID: providerID,
                    version: version
                )
                self?.providerRuntimeStatus = "安装 \(providerID) \(version) 失败：\(error.localizedDescription)"
            }
            self?.providerRuntimeProgress = nil
            self?.providerRuntimeBusy = false
        }
    }

    private func applyProviderRuntimeProgress(_ progress: ProviderInstallProgress) {
        providerRuntimeProgress = progress
        let identity = "\(progress.providerID) \(progress.version)"
        switch progress.phase {
        case .fetchingCatalog:
            providerRuntimeStatus = "正在检查 \(identity)"
        case .downloading:
            if let fraction = progress.fractionCompleted {
                providerRuntimeStatus = "正在下载 \(identity) \(Int(fraction * 100))%"
            } else {
                providerRuntimeStatus = "正在下载 \(identity)"
            }
        case .verifyingArchive:
            providerRuntimeStatus = "正在校验 \(identity)"
        case .extracting:
            providerRuntimeStatus = "正在解包 \(identity)"
        case .verifyingPackage:
            providerRuntimeStatus = "正在验证签名 \(identity)"
        case .launching:
            providerRuntimeStatus = "正在启动 \(identity)"
        case .completed:
            providerRuntimeStatus = "已安装 \(identity)"
        }
    }

    private func configurePlayerEngine(_ engine: MPVPlayerEngine, playerState: PlayerState) {
        engine.playerState = playerState
        engine.playbackFailureHandler = { [weak self] spec, message in
            Task { @MainActor in
                self?.handleMPVPlaybackFailure(spec: spec, message: message)
            }
        }
        engine.playbackStartedHandler = { [weak self] spec in
            Task { @MainActor in
                self?.handleMPVPlaybackStarted(spec: spec)
            }
        }
        engine.playbackPositionHandler = { [weak self] spec, positionSeconds in
            Task { @MainActor in
                self?.handleMPVPlaybackPosition(spec: spec, positionSeconds: positionSeconds)
            }
        }
        engine.playbackEndedHandler = { [weak self] spec in
            Task { @MainActor in
                self?.handleMPVPlaybackEnded(spec: spec)
            }
        }
        engine.playbackStallHandler = { [weak self] spec, positionSeconds in
            Task { @MainActor in
                self?.handleMPVPlaybackStall(spec: spec, positionSeconds: positionSeconds)
            }
        }
        engine.playbackStallRecoveryHandler = { [weak self] spec in
            Task { @MainActor in
                self?.handleMPVPlaybackStallRecovery(spec: spec)
            }
        }
        engine.subtitleSettingsProvider = {
            SubtitleRenderSettings(
                fontSize: UserPreferences.shared.subtitleFontSize,
                position: UserPreferences.shared.subtitlePosition,
                overrideSourceStyle: UserPreferences.shared.subtitleOverrideSourceStyle
            )
        }
    }

    // MARK: - 点播核心逻辑

    private func log(_ message: String) {
        print(message)
        DiagnosticLog.write(message)
        fflush(stdout)
    }

    private func redactedPlaybackURL(_ rawURL: String) -> String {
        if rawURL.lowercased().hasPrefix("data:"),
           let separator = rawURL.firstIndex(of: ",") {
            let descriptor = rawURL[..<separator]
            let payloadLength = rawURL.distance(from: rawURL.index(after: separator), to: rawURL.endIndex)
            return "\(descriptor),<redacted \(payloadLength) chars>"
        }
        guard var components = URLComponents(string: rawURL) else { return rawURL }
        components.queryItems = components.queryItems?.map { item in
            let lowerName = item.name.lowercased()
            if ["url", "share", "share_url"].contains(lowerName), let value = item.value {
                return URLQueryItem(name: item.name, value: redactedPlaybackURL(value))
            }
            if lowerName == "header"
                || lowerName == "headers"
                || lowerName == "h64"
                || lowerName == "u64"
                || lowerName == "cookie"
                || lowerName == "fid_token"
                || lowerName == "password"
                || lowerName == "pwd"
                || lowerName == "passcode"
                || lowerName == "receive_code"
                || lowerName == "auth_key"
                || lowerName == "signature"
                || lowerName == "ct"
                || lowerName == "ork"
                || lowerName == "ud"
                || lowerName == "dfi"
                || lowerName == "sp"
                || lowerName == "mt"
                || lowerName == "ossaccesskeyid"
                || lowerName == "callback"
                || lowerName == "callback-var"
                || lowerName == "upsig"
                || lowerName == "sign"
                || lowerName == "trid"
                || lowerName == "traceid"
                || lowerName == "e"
                || lowerName == "oi"
                || lowerName == "mid"
                || lowerName == "buvid"
                || lowerName == "qn_dyeid"
                || lowerName.contains("token") {
                return URLQueryItem(name: item.name, value: "<redacted>")
            }
            return item
        }
        return components.string ?? rawURL
    }

    private func registerBuiltInSpiderReplacements() async {
        await SpiderReplacementRegistry.shared.registerPublicUtilityProviders(
            myDrive: MyDrivePublicProvider(credentialProvider: { provider in
                Self.cloudCredential(for: provider)
            }),
            configurationCenter: ConfigurationCenterPublicProvider()
        )
#if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
        await SpiderReplacementRegistry.shared.registerBuiltInNativeProviders(
            myDrive: MyDriveNativeProvider(credentialProvider: { provider in
                Self.cloudCredential(for: provider)
            })
        )
        log("[DEBUG_LOGGER] 已注册内置 WoGG/AList/WebDAV/Bili/Push/AliShare/115Share/QuarkShare/UCShare/MyDrive/PanSearch/MelostDiskSearch/Jianpian/Bttwoo macOS 原生替代源")
#else
        log("[DEBUG_LOGGER] 公共壳已注册 MyDrive/配置中心公共适配器；其余站点仅注册已安装且签名验证通过的 Provider")
#endif
    }

    nonisolated private static func cloudCredential(for provider: DriveProvider) -> CloudCredential? {
        switch provider {
        case .quark:
            let cookie = UserPreferences.shared.quarkCookie.trimmingCharacters(in: .whitespacesAndNewlines)
            return cookie.isEmpty ? nil : .cookie(provider: .quark, value: cookie)
        case .uc:
            let cookie = UserPreferences.shared.ucCookie.trimmingCharacters(in: .whitespacesAndNewlines)
            return cookie.isEmpty ? nil : .cookie(provider: .uc, value: cookie)
        case .baidu:
            let cookie = UserPreferences.shared.baiduCookie.trimmingCharacters(in: .whitespacesAndNewlines)
            return cookie.isEmpty ? nil : .cookie(provider: .baidu, value: cookie)
        case .ali:
            let refreshToken = UserPreferences.shared.aliRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let accessToken = UserPreferences.shared.aliAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let openToken = UserPreferences.shared.aliOpenToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultDriveID = UserPreferences.shared.aliDefaultDriveID.trimmingCharacters(in: .whitespacesAndNewlines)
            let authDomain = UserPreferences.shared.aliAuthDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            let userID = UserPreferences.shared.aliUserID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !refreshToken.isEmpty || !accessToken.isEmpty || !openToken.isEmpty else { return nil }
            var metadata: [String: String] = [:]
            if !openToken.isEmpty {
                metadata["open_token"] = openToken
            }
            if !defaultDriveID.isEmpty {
                metadata["default_drive_id"] = defaultDriveID
            }
            if !authDomain.isEmpty { metadata["ali_auth_domain"] = authDomain }
            if !userID.isEmpty { metadata["user_id"] = userID }
            return CloudCredential(
                provider: .ali,
                kind: refreshToken.isEmpty ? .accessToken : .refreshToken,
                secret: accessToken.isEmpty ? refreshToken : accessToken,
                refreshToken: refreshToken.isEmpty ? nil : refreshToken,
                accessToken: accessToken.isEmpty ? nil : accessToken,
                metadata: metadata
            )
        case .p115:
            let cookie = UserPreferences.shared.p115Cookie.trimmingCharacters(in: .whitespacesAndNewlines)
            let accessToken = UserPreferences.shared.p115AccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            return cookie.isEmpty ? nil : CloudCredential(
                provider: .p115,
                kind: .cookie,
                secret: cookie,
                metadata: accessToken.isEmpty ? [:] : ["access_token": accessToken]
            )
        case .pikpak:
            let accessToken = UserPreferences.shared.pikpakAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let refreshToken = UserPreferences.shared.pikpakRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceID = UserPreferences.shared.pikpakDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !accessToken.isEmpty || !refreshToken.isEmpty else { return nil }
            var metadata: [String: String] = [:]
            if !accessToken.isEmpty { metadata["access_token"] = accessToken }
            if !refreshToken.isEmpty { metadata["refresh_token"] = refreshToken }
            if !deviceID.isEmpty { metadata["device_id"] = deviceID }
            return CloudCredential(
                provider: .pikpak,
                kind: accessToken.isEmpty ? .refreshToken : .accessToken,
                secret: accessToken,
                refreshToken: refreshToken.isEmpty ? nil : refreshToken,
                accessToken: accessToken.isEmpty ? nil : accessToken,
                deviceID: deviceID.isEmpty ? nil : deviceID,
                metadata: metadata
            )
        default:
            return nil
        }
    }

    func externalSourceReport(for site: Site) -> ExternalSourceReport? {
        if let exactKey = externalSourceReports.first(where: { $0.siteKey == site.key }) {
            return exactKey
        }
        return externalSourceReports.first { report in
            report.api == site.api
        }
    }

    func externalSourceReportCount(for status: ExternalSourceSupportStatus) -> Int {
        externalSourceReports.filter { $0.status == status }.count
    }

    func clearSiteHealthRecords() {
        SiteHealthStore.shared.clear()
        siteHealthSummaries = [:]
    }

    func clearLiveLineHealthRecords() {
        LiveLineHealthStore.shared.clear()
        liveLineHealthSummaries = []
    }

    func refreshLiveLineHealthSummaries() {
        liveLineHealthSummaries = LiveLineHealthStore.shared.summaries()
    }

    func reloadSourceHygieneRules() {
        sourceHygieneRules = SourceHygieneStore.shared.loadRules()
    }

    func blockActiveSiteByFingerprint() {
        guard let site = activeSite else { return }
        let fingerprint = SourceHygienePolicy.siteFingerprint(site)
        let rule = SourceHygieneRule(
            kind: .siteFingerprint,
            pattern: fingerprint,
            name: "屏蔽站点：\(site.name.isEmpty ? site.key : site.name)"
        )
        do {
            try SourceHygieneStore.shared.addRule(rule)
            reloadSourceHygieneRules()
            sourceDiagnosticExportStatus = "已添加治理规则，重新加载配置后生效"
        } catch {
            sourceDiagnosticExportStatus = "添加治理规则失败：\(error.localizedDescription)"
        }
    }

    func clearSourceHygieneRules() {
        do {
            try SourceHygieneStore.shared.clear()
            reloadSourceHygieneRules()
            sourceDiagnosticExportStatus = "已清空源治理规则，重新加载配置后恢复"
        } catch {
            sourceDiagnosticExportStatus = "清空治理规则失败：\(error.localizedDescription)"
        }
    }

    func exportSourceDiagnostics() {
        let export = SourceDiagnosticsExport(
            configURL: UserPreferences.shared.currentVodConfigUrl,
            snapshot: configAggregationSnapshot,
            reports: externalSourceReports,
            liveLineHealth: liveLineHealthSummaries,
            rules: sourceHygieneRules
        )
        do {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("NetVplayer/Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = directory.appendingPathComponent("source-diagnostics-\(formatter.string(from: Date())).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(export).write(to: url, options: .atomic)
            sourceDiagnosticExportStatus = "已导出诊断：\(url.path)"
        } catch {
            sourceDiagnosticExportStatus = "导出诊断失败：\(error.localizedDescription)"
        }
    }

    private func durationMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private func recordSiteHealth(
        eventType: SiteHealthEventType,
        siteKey: String,
        siteName: String,
        success: Bool,
        durationMs: Int = 0,
        errorCategory: AppFailureCategory? = nil,
        host: String = ""
    ) {
        guard !siteKey.isEmpty else { return }
        SiteHealthStore.shared.record(SiteHealthEvent(
            eventType: eventType,
            siteKey: siteKey,
            siteName: siteName,
            success: success,
            durationMs: durationMs,
            errorCategory: errorCategory,
            host: host
        ))
        siteHealthSummaries = SiteHealthStore.shared.summaries()
    }

    private func recordLiveLineHealth(
        channel: Channel,
        url: String,
        result: LiveProbeResult,
        durationMs: Int
    ) {
        let groupName = selectedGroup?.name ?? sourceGroup(forLiveChannel: channel)?.name ?? ""
        LiveLineHealthStore.shared.record(LiveLineHealthEvent(
            liveName: activeLive?.name ?? "live",
            groupName: groupName,
            channelName: channel.name,
            url: url,
            success: result.isPlayable,
            statusCode: result.statusCode,
            ttfbMs: durationMs,
            failureCategory: result.isPlayable ? nil : .live,
            message: result.message
        ))
        refreshLiveLineHealthSummaries()
    }

    func probeCurrentLiveGroup() async {
        guard let group = selectedGroup ?? channelGroups.first else {
            liveError = "Live: 当前没有可检测的频道分组"
            return
        }
        let liveName = activeLive?.name ?? "live"
        let groupName = group.name
        let targets = group.channels.flatMap { channel in
            channel.urls.enumerated().map { (channel: channel, index: $0.offset, url: $0.element) }
        }
        guard !targets.isEmpty else {
            liveError = "Live: \(group.name) 没有可检测线路"
            return
        }

        let batchSize = 4
        for start in stride(from: 0, to: targets.count, by: batchSize) {
            let batch = Array(targets[start..<min(start + batchSize, targets.count)])
            await withTaskGroup(of: LiveLineHealthEvent.self) { group in
                for target in batch {
                    group.addTask {
                        let spec = PlaySpec(
                            url: target.url,
                            headers: target.channel.requestHeaders,
                            format: target.channel.format,
                            drm: target.channel.drm,
                            title: target.channel.name,
                            flag: liveName
                        )
                        let startedAt = Date()
                        let result = await LivePlaybackProbe.shared.probe(spec: spec, timeout: 3)
                        let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                        return LiveLineHealthEvent(
                            liveName: liveName,
                            groupName: groupName,
                            channelName: target.channel.name,
                            url: target.url,
                            success: result.isPlayable,
                            statusCode: result.statusCode,
                            ttfbMs: durationMs,
                            failureCategory: result.isPlayable ? nil : .live,
                            message: result.message
                        )
                    }
                }
                for await event in group {
                    LiveLineHealthStore.shared.record(event)
                }
            }
        }
        refreshLiveLineHealthSummaries()
    }

    private func siteName(for key: String) -> String {
        sites.first { $0.key == key }?.name ?? key
    }

    /// 加载配置
    func loadConfig(url: String, persistUserConfig: Bool = true) async {
        await providerRuntimeStartupTask?.value
        log("[DEBUG_LOGGER] 开始加载配置: \(url)")
        do {
            self.availableDepots = []
            self.externalSourceReports = []
            self.configAggregationSnapshot = ConfigAggregationSnapshot(rootURL: url)
            self.nativeReplacementSiteKeys = []
            self.currentVodInputFingerprint = nil
            self.currentVodInputKind = nil
            self.currentVodProviderID = nil
            self.lastFeedbackFailureStage = nil
            self.lastFeedbackFailureCategory = nil
            await NodeBundleRuntimeRegistry.shared.shutdown()
            await registerBuiltInSpiderReplacements()
            let resolvedInput = try await configResolver.loadVodInput(url: url)
            let canonicalURL = resolvedInput.canonicalURL
            self.currentVodInputFingerprint = resolvedInput.fingerprint
            self.currentVodInputKind = resolvedInput.kind
            self.currentVodProviderID = resolvedInput.providerID
            log("[DEBUG_LOGGER] 点播输入识别成功: \(resolvedInput.kind.rawValue), 长度: \(resolvedInput.json.count)")

            do {
                try await VodConfig.shared.parseResolvingExternalArrays(
                    json: resolvedInput.json,
                    config: resolvedInput.config
                )
                log("[DEBUG_LOGGER] 解析成功")
            } catch {
                log("[DEBUG_LOGGER] parse 解析抛出异常: \(error)")
                throw error
            }
            
            // 写入偏好
            if persistUserConfig {
                userPreferences.currentVodConfigUrl = canonicalURL
            }

            self.sites = VodConfig.shared.sites
            if let providerID = resolvedInput.providerID {
                let provider = NodeBundleSiteContentProvider(providerID: providerID)
                for site in self.sites where site.isSpider {
                    await SpiderReplacementRegistry.shared.register(originalKey: site.key, provider: provider)
                    await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: provider)
                }
                log("[DEBUG_LOGGER] 已注册 Node .js.md5 Provider: \(providerID)，站点数: \(self.sites.filter(\.isSpider).count)")
            }
            self.configAggregationSnapshot = VodConfig.shared.aggregationSnapshot
            let replacementKeys = await replacementSiteKeys(for: self.sites)
            self.nativeReplacementSiteKeys = replacementKeys
            self.externalSourceReports = ExternalSourceCompatibilityAuditor
                .reports(configLocation: canonicalURL, sites: self.sites, snapshot: self.configAggregationSnapshot)
                .map { report in
                    guard replacementKeys.contains(report.siteKey), !report.status.isNativeReplacement else {
                        return report
                    }
                    var updated = report
                    updated.status = .native
                    updated.reason = "已命中 SpiderReplacementRegistry Swift provider"
                    updated.suggestion = "已接管该 csp_ 源；实际可用性以各功能运行结果为准"
                    return updated
                }
                .filter { $0.siteKey != SearchSitePlanner.builtInCMSKey }
            let configuredHome = VodConfig.shared.home
            let sourceSelection = ApplicationLibraryCore.sourceSelection(
                sites: self.sites,
                configuredHome: configuredHome,
                preferredSiteKey: userPreferences.currentVodSiteKey
            )
            self.activeSite = sourceSelection.site
            self.currentSiteName = sourceSelection.displayName
            self.preferredVodHomeSiteKey = sourceSelection.site?.key
            self.configNotice = VodConfig.shared.config?.notice.isEmpty == false ? VodConfig.shared.config?.notice : nil
            self.contentCatalogState = ContentCatalogCore.resetContent(self.contentCatalogState)
            self.vodError = nil
            if persistUserConfig {
                saveLoadedConfig(url: canonicalURL)
            }
            
            // 同步直播源
            self.lives = LiveConfig.shared.lives
            if !UserPreferences.shared.currentLiveName.isEmpty,
               let savedLive = self.lives.first(where: { $0.name == UserPreferences.shared.currentLiveName }) {
                self.activeLive = savedLive
                LiveConfig.shared.setCurrent(savedLive)
            } else {
                self.activeLive = LiveConfig.shared.currentLive
            }
            self.channelGroups = []
            self.selectedGroup = nil
            self.selectedChannel = nil
            self.liveContentLoadedAt = nil
            self.liveEpgData = nil
            self.liveEpgError = nil
            
            self.configError = nil
            self.isConfigLoaded = true
            
            // 异步自检测试：拉取前几个可加载的 JS 爬虫站点的首页内容，定位调试问题
            Task {
                let loadableSpiders = self.sites.filter { $0.type == 3 && ($0.api.hasPrefix("http://") || $0.api.hasPrefix("https://")) }
                log("[TEST_RUNNER] 发现可加载的远程 JS 爬虫站点共: \(loadableSpiders.count) 个")
                for site in loadableSpiders.prefix(5) {
                    log("[TEST_RUNNER] 尝试自检可加载的 JS 爬虫站点 site=\(site.name), key=\(site.key), api=\(site.api)")
                    do {
                        let res = try await SiteApi.shared.homeContent(site: site)
                        var listCount = res.list.count
                        if listCount == 0, let firstType = res.types.first {
                            let cateRes = try await SiteApi.shared.categoryContent(
                                key: site.key,
                                tid: firstType.typeId,
                                page: "1",
                                filter: true,
                                extend: [:],
                                sites: self.sites
                            )
                            listCount = cateRes.list.count
                        }
                        log("[TEST_RUNNER] 爬虫自检成功 site=\(site.name), 分类数=\(res.types.count), 列表数=\(listCount)")
                    } catch {
                        log("[TEST_RUNNER] 爬虫自检失败 site=\(site.name), error=\(error.localizedDescription) (\(error))")
                    }
                }
            }
            
            // 单个 MacCMS 输入的首次响应已经包含首页数据，无需再次请求。
            if let initialResult = resolvedInput.initialResult {
                let loadingState = ContentCatalogCore.beginHome(self.contentCatalogState)
                self.contentCatalogState = ContentCatalogCore.receiveHome(
                    loadingState,
                    generation: loadingState.generation,
                    payload: Self.catalogPayload(from: initialResult)
                )
                log("[DEBUG_LOGGER] 已应用 MacCMS 首次结果: 分类数 \(initialResult.types.count), 影片数 \(initialResult.list.count)")
            } else {
                await loadHomeContent()
            }
            await loadLiveContentAndResumeIfNeeded()
        } catch {
            if let configError = error as? ConfigError,
               case .isDepot(let depots) = configError {
                self.availableDepots = depots
                self.externalSourceReports = []
                self.configAggregationSnapshot = ConfigAggregationSnapshot(rootURL: url)
                self.nativeReplacementSiteKeys = []
                self.configError = "配置仓库需选择子配置"
                self.isConfigLoaded = false
                log("[DEBUG_LOGGER] 配置仓库包含 \(depots.count) 个子配置")
                return
            }
            log("[DEBUG_LOGGER] loadConfig 遭遇总异常: \(error)")
            self.configError = "\(error.localizedDescription) (\(error))"
            self.externalSourceReports = []
            self.configAggregationSnapshot = ConfigAggregationSnapshot(rootURL: url)
            self.nativeReplacementSiteKeys = []
            self.lastFeedbackFailureStage = "Config.load"
            self.lastFeedbackFailureCategory = .config
            self.isConfigLoaded = false
        }
    }

    func reloadSavedConfigs() {
        self.applicationLibraryState = ApplicationLibraryCore.replacingConfigs(
            applicationLibraryState,
            with: applicationLibraryPersistence.loadConfigs()
        )
        self.selectedSearchSiteKeys = UserPreferences.shared.defaultSearchSiteKeys
    }

    @discardableResult
    func deleteSavedConfig(_ config: Config) -> Bool {
        let removed = persistConfigTransition(
            ApplicationLibraryCore.removeConfig(applicationLibraryState, config: config)
        )
        guard removed else { return false }

        let currentURL = UserPreferences.shared.currentVodConfigUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let removedURL = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.type == .vod, currentURL == removedURL {
            UserPreferences.shared.currentVodConfigUrl = ""
        }
        return true
    }

    func loadDepot(_ depot: Depot) async {
        await loadConfig(url: depot.url)
    }

    func isDefaultSearchSiteEnabled(_ site: Site) -> Bool {
        selectedSearchSiteKeys.isEmpty || selectedSearchSiteKeys.contains(site.key)
    }

    func setDefaultSearchSite(_ site: Site, enabled: Bool) {
        let searchableKeys = sites.filter(\.isSearchable).map(\.key)
        var selected = Set(selectedSearchSiteKeys.isEmpty ? searchableKeys : selectedSearchSiteKeys)
        if enabled {
            selected.insert(site.key)
        } else {
            guard selected.count > 1 else { return }
            selected.remove(site.key)
        }
        let ordered = searchableKeys.filter { selected.contains($0) }
        selectedSearchSiteKeys = ordered.count == searchableKeys.count ? [] : ordered
        UserPreferences.shared.defaultSearchSiteKeys = selectedSearchSiteKeys
    }

    func resetDefaultSearchSites() {
        selectedSearchSiteKeys = []
        UserPreferences.shared.defaultSearchSiteKeys = []
    }

    func exportBackup(to url: URL) throws {
        try storageManager.exportBackup(to: url)
    }

    func exportPlaybackProgress(to url: URL) throws {
        try storageManager.exportPlaybackProgress(to: url)
    }

    func inspectBackup(from url: URL) throws -> StorageBackupPreview {
        try storageManager.inspectBackup(from: url)
    }

    @discardableResult
    func importBackup(from url: URL) throws -> StorageBackup {
        let backup = try storageManager.importBackup(from: url)
        self.applicationLibraryState = applicationLibraryPersistence.loadApplicationLibrary()
        self.trackItems = storageManager.loadTracks()
        self.selectedSearchSiteKeys = UserPreferences.shared.defaultSearchSiteKeys
        selectAppearanceTheme(AppAppearanceDefaults.resolvedThemeID(
            storedRawValue: UserPreferences.shared.appearanceThemeID
        ))
        return backup
    }

    @discardableResult
    func importPlaybackProgress(from url: URL) throws -> PlaybackProgressExport {
        let progress = try storageManager.importPlaybackProgress(from: url)
        self.applicationLibraryState = ApplicationLibraryCore.replacingHistory(
            applicationLibraryState,
            with: applicationLibraryPersistence.loadHistory()
        )
        return progress
    }

    func makeWebHomeBridgeDispatcher() -> WebHomeBridgeDispatcher {
        WebHomeBridgeDispatcher(
            handlers: WebHomeBridgeHandlers(
                search: { [weak self] context in
                    try await self?.webHomeSearch(context) ?? .object(["items": .array([])])
                },
                detail: { [weak self] context in
                    try await self?.webHomeDetail(context) ?? .object(["status": .string("unavailable")])
                },
                play: { [weak self] context in
                    guard let self else { throw WebHomeBridgeError.missingParameter("appState") }
                    return try await self.webHomePlay(context)
                },
                panCheck: { [weak self] context in
                    try await self?.webHomePanCheck(context) ?? .object(["status": .string("unknown")])
                },
                historyQuery: { [weak self] context in
                    try await self?.webHomeHistoryQuery(context) ?? .array([])
                },
                uiChrome: { [weak self] context in
                    try await self?.webHomeUIChrome(context) ?? .object(["accepted": .bool(true)])
                }
            ),
            diagnosticRecorder: { [weak self] invocation in
                self?.recordWebHomeInvocation(invocation)
            }
        )
    }

    func updateWebHomeURLStatus(_ status: String) {
        webHomeSessionDiagnostic.currentURLStatus = status
    }

    private func recordWebHomeInvocation(_ invocation: WebHomeBridgeInvocation) {
        lastWebHomeBridgeMethod = invocation.method
        webHomeSessionDiagnostic.record(invocation)
    }

    private func webHomeSearch(_ context: WebHomeBridgeContext) async throws -> JSONDynamicValue {
        lastWebHomeBridgeMethod = context.method.rawValue
        let keyword = webHomeString(in: context.params, keys: ["keyword", "wd", "query"])
        guard !keyword.isEmpty else { return .object(["items": .array([])]) }
        let searchSites = await searchSitesForCurrentPreference()
        var summaries: [JSONDynamicValue] = []
        var siteOrder: [String] = []
        for await result in SearchEngine.shared.search(keyword: keyword, sites: searchSites, quick: true) {
            siteOrder.append(result.siteKey)
            summaries.append(.object([
                "siteKey": .string(result.siteKey),
                "siteName": .string(result.siteName),
                "count": .number(Double(result.vods.count)),
                "durationMs": .number(Double(result.durationMs)),
                "error": result.error.map(JSONDynamicValue.string) ?? .null,
                "items": .array(result.vods.prefix(20).map(webHomeVodSummary))
            ]))
        }
        return .object([
            "keyword": .string(keyword),
            "siteOrder": .array(siteOrder.map(JSONDynamicValue.string)),
            "items": .array(summaries)
        ])
    }

    private func webHomeDetail(_ context: WebHomeBridgeContext) async throws -> JSONDynamicValue {
        lastWebHomeBridgeMethod = context.method.rawValue
        return .object([
            "status": .string("accepted"),
            "siteKey": .string(webHomeString(in: context.params, keys: ["siteKey", "site"])),
            "vodId": .string(webHomeString(in: context.params, keys: ["vodId", "id"]))
        ])
    }

    private func webHomePlay(_ context: WebHomeBridgeContext) async throws -> PlaySpec {
        lastWebHomeBridgeMethod = context.method.rawValue
        let rawURL = webHomeString(in: context.params, keys: ["url", "playURL", "playUrl"])
        guard !rawURL.isEmpty else { throw WebHomeBridgeError.missingParameter("url") }
        let safeURL = try ProxyAccessPolicy.validateTargetURL(rawURL)
        var spec = PlaySpec(
            url: safeURL.absoluteString,
            title: webHomeString(in: context.params, keys: ["title", "name"]),
            flag: webHomeString(in: context.params, keys: ["flag"]),
            siteKey: webHomeString(in: context.params, keys: ["siteKey", "site"])
        )
        spec.metadata["webhome.method"] = context.method.rawValue
        spec.metadata["webhome.source"] = "bridge"
        spec.metadata["webhome.originalHost"] = safeURL.host ?? ""
        let playable = await proxiedPlaySpec(spec, logContext: "WEBHOME")
        selectedTab = .vodHome
        isDetailPresented = false
        isPlayerPresented = true
        await play(spec: playable)
        return playable
    }

    private func webHomePanCheck(_ context: WebHomeBridgeContext) async throws -> JSONDynamicValue {
        lastWebHomeBridgeMethod = context.method.rawValue
        let rawURL = webHomeString(in: context.params, keys: ["url", "shareURL", "shareUrl"])
        guard !rawURL.isEmpty else { return .object(["status": .string("unknown")]) }
        if let candidate = SourceManager.externalDriveCandidate(for: rawURL) {
            return .object([
                "status": .string(candidate.support.status.rawValue),
                "provider": .string(candidate.provider),
                "kind": .string(candidate.kind),
                "canonicalURL": .string(candidate.canonicalURL),
                "reason": .string(candidate.support.reason),
                "requiresAuth": .bool(candidate.requiresAuth)
            ])
        }
        return .object([
            "status": .string("unknown"),
            "provider": .string("unknown"),
            "requiresAuth": .bool(false)
        ])
    }

    private func webHomeHistoryQuery(_ context: WebHomeBridgeContext) async throws -> JSONDynamicValue {
        lastWebHomeBridgeMethod = context.method.rawValue
        let limit = min(max(context.params["limit"]?.intValue ?? 50, 1), 200)
        let records = storageManager.makePlaybackProgressExport().records.prefix(limit).map { record in
            JSONDynamicValue.object([
                "title": .string(record.vodName),
                "siteKey": .string(record.siteKey),
                "vodId": .string(record.vodId),
                "flag": .string(record.vodFlag),
                "episodeKey": .string(record.episodeKey),
                "position": .number(Double(record.position)),
                "duration": .number(Double(record.duration)),
                "updatedAt": .string(Self.webHomeDateFormatter.string(from: record.updatedAt)),
                "driveProvider": .string(record.driveProvider),
                "driveReferenceURL": .string(record.driveReferenceURL),
                "driveRoute": .string(record.driveRoute)
            ])
        }
        return .array(Array(records))
    }

    private func webHomeUIChrome(_ context: WebHomeBridgeContext) async throws -> JSONDynamicValue {
        lastWebHomeBridgeMethod = context.method.rawValue
        let title = webHomeString(in: context.params, keys: ["title"])
        if !title.isEmpty {
            webHomeChromeTitle = title
        }
        return .object([
            "accepted": .bool(true),
            "title": .string(webHomeChromeTitle)
        ])
    }

    private func webHomeString(in params: [String: JSONDynamicValue], keys: [String]) -> String {
        for key in keys {
            let value = params[key]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return ""
    }

    private func webHomeVodSummary(_ vod: Vod) -> JSONDynamicValue {
        .object([
            "vodId": .string(vod.vodId),
            "name": .string(vod.vodName),
            "pic": .string(vod.vodPic),
            "remarks": .string(vod.vodRemarks),
            "siteKey": .string(vod.siteKey)
        ])
    }

    private static let webHomeDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func saveLoadedConfig(url: String) {
        let loaded = VodConfig.shared.config ?? Config.vod(url: url)
        let effectiveURL = loaded.url.isEmpty ? url : loaded.url
        persistConfigTransition(
            ApplicationLibraryCore.registerConfig(
                applicationLibraryState,
                loadedConfig: loaded,
                canonicalURL: url,
                fallbackName: displayName(forConfigURL: effectiveURL)
            )
        )
    }

    @discardableResult
    private func persistConfigTransition(_ transition: ApplicationLibraryTransition) -> Bool {
        guard transition.changed else { return false }
        do {
            try applicationLibraryPersistence.saveConfigs(transition.state.configs)
            applicationLibraryState = transition.state
            return true
        } catch {
            log("[APPLICATION_LIBRARY] 保存配置失败: \(error.localizedDescription)")
            return false
        }
    }

    private func displayName(forConfigURL url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else {
            return url.isEmpty ? "点播配置" : url
        }
        let path = components.path.split(separator: "/").last.map(String.init) ?? ""
        return path.isEmpty ? host : "\(host)/\(path)"
    }

    /// 切换当前激活的点播源
    func changeSite(site: Site) async {
        log("[DEBUG_LOGGER] 切换当前点播源 site=\(site.name)")
        libraryHomeRefreshTask?.cancel()
        libraryHomeRefreshTask = nil
        preferredVodHomeSiteKey = site.key
        userPreferences.currentVodSiteKey = site.key
        activateSite(site)
        await loadHomeContent()
    }

    private func activateSite(_ site: Site) {
        let sourceSelection = ApplicationLibraryCore.sourceSelection(site: site)
        self.activeSite = sourceSelection.site
        self.currentSiteName = sourceSelection.displayName
        self.contentCatalogState = ContentCatalogCore.resetContent(self.contentCatalogState)
        self.vodError = nil
    }

    @discardableResult
    private func activateSiteForLibraryNavigation(_ site: Site) -> Bool {
        guard activeSite?.key != site.key else { return false }
        libraryHomeRefreshTask?.cancel()
        libraryHomeRefreshTask = nil
        activateSite(site)
        return true
    }

    func restoreVodHomeSiteIfNeeded() {
        guard selectedTab == .vodHome,
              !isDetailPresented,
              !isPlayerPresented,
              !isDetailReturnPendingAfterPlayerExit,
              let preferredVodHomeSiteKey,
              activeSite?.key != preferredVodHomeSiteKey,
              let site = sites.first(where: { $0.key == preferredVodHomeSiteKey }) else {
            return
        }

        libraryHomeRefreshTask?.cancel()
        activateSite(site)
        libraryHomeRefreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.activeSite?.key == site.key else { return }
            await self.loadHomeContent()
        }
    }

    /// 加载激活站点的首页分类与推荐
    func loadHomeContent() async {
        guard let site = activeSite else {
            log("[DEBUG_LOGGER] loadHomeContent 失败: activeSite 为 nil")
            return
        }
        let loadingState = ContentCatalogCore.beginHome(contentCatalogState)
        contentCatalogState = loadingState
        let generation = loadingState.generation
        self.vodError = nil
        log("[DEBUG_LOGGER] 开始加载站点首页 site=\(site.name), key=\(site.key), type=\(site.siteType)")
        if site.isAndroidCrawlerSource,
           !(await SpiderReplacementRegistry.shared.hasReplacement(for: site)) {
            let isCurrent = contentCatalogState.generation == generation
            contentCatalogState = ContentCatalogCore.failHome(
                contentCatalogState,
                generation: generation,
                clearContent: true
            )
            if isCurrent {
                self.vodError = site.androidCrawlerUnsupportedMessage
            }
            log("[DEBUG_LOGGER] \(site.androidCrawlerUnsupportedMessage)")
            return
        }

        do {
            let result = try await SiteApi.shared.homeContent(site: site)
            contentCatalogState = ContentCatalogCore.receiveHome(
                contentCatalogState,
                generation: generation,
                payload: Self.catalogPayload(from: result)
            )
            log("[DEBUG_LOGGER] 首页加载成功! 分类数: \(result.types.count), 影片数: \(result.list.count)")
        } catch {
            log("[DEBUG_LOGGER] 加载首页推荐发生异常: \(error)")
            let isCurrent = contentCatalogState.generation == generation
            contentCatalogState = ContentCatalogCore.failHome(
                contentCatalogState,
                generation: generation
            )
            if isCurrent {
                self.vodError = error.localizedDescription
            }
        }
    }

    /// 切换点播分类
    func selectCategory(_ category: VodClass) async {
        guard let site = activeSite else { return }
        if site.isAllliveGuard, category.typeId == "search" {
            self.isDetailPresented = false
            self.isDetailLoading = false
            self.selectedTab = .search
            return
        }
        self.vodError = nil
        let transition = ContentCatalogCore.beginCategory(
            contentCatalogState,
            category: category
        )
        await executeCategoryTransition(transition, site: site)
    }

    func loadMoreCategoryContentIfNeeded(currentVod vod: Vod) async {
        guard let site = activeSite, let category = selectedCategory else { return }
        if site.isAndroidCrawlerSource,
           !(await SpiderReplacementRegistry.shared.hasReplacement(for: site)) {
            return
        }

        let transition = ContentCatalogCore.beginNextPage(
            contentCatalogState,
            triggerVodID: vod.vodId
        )
        contentCatalogState = transition.state
        guard let request = transition.request else { return }

        do {
            let result = try await SiteApi.shared.categoryContent(
                key: site.key,
                tid: request.categoryID,
                page: String(request.page),
                filter: true,
                extend: request.selection,
                sites: self.sites
            )
            contentCatalogState = ContentCatalogCore.receiveCategory(
                contentCatalogState,
                request: request,
                payload: Self.catalogPayload(from: result)
            )
            log("[DEBUG_LOGGER] 分类分页加载成功: \(category.typeName), page=\(contentCatalogState.currentPage)/\(contentCatalogState.pageCount), 新增=\(result.list.count)")
        } catch {
            contentCatalogState = ContentCatalogCore.failCategory(
                contentCatalogState,
                request: request
            )
            log("[DEBUG_LOGGER] 分类分页加载失败: \(category.typeName), page=\(request.page), error=\(error)")
        }
    }

    func selectCategoryFilter(_ filter: Filter, value: FilterValue) async {
        guard let site = activeSite else { return }
        let transition = ContentCatalogCore.selectOption(
            contentCatalogState,
            filterKey: filter.key,
            value: value.value
        )
        await executeCategoryTransition(transition, site: site)
    }

    func updateCategoryTextFilterDraft(_ filter: Filter, value: String) {
        let transition = ContentCatalogCore.updateTextDraft(
            contentCatalogState,
            filterKey: filter.key,
            value: value
        )
        contentCatalogState = transition.state
    }

    func applyCategoryTextFilter(_ filter: Filter) async {
        guard let site = activeSite else { return }
        let transition = ContentCatalogCore.applyTextFilter(
            contentCatalogState,
            filterKey: filter.key
        )
        await executeCategoryTransition(transition, site: site)
    }

    func selectedCategoryFilterName(for filter: Filter) -> String {
        ContentCatalogCore.selectedFilterName(
            in: contentCatalogState,
            filterKey: filter.key
        )
    }

    private func executeCategoryTransition(
        _ transition: ContentCatalogTransition,
        site: Site
    ) async {
        contentCatalogState = transition.state
        if case let .invalidTextFilter(name) = transition.failure {
            vodError = "\(name)筛选值无效"
            return
        }
        if transition.failure == nil {
            vodError = nil
        }
        guard transition.failure == nil, let request = transition.request else { return }

        if site.isAndroidCrawlerSource,
           !(await SpiderReplacementRegistry.shared.hasReplacement(for: site)) {
            let isCurrent = contentCatalogState.generation == request.generation
            contentCatalogState = ContentCatalogCore.failCategory(
                contentCatalogState,
                request: request
            )
            if isCurrent {
                vodError = site.androidCrawlerUnsupportedMessage
            }
            return
        }

        do {
            let result = try await SiteApi.shared.categoryContent(
                key: site.key,
                tid: request.categoryID,
                page: String(request.page),
                filter: true,
                extend: request.selection,
                sites: self.sites
            )
            contentCatalogState = ContentCatalogCore.receiveCategory(
                contentCatalogState,
                request: request,
                payload: Self.catalogPayload(from: result)
            )
        } catch {
            let isCurrent = contentCatalogState.generation == request.generation
            contentCatalogState = ContentCatalogCore.failCategory(
                contentCatalogState,
                request: request
            )
            if isCurrent {
                print("[AppState] 加载分类 \(transition.state.selectedCategory?.typeName ?? request.categoryID) 失败: \(error)")
                vodError = error.localizedDescription
            }
        }
    }

    private static func catalogPayload(from result: Result) -> ContentCatalogPayload {
        ContentCatalogPayload(
            types: result.types,
            vods: result.list,
            filters: result.filters,
            page: result.page,
            pageCount: result.pagecount
        )
    }

    /// 打开首页/分类卡片。部分抓包源的卡片在 Android 端是搜索或二级分类入口。
    func openVodCard(_ vod: Vod) async {
        guard let site = activeSite else { return }
        if let action = MyDriveConfigurationAction.decode(vodID: vod.vodId) {
            handleMyDriveConfigurationAction(action)
            return
        }
        if let action = ConfigurationCenterAction.decode(vodID: vod.vodId) {
            handleConfigurationCenterAction(action)
            return
        }
        if let category = site.allliveCategory(for: vod) {
            self.isDetailPresented = false
            self.isDetailLoading = false
            await selectCategory(category)
            return
        }
        let keyword = vod.vodName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFongMiSearchCard = VodCardRoutingPolicy.shouldRouteToGlobalSearch(
            site: site,
            vod: vod
        )
        if isFongMiSearchCard, !keyword.isEmpty {
            self.isDetailPresented = false
            self.isDetailLoading = false
            self.selectedTab = .search
            await search(keyword: keyword)
            return
        }
        await selectVod(vod)
    }

    private func handleMyDriveConfigurationAction(_ action: MyDriveConfigurationAction) {
        isDetailPresented = false
        isDetailLoading = false
        switch action {
        case .manageAccounts:
            settingsNavigationDestination = .dataSource
            selectedTab = .settings
        case .clearCredential(let provider):
            cloudCredentialClearRequest = CloudCredentialClearRequest(provider: provider)
        }
    }

    private func handleConfigurationCenterAction(_ action: ConfigurationCenterAction) {
        isDetailPresented = false
        isDetailLoading = false
        guard case .open(let section) = action else { return }
        settingsNavigationDestination = switch section {
        case .dataSource: .dataSource
        case .providers: .providers
        case .playback: .playback
        case .network: .network
        case .system: .system
        case .appearance: .appearance
        }
        selectedTab = .settings
    }

    func openFeedback() {
        settingsNavigationDestination = .feedback
        selectedTab = .settings
    }

    func feedbackSourceContext(for category: FeedbackCategory) async -> SourceReproductionContext {
        let site = activeSite
        let installedManifests: [SignedProviderManifest]
        if providerRuntimeInstalled.isEmpty, let providerRuntimeBootstrap {
            installedManifests = await providerRuntimeBootstrap.installedManifests()
            providerRuntimeInstalled = installedManifests
        } else {
            installedManifests = providerRuntimeInstalled
        }
        let providerID = currentVodProviderID
            ?? site.flatMap { candidate in
                candidate.isAndroidCrawlerSource ? candidate.androidCrawlerName : nil
            }
        let providerVersion = providerID.flatMap { identifier in
            installedManifests.first { $0.manifest.providerID == identifier }?.manifest.version
        }
        return SourceReproductionContext(
            configFingerprint: currentVodInputFingerprint,
            inputKind: currentVodInputKind?.rawValue,
            adapterID: site.map(Self.feedbackAdapterID),
            providerID: providerID,
            providerVersion: providerVersion,
            siteKeyFingerprint: site.flatMap { candidate in
                candidate.key.isEmpty ? nil : StableFingerprint.sha256Prefix(candidate.key)
            },
            failureStage: lastFeedbackFailureStage,
            errorCategory: lastFeedbackFailureCategory
        )
    }

    private static func feedbackAdapterID(for site: Site) -> String {
        switch site.siteType {
        case .cmsXML: return "cms-xml"
        case .cmsJSON: return "cms-json"
        case .spider: return site.isAndroidCrawlerSource ? "android-crawler" : "spider"
        case .xpath: return "xpath"
        }
    }

    func consumeSettingsNavigationDestination(_ destination: SettingsNavigationDestination) {
        guard settingsNavigationDestination == destination else { return }
        settingsNavigationDestination = nil
    }

    func cancelCloudCredentialClear() {
        cloudCredentialClearRequest = nil
    }

    func confirmCloudCredentialClear() {
        guard let request = cloudCredentialClearRequest else { return }
        clearCloudCredential(for: request.provider)
        cloudCredentialClearRequest = nil
        vods = vods.map { vod in
            guard MyDriveConfigurationAction.decode(vodID: vod.vodId) == .clearCredential(request.provider) else {
                return vod
            }
            var updated = vod
            updated.vodContent = "当前未保存\(request.provider.displayName)授权。"
            return updated
        }
    }

    private func clearCloudCredential(for provider: DriveProvider) {
        switch provider {
        case .quark:
            userPreferences.quarkCookie = ""
            userPreferences.quarkTVDeviceID = ""
            userPreferences.quarkTVQueryToken = ""
            userPreferences.quarkTVRefreshToken = ""
            userPreferences.quarkTVAccessToken = ""
        case .uc:
            userPreferences.ucCookie = ""
            userPreferences.ucTVDeviceID = ""
            userPreferences.ucTVQueryToken = ""
            userPreferences.ucTVRefreshToken = ""
            userPreferences.ucTVAccessToken = ""
            userPreferences.ucFongMiAccountToken = ""
            userPreferences.ucFongMiPlaybackToken = ""
            userPreferences.ucFongMiAccountExpiresAt = ""
            userPreferences.ucFongMiPlaybackExpiresAt = ""
            userPreferences.ucFongMiFixtureID = ""
            userPreferences.ucFongMiEvidenceStatus = ""
        case .baidu:
            userPreferences.baiduCookie = ""
        case .ali:
            userPreferences.aliRefreshToken = ""
            userPreferences.aliAccessToken = ""
            userPreferences.aliOpenToken = ""
            userPreferences.aliDefaultDriveID = ""
            userPreferences.aliAuthDomain = ""
            userPreferences.aliUserID = ""
        case .p115:
            userPreferences.p115Cookie = ""
            userPreferences.p115AccessToken = ""
        case .pikpak:
            userPreferences.pikpakAccessToken = ""
            userPreferences.pikpakRefreshToken = ""
            userPreferences.pikpakDeviceID = ""
        default:
            break
        }
    }

    /// 搜索结果已确定目标站点，只重置旧目录并直接加载详情，避免等待无关的首页请求。
    func openSearchResultVod(_ vod: Vod, from site: Site) async {
        activateSite(site)
        await selectVod(vod)
    }

    func openImportedDriveShare(_ vod: Vod) async {
        let candidate = SourceManager.externalDriveCandidate(for: vod.vodId)
            ?? SourceManager.externalDriveCandidate(for: vod.vodContent)
        guard let candidate else { return }

        let site = Self.driveShareImportSite
        ensureDriveShareImportSite()
        activeSite = site
        currentSiteName = site.name
        selectedTab = .vodHome
        isDetailPresented = true
        isDetailLoading = true
        defer { isDetailLoading = false }

        let title = vod.vodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(Self.driveProviderDisplayName(candidate.provider))分享"
            : vod.vodName
        let episodes = await importedDriveEpisodes(for: candidate, title: title)
        let playURL = episodes.map { "\(Self.safeEpisodeTitle($0.name))$\($0.url)" }.joined(separator: "#")
        let detail = Vod(
            vodId: candidate.canonicalURL,
            vodName: title,
            vodPic: vod.vodPic,
            vodContent: candidate.support.reason,
            vodRemarks: candidate.support.status == .supported ? Self.driveProviderDisplayName(candidate.provider) : "待验证",
            vodPlayFrom: "网盘分享",
            vodPlayUrl: playURL,
            siteKey: site.key
        )

        detailVod = detail
        applyPlaybackAvailability(for: detail)
        isPlayerPresented = false
    }

    /// 选中视频并加载详情
    func selectVod(_ vod: Vod, acknowledgeKeepUpdate: Bool = false) async {
        guard let site = activeSite else { return }
        let detailStartedAt = Date()
        var initialVod = vod
        if initialVod.siteKey.isEmpty {
            initialVod.siteKey = site.key
        }
        self.detailVod = initialVod
        self.episodes = []
        self.playFlags = []
        self.selectedPlayFlag = ""
        self.availablePlaybackLines = []
        self.isDetailPresented = true
        self.isDetailLoading = true
        defer { self.isDetailLoading = false }

        do {
            let result = try await SiteApi.shared.detailContent(key: site.key, id: vod.vodId, sites: self.sites)
            recordSiteHealth(
                eventType: .detail,
                siteKey: site.key,
                siteName: site.name,
                success: !result.list.isEmpty,
                durationMs: durationMilliseconds(since: detailStartedAt),
                errorCategory: result.list.isEmpty ? .source : nil,
                host: site.api
            )
            if var detail = result.list.first {
                if detail.siteKey.isEmpty {
                    detail.siteKey = site.key
                }
                self.detailVod = detail
                syncKeepRemarks(for: detail, acknowledge: acknowledgeKeepUpdate)

                let visibleLines = VodPlaybackAvailabilityPolicy.visibleLines(in: detail)
                let visibleFlags = visibleLines.map(\.flag)
                let history = PlaybackLinkage.history(for: detail, activeSiteKey: site.key, items: historyItems)
                let historyFlag = PlaybackLinkage.preferredFlag(from: history, availableFlags: visibleFlags)
                applyPlaybackAvailability(visibleLines: visibleLines, preferredFlag: historyFlag)
            }
        } catch {
            recordSiteHealth(
                eventType: .detail,
                siteKey: site.key,
                siteName: site.name,
                success: false,
                durationMs: durationMilliseconds(since: detailStartedAt),
                errorCategory: .spider,
                host: site.api
            )
            print("[AppState] 加载详情失败: \(error)")
        }
    }

    /// 切换播放线路
    func selectPlayFlag(_ flag: String) {
        guard let line = availablePlaybackLines.first(where: { $0.flag == flag }) else {
            selectedPlayFlag = ""
            episodes = []
            return
        }
        selectedPlayFlag = line.flag
        episodes = line.episodes
    }

    func playbackEpisodes(for flag: String) -> [Episode] {
        availablePlaybackLines.first(where: { $0.flag == flag })?.episodes ?? []
    }

    func applyPlaybackAvailability(for detail: Vod, preferredFlag: String? = nil) {
        applyPlaybackAvailability(
            visibleLines: VodPlaybackAvailabilityPolicy.visibleLines(in: detail),
            preferredFlag: preferredFlag
        )
    }

    private func applyPlaybackAvailability(
        visibleLines: [VodPlaybackLine],
        preferredFlag: String?
    ) {
        availablePlaybackLines = visibleLines
        playFlags = visibleLines.map(\.flag)

        let selected = preferredFlag.flatMap { candidate in
            playFlags.contains(candidate) ? candidate : nil
        } ?? preferredPlayFlag(from: visibleLines)

        guard let selected else {
            selectedPlayFlag = ""
            episodes = []
            return
        }
        selectPlayFlag(selected)
    }

    func episodeForCurrentPlayback(in episodeList: [Episode]) -> Episode? {
        guard !episodeList.isEmpty, let spec = playerState.currentSpec else { return nil }
        return PlaybackSessionCore.episode(
            in: episodeList,
            metadataEpisodeURL: spec.metadata["vod.episodeURL"],
            fallbackPlaybackURL: spec.url,
            metadataEpisodeName: spec.metadata["vod.episodeName"]
        )
    }

    func playbackEpisodeContext(in episodeList: [Episode]? = nil) -> PlaybackEpisodeContext {
        let list = episodeList ?? episodes
        let spec = playerState.currentSpec
        return PlaybackSessionCore.episodeContext(
            episodes: list,
            metadataEpisodeURL: spec?.metadata["vod.episodeURL"],
            fallbackPlaybackURL: spec?.url ?? "",
            metadataEpisodeName: spec?.metadata["vod.episodeName"],
            progressText: currentPlaybackProgressText()
        )
    }

    @discardableResult
    func playRelativeEpisode(offset: Int, automaticSelection: Bool = false) async -> Episode? {
        let context = playbackEpisodeContext()
        guard let target = PlaybackSessionCore.relativeEpisode(
            in: episodes,
            context: context,
            offset: offset
        ) else { return nil }
        await playEpisode(target, automaticSelection: automaticSelection)
        return target
    }

    private func currentPlaybackProgressText() -> String? {
        if playerState.position > 0 {
            let minutes = max(1, Int(playerState.position / 60))
            return "已观看 \(minutes) 分钟"
        }
        return currentDetailHistoryProgressText()
    }

    /// 取消当前的视频加载/解析
    func cancelLoading() async {
        self.log("[AppState] 用户主动取消当前播放加载任务")
        ParseEngine.shared.cancelCurrentSniff()
        playbackSessionState = PlaybackSessionCore.cancel(playbackSessionState)
        self.isPlayerLoading = false
        self.playerLoadingMessage = "正在解析视频，请稍候..."
    }

    static func sourceResultShouldReplaceInheritedHeaders(
        metadata: [String: String],
        isDirectMedia: Bool
    ) -> Bool {
        isDirectMedia && metadata[DrivePlaybackMetadataKey.provider] != nil
    }

    /// 播放单集剧集
    func playEpisode(
        _ episode: Episode,
        resumePosition: Int64? = nil,
        resumeDuration: Int64? = nil,
        automaticSelection: Bool = false,
        lineFallbackApplied: Bool = false
    ) async {
        guard let site = activeSite else { return }
        resetDrivePlaybackRoutes()
        if !lineFallbackApplied {
            vodLineFallbackTask?.cancel()
            vodLineFallbackTask = nil
        }
        let preferenceKey = PlaybackSessionCore.preferenceKey(
            siteKey: site.key,
            vodID: detailVod?.vodId ?? "",
            playFlag: selectedPlayFlag
        )
        playbackSessionState = PlaybackSessionCore.beginEpisode(
            playbackSessionState,
            site: site,
            episode: episode,
            resumePosition: resumePosition,
            resumeDuration: resumeDuration,
            automaticSelection: automaticSelection,
            preferenceKey: preferenceKey
        )
        let generation = playbackSessionState.generation
        vodLineFallbackGeneration = lineFallbackApplied ? generation : nil
        
        if isPlayerLoading {
            ParseEngine.shared.cancelCurrentSniff()
        }
        
        self.isPlayerLoading = true
        self.playerLoadingMessage = "正在解析视频，请稍候..."
        self.playbackWarningMessage = nil
        self.playbackDowngradeMessage = nil
        self.playbackErrorAuthProvider = nil
        self.pendingAuthEpisode = nil
        defer {
            if self.playbackSessionState.generation == generation {
                self.isPlayerLoading = false
                self.playerLoadingMessage = "正在解析视频，请稍候..."
            }
        }
        
        self.log("[PLAY_EPISODE] 开始播放剧集 title=\(episode.name), url=\(redactedPlaybackURL(episode.url))")
        
        do {
            // 调用 SiteApi 抓取该剧集对应的播放流地址
            let result = try await SiteApi.shared.playerContent(
                key: site.key,
                flag: self.selectedPlayFlag,
                id: episode.url,
                sites: self.sites
            )
            
            self.log("[PLAY_EPISODE] SiteApi 返回 url: \(redactedPlaybackURL(result.url)), needParse: \(result.needParse)")
            let transition = PlaybackSessionCore.receivePlayerResult(
                playbackSessionState,
                generation: generation,
                result: result,
                preferredSignature: nil
            )
            playbackSessionState = transition.state
            guard transition.failure == nil else { return }
            try await executePlaybackSessionCommand(transition.command)
        } catch {
            let isCurrent = playbackSessionState.generation == generation
            playbackSessionState = PlaybackSessionCore.fail(
                playbackSessionState,
                generation: generation
            )
            if isCurrent {
                self.log("[PLAY_EPISODE] 播放异常失败: \(error)")
                handlePlaybackError(error, episode: episode)
            }
        }
    }

    func selectPlaybackCandidate(_ candidate: PlaybackCandidate) async {
        guard let request = playbackSessionState.selection else { return }
        let transition = PlaybackSessionCore.selectCandidate(
            playbackSessionState,
            selectionID: request.id,
            candidateID: candidate.id
        )
        playbackSessionState = transition.state
        guard transition.failure == nil else { return }
        let generation = request.generation
        isPlayerLoading = true
        playerLoadingMessage = "正在加载字幕并启动播放器..."
        defer {
            if playbackSessionState.generation == generation {
                isPlayerLoading = false
                playerLoadingMessage = "正在解析视频，请稍候..."
            }
        }

        do {
            try await executePlaybackSessionCommand(transition.command)
        } catch {
            let isCurrent = playbackSessionState.generation == generation
            playbackSessionState = PlaybackSessionCore.fail(
                playbackSessionState,
                generation: generation
            )
            if isCurrent {
                log("[PLAY_EPISODE] 播放候选启动失败: \(error)")
                handlePlaybackError(error, episode: request.episode)
            }
        }
    }

    func dismissPlaybackSelection() {
        playbackSessionState = PlaybackSessionCore.dismissSelection(playbackSessionState)
    }

    func preferredPlaybackCandidateID(for _: PlaybackSelectionRequest) -> String? {
        nil
    }

    private func executePlaybackSessionCommand(
        _ initialCommand: PlaybackSessionCommand
    ) async throws {
        var command = initialCommand
        while true {
            switch command {
            case .none:
                return
            case let .resolveCandidate(request, candidate, _):
                let resolved = resolvedPlaybackCandidateResult(
                    request.result,
                    candidate: candidate
                )
                let transition = PlaybackSessionCore.receiveResolvedCandidate(
                    playbackSessionState,
                    generation: request.generation,
                    result: resolved
                )
                playbackSessionState = transition.state
                guard transition.failure == nil else { return }
                command = transition.command
            case let .startResolved(intent, result):
                guard playbackSessionState.generation == intent.generation else { return }
                let didStart = try await startResolvedPlayback(
                    result: result,
                    episode: intent.episode,
                    site: intent.site,
                    resumePosition: intent.resumePosition,
                    resumeDuration: intent.resumeDuration,
                    sessionGeneration: intent.generation
                )
                if didStart {
                    playbackSessionState = PlaybackSessionCore.finishStarting(
                        playbackSessionState,
                        generation: intent.generation
                    )
                } else {
                    playbackSessionState = PlaybackSessionCore.fail(
                        playbackSessionState,
                        generation: intent.generation
                    )
                }
                return
            }
        }
    }

    private func resolvedPlaybackCandidateResult(
        _ result: Result,
        candidate: PlaybackCandidate
    ) -> Result {
        var resolved = result
        resolved.url = candidate.url
        resolved.playUrl = ""
        resolved.parse = 0
        resolved.header = candidate.headers
        resolved.format = candidate.format
        resolved.subs = candidate.subtitles
        resolved.playbackCandidates = [candidate]
        return resolved
    }

    private func startResolvedPlayback(
        result: Result,
        episode: Episode,
        site: Site,
        resumePosition: Int64?,
        resumeDuration: Int64?,
        sessionGeneration: UInt64
    ) async throws -> Bool {
            guard playbackSessionState.generation == sessionGeneration else { return false }
            cancelPendingPlaybackStart()
            MPVPlayerEngine.vod.stop()

            var finalSpec = PlaySpec(
                url: result.playUrl + result.url,
                externalAudioURL: result.externalAudioURL,
                contentLength: result.contentLength,
                headers: result.header,
                format: result.format,
                artwork: Self.playbackArtwork(from: result),
                drm: result.drm,
                subs: result.subs,
                title: "\(self.detailVod?.vodName ?? "") - \(episode.name)",
                flag: self.selectedPlayFlag,
                siteKey: site.key
            )
            finalSpec.metadata["vod.siteKey"] = site.key
            finalSpec.metadata["vod.id"] = self.detailVod?.vodId ?? ""
            finalSpec.metadata["vod.episodeURL"] = episode.url
            finalSpec.metadata["vod.episodeName"] = episode.name
            if vodLineFallbackGeneration == sessionGeneration {
                finalSpec.metadata[VodLineFallbackPolicy.appliedMetadataKey] = "true"
            }

            if finalSpec.url.isEmpty {
                finalSpec.url = episode.url
            }

            var resolveResult = result
            var sourceResolvedDirectMedia = result.playbackCandidates.contains {
                $0.isPlayable && $0.url == finalSpec.url
            }
            let sourceResult = try await SourceManager.shared.fetchResult(url: finalSpec.url)
            guard playbackSessionState.generation == sessionGeneration else { return false }
            if sourceResult.url != finalSpec.url {
                self.log("[PLAY_EPISODE] Source 预处理: \(redactedPlaybackURL(finalSpec.url)) -> \(redactedPlaybackURL(sourceResult.url))")
                finalSpec.url = sourceResult.url
                resolveResult.url = sourceResult.url
            }
            if Self.sourceResultShouldReplaceInheritedHeaders(
                metadata: sourceResult.metadata,
                isDirectMedia: sourceResult.isDirectMedia
            ) {
                finalSpec.headers = sourceResult.headers
            } else if !sourceResult.headers.isEmpty {
                finalSpec.headers.merge(sourceResult.headers) { _, new in new }
            }
            if !sourceResult.fallbackHeaders.isEmpty {
                finalSpec.fallbackHeaders.merge(sourceResult.fallbackHeaders) { _, new in new }
            }
            if !sourceResult.mpvOptions.isEmpty {
                finalSpec.mpvOptions.merge(sourceResult.mpvOptions) { _, new in new }
                self.log("[PLAY_EPISODE] Source 提供 mpv 播放参数: \(sourceResult.mpvOptions.keys.sorted())")
            }
            if !sourceResult.metadata.isEmpty {
                finalSpec.metadata.merge(sourceResult.metadata) { _, new in new }
                self.log("[PLAY_EPISODE] Source 提供播放元数据: \(sourceResult.metadata.keys.sorted())")
            }
            finalSpec.drivePlaybackPlan = sourceResult.drivePlaybackPlan
            sourceResolvedDirectMedia = sourceResult.isDirectMedia
            if sourceResult.needParse {
                resolveResult.parse = 1
                resolveResult.url = finalSpec.url
            }
            
            // 判断是否需要二次解析/网页嗅探
            if result.needParse || sourceResult.needParse {
                if resolveResult.url.isEmpty {
                    resolveResult.url = episode.url
                }
                let parseConfig = VodConfig.shared.parses.first { $0.name == result.jxFrom } ?? VodConfig.shared.parses.first
                self.log("[PLAY_EPISODE] 正在进行二次解析, 目标: \(redactedPlaybackURL(resolveResult.url))")
                let parsedSpec = await ParseEngine.shared.resolve(result: resolveResult, parse: parseConfig)
                guard playbackSessionState.generation == sessionGeneration else { return false }
                finalSpec = finalSpec.merging(parsedSpec)
            }
            
            // Unknown HTTP pages still need WebView discovery; known media and local provider routes do not.
            if PlaybackProxyPolicy.shouldAttemptWebSniff(
                for: finalSpec,
                sourceResolvedDirectMedia: sourceResolvedDirectMedia
            ) {
                self.log("[PLAY_EPISODE] 检测到播放 URL 可能是网页而非直连视频流，强制启动 WebView 网页嗅探: \(redactedPlaybackURL(finalSpec.url))")
                let sniffBaseURL = finalSpec.url
                var resolveResult = result
                resolveResult.url = sniffBaseURL
                let parseConfig = VodConfig.shared.parses.first ?? Parse(name: "默认嗅探", type: 0)
                let sniffedSpec = await ParseEngine.shared.resolve(result: resolveResult, parse: parseConfig)
                guard playbackSessionState.generation == sessionGeneration else { return false }
                if !sniffedSpec.url.isEmpty {
                    let resolvedURL = URLHelper.resolveMediaURL(base: sniffBaseURL, candidate: sniffedSpec.url)
                    var normalizedSniffedSpec = sniffedSpec
                    normalizedSniffedSpec.url = resolvedURL
                    if resolvedURL != sniffedSpec.url {
                        self.log("[PLAY_EPISODE] 智能网页嗅探成功，流地址归一化: \(redactedPlaybackURL(sniffedSpec.url)) -> \(redactedPlaybackURL(resolvedURL))")
                    } else {
                        self.log("[PLAY_EPISODE] 智能网页嗅探成功，获取到真实流地址: \(redactedPlaybackURL(resolvedURL))")
                    }
                    finalSpec = finalSpec.merging(normalizedSniffedSpec)
                } else {
                    self.log("[PLAY_EPISODE] 智能网页嗅探失败，保持原 URL 尝试直接播放")
                }
            }
            if sourceResolvedDirectMedia {
                self.log("[PLAY_EPISODE] Source 已解析为直连媒体，跳过网页嗅探")
            }
            
            finalSpec = configureDrivePlaybackRoutes(for: finalSpec)

            if requiresBiliPlaybackMaterialization(finalSpec) {
                finalSpec = try await materializeBiliPlayback(finalSpec)
                guard playbackSessionState.generation == sessionGeneration else {
                    releaseBiliPlaybackCacheIfNeeded(spec: finalSpec, reason: "playback-cancelled")
                    return false
                }
            }

            // 标准媒体直连优先交给 libmpv；本地代理只保留给需要中转/改写的场景。
            finalSpec = await proxiedPlaySpec(finalSpec, logContext: "PLAY_EPISODE")
            guard playbackSessionState.generation == sessionGeneration else { return false }
            updateDrivePlaybackWarning(for: finalSpec, episode: episode)
            
            // 调用内嵌 libmpv 执行实机播放
            guard !finalSpec.url.isEmpty else {
                self.log("[PLAY_EPISODE] 获取到的播放 URL 为空，中止播放")
                return false
            }
            guard playbackSessionState.generation == sessionGeneration else { return false }
            
            // 成功获取流地址，即将拉起播放器。安全关闭详情弹窗并切换 Tab
            self.selectedTab = .vodHome
            self.isDetailPresented = false
            self.isPlayerPresented = true
            
            // 记录初始历史（存盘）
            if let vod = self.detailVod {
                self.addHistory(
                    vod: vod,
                    flag: self.selectedPlayFlag,
                    episode: episode,
                    position: resumePosition ?? 0,
                    duration: resumeDuration ?? 0
                )
            }
            
            let skipSettings = VodSkipSettingsStore.shared.settings(for: finalSpec.metadata)
            setPendingPlaybackStart(
                resumePosition: resumePosition,
                episodeURL: episode.url,
                openingSkipSeconds: skipSettings.openingSeconds
            )
            MPVPlayerEngine.vod.speed = UserPreferences.shared.defaultPlaybackSpeed
            await play(spec: finalSpec)
            return true
    }

    static func playbackArtwork(from result: Result) -> String {
        result.artwork
    }

    private func preferredPlayFlag(from lines: [VodPlaybackLine]) -> String? {
        if let direct = lines.first(where: { $0.flag.lowercased().contains("m3u8") }) {
            return direct.flag
        }

        for line in lines {
            if line.episodes.contains(where: { DriveFileReference.parse($0.url) != nil }) {
                return line.flag
            }
        }
        return lines.first?.flag
    }

    func handlePlaybackError(_ error: Error, episode: Episode) {
        lastFeedbackFailureStage = error is DriveEngineError ? "Source.resolve" : "Player.prepare"
        lastFeedbackFailureCategory = error is DriveEngineError ? .source : .player
        playbackErrorMessage = error.localizedDescription
        playbackErrorAuthProvider = nil

        if let driveError = error as? DriveEngineError {
            switch driveError {
            case .loginRequired(let provider):
                playbackErrorAuthProvider = provider
                pendingAuthEpisode = episode
                isPlaybackErrorPresented = false
                requestCloudAuth(provider)
                return
            default:
                break
            }
        }

        isPlaybackErrorPresented = true
    }

    func clearPlaybackError() {
        clearPlaybackError(clearPendingEpisode: true)
    }

    private func clearPlaybackError(clearPendingEpisode: Bool) {
        isPlaybackErrorPresented = false
        playbackErrorMessage = nil
        playbackErrorAuthProvider = nil
        if clearPendingEpisode {
            pendingAuthEpisode = nil
        }
    }

    func openCloudAuthFromPlaybackError() {
        guard let provider = playbackErrorAuthProvider else { return }
        playerState.errorMessage = nil
        playbackWarningMessage = nil
        clearPlaybackError(clearPendingEpisode: false)
        requestCloudAuth(provider)
    }

    func dismissPlaybackWarning() {
        playbackWarningMessage = nil
    }

    func dismissPlaybackDowngradeNotice() {
        playbackDowngradeMessage = nil
    }

    func updateDrivePlaybackWarning(for spec: PlaySpec, episode: Episode) {
        guard let plan = spec.drivePlaybackPlan,
              let unavailableReason = plan.unavailableReason else {
            playbackWarningMessage = nil
            return
        }

        if plan.reauthenticationRequired {
            playbackWarningMessage = "\(plan.provider.displayName)备用线路需要重新授权，当前线路仍会继续尝试播放。"
            playbackErrorAuthProvider = plan.provider
            pendingAuthEpisode = episode
            log("[DRIVE_PLAYBACK_WARNING] provider=\(plan.provider.displayName) reason=\(unavailableReason) authRequired=true")
        } else {
            playbackWarningMessage = "\(plan.provider.displayName)备用线路暂不可用，当前线路仍会继续尝试播放。"
            playbackErrorAuthProvider = nil
            pendingAuthEpisode = nil
            log("[DRIVE_PLAYBACK_WARNING] provider=\(plan.provider.displayName) reason=\(unavailableReason) authRequired=false")
        }
    }

    func requestCloudAuth(_ provider: DriveProvider) {
        cloudAuthRequest = CloudAuthRequest(provider: provider, pendingEpisodeURL: pendingAuthEpisode?.url)
    }

    func requestCloudAuthFromSettings(_ provider: DriveProvider) {
        pendingAuthEpisode = nil
        playbackErrorAuthProvider = nil
        cloudAuthRequest = CloudAuthRequest(provider: provider)
    }

    func completeCloudAuth(credential: CloudCredential) async throws -> CloudAuthCompletion {
        switch credential.provider {
        case .quark:
            switch credential.kind {
            case .cookie:
                return try await completeQuarkCookieAuth(credential)
            case .refreshToken, .accessToken:
                return try await completeQuarkTVAuth(credential)
            default:
                throw DriveEngineError.unsupported("夸克授权暂不支持 \(credential.kind.rawValue) 凭证。")
            }
        case .uc:
            switch credential.kind {
            case .cookie:
                return try await completeUCCookieAuth(credential)
            case .refreshToken, .accessToken:
                return try await completeUCTVAuth(credential)
            case .shareToken:
                return try await completeUCFongMiAuth(credential)
            default:
                throw DriveEngineError.unsupported("UC 授权暂不支持 \(credential.kind.rawValue) 凭证。")
            }
        case .ali:
            return await completeAliAuth(credential)
        case .p115:
            switch credential.kind {
            case .cookie:
                return try await completeP115CookieAuth(credential)
            default:
                throw DriveEngineError.unsupported("115 授权暂只支持 Cookie。")
            }
        case .pikpak:
            return await completePikPakAuth(credential)
        case .baidu:
            guard credential.kind == .cookie else {
                throw DriveEngineError.unsupported("百度网盘授权只支持扫码或 Cookie。")
            }
            return try await completeBaiduAuth(credential)
        default:
            throw DriveEngineError.unsupported("\(credential.provider.displayName) 授权暂未适配。")
        }
    }

    func validateAndSaveCloudCookie(provider: DriveProvider, cookie: String) async throws {
        let credential = CloudCredential.cookie(provider: provider, value: cookie)
        _ = try await completeCloudAuth(credential: credential)
    }

    private func completeQuarkCookieAuth(_ credential: CloudCredential) async throws -> CloudAuthCompletion {
        let reference = pendingAuthReference()
        let validated = try await QuarkCookieDriver().validate(credential, reference: reference)
        UserPreferences.shared.quarkCookie = validated.secret.trimmingCharacters(in: .whitespacesAndNewlines)

        cloudAuthRequest = nil
        clearPlaybackError(clearPendingEpisode: false)

        if let episode = pendingAuthEpisode {
            pendingAuthEpisode = nil
            await playEpisode(episode)
        }
        return .dismiss("夸克 Cookie 验证成功，已保存。")
    }

    private func completeBaiduAuth(_ credential: CloudCredential) async throws -> CloudAuthCompletion {
        let validated = try await BaiduDriveClient().validate(credential)
        UserPreferences.shared.baiduCookie = validated.secret.trimmingCharacters(in: .whitespacesAndNewlines)

        cloudAuthRequest = nil
        clearPlaybackError(clearPendingEpisode: false)
        if let episode = pendingAuthEpisode {
            pendingAuthEpisode = nil
            await playEpisode(episode)
        }
        return .dismiss("百度网盘登录验证成功，已保存并继续播放。")
    }

    private func completeQuarkTVAuth(_ credential: CloudCredential) async throws -> CloudAuthCompletion {
        let validated = try await QuarkTVDriver().validate(credential, reference: nil)
        UserPreferences.shared.quarkTVDeviceID = validated.deviceID ?? ""
        UserPreferences.shared.quarkTVQueryToken = validated.queryToken ?? ""
        UserPreferences.shared.quarkTVRefreshToken = validated.refreshToken ?? ""
        UserPreferences.shared.quarkTVAccessToken = validated.accessToken ?? ""

        return .stay("QuarkTV Token 已保存。请继续扫码获取 Cookie，公开分享完整播放会使用 Cookie。")
    }

    private func completeUCCookieAuth(_ credential: CloudCredential) async throws -> CloudAuthCompletion {
        let reference = pendingAuthReference()
        let validated = try await UCCookieDriver().validate(credential, reference: reference)
        UserPreferences.shared.ucCookie = validated.secret.trimmingCharacters(in: .whitespacesAndNewlines)

        cloudAuthRequest = nil
        clearPlaybackError(clearPendingEpisode: false)

        if let episode = pendingAuthEpisode {
            pendingAuthEpisode = nil
            await playEpisode(episode)
        }
        return .dismiss("UC Cookie 验证成功，已保存。")
    }

    private func completeUCTVAuth(_ credential: CloudCredential) async throws -> CloudAuthCompletion {
        let validated = try await QuarkTVDriver(provider: .uc).validate(credential, reference: nil)
        UserPreferences.shared.ucTVDeviceID = validated.deviceID ?? ""
        UserPreferences.shared.ucTVQueryToken = validated.queryToken ?? ""
        UserPreferences.shared.ucTVRefreshToken = validated.refreshToken ?? ""
        UserPreferences.shared.ucTVAccessToken = validated.accessToken ?? ""

        if pendingAuthEpisode != nil {
            return .stay("UCTV Token 已保存；UC 分享播放仍需要 Cookie。请继续网页扫码，完成后会优先播放原文件。")
        }

        cloudAuthRequest = nil
        clearPlaybackError(clearPendingEpisode: false)

        return .dismiss("UCTV Token 验证成功，已保存。")
    }

    private func completeUCFongMiAuth(_ credential: CloudCredential) async throws -> CloudAuthCompletion {
        let validated = try await UCFongMiQRLoginClient().validate(credential)
        let token = validated.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = validated.metadata[UCFongMiCredentialMetadataKey.kind] ?? ""
        let expiresAt = validated.metadata[UCFongMiCredentialMetadataKey.expiresAt] ?? ""

        switch UCFongMiQRLoginKind(rawValue: kind) {
        case .account:
            UserPreferences.shared.ucFongMiAccountToken = token
            UserPreferences.shared.ucFongMiAccountExpiresAt = expiresAt
        case .playback:
            UserPreferences.shared.ucFongMiPlaybackToken = token
            UserPreferences.shared.ucFongMiPlaybackExpiresAt = expiresAt
        case .none:
            throw DriveEngineError.unsupported("UC FongMi 私有码凭证缺少用途标记。")
        }

        UserPreferences.shared.ucFongMiFixtureID = validated.metadata[UCFongMiCredentialMetadataKey.fixtureID] ?? ""
        UserPreferences.shared.ucFongMiEvidenceStatus = validated.metadata[UCFongMiCredentialMetadataKey.evidenceStatus] ?? ""

        if UCFongMiQRLoginKind(rawValue: kind) == .playback,
           pendingAuthEpisode != nil,
           !UserPreferences.shared.ucCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cloudAuthRequest = nil
            clearPlaybackError(clearPendingEpisode: false)
            if let episode = pendingAuthEpisode {
                pendingAuthEpisode = nil
                await playEpisode(episode)
            }
            return .dismiss("UC FongMi 播放授权已保存，正在重试播放。")
        }

        return .stay("UC FongMi 私有码凭证已保存；公开分享播放仍优先使用 UC Cookie。")
    }

    private func completeAliAuth(_ credential: CloudCredential) async -> CloudAuthCompletion {
        switch credential.kind {
        case .refreshToken:
            UserPreferences.shared.aliRefreshToken = credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
            UserPreferences.shared.aliAccessToken = credential.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            UserPreferences.shared.aliOpenToken = credential.metadata["open_token"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            UserPreferences.shared.aliDefaultDriveID = credential.metadata["default_drive_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            UserPreferences.shared.aliAuthDomain = credential.metadata["ali_auth_domain"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            UserPreferences.shared.aliUserID = credential.metadata["user_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .accessToken, .cookie:
            UserPreferences.shared.aliAccessToken = credential.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
            if let defaultDriveID = credential.metadata["default_drive_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !defaultDriveID.isEmpty {
                UserPreferences.shared.aliDefaultDriveID = defaultDriveID
            }
            if let authDomain = credential.metadata["ali_auth_domain"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !authDomain.isEmpty {
                UserPreferences.shared.aliAuthDomain = authDomain
            }
            if let userID = credential.metadata["user_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !userID.isEmpty {
                UserPreferences.shared.aliUserID = userID
            }
        default:
            break
        }

        cloudAuthRequest = nil
        clearPlaybackError(clearPendingEpisode: false)
        if let episode = pendingAuthEpisode {
            pendingAuthEpisode = nil
            await playEpisode(episode)
        }
        return .dismiss("阿里云盘 Token 已保存，将在播放时校验。")
    }

    private func completeP115CookieAuth(_ credential: CloudCredential) async throws -> CloudAuthCompletion {
        let validated = try await P115DriveClient().validate(credential)
        UserPreferences.shared.p115Cookie = validated.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if let accessToken = validated.metadata["access_token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accessToken.isEmpty {
            UserPreferences.shared.p115AccessToken = accessToken
        }

        cloudAuthRequest = nil
        clearPlaybackError(clearPendingEpisode: false)
        if let episode = pendingAuthEpisode {
            pendingAuthEpisode = nil
            await playEpisode(episode)
        }
        return .dismiss("115 Cookie 验证成功，已保存并继续播放。")
    }

    private func completePikPakAuth(_ credential: CloudCredential) async -> CloudAuthCompletion {
        UserPreferences.shared.pikpakAccessToken = credential.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? credential.metadata["access_token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        UserPreferences.shared.pikpakRefreshToken = credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? credential.metadata["refresh_token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        UserPreferences.shared.pikpakDeviceID = credential.deviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? credential.metadata["device_id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        cloudAuthRequest = nil
        clearPlaybackError(clearPendingEpisode: false)
        if let episode = pendingAuthEpisode {
            pendingAuthEpisode = nil
            await playEpisode(episode)
        }
        return .dismiss("PikPak Token 已保存，将在播放时校验。")
    }

    private func pendingAuthReference() -> DriveFileReference? {
        guard let episode = pendingAuthEpisode else { return nil }
        return DriveFileReference.parse(episode.url)
    }

    private func releaseLocalStreamRelayIfNeeded(
        spec: PlaySpec?,
        replacingWith replacement: PlaySpec? = nil,
        reason: String
    ) {
        guard let spec else { return }
        let replacementURLs = Set([replacement?.url, replacement?.externalAudioURL].compactMap { $0 })
        for url in [spec.url, spec.externalAudioURL] where !url.isEmpty && !replacementURLs.contains(url) {
            if ProxyServer.shared.unregisterRemoteStream(forLocalURL: url) {
                log("[REMOTE_STREAM_RELEASE] reason=\(reason) url=\(redactedPlaybackURL(url))")
            }
        }
    }

    private func requiresBiliPlaybackMaterialization(_ spec: PlaySpec) -> Bool {
        let urls = [spec.url, spec.externalAudioURL].filter { !$0.isEmpty }
        return !spec.externalAudioURL.isEmpty && urls.allSatisfy { rawURL in
            guard let host = URL(string: rawURL)?.host?.lowercased() else { return false }
            return host == "bilivideo.com" || host.hasSuffix(".bilivideo.com")
        }
    }

    private func materializeBiliPlayback(_ spec: PlaySpec) async throws -> PlaySpec {
        var localSpec = spec
        var downloadedFiles: [URL] = []
        do {
            let videoExtension = spec.format.lowercased() == ProviderPlaybackFormat.biliProgressiveMP4
                ? "mp4"
                : "m4s"
            let videoURL = Self.biliPlaybackCacheDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(videoExtension)
            log("[BILI_CACHE] 正在下载视频到临时缓存")
            try await HTTPClient.shared.downloadFile(
                url: spec.url,
                headers: spec.headers,
                to: videoURL,
                redactsURLInLogs: true
            )
            downloadedFiles.append(videoURL)

            let videoSize = Self.fileSize(at: videoURL)
            guard videoSize > 0 else {
                throw HTTPError.invalidResponse
            }
            if let expectedSize = spec.contentLength,
               expectedSize > 0,
               expectedSize != videoSize {
                log("[BILI_CACHE] 视频长度与接口声明不一致 expected=\(expectedSize) actual=\(videoSize)，继续交给播放器校验")
            }

            localSpec.url = videoURL.absoluteString
            localSpec.headers = [:]
            localSpec.contentLength = videoSize
            localSpec.metadata[Self.biliPlaybackCacheMetadataKey] = videoURL.path

            if !spec.externalAudioURL.isEmpty {
                let audioURL = Self.biliPlaybackCacheDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("m4s")
                log("[BILI_CACHE] 正在下载独立音轨到临时缓存")
                try await HTTPClient.shared.downloadFile(
                    url: spec.externalAudioURL,
                    headers: spec.headers,
                    to: audioURL,
                    redactsURLInLogs: true
                )
                downloadedFiles.append(audioURL)
                guard Self.fileSize(at: audioURL) > 0 else {
                    throw HTTPError.invalidResponse
                }
                localSpec.externalAudioURL = audioURL.absoluteString
                localSpec.metadata[Self.biliAudioCacheMetadataKey] = audioURL.path
            }

            if spec.format.lowercased() == ProviderPlaybackFormat.biliProgressiveMP4 {
                localSpec.format = "mp4"
            }
            localSpec.mpvOptions.removeValue(forKey: "http-proxy")
            log("[BILI_CACHE] 下载完成 size=\(videoSize)，使用本地文件播放")
            return localSpec
        } catch {
            for fileURL in downloadedFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
            throw error
        }
    }

    private static func fileSize(at fileURL: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func releaseBiliPlaybackCacheIfNeeded(
        spec: PlaySpec?,
        replacingWith replacement: PlaySpec? = nil,
        reason: String
    ) {
        guard let spec else { return }
        let replacementPaths = Set([
            replacement?.metadata[Self.biliPlaybackCacheMetadataKey],
            replacement?.metadata[Self.biliAudioCacheMetadataKey]
        ].compactMap { $0 })
        let cacheRoot = Self.biliPlaybackCacheDirectory.standardizedFileURL.path + "/"

        for key in [Self.biliPlaybackCacheMetadataKey, Self.biliAudioCacheMetadataKey] {
            guard let rawPath = spec.metadata[key], !replacementPaths.contains(rawPath) else { continue }
            let fileURL = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard fileURL.path.hasPrefix(cacheRoot) else {
                log("[BILI_CACHE] 拒绝清理缓存目录之外的路径")
                continue
            }
            do {
                try FileManager.default.removeItem(at: fileURL)
                log("[BILI_CACHE] 已清理临时文件 reason=\(reason)")
            } catch where (error as NSError).code == NSFileNoSuchFileError {
                continue
            } catch {
                log("[BILI_CACHE] 清理临时文件失败 reason=\(reason) error=\(error.localizedDescription)")
            }
        }
    }

    func cleanupDrivePlaybackIfNeeded(spec: PlaySpec?) {
        releaseLocalStreamRelayIfNeeded(spec: spec, reason: "playback-closed")
        releaseBiliPlaybackCacheIfNeeded(spec: spec, reason: "playback-closed")
        guard let cleanup = spec?.drivePlaybackPlan?.cleanup,
              cleanup.isTemporary,
              UserPreferences.shared.cloudDriveAutoDeleteSavedFiles(providerID: cleanup.provider.rawValue) else {
            return
        }

        let provider = cleanup.provider
        let cacheKey = cleanup.cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let driveID = cleanup.driveID.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileID = cleanup.fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileID.isEmpty else {
            log("[DRIVE_CLEANUP] 跳过自动删除，\(provider.displayName)临时文件缺少文件 ID")
            return
        }

        let cleanupIdentity = cacheKey.isEmpty ? "\(driveID):\(fileID)" : cacheKey
        let cleanupKey = "\(provider.rawValue):\(cleanupIdentity)"
        guard !driveCleanupInFlight.contains(cleanupKey) else { return }
        guard let credential = Self.cloudCredential(for: provider) else {
            log("[DRIVE_CLEANUP] 跳过自动删除，\(provider.displayName)授权为空 fileID=\(fileID)")
            return
        }
        let adapter = DrivePlaybackProviderAdapters.adapter(for: provider)

        driveCleanupInFlight.insert(cleanupKey)
        Task { [weak self] in
            guard let self else { return }
            defer { self.driveCleanupInFlight.remove(cleanupKey) }
            do {
                if let updated = try await adapter.cleanupTemporaryFile(
                    cleanup,
                    credential: credential
                ) {
                    self.persistCloudCredential(updated)
                }
                self.log("[DRIVE_CLEANUP] 已清理\(provider.displayName)临时转存文件 fileID=\(fileID)")
            } catch {
                self.log("[DRIVE_CLEANUP] 清理\(provider.displayName)临时转存文件失败 fileID=\(fileID), error=\(error.localizedDescription)")
            }
        }
    }

    private func persistCloudCredential(_ credential: CloudCredential) {
        switch credential.provider {
        case .quark:
            UserPreferences.shared.quarkCookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        case .uc:
            UserPreferences.shared.ucCookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        case .ali:
            persistAliCredential(credential)
        case .p115:
            UserPreferences.shared.p115Cookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        case .pikpak:
            UserPreferences.shared.pikpakAccessToken = credential.accessToken ?? credential.secret
            UserPreferences.shared.pikpakRefreshToken = credential.refreshToken ?? ""
            UserPreferences.shared.pikpakDeviceID = credential.deviceID ?? ""
        case .baidu:
            UserPreferences.shared.baiduCookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            break
        }
    }

    private func persistAliCredential(_ credential: CloudCredential) {
        if let refreshToken = credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refreshToken.isEmpty {
            UserPreferences.shared.aliRefreshToken = refreshToken
        }
        if let accessToken = credential.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accessToken.isEmpty {
            UserPreferences.shared.aliAccessToken = accessToken
        }
        if let openToken = credential.metadata["open_token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !openToken.isEmpty {
            UserPreferences.shared.aliOpenToken = openToken
        }
        if let defaultDriveID = credential.metadata["default_drive_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !defaultDriveID.isEmpty {
            UserPreferences.shared.aliDefaultDriveID = defaultDriveID
        }
        if let authDomain = credential.metadata["ali_auth_domain"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !authDomain.isEmpty {
            UserPreferences.shared.aliAuthDomain = authDomain
        }
        if let userID = credential.metadata["user_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            UserPreferences.shared.aliUserID = userID
        }
    }

    private func proxiedPlaySpec(_ spec: PlaySpec, logContext: String, livePlayback: Bool = false) async -> PlaySpec {
        guard spec.url.hasPrefix("http") else { return spec }
        if spec.format.lowercased() == ProviderPlaybackFormat.biliProgressiveMP4,
           let relayURL = LiveHLSRelayPolicy.localRelayURL(
               for: spec.url,
               headers: spec.headers,
               proxyPort: ProxyServer.shared.port,
               streaming: true
           ) {
            var relaySpec = spec
            relaySpec.url = relayURL
            relaySpec.format = "mp4"
            relaySpec.mpvOptions.removeValue(forKey: "http-proxy")
            self.log("[\(logContext)] B站合并 MP4 使用本地流式代理: \(redactedPlaybackURL(relayURL))")
            return relaySpec
        }
        let relayMode: RemoteStreamRelayMode = PlaybackProxyPolicy.shouldUseChunkedRangeRelay(
            for: spec,
            enabled: UserPreferences.shared.chunkedRangeRelayEnabled
        ) ? .chunked : .buffered
        if (relayMode == .chunked || PlaybackProxyPolicy.shouldUseRemoteStreamProxy(for: spec)),
           let streamSpec = LiveHLSRelayPolicy.localStreamRelaySpec(from: spec, relayMode: relayMode) {
            let providerLabel = driveProviderLabel(for: spec)
            let modeLabel = relayMode == .chunked ? "分片 Range" : "缓冲"
            self.log("[\(logContext)] \(providerLabel)原文件使用本地\(modeLabel)流代理: \(redactedPlaybackURL(streamSpec.url)) -> \(redactedPlaybackURL(spec.url))")
            return streamSpec
        }

        if PlaybackProxyPolicy.shouldProxyDriveTranscodeHLS(for: spec),
           let relaySpec = LiveHLSRelayPolicy.localRelaySpec(from: spec, proxyPort: ProxyServer.shared.port) {
            let providerLabel = driveProviderLabel(for: spec)
            self.log("[\(logContext)] \(providerLabel)转码 HLS 使用本地代理: \(redactedPlaybackURL(relaySpec.url)) -> \(redactedPlaybackURL(spec.url))")
            return relaySpec
        }

        if PlaybackProxyPolicy.shouldUseLocalHLSProxy(for: spec),
           let relayURL = LiveHLSRelayPolicy.localRelayURL(for: spec.url, headers: spec.headers, proxyPort: ProxyServer.shared.port) {
            var relaySpec = spec
            relaySpec.url = relayURL
            relaySpec.mpvOptions.removeValue(forKey: "http-proxy")
            relaySpec.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.localRelayTransport
            self.log("[\(logContext)] HLS 使用本地播放列表代理: \(redactedPlaybackURL(relayURL)) -> \(redactedPlaybackURL(spec.url))")
            return relaySpec
        }

        if let reason = PlaybackProxyPolicy.bypassReason(for: spec) {
            var directSpec = spec
            directSpec.headers = PlaybackProxyPolicy.headersForDirectPlayback(spec.headers, reason: reason)
            let proxyOptions: [String: String]
            if livePlayback {
                proxyOptions = PlaybackProxyPolicy.mpvOptionsForLivePlayback(
                    reason: reason,
                    proxyMode: UserPreferences.shared.proxyMode,
                    customProxyPort: UserPreferences.shared.customProxyPort,
                    existingStreamLavfOptions: directSpec.mpvOptions["stream-lavf-o"]
                )
            } else {
                let activeProxyPort = await ProxyDetector.shared.detectActiveProxy()
                proxyOptions = PlaybackProxyPolicy.mpvOptionsForDirectPlayback(reason: reason, activeProxyPort: activeProxyPort)
            }
            directSpec.mpvOptions.merge(proxyOptions) { _, new in new }
            let reasonLabel = livePlayback && reason == .directHLS ? "direct-live-hls" : reason.rawValue
            if let httpProxy = proxyOptions["http-proxy"] {
                self.log("[\(logContext)] 跳过本地代理(\(reasonLabel))，交给 mpv 直连处理，并使用显式网络代理 \(httpProxy): \(redactedPlaybackURL(spec.url))")
            } else if livePlayback {
                self.log("[\(logContext)] 跳过本地代理(\(reasonLabel))，直播默认直连 mpv，不使用自动探测代理: \(redactedPlaybackURL(spec.url))")
            } else {
                self.log("[\(logContext)] 跳过本地代理(\(reasonLabel))，交给 mpv 直连处理: \(redactedPlaybackURL(spec.url))")
            }
            return directSpec
        }

        guard let proxyURL = LiveHLSRelayPolicy.localRelayURL(
            for: spec.url,
            headers: spec.headers,
            proxyPort: ProxyServer.shared.port,
            streaming: true
        ) else { return spec }

        var proxied = spec
        proxied.url = proxyURL
        self.log("[\(logContext)] 重写播放地址为本地代理: \(redactedPlaybackURL(proxyURL))")
        return proxied
    }

    // MARK: - 直播核心逻辑

    func presentLivePlayer() {
        isLivePlayerPresented = true
        livePlayerOpenRequestSerial &+= 1
    }

    func activateLivePlayerWindow() async {
        isLivePlayerPresented = true
        guard isConfigLoaded else { return }
        if channelGroups.isEmpty {
            _ = await loadLiveContentAndResumeIfNeeded()
        } else {
            await resumeSelectedLiveChannelIfNeeded()
        }
    }

    func dismissLivePlayer() {
        isLivePlayerPresented = false
        beginLivePlaybackSession(attempts: [])
    }

    func cancelLivePlaybackAttempts() {
        beginLivePlaybackSession(attempts: [])
    }

    /// 切换直播配置源
    func changeLive(_ live: Live) async {
        LiveConfig.shared.setCurrent(live)
        self.activeLive = live
        UserPreferences.shared.currentLiveName = live.name
        self.channelGroups = []
        self.selectedGroup = nil
        self.selectedChannel = nil
        self.liveContentLoadedAt = nil
        self.liveEpgData = nil
        self.liveEpgError = nil
        
        await loadLiveContentAndResumeIfNeeded()
    }

    /// 加载当前直播配置的频道列表
    @discardableResult
    func loadLiveContent() async -> Bool {
        guard let live = activeLive, !isLoadingLive else { return false }
        self.isLoadingLive = true
        defer { self.isLoadingLive = false }
        
        do {
            let url = live.url
            guard !url.isEmpty else { return false }
            
            var text: String
            if url.hasPrefix("http") {
                let response = try await liveHTTPClient.get(url: url)
                text = response.text
                if LiveParser.parse(text: text).isEmpty {
                    log(
                        "[LIVE_CONTENT_REFRESH_RETRY] source=\(live.name) "
                            + "status=\(response.statusCode) bytes=\(response.data.count) reason=empty channel list"
                    )
                    let retryResponse = try await liveHTTPClient.get(
                        url: url,
                        headers: [
                            "Cache-Control": "no-cache",
                            "Pragma": "no-cache",
                        ]
                    )
                    text = retryResponse.text
                }
            } else {
                if FileManager.default.fileExists(atPath: url) {
                    text = try String(contentsOfFile: url, encoding: .utf8)
                } else {
                    text = ""
                }
            }
            
            let groups = LiveParser.parse(text: text).map { $0.applying(live: live) }
            guard !groups.isEmpty else {
                log("[LIVE_CONTENT_REFRESH_FAILED] source=\(live.name) reason=empty channel list")
                return false
            }
            self.channelGroups = groups
            restoreLiveSelection(groups: groups)
            self.liveContentLoadedAt = Date()
            log("[LIVE_CONTENT_REFRESHED] source=\(live.name) groups=\(groups.count)")
            return true
        } catch {
            log("[LIVE_CONTENT_REFRESH_FAILED] source=\(live.name) error=\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func loadLiveContentAndResumeIfNeeded() async -> Bool {
        guard await loadLiveContent() else { return false }
        guard isLivePlayerPresented else { return true }
        await resumeSelectedLiveChannelIfNeeded()
        return true
    }

    /// 加载直播频道当天 EPG，仅用于 UI 展示，不影响播放链路。
    func loadLiveEpg(for channel: Channel, forceRefresh: Bool = false) async {
        let template = channel.epg.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelKey = liveEpgChannelKey(for: channel)
        let date = liveEpgDateString()
        let requestKey = "\(template)|\(channelKey)|\(date)"
        let keepExistingData = forceRefresh && liveEpgRequestKey == requestKey && liveEpgData != nil

        liveEpgTask?.cancel()
        liveEpgRequestKey = requestKey
        if !keepExistingData {
            liveEpgData = nil
        }
        liveEpgError = nil

        guard !template.isEmpty else {
            liveEpgTask = nil
            isLoadingLiveEpg = false
            liveEpgData = EpgData(channelName: channel.name)
            return
        }

        isLoadingLiveEpg = true
        let task = Task {
            await EpgParser.fetch(
                apiTemplate: template,
                channelId: channelKey,
                date: date,
                timeout: 5,
                bypassCache: forceRefresh
            )
        }
        liveEpgTask = task

        let data = await task.value
        guard liveEpgRequestKey == requestKey else { return }
        liveEpgTask = nil
        isLoadingLiveEpg = false
        liveEpgData = data
        if data.items.isEmpty {
            liveEpgError = nil
        }
    }

    /// 播放直播频道
    func playChannel(_ channel: Channel) async {
        self.selectedChannel = channel
        self.currentChannelUrlIndex = 0
        persistLiveSelection(channel: channel, urlIndex: 0)
        beginLivePlaybackSession(
            attempts: LivePlaybackPlanner.attempts(
                startingFrom: channel,
                selectedGroup: selectedGroup,
                preferredIndex: 0,
                maxChannels: 1
            )
        )

        MPVPlayerEngine.live.stop()
        self.liveError = nil
        self.livePlayerState.errorMessage = nil

        if await playNextLiveAttempt(sessionID: livePlaybackSessionID, logContext: "playChannel") {
            return
        }

        let message = self.liveError ?? "Live: \(channel.name) 没有可用线路，请尝试切换直播源"
        self.liveError = message
        self.livePlayerState.errorMessage = message
        self.log("[playChannel] \(message)")
    }

    /// 直播换源播放
    func changeChannelUrlIndex(_ index: Int) async {
        guard let channel = selectedChannel, index >= 0 && index < channel.urls.count else { return }
        self.currentChannelUrlIndex = index
        persistLiveSelection(channel: channel, urlIndex: index)
        beginLivePlaybackSession(
            attempts: LivePlaybackPlanner.attempts(
                startingFrom: channel,
                selectedGroup: selectedGroup,
                preferredIndex: index,
                maxChannels: 1
            )
        )
        
        MPVPlayerEngine.live.stop()
        self.liveError = nil
        self.livePlayerState.errorMessage = nil

        if await playNextLiveAttempt(sessionID: livePlaybackSessionID, logContext: "changeChannelUrlIndex") {
            return
        }

        let message = self.liveError ?? "Live: \(channel.name) 线路\(index + 1) 不可用，请尝试其它线路或直播源"
        self.liveError = message
        self.livePlayerState.errorMessage = message
        self.log("[changeChannelUrlIndex] \(message)")
    }

    /// 进入直播页时恢复上次选中的频道播放。配置加载只恢复 selection，不应让 UI 停在黑屏。
    func resumeSelectedLiveChannelIfNeeded() async {
        guard !isLoadingLive else { return }

        if LiveContentRefreshPolicy.shouldRefresh(
            sourceURL: activeLive?.url ?? "",
            groupsAreEmpty: channelGroups.isEmpty,
            loadedAt: liveContentLoadedAt
        ) {
            log("[LIVE_CONTENT_REFRESH] reason=resume source=\(activeLive?.name ?? "live")")
            _ = await loadLiveContent()
        }
        guard !Task.isCancelled else { return }

        guard var channel = selectedChannel else { return }
        guard !channel.urls.isEmpty else {
            let message = "Live: \(channel.name) 没有可用线路，请切换频道"
            liveError = message
            livePlayerState.errorMessage = message
            return
        }

        let preferredIndex = min(max(currentChannelUrlIndex, 0), channel.urls.count - 1)
        channel.currentUrlIndex = preferredIndex
        selectedChannel = channel
        currentChannelUrlIndex = preferredIndex

        guard !isActiveLivePlayback(channel: channel, urlIndex: preferredIndex) else {
            return
        }

        log("[LIVE_RESUME_SELECTED] channel=\(channel.name) urlIndex=\(preferredIndex)")
        guard !Task.isCancelled else { return }
        await changeChannelUrlIndex(preferredIndex)
    }

    private func isActiveLivePlayback(channel: Channel, urlIndex: Int) -> Bool {
        guard let spec = livePlayerState.currentSpec,
              spec.metadata["playback.kind"] == "live",
              spec.metadata["live.channelName"] == channel.name,
              spec.metadata["live.urlIndex"] == "\(urlIndex)" else {
            return false
        }

        switch MPVPlayerEngine.live.status {
        case .loading, .playing, .paused:
            return true
        case .idle, .error:
            return false
        }
    }

    private func beginLivePlaybackSession(attempts: [LivePlaybackAttempt]) {
        liveFallbackTask?.cancel()
        liveFallbackTask = nil
        livePendingFailureTask?.cancel()
        livePendingFailureTask = nil
        livePlaybackSessionID = UUID()
        livePlaybackLoadingID = nil
        isLivePlaybackLoading = false
        livePlaybackLoadingMessage = "正在检查当前频道线路，请稍候。"
        liveExpiredAddressRefreshSessionID = nil
        liveFallbackAttempts = attempts
        liveFallbackNextIndex = 0
    }

    private func playNextLiveAttempt(sessionID: UUID, logContext: String) async -> Bool {
        guard Self.shouldContinueLivePlayback(
            sessionID: sessionID,
            currentSessionID: livePlaybackSessionID,
            isLivePlayerPresented: isLivePlayerPresented
        ) else { return false }

        let loadingID = UUID()
        livePlaybackLoadingID = loadingID
        isLivePlaybackLoading = true
        livePlaybackLoadingMessage = "正在检查当前频道线路，请稍候。"
        defer {
            if livePlaybackLoadingID == loadingID {
                livePlaybackLoadingID = nil
                isLivePlaybackLoading = false
                livePlaybackLoadingMessage = "正在检查当前频道线路，请稍候。"
            }
        }

        var lastMessage: String?
        while Self.shouldContinueLivePlayback(
            sessionID: sessionID,
            currentSessionID: livePlaybackSessionID,
            isLivePlayerPresented: isLivePlayerPresented
        ) && liveFallbackNextIndex < liveFallbackAttempts.count {
            let attemptIndex = liveFallbackNextIndex
            let attempt = liveFallbackAttempts[attemptIndex]
            liveFallbackNextIndex += 1
            livePlaybackLoadingMessage = "正在检查 \(attempt.channel.name) 线路 \(attempt.urlIndex + 1)。"
            let result = await playLiveURL(
                channel: attempt.channel,
                url: attempt.url,
                urlIndex: attempt.urlIndex,
                sessionID: sessionID,
                attemptIndex: attemptIndex,
                logContext: logContext
            )
            if result == .started {
                return true
            }
            lastMessage = liveError
            if result == .expiredAddress,
               await refreshExpiredLiveContent(
                    staleChannel: attempt.channel,
                    preferredURLIndex: attempt.urlIndex,
                    sessionID: sessionID,
                    logContext: logContext
               ) {
                continue
            }
        }

        guard Self.shouldContinueLivePlayback(
            sessionID: sessionID,
            currentSessionID: livePlaybackSessionID,
            isLivePlayerPresented: isLivePlayerPresented
        ) else { return false }
        liveError = lastMessage ?? "Live: 没有可用线路，请尝试切换直播源"
        return false
    }

    private func refreshExpiredLiveContent(
        staleChannel: Channel,
        preferredURLIndex: Int,
        sessionID: UUID,
        logContext: String
    ) async -> Bool {
        guard liveExpiredAddressRefreshSessionID != sessionID else {
            log("[LIVE_CONTENT_REFRESH_SKIPPED] reason=already-attempted session=\(sessionID)")
            return false
        }
        guard Self.shouldContinueLivePlayback(
            sessionID: sessionID,
            currentSessionID: livePlaybackSessionID,
            isLivePlayerPresented: isLivePlayerPresented
        ) else { return false }

        liveExpiredAddressRefreshSessionID = sessionID
        let groupName = sourceGroup(forLiveChannel: staleChannel)?.name ?? selectedGroup?.name ?? ""
        let selectionKey = LiveChannelSelectionKey(groupName: groupName, channel: staleChannel)
        let maximumChannels = max(1, Set(liveFallbackAttempts.map { $0.channel.id }).count)
        log("[LIVE_CONTENT_REFRESH] reason=expired-address channel=\(staleChannel.name) context=\(logContext)")

        guard await loadLiveContent(),
              Self.shouldContinueLivePlayback(
                sessionID: sessionID,
                currentSessionID: livePlaybackSessionID,
                isLivePlayerPresented: isLivePlayerPresented
              ),
              let refreshed = LiveContentRefreshPolicy.matchingSelection(
                for: selectionKey,
                in: channelGroups
              ) else {
            log("[LIVE_CONTENT_RECOVERY_FAILED] channel=\(staleChannel.name)")
            return false
        }

        var refreshedChannel = refreshed.channel
        let refreshedIndex = min(max(preferredURLIndex, 0), max(refreshedChannel.urls.count - 1, 0))
        refreshedChannel.currentUrlIndex = refreshedIndex
        selectedGroup = refreshed.group
        selectedChannel = refreshedChannel
        currentChannelUrlIndex = refreshedIndex
        persistLiveSelection(channel: refreshedChannel, urlIndex: refreshedIndex)
        liveFallbackAttempts = LivePlaybackPlanner.attempts(
            startingFrom: refreshedChannel,
            selectedGroup: refreshed.group,
            preferredIndex: refreshedIndex,
            maxChannels: maximumChannels
        )
        liveFallbackNextIndex = 0
        liveError = nil
        livePlayerState.errorMessage = nil
        log("[LIVE_CONTENT_RECOVERY_READY] channel=\(refreshedChannel.name) attempts=\(liveFallbackAttempts.count)")
        return !liveFallbackAttempts.isEmpty
    }

    static func shouldContinueLivePlayback(
        sessionID: UUID,
        currentSessionID: UUID,
        isLivePlayerPresented: Bool
    ) -> Bool {
        isLivePlayerPresented && sessionID == currentSessionID
    }

    private func playLiveURL(channel: Channel, url: String, urlIndex: Int, sessionID: UUID, attemptIndex: Int, logContext: String) async -> LivePlaybackAttemptResult {
        do {
            var spec = try await normalizedLivePlaySpec(channel: channel, url: url, logContext: logContext)
            guard Self.shouldContinueLivePlayback(
                sessionID: sessionID,
                currentSessionID: livePlaybackSessionID,
                isLivePlayerPresented: isLivePlayerPresented
            ) else { return .failed }
            let probeStart = Date()
            livePlaybackLoadingMessage = "正在探测 \(channel.name) 线路 \(urlIndex + 1)。"
            let probe = await livePlaybackProbe.probe(spec: spec)
            guard Self.shouldContinueLivePlayback(
                sessionID: sessionID,
                currentSessionID: livePlaybackSessionID,
                isLivePlayerPresented: isLivePlayerPresented
            ) else { return .failed }
            let probeDurationMs = durationMilliseconds(since: probeStart)
            logLiveProbe(channel: channel, urlIndex: urlIndex, result: probe)
            recordLiveLineHealth(channel: channel, url: url, result: probe, durationMs: probeDurationMs)
            if LiveContentRefreshPolicy.shouldRefresh(after: probe) {
                liveError = "Live: \(channel.name) 线路\(urlIndex + 1) 的签名/鉴权已失效，正在刷新频道列表"
                self.log("[\(logContext)] 直播地址可能已过期，刷新频道列表后重试: channel=\(channel.name) status=\(probe.statusCode)")
                return .expiredAddress
            }
            if LiveHLSRelayPolicy.shouldSkipDirectPlaybackForProbe(
                isPlayable: probe.isPlayable,
                statusCode: probe.statusCode,
                bodyPrefix: probe.bodyPrefix
            ) {
                let hasMoreAttempts = attemptIndex + 1 < liveFallbackAttempts.count
                liveError = liveProbeFailureMessage(
                    channel: channel.name,
                    urlIndex: urlIndex,
                    statusCode: probe.statusCode,
                    hasMoreAttempts: hasMoreAttempts
                )
                self.log("[\(logContext)] 直播上游确定性失败，跳过播放器尝试: channel=\(channel.name) status=\(probe.statusCode)")
                return .failed
            }
            if !probe.isPlayable {
                self.log("[\(logContext)] 直播探测失败但继续交给播放器尝试: channel=\(channel.name) message=\(probe.message)")
            }

            spec.metadata["playback.kind"] = "live"
            spec.metadata["live.sessionID"] = sessionID.uuidString
            spec.metadata["live.attemptIndex"] = "\(attemptIndex)"
            spec.metadata["live.channelName"] = channel.name
            spec.metadata["live.urlIndex"] = "\(urlIndex)"
            let bypassReason = PlaybackProxyPolicy.bypassReason(for: spec)
            if bypassReason == .directHLS {
                spec.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.directTransport
                spec.metadata[LiveHLSRelayPolicy.probePlayableMetadataKey] = probe.isPlayable ? "true" : "false"
            } else if bypassReason == .directMedia {
                spec.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.directMediaTransport
                spec.metadata[LiveHLSRelayPolicy.probePlayableMetadataKey] = probe.isPlayable ? "true" : "false"
            }
            spec = await proxiedPlaySpec(spec, logContext: logContext, livePlayback: true)
            guard Self.shouldContinueLivePlayback(
                sessionID: sessionID,
                currentSessionID: livePlaybackSessionID,
                isLivePlayerPresented: isLivePlayerPresented
            ) else { return .failed }
            if let transport = spec.metadata[LiveHLSRelayPolicy.transportMetadataKey] {
                self.log("[LIVE_TRANSPORT] channel=\(channel.name) urlIndex=\(urlIndex) transport=\(transport) probe=\(probe.isPlayable)")
            }
            var updatedChannel = channel
            updatedChannel.currentUrlIndex = urlIndex
            self.selectedChannel = updatedChannel
            self.currentChannelUrlIndex = urlIndex
            self.liveError = nil
            persistLiveSelection(channel: updatedChannel, urlIndex: urlIndex)
            Task { await self.loadLiveEpg(for: updatedChannel) }
            livePlaybackLoadingMessage = "线路已就绪，正在启动播放器。"
            await play(spec: spec)
            return .started
        } catch {
            guard Self.shouldContinueLivePlayback(
                sessionID: sessionID,
                currentSessionID: livePlaybackSessionID,
                isLivePlayerPresented: isLivePlayerPresented
            ) else { return .failed }
            liveError = "Live: \(channel.name) 线路\(urlIndex + 1) 预处理失败: \(error.localizedDescription)"
            self.log("[\(logContext)] 直播播放预处理失败: \(error.localizedDescription)")
            return .failed
        }
    }

    private func liveProbeFailureMessage(channel: String, urlIndex: Int, statusCode: Int, hasMoreAttempts: Bool) -> String {
        if hasMoreAttempts {
            return "Live: \(channel) 线路\(urlIndex + 1) 上游返回 HTTP \(statusCode)，正在尝试下一线路"
        }
        return "Live: \(channel) 线路\(urlIndex + 1) 上游返回 HTTP \(statusCode)，请尝试其它线路或直播源"
    }

    private func driveProviderLabel(for spec: PlaySpec) -> String {
        spec.drivePlaybackPlan?.provider.displayName
            ?? DriveProvider(rawValue: spec.metadata[DrivePlaybackMetadataKey.provider] ?? "")?.displayName
            ?? "网盘"
    }

    func handleMPVPlaybackFailure(spec: PlaySpec?, message: String) {
        lastFeedbackFailureStage = "Player.mpv"
        lastFeedbackFailureCategory = spec?.metadata["playback.kind"] == "live" ? .live : .player
        if let spec, spec.metadata["playback.kind"] != "live" {
            recordSiteHealth(
                eventType: .play,
                siteKey: spec.siteKey,
                siteName: siteName(for: spec.siteKey),
                success: false,
                errorCategory: .player,
                host: spec.url
            )
        }

        if let spec,
           spec.metadata["playback.kind"] != "live",
           spec.drivePlaybackPlan != nil {
            handleDrivePlaybackFailure(spec: spec, message: message)
            return
        }

        if let spec,
           spec.metadata["playback.kind"] != "live",
           switchToVodLineFallback(from: spec) {
            return
        }

        guard let spec,
              spec.metadata["playback.kind"] == "live",
              spec.metadata["live.sessionID"] == livePlaybackSessionID.uuidString else {
            return
        }

        let channelName = spec.metadata["live.channelName"] ?? selectedChannel?.name ?? "直播频道"
        log("[LIVE_MPV_FAILURE] channel=\(channelName) attempt=\(spec.metadata["live.attemptIndex"] ?? "-") message=\(message)")

        livePendingFailureTask?.cancel()
        let sessionID = livePlaybackSessionID
        livePendingFailureTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.livePendingFailureTask = nil
            guard self.isCurrentLivePlaybackSpec(spec, sessionID: sessionID) else {
                self.log("[LIVE_MPV_FAILURE_IGNORED] stale failure ignored for channel=\(channelName)")
                return
            }
            self.processConfirmedMPVPlaybackFailure(spec: spec, message: message)
        }
    }

    private func handleDrivePlaybackFailure(spec: PlaySpec, message: String) {
        processDrivePlaybackTransition(
            drivePlaybackSessionController.requestFailure(for: spec, message: message),
            failedSpec: spec,
            message: message
        )
    }

    private func processDrivePlaybackTransition(
        _ outcome: DrivePlaybackTransitionOutcome,
        failedSpec spec: PlaySpec,
        message: String
    ) {
        let provider = spec.drivePlaybackPlan?.provider ?? .unknown
        switch outcome {
        case .started(let candidate):
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                let failedCandidateID = DrivePlaybackRoutePolicy.candidate(for: spec)?.id
                let nextSpec: PlaySpec
                if candidate.id == failedCandidateID {
                    guard let refreshed = await self.refreshedDrivePlaybackSpec(
                        from: spec,
                        candidateID: candidate.id
                    ) else {
                        guard !Task.isCancelled else { return }
                        self.processDrivePlaybackTransition(
                            self.drivePlaybackSessionController.requestRefreshFailure(for: spec),
                            failedSpec: spec,
                            message: message
                        )
                        return
                    }
                    nextSpec = refreshed
                } else {
                    nextSpec = DrivePlaybackRoutePolicy.spec(
                        for: candidate,
                        basedOn: spec,
                        manualSelection: false
                    )
                }
                guard !Task.isCancelled else { return }
                let routeTitle = DrivePlaybackRoutePolicy.title(for: nextSpec) ?? provider.displayName
                let quality = candidate.quality.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let qualitySuffix = quality.isEmpty ? "" : "（\(quality)）"
                _ = await self.beginDrivePlaybackRouteSwitch(
                    to: nextSpec,
                    routeTitle: routeTitle,
                    positionSeconds: self.playerState.position,
                    reason: candidate.id == failedCandidateID
                        ? "\(provider.displayName)线路失效，刷新后重试"
                        : "\(provider.displayName)当前线路播放失败",
                    successMessage: candidate.id == failedCandidateID
                        ? "已刷新“\(routeTitle)”线路并恢复播放。"
                        : "已自动降级到“\(routeTitle)”线路\(qualitySuffix)，以保持播放流畅。",
                    logContext: candidate.id == failedCandidateID
                        ? "DRIVE_PLAYBACK_ROUTE_RECOVERY"
                        : "DRIVE_PLAYBACK_DOWNGRADE"
                )
            }
        case .coalesced:
            log("[DRIVE_PLAYBACK_FAILURE_COALESCED] provider=\(provider.rawValue) message=\(message)")
        case .stale:
            log("[DRIVE_PLAYBACK_FAILURE_STALE] provider=\(provider.rawValue) message=\(message)")
        case .exhausted:
            if !switchToVodLineFallback(from: spec) {
                presentDrivePlaybackTerminalError(for: spec)
            }
        }
    }

    private func refreshedDrivePlaybackSpec(from spec: PlaySpec, candidateID: String) async -> PlaySpec? {
        guard let sourceURL = spec.metadata["vod.episodeURL"], !sourceURL.isEmpty else { return nil }
        do {
            var refreshed: PlaySpec
            if let drivePlaybackSourceRefreshHandler {
                refreshed = try await drivePlaybackSourceRefreshHandler(spec, sourceURL)
            } else {
                let result = try await SourceManager.shared.fetchResult(url: sourceURL)
                refreshed = spec
                refreshed.url = result.url
                refreshed.headers = result.headers
                refreshed.fallbackHeaders = result.fallbackHeaders
                refreshed.mpvOptions = result.mpvOptions
                refreshed.metadata.merge(result.metadata) { _, new in new }
                refreshed.drivePlaybackPlan = result.drivePlaybackPlan
            }
            guard let plan = refreshed.drivePlaybackPlan,
                  let candidate = plan.candidates.first(where: { $0.id == candidateID }),
                  drivePlaybackSessionController.replacePlan(
                    plan,
                    generation: spec.drivePlaybackSessionGeneration
                  ) else {
                return nil
            }
            refreshed.drivePlaybackSessionGeneration = spec.drivePlaybackSessionGeneration
            log("[DRIVE_PLAYBACK_ROUTE_REFRESH] provider=\(plan.provider.rawValue) candidate=\(candidate.id)")
            return DrivePlaybackRoutePolicy.spec(
                for: candidate,
                basedOn: refreshed,
                manualSelection: DrivePlaybackRoutePolicy.isManualSelection(spec)
            )
        } catch {
            log("[DRIVE_PLAYBACK_ROUTE_REFRESH_FAILED] provider=\(spec.drivePlaybackPlan?.provider.rawValue ?? "unknown") reason=\(error.localizedDescription)")
            return nil
        }
    }

    private func switchToVodLineFallback(from spec: PlaySpec) -> Bool {
        guard vodLineFallbackTask == nil,
              let currentSpec = playerState.currentSpec,
              currentSpec.url == spec.url,
              let site = activeSite,
              let detail = detailVod,
              let target = VodLineFallbackPolicy.target(site: site, detail: detail, failedSpec: spec) else {
            return false
        }

        let resumePosition = playerState.position >= 1 ? Int64(playerState.position) : nil
        let resumeDuration = playerState.duration >= 1 ? Int64(playerState.duration) : nil
        playerState.errorMessage = nil
        isPlaybackErrorPresented = false
        selectPlayFlag(target.flag)
        log("[VOD_LINE_FALLBACK] flag=\(spec.flag) -> \(target.flag) episode=\(target.episode.name) position=\(resumePosition ?? 0)")

        vodLineFallbackTask = Task { @MainActor in
            defer { self.vodLineFallbackTask = nil }
            await self.playEpisode(
                target.episode,
                resumePosition: resumePosition,
                resumeDuration: resumeDuration,
                automaticSelection: true,
                lineFallbackApplied: true
            )
        }
        return true
    }

    func handleMPVPlaybackStall(spec: PlaySpec?, positionSeconds _: Double) {
        if let spec,
           spec.metadata["playback.kind"] != "live",
           let plan = spec.drivePlaybackPlan,
           !DrivePlaybackRoutePolicy.isManualSelection(spec) {
            drivePlaybackStallTask?.cancel()
            drivePlaybackStallGeneration &+= 1
            let generation = drivePlaybackStallGeneration
            drivePlaybackStallSpecURL = spec.url
            drivePlaybackStallTask = Task { @MainActor in
                defer {
                    if self.drivePlaybackStallGeneration == generation {
                        self.drivePlaybackStallTask = nil
                        self.drivePlaybackStallSpecURL = nil
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled,
                      self.drivePlaybackStallGeneration == generation,
                      self.playerState.isBuffering else {
                    return
                }
                self.handleDrivePlaybackFailure(
                    spec: spec,
                    message: "\(plan.provider.displayName)播放缓存停滞"
                )
            }
            return
        }

    }

    func handleMPVPlaybackStallRecovery(spec: PlaySpec?) {
        guard let spec, drivePlaybackStallSpecURL == spec.url else { return }
        drivePlaybackStallGeneration &+= 1
        drivePlaybackStallTask?.cancel()
        drivePlaybackStallTask = nil
        drivePlaybackStallSpecURL = nil
        log("[DRIVE_PLAYBACK_DOWNGRADE_ABORT] 缓存已恢复，保留当前线路")
    }

    private func processConfirmedMPVPlaybackFailure(spec: PlaySpec, message: String) {
        let channelName = spec.metadata["live.channelName"] ?? selectedChannel?.name ?? "直播频道"
        let diagnostic = liveMPVFailureMessage(channelName: channelName, message: message, spec: spec)

        guard liveFallbackTask == nil else { return }
        if LiveHLSRelayPolicy.shouldRetryWithLocalRelay(spec: spec, failureMessage: message),
           let relaySpec = LiveHLSRelayPolicy.localRelaySpec(from: spec, proxyPort: ProxyServer.shared.port) {
            liveError = nil
            livePlayerState.errorMessage = nil
            log("[LIVE_RELAY_RETRY] channel=\(channelName) attempt=\(spec.metadata["live.attemptIndex"] ?? "-") url=\(redactedPlaybackURL(spec.url)) relay=\(redactedPlaybackURL(relaySpec.url))")
            let sessionID = livePlaybackSessionID
            liveFallbackTask = Task { @MainActor in
                defer { self.liveFallbackTask = nil }
                guard sessionID == self.livePlaybackSessionID else { return }
                self.log("[LIVE_TRANSPORT] channel=\(channelName) transport=\(LiveHLSRelayPolicy.localRelayTransport)")
                await self.play(spec: relaySpec)
            }
            return
        }
        if LiveHLSRelayPolicy.shouldRetryWithLocalStreamRelay(spec: spec, failureMessage: message),
           let relaySpec = LiveHLSRelayPolicy.localStreamRelaySpec(from: spec) {
            liveError = nil
            livePlayerState.errorMessage = nil
            log("[LIVE_RELAY_RETRY] channel=\(channelName) attempt=\(spec.metadata["live.attemptIndex"] ?? "-") url=\(redactedPlaybackURL(spec.url)) relay=\(redactedPlaybackURL(relaySpec.url))")
            let sessionID = livePlaybackSessionID
            liveFallbackTask = Task { @MainActor in
                defer { self.liveFallbackTask = nil }
                guard sessionID == self.livePlaybackSessionID else { return }
                self.log("[LIVE_TRANSPORT] channel=\(channelName) transport=\(LiveHLSRelayPolicy.localStreamRelayTransport)")
                await self.play(spec: relaySpec)
            }
            return
        }
        if LiveContentRefreshPolicy.shouldRefresh(afterPlaybackFailure: message),
           let staleChannel = selectedChannel {
            let preferredURLIndex = Int(spec.metadata["live.urlIndex"] ?? "") ?? currentChannelUrlIndex
            let sessionID = livePlaybackSessionID
            liveError = nil
            livePlayerState.errorMessage = nil
            liveFallbackTask = Task { @MainActor in
                defer { self.liveFallbackTask = nil }
                guard await self.refreshExpiredLiveContent(
                    staleChannel: staleChannel,
                    preferredURLIndex: preferredURLIndex,
                    sessionID: sessionID,
                    logContext: "liveMPVFailure"
                ) else {
                    self.liveError = diagnostic
                    self.livePlayerState.errorMessage = diagnostic
                    return
                }
                let didStart = await self.playNextLiveAttempt(
                    sessionID: sessionID,
                    logContext: "liveContentRecovery"
                )
                if !didStart {
                    let finalMessage = self.liveError ?? diagnostic
                    self.liveError = finalMessage
                    self.livePlayerState.errorMessage = finalMessage
                }
            }
            return
        }

        guard liveFallbackNextIndex < liveFallbackAttempts.count else {
            liveError = diagnostic
            livePlayerState.errorMessage = diagnostic
            return
        }

        liveError = nil
        livePlayerState.errorMessage = nil
        log("[LIVE_FALLBACK_NEXT] \(diagnostic)，正在尝试下一线路")
        let sessionID = livePlaybackSessionID
        liveFallbackTask = Task { @MainActor in
            defer { self.liveFallbackTask = nil }
            let didStart = await self.playNextLiveAttempt(sessionID: sessionID, logContext: "liveFallback")
            if !didStart {
                let finalMessage = self.liveError ?? diagnostic
                self.liveError = finalMessage
                self.livePlayerState.errorMessage = finalMessage
                self.log("[liveFallback] \(finalMessage)")
            }
        }
    }

    func handleMPVPlaybackStarted(spec: PlaySpec?) {
        if let spec, spec.metadata["playback.kind"] != "live" {
            isPlayerLoading = false
            if spec.drivePlaybackPlan != nil {
                _ = drivePlaybackSessionController.confirmStarted(spec: spec)
            }
            confirmDrivePlaybackRouteStarted(spec: spec)
            recordSiteHealth(
                eventType: .play,
                siteKey: spec.siteKey,
                siteName: siteName(for: spec.siteKey),
                success: true,
                host: spec.url
            )
            let restoredSubtitlePreference = restoreTrackPreferences(for: spec)
            if !restoredSubtitlePreference {
                autoSelectPreferredSubtitleTrack(for: spec)
            }
            attemptPendingPlaybackStart(for: spec)
        }

        guard let spec,
              spec.metadata["playback.kind"] == "live",
              spec.metadata["live.sessionID"] == livePlaybackSessionID.uuidString else {
            return
        }
        livePendingFailureTask?.cancel()
        livePendingFailureTask = nil
        liveFallbackTask?.cancel()
        liveFallbackTask = nil
        liveError = nil
        livePlayerState.errorMessage = nil
        let channelName = spec.metadata["live.channelName"] ?? selectedChannel?.name ?? "直播频道"
        let transport = spec.metadata[LiveHLSRelayPolicy.transportMetadataKey] ?? "live"
        log("[LIVE_PLAYBACK_STARTED] channel=\(channelName) transport=\(transport)")
    }

    var activeDrivePlaybackRouteLabel: String? {
        guard let selectedDrivePlaybackRouteID else { return nil }
        return drivePlaybackRoutes.first(where: { $0.id == selectedDrivePlaybackRouteID })?.title
    }

    @discardableResult
    func configureDrivePlaybackRoutes(for spec: PlaySpec) -> PlaySpec {
        var prepared = DrivePlaybackRoutePolicy.preparedSpec(spec)
        if let plan = prepared.drivePlaybackPlan,
           let candidate = DrivePlaybackRoutePolicy.candidate(for: prepared) {
            prepared.drivePlaybackSessionGeneration = drivePlaybackSessionController.begin(
                plan: plan,
                candidateID: candidate.id
            )
        }
        let options = DrivePlaybackRoutePolicy.options(for: prepared)
        drivePlaybackRoutes = options
        let selectionID = prepared.metadata[DrivePlaybackRoutePolicy.selectionIDMetadataKey]
        selectedDrivePlaybackRouteID = options.contains(where: { $0.id == selectionID })
            ? selectionID
            : nil
        pendingDrivePlaybackRouteID = nil
        pendingDrivePlaybackSuccessMessage = nil
        return prepared
    }

    func selectDrivePlaybackRoute(_ route: DrivePlaybackRouteOption) async {
        guard drivePlaybackRoutes.contains(where: { $0.id == route.id }),
              pendingDrivePlaybackRouteID == nil else {
            return
        }
        let currentRouteID = playerState.currentSpec?.metadata[DrivePlaybackRoutePolicy.selectionIDMetadataKey]
        guard currentRouteID != route.id || playerState.errorMessage != nil else { return }

        if let currentSpec = playerState.currentSpec,
           currentSpec.drivePlaybackPlan != nil {
            switch drivePlaybackSessionController.requestManualTransition(
                to: route.id,
                generation: currentSpec.drivePlaybackSessionGeneration
            ) {
            case .started(let candidate):
                let selectedSpec = DrivePlaybackRoutePolicy.spec(
                    for: candidate,
                    basedOn: currentSpec,
                    manualSelection: true
                )
                _ = await beginDrivePlaybackRouteSwitch(
                    to: selectedSpec,
                    routeTitle: route.title,
                    positionSeconds: max(0, playerState.position),
                    reason: "用户手动选择线路",
                    successMessage: "已切换到“\(route.title)”线路。",
                    logContext: "DRIVE_PLAYBACK_ROUTE"
                )
            case .coalesced, .stale, .exhausted:
                break
            }
            return
        }

    }

    private func beginDrivePlaybackRouteSwitch(
        to sourceSpec: PlaySpec,
        routeTitle: String,
        positionSeconds: Double,
        reason: String,
        successMessage: String,
        logContext: String
    ) async -> DrivePlaybackTransitionOutcome {
        let prepared = DrivePlaybackRoutePolicy.preparedSpec(sourceSpec)
        guard let selectionID = prepared.metadata[DrivePlaybackRoutePolicy.selectionIDMetadataKey],
              let candidate = DrivePlaybackRoutePolicy.candidate(for: prepared) else {
            return .stale
        }
        if let pendingDrivePlaybackRouteID {
            return pendingDrivePlaybackRouteID == selectionID ? .coalesced : .stale
        }

        pendingDrivePlaybackRouteID = selectionID
        pendingDrivePlaybackSuccessMessage = successMessage
        playbackDowngradeMessage = nil
        playerState.errorMessage = nil
        isPlaybackErrorPresented = false
        playerState.drivePlaybackStatus = "正在切换 \(routeTitle)"
        log("[\(logContext)] \(reason)，切换到 \(routeTitle): \(redactedPlaybackURL(prepared.url))")

        let playable = await proxiedPlaySpec(prepared, logContext: logContext)
        let resumeMilliseconds = Int64(max(0, positionSeconds) * 1000)
        let episodeURL = PlaybackResumePolicy.episodeURL(for: prepared)
        let skipSettings = VodSkipSettingsStore.shared.settings(for: prepared.metadata)
        setPendingPlaybackStart(
            resumePosition: resumeMilliseconds > 0 ? resumeMilliseconds : nil,
            episodeURL: episodeURL,
            openingSkipSeconds: skipSettings.openingSeconds
        )
        await play(spec: playable)
        return .started(candidate)
    }

    private func confirmDrivePlaybackRouteStarted(spec: PlaySpec) {
        guard let selectionID = spec.metadata[DrivePlaybackRoutePolicy.selectionIDMetadataKey] else {
            return
        }
        guard let pendingDrivePlaybackRouteID else {
            if drivePlaybackRoutes.contains(where: { $0.id == selectionID }) {
                selectedDrivePlaybackRouteID = selectionID
            }
            return
        }
        guard pendingDrivePlaybackRouteID == selectionID else { return }

        selectedDrivePlaybackRouteID = selectionID
        self.pendingDrivePlaybackRouteID = nil
        playbackDowngradeMessage = pendingDrivePlaybackSuccessMessage
        pendingDrivePlaybackSuccessMessage = nil
        let title = DrivePlaybackRoutePolicy.title(for: spec) ?? selectionID
        log("[DRIVE_PLAYBACK_ROUTE_STARTED] route=\(title)")
    }

    private func resetDrivePlaybackRoutes() {
        drivePlaybackSessionController.cancel()
        drivePlaybackRoutes = []
        selectedDrivePlaybackRouteID = nil
        pendingDrivePlaybackRouteID = nil
        pendingDrivePlaybackSuccessMessage = nil
    }

    private func presentDrivePlaybackTerminalError(for spec: PlaySpec) {
        guard playerState.currentSpec?.drivePlaybackSessionGeneration == spec.drivePlaybackSessionGeneration,
              let plan = spec.drivePlaybackPlan else {
            return
        }
        isPlayerLoading = false
        playerState.isMediaLoading = false
        playbackDowngradeMessage = nil
        pendingDrivePlaybackRouteID = nil
        pendingDrivePlaybackSuccessMessage = nil
        playerState.drivePlaybackStatus = nil
        if plan.reauthenticationRequired {
            playerState.errorMessage = "\(plan.provider.displayName)登录已失效，请重新授权后重试。"
            playbackErrorAuthProvider = plan.provider
            pendingAuthEpisode = episodeForCurrentPlayback(in: episodes)
        } else {
            playerState.errorMessage = "\(plan.provider.displayName)原片和兼容线路均播放失败，请重试或切换来源。"
            playbackErrorAuthProvider = nil
        }
        let route = DrivePlaybackRoutePolicy.candidate(for: spec)?.providerRoute ?? "-"
        log("[DRIVE_PLAYBACK_TERMINAL] provider=\(plan.provider.rawValue) route=\(route)")
    }

    private func play(spec: PlaySpec) async {
        let currentSpec = spec.metadata["playback.kind"] == "live"
            ? livePlayerState.currentSpec
            : playerState.currentSpec
        releaseLocalStreamRelayIfNeeded(
            spec: currentSpec,
            replacingWith: spec,
            reason: "playback-replaced"
        )
        releaseBiliPlaybackCacheIfNeeded(
            spec: currentSpec,
            replacingWith: spec,
            reason: "playback-replaced"
        )
        if spec.metadata["playback.kind"] != "live" {
            refreshDanmakuOverlay(for: spec)
        }
        if let playSpecHandler {
            await playSpecHandler(spec)
        } else {
            let engine = spec.metadata["playback.kind"] == "live"
                ? MPVPlayerEngine.live
                : MPVPlayerEngine.vod
            await engine.play(spec: spec)
        }
    }

    func refreshDanmakuOverlay(for spec: PlaySpec?) {
        guard UserPreferences.shared.danmakuEnabled else {
            currentDanmakuCues = []
            lastDanmakuParseDiagnostic = nil
            lastDanmakuRenderStatus = "弹幕已关闭"
            return
        }
        guard let attachment = spec?.danmakuAttachment else {
            currentDanmakuCues = []
            lastDanmakuParseDiagnostic = nil
            lastDanmakuRenderStatus = "暂无弹幕附件"
            return
        }
        guard let payload = DanmakuEngine.shared.cachedPayload(cacheKey: attachment.trackCacheKey),
              let track = DanmakuEngine.shared.cachedTrack(cacheKey: attachment.trackCacheKey) else {
            currentDanmakuCues = []
            lastDanmakuParseDiagnostic = nil
            playerState.danmakuStatus = "弹幕缓存缺失"
            lastDanmakuRenderStatus = "弹幕缓存缺失"
            return
        }
        let result = DanmakuPayloadParser.parseWithDiagnostic(payload: payload, format: track.format)
        lastDanmakuParseDiagnostic = result.diagnostic
        currentDanmakuCues = result.cues
        let status: String
        if let failure = result.diagnostic.failureCategory {
            status = "弹幕解析失败：\(failure.rawValue)"
        } else if result.cues.isEmpty {
            status = "弹幕解析为空"
        } else if result.diagnostic.truncatedCount > 0 {
            status = "弹幕渲染限流：已加载 \(result.cues.count) 条，截断 \(result.diagnostic.truncatedCount) 条"
        } else {
            status = "弹幕已加载 \(result.cues.count) 条"
        }
        playerState.danmakuStatus = status
        lastDanmakuRenderStatus = status
    }

    func manualSearchDanmakuForCurrentPlayback() async {
        guard UserPreferences.shared.danmakuEnabled else {
            playerState.danmakuStatus = "弹幕已关闭"
            return
        }
        guard var spec = playerState.currentSpec else { return }
        let sourceURL = (spec.danmaku.isEmpty ? (VodConfig.shared.config?.danmaku ?? "") : spec.danmaku)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceURL.isEmpty else {
            playerState.danmakuStatus = "暂无弹幕源"
            return
        }
        let title = spec.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (detailVod?.vodName ?? "")
            : spec.title
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            playerState.danmakuStatus = "缺少弹幕搜索标题"
            return
        }
        playerState.danmakuStatus = "正在手动搜索弹幕..."
        let source = DanmakuSource(
            id: "config-danmaku",
            name: "配置弹幕源",
            apiURL: sourceURL,
            enabled: true,
            parserType: .xml
        )
        let matches = await DanmakuEngine.shared.manualSearch(
            request: DanmakuSearchRequest(title: title, siteKey: spec.siteKey),
            sources: [source]
        )
        guard let match = matches.first else {
            playerState.danmakuStatus = "未找到可用弹幕"
            return
        }
        spec.danmakuAttachment = DanmakuAttachment(
            sourceID: source.id,
            trackCacheKey: match.track.cacheKey,
            offsetMs: UserPreferences.shared.danmakuOffsetMs,
            style: DanmakuAttachmentStyle(
                opacity: UserPreferences.shared.danmakuOpacity,
                fontSize: UserPreferences.shared.danmakuFontSize
            )
        )
        playerState.currentSpec = spec
        refreshDanmakuOverlay(for: spec)
    }

    func playbackDiagnosticLines(for spec: PlaySpec) -> [String] {
        var lines: [String] = []
        func append(_ title: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                lines.append("\(title)：\(trimmed)")
            }
        }
        append("路线", spec.metadata[DrivePlaybackMetadataKey.route])
        if let plan = spec.drivePlaybackPlan {
            append("候选线路", plan.candidates.map(\.providerRoute).joined(separator: " → "))
        }
        append("Relay", spec.metadata["stream.relayMode"])
        append("WebHome", spec.metadata["webhome.method"] ?? lastWebHomeBridgeMethod)
        append("弹幕", lastDanmakuRenderStatus ?? playerState.danmakuStatus)
        if let diagnostic = lastDanmakuParseDiagnostic {
            append("弹幕解析", "format=\(diagnostic.format.rawValue) size=\(diagnostic.rawSizeBytes) parsed=\(diagnostic.parsedCount) returned=\(diagnostic.returnedCount) truncated=\(diagnostic.truncatedCount)")
        }
        let fixture = [
            spec.metadata["drive.fixtureProvider"],
            spec.metadata["drive.fixtureScenario"]
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " / ")
        append("Fixture", fixture.isEmpty ? lastDriveFixtureDiagnostic : fixture)
        append("样本状态", spec.metadata[DrivePlaybackMetadataKey.fixtureStatus] ?? spec.metadata["drive.sampleStatus"])
        append("UC 选择原因", spec.metadata[DrivePlaybackMetadataKey.selectedReason])
        append("UC 候选摘要", spec.metadata[DrivePlaybackMetadataKey.candidateSummary])
        return lines
    }

    private func setPendingPlaybackStart(
        resumePosition: Int64?,
        episodeURL: String,
        openingSkipSeconds: Int
    ) {
        let normalizedResume = resumePosition.flatMap { $0 > 0 ? $0 : nil }
        let normalizedOpening = max(0, openingSkipSeconds)
        guard !episodeURL.isEmpty,
              normalizedResume != nil || normalizedOpening > 0 else {
            cancelPendingPlaybackStart()
            return
        }
        pendingPlaybackStartTask?.cancel()
        pendingPlaybackStartTask = nil
        let pending = PendingPlaybackStart(
            episodeURL: episodeURL,
            resumePosition: normalizedResume,
            openingSkipSeconds: normalizedOpening
        )
        pendingPlaybackStart = pending
        log("[PLAYBACK_START_PENDING] episode=\(pending.logID) resumeMs=\(normalizedResume ?? 0) openingSeconds=\(normalizedOpening)")
    }

    private func cancelPendingPlaybackStart() {
        pendingPlaybackStartTask?.cancel()
        pendingPlaybackStartTask = nil
        pendingPlaybackStart = nil
    }

    private func attemptPendingPlaybackStart(for spec: PlaySpec) {
        guard let pending = pendingPlaybackStart else { return }
        guard PlaybackStartPolicy.canApply(episodeURL: pending.episodeURL, spec: spec) else {
            log("[PLAYBACK_START_CANCELLED] currentEpisode=\(PlaybackResumePolicy.episodeURL(for: spec).hashValue) pending=\(pending.logID)")
            cancelPendingPlaybackStart()
            return
        }

        pendingPlaybackStartTask?.cancel()
        pendingPlaybackStartTask = Task { @MainActor in
            let maxAttempts = 20
            for attempt in 1...maxAttempts {
                guard !Task.isCancelled, self.pendingPlaybackStart == pending else { return }
                guard let currentSpec = self.playerState.currentSpec,
                      PlaybackStartPolicy.canApply(
                        episodeURL: pending.episodeURL,
                        spec: currentSpec
                      ) else {
                    self.log("[PLAYBACK_START_CANCELLED] stale pending start episode=\(pending.logID)")
                    self.cancelPendingPlaybackStart()
                    return
                }

                if let startPosition = PlaybackStartPolicy.normalizedStartPositionMilliseconds(
                    resumePosition: pending.resumePosition,
                    openingSkipSeconds: pending.openingSkipSeconds,
                    durationSeconds: self.playerState.duration
                ) {
                    self.pendingPlaybackStart = nil
                    self.pendingPlaybackStartTask = nil
                    self.log("[PLAYBACK_START_APPLY] episode=\(pending.logID) positionMs=\(startPosition) attempt=\(attempt) durationSeconds=\(self.playerState.duration)")
                    MPVPlayerEngine.vod.seek(to: startPosition)
                    return
                }

                if PlaybackResumePolicy.isSeekReady(durationSeconds: self.playerState.duration) {
                    self.log("[PLAYBACK_START_CANCELLED] no-valid-target episode=\(pending.logID) durationSeconds=\(self.playerState.duration)")
                    self.cancelPendingPlaybackStart()
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 300_000_000)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled, self.pendingPlaybackStart == pending else { return }
            self.log("[PLAYBACK_START_TIMEOUT] episode=\(pending.logID) durationSeconds=\(self.playerState.duration)")
            self.cancelPendingPlaybackStart()
        }
    }

    private func isCurrentLivePlaybackSpec(_ spec: PlaySpec, sessionID: UUID) -> Bool {
        guard spec.metadata["playback.kind"] == "live",
              spec.metadata["live.sessionID"] == sessionID.uuidString,
              let currentSpec = livePlayerState.currentSpec,
              currentSpec.metadata["playback.kind"] == "live",
              currentSpec.metadata["live.sessionID"] == sessionID.uuidString else {
            return false
        }
        return currentSpec.url == spec.url
            && currentSpec.metadata[LiveHLSRelayPolicy.transportMetadataKey] == spec.metadata[LiveHLSRelayPolicy.transportMetadataKey]
    }

    private func liveMPVFailureMessage(channelName: String, message: String, spec: PlaySpec) -> String {
        let lower = message.lowercased()
        let transport = spec.metadata[LiveHLSRelayPolicy.transportMetadataKey] ?? ""
        if transport == LiveHLSRelayPolicy.localRelayTransport {
            return "Live: \(channelName) 本地 HLS relay 失败：\(message)"
        }
        if transport == LiveHLSRelayPolicy.localStreamRelayTransport {
            return "Live: \(channelName) 本地 stream relay 失败：\(message)"
        }
        if lower.contains("404") || lower.contains("not found") {
            return "Live: \(channelName) 上游直播源不存在或已失效：\(message)"
        }
        if lower.contains("403") || lower.contains("401") || lower.contains("expired") || lower.contains("signature") || lower.contains("鉴权") {
            return "Live: \(channelName) 直播地址可能签名/鉴权失效：\(message)"
        }
        if lower.contains("502") || lower.contains("tls") || lower.contains("proxy") || lower.contains("io error") || lower.contains("connection reset") {
            return "Live: \(channelName) 播放器网络路径失败：\(message)。如启用了代理，请切换为直连或改用可用代理"
        }
        return "Live: \(channelName) 播放器加载失败：\(message)"
    }

    private func logLiveProbe(channel: Channel, urlIndex: Int, result: LiveProbeResult) {
        let source = activeLive?.name ?? "live"
        let compactPrefix = result.bodyPrefix
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        self.log("[LIVE_PROBE] source=\(source) channel=\(channel.name) urlIndex=\(urlIndex) status=\(result.statusCode) contentType=\(result.contentType) bodyPrefix=\(compactPrefix)")
    }

    private func normalizedLivePlaySpec(channel: Channel, url: String, logContext: String) async throws -> PlaySpec {
        var spec = PlaySpec(
            url: url,
            headers: channel.requestHeaders,
            format: channel.format,
            drm: channel.drm,
            title: channel.name,
            flag: activeLive?.name ?? "live"
        )

        let sourceResult = try await SourceManager.shared.fetch(url: spec.url)
        if sourceResult.url != spec.url {
            self.log("[\(logContext)] Source 预处理: \(redactedPlaybackURL(spec.url)) -> \(redactedPlaybackURL(sourceResult.url))")
            spec.url = sourceResult.url
        }

        if sourceResult.needParse || channel.parseFlag == 1 {
            let parseConfig = VodConfig.shared.parses.first ?? Parse(name: "默认嗅探", type: 0)
            let result = Result(
                url: spec.url,
                parse: 1,
                flag: spec.flag,
                header: spec.headers,
                format: spec.format,
                key: spec.siteKey,
                drm: spec.drm
            )
            let parsed = await ParseEngine.shared.resolve(result: result, parse: parseConfig)
            spec = spec.merging(parsed)
        }

        return spec
    }

    private func restoreLiveSelection(groups: [ChannelGroup]) {
        let savedGroupName = UserPreferences.shared.currentLiveGroupName
        let savedChannelName = UserPreferences.shared.currentLiveChannelName
        let savedIndex = UserPreferences.shared.currentLiveChannelUrlIndex

        let group = groups.first { $0.name == savedGroupName } ?? groups.first
        let channel = group?.channels.first { $0.name == savedChannelName } ?? group?.channels.first

        self.selectedGroup = group
        if var channel {
            channel.currentUrlIndex = min(max(savedIndex, 0), max(channel.urls.count - 1, 0))
            self.selectedChannel = channel
            self.currentChannelUrlIndex = channel.currentUrlIndex
        } else {
            self.selectedChannel = nil
            self.currentChannelUrlIndex = 0
        }
    }

    private func persistLiveSelection(channel: Channel, urlIndex: Int) {
        UserPreferences.shared.currentLiveName = activeLive?.name ?? ""
        UserPreferences.shared.currentLiveGroupName = selectedGroup?.name ?? ""
        UserPreferences.shared.currentLiveChannelName = channel.name
        UserPreferences.shared.currentLiveChannelUrlIndex = urlIndex
    }

    private func liveEpgChannelKey(for channel: Channel) -> String {
        if !channel.tvgId.isEmpty { return channel.tvgId }
        if !channel.epgName.isEmpty { return channel.epgName }
        if !channel.tvgName.isEmpty { return channel.tvgName }
        return channel.name
    }

    private func liveEpgDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }

    // MARK: - 收藏和历史记录持久化

    private func driveMetadata(for episodeURL: String) -> (provider: String, referenceURL: String) {
        guard let reference = DriveFileReference.parse(episodeURL) else {
            return ("", "")
        }
        return (reference.provider.rawValue, reference.encodedURL)
    }

    private func drivePlaybackMetadata(for spec: PlaySpec, episodeURL: String) -> (provider: String, referenceURL: String, route: String) {
        let reference = driveMetadata(for: episodeURL)
        let provider = spec.metadata[DrivePlaybackMetadataKey.provider] ?? reference.provider
        let route = spec.metadata[DrivePlaybackMetadataKey.route] ?? ""
        return (provider, reference.referenceURL, route)
    }

    /// 保存当前点播的播放位置进度
    func saveCurrentPlaybackProgress() {
        guard let spec = playerState.currentSpec,
              let vod = detailVod else { return }
        
        let siteKey = vod.siteKey.isEmpty ? (activeSite?.key ?? "") : vod.siteKey
        let historyKey = PlaybackLinkage.vodKey(siteKey: siteKey, vodId: vod.vodId)
        let episodeURL = spec.metadata["vod.episodeURL"] ?? spec.url
        let driveMetadata = drivePlaybackMetadata(for: spec, episodeURL: episodeURL)
        let history = History(
            key: historyKey,
            siteKey: siteKey,
            vodId: vod.vodId,
            vodPic: vod.vodPic,
            vodName: vod.vodName,
            vodFlag: selectedPlayFlag,
            vodRemarks: vod.vodRemarks,
            episodeUrl: episodeURL,
            position: Int64(playerState.position * 1000),
            duration: Int64(playerState.duration * 1000),
            driveProvider: driveMetadata.provider,
            driveReferenceURL: driveMetadata.referenceURL,
            driveRoute: driveMetadata.route,
            createTime: Date()
        )
        applicationLibraryState = ApplicationLibraryCore.recordHistory(
            applicationLibraryState,
            record: history,
            preservingPlaybackPreferences: true
        ).state
        
        scheduleHistorySave()
    }

    private func scheduleHistorySave() {
        let snapshot = historyItems
        let persistence = self.applicationLibraryPersistence
        historySaveTask?.cancel()
        historySaveTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            try? persistence.saveHistory(snapshot)
        }
    }

    private func handleMPVPlaybackPosition(spec: PlaySpec?, positionSeconds: Double) {
        guard let spec, spec.metadata["playback.kind"] != "live" else { return }
        let context = playbackEpisodeContext()
        let skipSettings = VodSkipSettingsStore.shared.settings(for: spec.metadata)
        guard PlaybackAutoAdvancePolicy.shouldAdvance(
            positionSeconds: positionSeconds,
            durationSeconds: playerState.duration,
            endingSkipSeconds: skipSettings.endingSeconds,
            hasNextEpisode: context.hasNext
        ) else { return }
        requestAutoAdvance(for: spec, trigger: "ending-skip")
    }

    private func handleMPVPlaybackEnded(spec: PlaySpec?) {
        guard let spec, spec.metadata["playback.kind"] != "live" else { return }
        requestAutoAdvance(for: spec, trigger: "natural-eof")
    }

    private func requestAutoAdvance(for spec: PlaySpec, trigger: String) {
        let episodeURL = PlaybackResumePolicy.episodeURL(for: spec)
        guard playerState.currentSpec != nil else { return }
        let transition = PlaybackSessionCore.requestAutoAdvance(
            playbackSessionState,
            episodeURL: episodeURL,
            context: playbackEpisodeContext(),
            isLoading: isPlayerLoading
        )
        playbackSessionState = transition.state
        guard let targetEpisode = transition.targetEpisode else { return }

        saveCurrentPlaybackProgress()
        log("[PLAYBACK_AUTO_ADVANCE] episode=\(episodeURL.hashValue) trigger=\(trigger)")
        Task { @MainActor in
            await self.playEpisode(targetEpisode, automaticSelection: true)
        }
    }

    func saveTrackPreference(type: TrackType, id: String, name: String, format: String) {
        guard let spec = playerState.currentSpec else { return }
        let key = PlaybackLinkage.trackPreferenceKey(for: spec)
        trackItems.removeAll { $0.key == key && $0.type == type }
        trackItems.append(Track(key: key, type: type, selectionId: id, name: name.isEmpty ? id : name, format: format, isSelected: true))
        try? storageManager.saveTracks(trackItems)
    }

    @discardableResult
    private func restoreTrackPreferences(for spec: PlaySpec) -> Bool {
        if let audio = PlaybackLinkage.trackPreference(type: .audio, for: spec, in: trackItems) {
            let id = audio.selectionId.isEmpty ? audio.name : audio.selectionId
            if !id.isEmpty {
                MPVPlayerEngine.vod.selectAudioTrack(id: id)
                log("[TRACK_RESTORE] audio id=\(id) name=\(audio.name)")
            }
        }

        guard let subtitle = PlaybackLinkage.trackPreference(type: .subtitle, for: spec, in: trackItems) else { return false }
        let id = subtitle.selectionId.isEmpty ? subtitle.name : subtitle.selectionId
        guard !id.isEmpty else { return false }

        if id == PlaybackLinkage.disabledSubtitleTrackID {
            MPVPlayerEngine.vod.disableSubtitle()
            log("[TRACK_RESTORE] subtitle disabled")
            return true
        }

        if id.hasPrefix("external:") {
            let subID = String(id.dropFirst("external:".count))
            if let sub = spec.subs.first(where: { $0.id == subID }) {
                MPVPlayerEngine.vod.loadExternalSubtitle(sub, select: true)
                log("[TRACK_RESTORE] external subtitle id=\(id) name=\(subtitle.name)")
                return true
            }
            return false
        }

        MPVPlayerEngine.vod.selectSubtitleTrack(id: id)
        log("[TRACK_RESTORE] subtitle id=\(id) name=\(subtitle.name)")
        return true
    }

    private func autoSelectPreferredSubtitleTrack(for spec: PlaySpec) {
        guard spec.metadata["playback.kind"] != "live" else { return }
        guard spec.subs.isEmpty else { return }
        guard let track = PlayerSubtitlePolicy.preferredInitialSubtitleTrack(
            from: playerState.subtitleTracks,
            selectedID: playerState.selectedSubtitleTrackID
        ) else { return }

        let currentID = playerState.selectedSubtitleTrackID ?? "-"
        MPVPlayerEngine.vod.selectSubtitleTrack(id: track.id)
        log("[SUBTITLE_AUTO_SELECT] from=\(currentID) to=\(track.id) name=\(track.displayName) reason=first-chinese-track")
    }

    /// 追加或更新历史记录
    func addHistory(vod: Vod, flag: String, episode: Episode, position: Int64, duration: Int64) {
        let siteKey = vod.siteKey.isEmpty ? (activeSite?.key ?? "") : vod.siteKey
        let historyKey = PlaybackLinkage.vodKey(siteKey: siteKey, vodId: vod.vodId)
        let history = History(
            key: historyKey,
            siteKey: siteKey,
            vodId: vod.vodId,
            vodPic: vod.vodPic,
            vodName: vod.vodName,
            vodFlag: flag,
            vodRemarks: vod.vodRemarks,
            episodeUrl: episode.url,
            episodeName: episode.name,
            position: position,
            duration: duration,
            driveProvider: driveMetadata(for: episode.url).provider,
            driveReferenceURL: driveMetadata(for: episode.url).referenceURL,
            driveRoute: "",
            createTime: Date()
        )
        applicationLibraryState = ApplicationLibraryCore.recordHistory(
            applicationLibraryState,
            record: history,
            preservingPlaybackPreferences: false
        ).state
        scheduleHistorySave()
    }

    /// 从历史记录恢复到上次剧集与进度
    func playHistory(_ item: History) async {
        let intent = ApplicationLibraryCore.historyPlaybackIntent(history: item, sites: sites)
        if let matchingSite = intent.site {
            activateSiteForLibraryNavigation(matchingSite)
        }

        await selectVod(intent.vod)

        if let preferredFlag = intent.preferredFlag, playFlags.contains(preferredFlag) {
            selectPlayFlag(preferredFlag)
        }

        let episode = intent.episode(from: episodes, history: item)

        guard !episode.url.isEmpty else { return }
        await playEpisode(
            episode,
            resumePosition: intent.resumePosition,
            resumeDuration: intent.resumeDuration
        )
    }

    /// 打开收藏详情，并同步切回对应点播源或直播源
    func openKeep(_ item: Keep) async {
        if item.type == .live {
            await openLiveKeep(item)
            return
        }

        let identity = PlaybackLinkage.vodIdentity(from: item.key)
        guard !identity.siteKey.isEmpty, !identity.vodId.isEmpty else { return }

        if let matchingSite = sites.first(where: { $0.key == identity.siteKey }) {
            activateSiteForLibraryNavigation(matchingSite)
        }

        let vod = Vod(
            vodId: identity.vodId,
            vodName: item.vodName,
            vodPic: item.vodPic,
            siteKey: identity.siteKey
        )
        await selectVod(vod, acknowledgeKeepUpdate: true)
    }

    /// 清空播放历史
    func clearHistory() {
        historySaveTask?.cancel()
        historySaveTask = nil
        let transition = ApplicationLibraryCore.clearHistory(applicationLibraryState)
        do {
            try applicationLibraryPersistence.clearHistoryRecords()
            applicationLibraryState = transition.state
        } catch {
            log("[APPLICATION_LIBRARY] 清空历史失败: \(error.localizedDescription)")
        }
    }

    /// 删除单条播放历史
    func removeHistory(_ item: History) {
        let transition = ApplicationLibraryCore.removeHistory(
            applicationLibraryState,
            id: item.id
        )
        guard transition.changed else { return }
        historySaveTask?.cancel()
        historySaveTask = nil
        do {
            try applicationLibraryPersistence.saveHistory(transition.state.history)
            applicationLibraryState = transition.state
        } catch {
            log("[APPLICATION_LIBRARY] 删除历史失败: \(error.localizedDescription)")
        }
    }

    /// 切换点播收藏状态
    func toggleKeep(vod: Vod) {
        let siteKey = vod.siteKey.isEmpty ? (activeSite?.key ?? "") : vod.siteKey
        let key = PlaybackLinkage.vodKey(siteKey: siteKey, vodId: vod.vodId)
        
        let history = PlaybackLinkage.history(for: vod, activeSiteKey: siteKey, items: historyItems)
        let keep = Keep(
            key: key,
            siteName: activeSite?.name ?? "点播源",
            vodName: vod.vodName,
            vodPic: vod.vodPic,
            vodRemarks: vod.vodRemarks,
            type: .vod,
            driveProvider: history?.driveProvider ?? "",
            driveReferenceURL: history?.driveReferenceURL ?? "",
            driveRoute: history?.driveRoute ?? "",
            configId: 0
        )
        persistKeepTransition(
            ApplicationLibraryCore.toggleKeep(applicationLibraryState, candidate: keep)
        )
    }

    /// 删除单条收藏
    func removeKeep(_ item: Keep) {
        persistKeepTransition(
            ApplicationLibraryCore.removeKeep(
                applicationLibraryState,
                id: item.id,
                type: item.type
            )
        )
    }

    /// 检查是否收藏
    func isKept(vodId: String) -> Bool {
        let key = PlaybackLinkage.vodKey(siteKey: activeSite?.key ?? "", vodId: vodId)
        return ApplicationLibraryCore.containsKeep(
            applicationLibraryState,
            key: key,
            type: .vod
        )
    }

    func currentDetailHistory() -> History? {
        guard let vod = detailVod else { return nil }
        return PlaybackLinkage.history(for: vod, activeSiteKey: activeSite?.key ?? "", items: historyItems)
    }

    func isHistoryEpisode(_ episode: Episode) -> Bool {
        currentDetailHistory()?.episodeUrl == episode.url
    }

    func currentDetailHistoryProgressText() -> String? {
        PlaybackLinkage.progressText(for: currentDetailHistory())
    }

    func liveGuideGroups(from visibleGroups: [ChannelGroup]) -> [ChannelGroup] {
        PlaybackLinkage.liveGuideGroups(
            keeps: keepItems,
            groups: visibleGroups,
            liveName: activeLive?.name ?? ""
        )
    }

    func sourceGroup(forLiveChannel channel: Channel) -> ChannelGroup? {
        let identity = PlaybackLinkage.channelIdentity(channel)
        return channelGroups.first { group in
            group.channels.contains { PlaybackLinkage.channelIdentity($0) == identity }
        }
    }

    func isLiveChannelKept(_ channel: Channel, group: ChannelGroup?) -> Bool {
        guard let group = normalizedLiveSourceGroup(channel: channel, group: group) else { return false }
        let key = PlaybackLinkage.liveKeepKey(
            liveName: activeLive?.name ?? "",
            groupName: group.name,
            channel: channel
        )
        return ApplicationLibraryCore.containsKeep(
            applicationLibraryState,
            key: key,
            type: .live
        )
    }

    func toggleLiveKeep(channel: Channel, group: ChannelGroup?) {
        guard let group = normalizedLiveSourceGroup(channel: channel, group: group) else { return }
        let key = PlaybackLinkage.liveKeepKey(
            liveName: activeLive?.name ?? "",
            groupName: group.name,
            channel: channel
        )
        let keep = Keep(
            key: key,
            siteName: group.name,
            vodName: channel.name,
            vodPic: channel.logo,
            vodRemarks: channel.number,
            type: .live,
            configId: 0
        )
        persistKeepTransition(
            ApplicationLibraryCore.toggleKeep(applicationLibraryState, candidate: keep)
        )
    }

    private func syncKeepRemarks(for vod: Vod, acknowledge: Bool) {
        let siteKey = vod.siteKey.isEmpty ? (activeSite?.key ?? "") : vod.siteKey
        let key = PlaybackLinkage.vodKey(siteKey: siteKey, vodId: vod.vodId)
        persistKeepTransition(
            ApplicationLibraryCore.updateKeepRemarks(
                applicationLibraryState,
                key: key,
                currentRemarks: vod.vodRemarks,
                acknowledge: acknowledge
            )
        )
    }

    private func persistKeepTransition(_ transition: ApplicationLibraryTransition) {
        guard transition.changed else { return }
        do {
            try applicationLibraryPersistence.saveKeeps(transition.state.keeps)
            applicationLibraryState = transition.state
        } catch {
            log("[APPLICATION_LIBRARY] 保存收藏失败: \(error.localizedDescription)")
        }
    }

    private func normalizedLiveSourceGroup(channel: Channel, group: ChannelGroup?) -> ChannelGroup? {
        if let group, group.name != PlaybackLinkage.liveFavoritesGroupName {
            return group
        }
        return sourceGroup(forLiveChannel: channel)
    }

    private func openLiveKeep(_ item: Keep) async {
        guard let identity = PlaybackLinkage.liveKeepIdentity(from: item.key) else { return }
        if activeLive?.name != identity.liveName,
           let live = lives.first(where: { $0.name == identity.liveName }) {
            await changeLive(live)
        } else if channelGroups.isEmpty {
            await loadLiveContent()
        }

        presentLivePlayer()
        guard let match = PlaybackLinkage.matchingLiveChannel(
            for: item,
            in: channelGroups,
            liveName: activeLive?.name ?? ""
        ) else {
            liveError = "Live: 收藏频道 \(item.vodName) 已不在当前直播源中"
            return
        }
        selectedGroup = match.group
        await playChannel(match.channel)
    }

    // MARK: - 搜索接口

    func resetSearchState() {
        contentSearchState = ContentSearchCore.reset(contentSearchState)
    }

    /// 多站聚合搜索
    func search(keyword: String) async {
        guard !keyword.isEmpty, !Task.isCancelled else { return }
        if let candidate = SourceManager.externalDriveCandidate(for: keyword) {
            self.contentSearchState = ContentSearchCore.resolved(
                contentSearchState,
                keyword: keyword,
                results: [driveShareImportResult(for: candidate)]
            )
            self.selectedTab = .search
            log("[DRIVE_SHARE_IMPORT_CANDIDATE] provider=\(candidate.provider) status=\(candidate.support.status.rawValue) url=\(redactedPlaybackURL(candidate.canonicalURL))")
            return
        }
        self.contentSearchState = ContentSearchCore.begin(
            contentSearchState,
            keyword: keyword
        )
        let generation = contentSearchState.generation
        defer {
            contentSearchState = ContentSearchCore.finish(
                contentSearchState,
                generation: generation
            )
        }

        let searchableSites = await searchSitesForCurrentPreference()
        guard !Task.isCancelled, contentSearchState.generation == generation else { return }
        let siteOrder = searchableSites.map(\.key)
        contentSearchState = ContentSearchCore.updateSiteOrder(
            contentSearchState,
            generation: generation,
            siteOrder: siteOrder
        )
        log("[SEARCH_START] keyword=\(keyword) appSiteCount=\(searchableSites.count) active=\(activeSite?.key ?? "-")")
        let stream = SearchEngine.shared.search(keyword: keyword, sites: searchableSites)
        for await result in stream {
            guard !Task.isCancelled else { return }
            guard contentSearchState.generation == generation else { return }
            self.log("[SEARCH_SITE_RESULT] site=\(result.siteName) key=\(result.siteKey) list=\(result.vods.count) error=\(result.error ?? "-")")
            recordSiteHealth(
                eventType: .search,
                siteKey: result.siteKey,
                siteName: result.siteName,
                success: result.error == nil,
                durationMs: result.durationMs,
                errorCategory: result.errorCategory
            )
            self.contentSearchState = ContentSearchCore.ingest(
                contentSearchState,
                generation: generation,
                result: result
            )
        }

        guard !Task.isCancelled else { return }
        if let summary = ContentSearchCore.summary(contentSearchState, generation: generation) {
            log("[SEARCH_FINISH] keyword=\(keyword) totalResults=\(summary.totalResults) errorCount=\(summary.errorCount)")
        }
    }

    private func driveShareImportResult(for candidate: ExternalDriveCandidate) -> SearchResult {
        let providerName = Self.driveProviderDisplayName(candidate.provider)
        let isSupported = candidate.support.status == .supported
        let vod = Vod(
            vodId: candidate.canonicalURL,
            vodName: "\(providerName)分享",
            vodPic: Self.driveProviderImage(candidate.provider),
            vodContent: candidate.support.reason,
            vodRemarks: isSupported ? providerName : "待验证",
            typeName: "网盘分享",
            siteKey: Self.driveShareImportSiteKey
        )
        return SearchResult(
            siteName: "网盘分享",
            siteKey: Self.driveShareImportSiteKey,
            vods: [vod],
            page: 1,
            hasMore: false
        )
    }

    private func importedDriveEpisodes(for candidate: ExternalDriveCandidate, title: String) async -> [Episode] {
        guard candidate.support.status == .supported else {
            return [Self.unavailableDriveEpisode(title: Self.driveProviderDisplayName(candidate.provider), reason: candidate.support.reason)]
        }
        switch await driveShareExpander.expansionOutcome(url: candidate.canonicalURL, fallbackTitle: title) {
        case .expanded(let episodes):
            return episodes
        case .unavailable(let reason):
            return [Self.unavailableDriveEpisode(title: title, reason: reason)]
        }
    }

    private func ensureDriveShareImportSite() {
        let site = Self.driveShareImportSite
        if !sites.contains(where: { $0.key == site.key }) {
            sites.append(site)
        }
    }

    private static var driveShareImportSite: Site {
        Site(
            key: driveShareImportSiteKey,
            name: "网盘分享",
            type: SiteType.cmsJSON.rawValue,
            api: "netvplayer://drive-share-import",
            searchable: 0,
            quickSearch: 0
        )
    }

    private static func unavailableDriveEpisode(title: String, reason: String) -> Episode {
        let safeReason = reason
            .replacingOccurrences(of: "$", with: " ")
            .replacingOccurrences(of: "#", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents()
        components.scheme = "netvplayer-unavailable"
        components.host = "drive-share"
        components.queryItems = [URLQueryItem(name: "reason", value: safeReason)]
        let name = safeEpisodeTitle(title.isEmpty ? "不可用" : title)
        return Episode(name: name, url: components.url?.absoluteString ?? "netvplayer-unavailable://drive-share")
    }

    private static func safeEpisodeTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "$", with: " ")
            .replacingOccurrences(of: "#", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func driveProviderDisplayName(_ provider: String) -> String {
        switch provider {
        case "quark": return "夸克网盘"
        case "uc": return "UC网盘"
        case "ali": return "阿里云盘"
        case "115", "p115": return "115网盘"
        case "pikpak": return "PikPak"
        case "baidu": return "百度网盘"
        case "cloud123": return "123 网盘"
        case "xunlei", "thunder": return "迅雷云盘"
        case "mobile": return "中国移动云盘"
        case "tianyi": return "天翼云盘"
        default: return "网盘"
        }
    }

    private static func driveProviderImage(_ provider: String) -> String {
        switch provider {
        case "quark": return "https://pan.quark.cn/favicon.ico"
        case "uc": return "https://drive.uc.cn/favicon.ico"
        case "ali": return "https://img.alicdn.com/imgextra/i3/O1CN01fI0Vgb1iHn5wIr0nY_!!6000000004385-2-tps-1024-1024.png"
        case "115", "p115": return "https://115.com/favicon.ico"
        default: return "video"
        }
    }

    private func searchSitesForCurrentPreference() async -> [Site] {
        let replacementKeys = await replacementSiteKeys(for: sites)
        return SearchSitePlanner.orderedSearchSites(
            sites: sites,
            activeSiteKey: activeSite?.key,
            selectedKeys: selectedSearchSiteKeys,
            replacementSiteKeys: replacementKeys,
            healthSummaries: siteHealthSummaries,
            healthSortingEnabled: UserPreferences.shared.siteHealthSortingEnabled
        )
    }

    private func replacementSiteKeys(for sites: [Site]) async -> Set<String> {
        var keys = Set<String>()
        for site in sites {
            if await SpiderReplacementRegistry.shared.hasReplacement(for: site) {
                keys.insert(site.key)
            }
        }
        return keys
    }

}

extension Site {
    var isAllliveGuard: Bool {
        api.trimmingCharacters(in: .whitespacesAndNewlines) == "csp_AllliveGuard" || key == "alllive"
    }

    var showsSyntheticRecommendation: Bool {
        let guardAPI = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard guardAPI.hasSuffix("Guard") else { return true }
        return !Self.guardKeysWithoutRecommendation.contains(key)
    }

    func allliveCategory(for vod: Vod) -> VodClass? {
        guard isAllliveGuard else { return nil }
        let prefix = "alllive-category:"
        guard vod.vodId.hasPrefix(prefix) else { return nil }
        let parts = vod.vodId.dropFirst(prefix.count).split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return VodClass(typeId: "\(parts[0])_\(parts[1])", typeName: vod.vodName)
    }

    private static let guardKeysWithoutRecommendation: Set<String> = [
        "YGP", "原创", "新6V", "看球", "吃瓜", "alllive", "有声小说", "Aid",
        "YpanSo", "BpanSo", "抠搜", "UC", "cc"
    ]
}
