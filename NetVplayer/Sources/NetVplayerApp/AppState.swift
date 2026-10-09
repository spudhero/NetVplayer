// NetVplayerApp/AppState.swift
// 全局应用状态

import SwiftUI
import Combine
import CryptoKit
import UniformTypeIdentifiers
import Models
import ApplicationCore
import DriveEngine
import FileServiceEngine
import MediaLibraryEngine
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
    case vodHome
    case search
    case liveStream
    case history
    case favorites
    case webHome
    case settings

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

    var title: String {
        switch self {
        case .vodHome: L10n.text("点播")
        case .search: L10n.text("搜索")
        case .liveStream: L10n.text("直播")
        case .history: L10n.text("历史")
        case .favorites: L10n.text("收藏")
        case .webHome: L10n.text("WebHome")
        case .settings: L10n.text("设置")
        }
    }

    static var visibleTabs: [SidebarTab] {
        allCases.filter { tab in
            tab != .webHome || UserPreferences.shared.webHomeEnabled
        }
    }
}

struct PlaybackVerificationRequest: Identifiable {
    let interaction: PlaybackInteraction
    let episode: Episode

    var id: String {
        [interaction.kind.rawValue, interaction.url, episode.url].joined(separator: ":")
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
    let credentialsValidated: Bool

    init(message: String?, shouldDismiss: Bool, credentialsValidated: Bool = false) {
        self.message = message
        self.shouldDismiss = shouldDismiss
        self.credentialsValidated = credentialsValidated
    }

    static func dismiss(_ message: String? = nil, credentialsValidated: Bool = false) -> CloudAuthCompletion {
        CloudAuthCompletion(message: message, shouldDismiss: true, credentialsValidated: credentialsValidated)
    }

    static func stay(_ message: String, credentialsValidated: Bool = false) -> CloudAuthCompletion {
        CloudAuthCompletion(message: message, shouldDismiss: false, credentialsValidated: credentialsValidated)
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

enum SavedConfigStartupPhase: Equatable {
    case unconfigured
    case preparingExtension
    case loading
    case ready
    case failed(String)
}

private struct PlaybackStartupTrace {
    let generation: UInt64
    let siteKey: String
    let startedAt: ContinuousClock.Instant
    var lastStageAt: ContinuousClock.Instant
}

enum ProviderRuntimeUpdateState {
    static func pendingVersions(catalog: [ProviderRelease], installedVersions: [String: String]) -> [String: String] {
        var latestByID: [String: ProviderRelease] = [:]
        for release in catalog {
            if let current = latestByID[release.providerID],
               ProviderManifestVerifier.compareVersions(current.version, release.version) >= 0 {
                continue
            }
            latestByID[release.providerID] = release
        }
        var pending: [String: String] = [:]
        for (id, release) in latestByID {
            let installedVersion = installedVersions[id]
            if installedVersion.map({ ProviderManifestVerifier.compareVersions($0, release.version) < 0 }) ?? true {
                pending[id] = release.version
            }
        }
        return pending
    }
}

/// 全局应用状态
@MainActor
final class AppState: ObservableObject {
    static let driveShareImportSiteKey = "__drive_share_import__"
    private static let biliPlaybackCacheMetadataKey = "bili.cache.videoPath"
    private static let biliAudioCacheMetadataKey = "bili.cache.audioPath"
    private static let biliPlaybackCacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NetVplayer/BiliPlayback", isDirectory: true)
    @Published var selectedTab: SidebarTab = .vodHome {
        didSet {
            if oldValue == .search && selectedTab != .search {
                resetSearchState()
            }
        }
    }
    @Published private(set) var appearanceThemeID = AppAppearanceDefaults.releaseDefaultThemeID
    var appearancePalette: AppThemePalette { AppThemeCatalog.palette(for: appearanceThemeID) }
    @Published var isConfigLoaded: Bool = false
    @Published var configError: String?
    @Published private(set) var savedConfigStartupPhase: SavedConfigStartupPhase = .unconfigured
    @Published var currentSiteName: String = L10n.text("未加载")
    @Published var vodError: String? = nil
    var savedConfigs: [Config] {
        get { applicationLibraryState.configs }
        set { applicationLibraryState.configs = newValue }
    }
    @Published var availableDepots: [Depot] = []
    @Published var configNotice: String?
    @Published var selectedSearchSiteKeys: [String] = [] { didSet { if oldValue != selectedSearchSiteKeys { resetSearchState() } } }
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
    @Published private(set) var providerRuntimeStatus: String = L10n.text("未配置")
    @Published var providerStorageUsage: ProviderStorageUsage?
    @Published var providerMaintenancePlan: ProviderMaintenancePlan?
    @Published var providerComponentsDisabled = false
    @Published private(set) var providerRuntimeBusy = false
    @Published private(set) var providerRuntimeHasFailure = false
    @Published private(set) var providerRuntimeProgress: ProviderInstallProgress?
    @Published private(set) var providerInstallation = ProviderInstallationPresentation()
    @Published private(set) var providerRuntimeFailedRelease: ProviderVersionReference?
    @Published private(set) var providerRuntimePendingVersions: [String: String] = [:]
    @Published private(set) var providerRuntimeLocalPackageInvalid = false
    @Published var webHomeChromeTitle: String = "WebHome"
    @Published var lastWebHomeBridgeMethod: String?
    @Published var webHomeSessionDiagnostic = WebHomeSessionDiagnostic()
    @Published var lastDanmakuRenderStatus: String?
    @Published var lastDanmakuParseDiagnostic: DanmakuPayloadParseDiagnostic?
    @Published var lastDriveFixtureDiagnostic: String?
    private let driveShareExpander: DriveShareExpander
    private let storageManager: StorageManager
    private let fileServiceStore: FileServiceStore
    private let applicationLibraryPersistence: any ApplicationLibraryPersistence
    private let historyWriter: HistoryWriteCoordinator
    var libraryConfigurationURL = ""
    private var historyDeletedThroughGeneration: [String: UInt64] = [:]
    private var historyClearedThroughGeneration: UInt64?
    private var danmakuRequestID = UUID()
    private var danmakuCandidateOwner: (id: UUID, url: String, session: String?)?
    private let danmakuBindings: DanmakuBindingStore
    @Published var danmakuCandidates: [DanmakuMatch] = []
    @Published private(set) var danmakuRenderRevision = UUID()
    var danmakuSearchOperation: @Sendable (DanmakuSearchRequest, [DanmakuSource]) async -> [DanmakuMatch] = {
        await DanmakuEngine.shared.manualSearch(request: $0, sources: $1)
    }
    private let configResolver: ConfigResolver
    private let userPreferences: UserPreferences
    private let providerRuntimeBootstrap: ProviderRuntimeBootstrap?
    private let providerRuntimeStartupOverride: (@MainActor @Sendable () async -> Bool)?
    private var providerRuntimeRegistrationTask: Task<Bool, Never>?
    private(set) var providerRuntimeStartupTask: Task<Void, Never>?
    private(set) var providerRuntimeCollapseTask: Task<Void, Never>?
    private let providerRuntimeCollapseDelay: @Sendable () async throws -> Void
    private var providerRuntimeLocalReady = false
    private var providerRuntimeRegistrationResolved = false
    private var savedConfigBlockedByProviderRuntime = false
    var providerRuntimeIsConfigured: Bool {
        guard providerRuntimeBootstrap != nil,
              let rawURL = Bundle.main.infoDictionary?["NetVplayerProviderDistributionIndexURL"] as? String,
              let url = URL(string: rawURL) else { return false }
        return url.scheme == "https" && url.host != nil
    }
    var providerRuntimeInitialInstallCompleted: Bool {
        userPreferences.providerRuntimeInitialInstallCompleted && providerRuntimeLocalReady
    }
    private var preferredVodHomeSiteKey: String?

    // 子状态
    @Published var playerState = PlayerState()
    @Published var livePlayerState = PlayerState()
    @Published var currentDanmakuCues: [DanmakuCue] = []

    // 点播业务数据
    @Published var sites: [Site] = [] {
        didSet {
            // The local share-detail adapter is not a searchable configuration source.
            let oldSources = oldValue.filter { $0.key != Self.driveShareImportSiteKey }
            let newSources = sites.filter { $0.key != Self.driveShareImportSiteKey }
            if oldSources != newSources { resetSearchState() }
        }
    }
    @Published var activeSite: Site?
    @Published private(set) var contentCatalogState = ContentCatalogState()
    @Published private(set) var isCatalogRefreshing = false
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
    @Published var episodeSortOrder: EpisodeSortOrder = .ascending {
        didSet {
            guard oldValue != episodeSortOrder else { return }
            invalidateNextEpisodePreload(reason: "episode-sort-changed")
        }
    }
    // The visible list is also the playback queue. Names, formats and versions
    // never silently exclude a selectable entry from previous/next or auto-advance.
    var displayedPlaybackEpisodes: [Episode] { episodeSortOrder.ordered(episodes) }
    private var availablePlaybackLines: [VodPlaybackLine] = []
    @Published var episodeDisplayMode: EpisodeDisplayMode = .grid
    @Published var isDetailPresented: Bool = false
    @Published var isDetailLoading: Bool = false
    @Published private(set) var episodeListState: EpisodeListLoadState = .ready
    private var episodeListRefreshTask: Task<Void, Never>?
    private var episodeListRefreshID = UUID()
    var episodeListRefreshTimeout: Duration = .seconds(12)
    @Published var isPlayerPresented: Bool = false {
        didSet {
            if !isPlayerPresented {
                pendingAutoAdvanceID = nil
                episodePreparation = nil
                danmakuRequestID = UUID()
                if oldValue {
                    cancelCloudAuthorization()
                    if !isDetailPresented { cancelEpisodeListRefresh() }
                }
            }
        }
    }
    private(set) var isDetailReturnPendingAfterPlayerExit: Bool = false
    @Published var isLivePlayerPresented: Bool = false
    @Published private(set) var livePlayerOpenRequestSerial: Int = 0
    @Published var isPlayerLoading: Bool = false
    @Published private var pendingAutoAdvanceID: UUID?
    private struct EpisodePreparation {
        let id = UUID()
        let episode: Episode
        let title: String
    }
    @Published private var episodePreparation: EpisodePreparation?
    var preparingEpisode: Episode? { episodePreparation?.episode }
    var preparingPlaybackTitle: String? { episodePreparation?.title }
    var isPreparingVodPlayback: Bool {
        isPlayerLoading || pendingAutoAdvanceID != nil || episodePreparation != nil
    }
    var shouldShowPlaybackEndedPanel: Bool {
        playerState.hasEnded && !isPreparingVodPlayback && playerState.errorMessage == nil
    }
    @Published var playerLoadingMessage: String = L10n.text("正在解析视频，请稍候...")
    @Published var isPlaybackErrorPresented: Bool = false
    @Published var playbackErrorMessage: String?
    @Published var playbackErrorAuthProvider: DriveProvider?
    @Published var playbackVerificationRequest: PlaybackVerificationRequest?
    @Published var playbackWarningMessage: String?
    @Published private(set) var playbackRouteNotice: DrivePlaybackRouteNotice?
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
        cancelCloudAuthorization()
        invalidateNextEpisodePreload(reason: "player-dismissed")
        playerDismissalDetailTask?.cancel()
        isDetailReturnPendingAfterPlayerExit = detailVod != nil
        DiagnosticLog.write(
            "[VOD_PLAYER_EXIT] stage=begin hasDetail=\(detailVod != nil) returnPending=\(isDetailReturnPendingAfterPlayerExit)"
        )
        isDetailPresented = false
        isPlayerPresented = false
        playerDismissalDetailTask = Task { @MainActor [weak self] in
            await FileServiceRuntime.shared.releasePlayback()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.completePlayerDismissalPresentation()
        }
    }

    func completePlayerDismissalPresentation() {
        guard isDetailReturnPendingAfterPlayerExit else {
            DiagnosticLog.write("[VOD_PLAYER_EXIT] stage=complete returnPending=false")
            return
        }
        playerDismissalDetailTask?.cancel()
        playerDismissalDetailTask = nil
        isDetailReturnPendingAfterPlayerExit = false
        guard !isPlayerPresented, detailVod != nil else {
            DiagnosticLog.write(
                "[VOD_PLAYER_EXIT] stage=complete restored=false playerPresented=\(isPlayerPresented) hasDetail=\(detailVod != nil)"
            )
            return
        }
        isDetailPresented = true
        DiagnosticLog.write("[VOD_PLAYER_EXIT] stage=complete restored=true")
    }

    @Published var cloudAuthRequest: CloudAuthRequest? {
        didSet {
            if oldValue?.id != cloudAuthRequest?.id {
                cloudAuthAttempt = nil
                if cloudAuthRequest == nil { pendingAuthorization = nil }
            }
        }
    }
    @Published private(set) var settingsNavigationDestination: SettingsNavigationDestination?
    @Published var cloudCredentialClearRequest: CloudCredentialClearRequest?
    private var pendingAuthorization: PlaybackAuthorizationResume?
    private var cloudAuthAttempt: (id: UUID, requestID: UUID?)?
    var cloudAuthCredentialOperation: ((CloudCredential, DriveFileReference?, Bool) async throws -> CloudAuthCompletion)?
    private var pendingAuthEpisode: Episode? {
        get { pendingAuthorization?.episode }
        set {
            pendingAuthorization = newValue.map {
                PlaybackAuthorizationResume(origin: playbackAuthorizationOrigin, episode: $0,
                    resumePosition: playbackSessionState.intent?.resumePosition,
                    resumeDuration: playbackSessionState.intent?.resumeDuration,
                    automaticSelection: playbackSessionState.intent?.isAutomatic ?? false,
                        restartFromBeginning: playbackSessionState.intent?.restartFromBeginning ?? false)
            }
        }
    }
    private var driveCleanupInFlight = Set<String>()
    private var pendingPlaybackStart: PendingPlaybackStart?
    private var playbackStartupTrace: PlaybackStartupTrace?
    private var pendingPlaybackStartTask: Task<Void, Never>?
    private var playerDismissalDetailTask: Task<Void, Never>?
    private var detailPrefetchTask: Task<Void, Never>?
    private var detailLoadGeneration: UInt64 = 0
    private var historySaveTask: Task<Void, Never>?
    private var searchContinuationTasks: [String: Task<Void, Never>] = [:]
    private var libraryHomeRefreshTask: Task<Void, Never>?
    private let vodDataSource = VodDataSourceCoordinator()
    private let liveDataSource = LiveDataSourceCoordinator()
    private let catalogRepository: CatalogRepository
    private var catalogRefreshTask: Task<Void, Never>?
    private var catalogCacheRevision: UInt64 = 0
    private var catalogRequestSerial: UInt64 = 0
    private var displayedCatalogCacheKey: CatalogCacheBaseKey?
    private var loadingCatalogCacheKey: CatalogCacheBaseKey?
    private var vodLineFallbackGeneration: UInt64?
    private var vodLineFallbackTask: Task<Void, Never>?
    private let nextEpisodePreloadCoordinator = NextEpisodePreloadCoordinator()
    private var nextEpisodeEssentialsTask: Task<Void, Never>?
    private var nextEpisodeThunderTask: Task<Void, Never>?
    private var nextEpisodeThunderKey: PlaybackPreloadKey?
    private var drivePlaybackStallGeneration: UInt64 = 0
    private var drivePlaybackStallTask: Task<Void, Never>?
    private var drivePlaybackStallSpecURL: String?
    private var pendingDrivePlaybackNotice: DrivePlaybackRouteNotice?
    private let drivePlaybackSessionController = DrivePlaybackSessionController()

    // 直播业务数据
    @Published var lives: [Live] = []
    @Published var activeLive: Live?
    @Published var channelGroups: [ChannelGroup] = []
    @Published var selectedGroup: ChannelGroup?
    @Published var selectedChannel: Channel?
    @Published var isLoadingLive: Bool = false
    @Published private(set) var isLoadingLiveConfiguration = false
    @Published private(set) var liveConfigurationError: String?
    @Published private(set) var isLivePlaybackLoading: Bool = false
    @Published private(set) var livePlaybackLoadingMessage: String = L10n.text("正在检查当前频道线路，请稍候。")
    @Published var currentChannelUrlIndex: Int = 0
    @Published var liveError: String?
    @Published var liveEpgData: EpgData?
    @Published var isLoadingLiveEpg: Bool = false
    @Published var liveEpgError: String?
    private var liveEpgRequestKey = ""
    @Published var liveEpgAvailability: EpgAvailability = .unconfigured
    private var liveEpgRequestID = UUID()
    private var liveEpgTask: Task<EpgLoadResult, Never>?
    private var hlsRecoveryTasks: [Bool: Task<Void, Never>] = [:]
    private var hlsRecoverySlots = HLSRecoverySlots()
    private var livePlaybackSessionID = UUID()
    private var livePlaybackLoadingID: UUID?
    private var liveFallbackAttempts: [LivePlaybackAttempt] = []
    private var liveFallbackNextIndex: Int = 0
    private var liveFallbackTask: Task<Void, Never>?
    private var livePendingFailureTask: Task<Void, Never>?
    private var liveContentLoadedAt: Date?
    private var liveContentRequestID: UUID?
    private var liveConfigurationRequestID = UUID()
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
    var searchEngine = SearchEngine.shared
    private var activeSearchTask: Task<Void, Never>?
    private var activeSearchID = UUID()
    private var activeSearchKey: String?
    private var searchSnapshotPublisher: SearchSnapshotPublisher?
    private let searchSessionNamespace = UUID().uuidString
    private var lastSearchCredentialRevision: UInt64 = 0
    private var searchCredentialsObserver: AnyCancellable?
    private var fileServicesObserver: AnyCancellable?

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
    private(set) var configurationRefreshTask: Task<Void, Never>?
    private var configurationLoadGeneration: UInt64 = 0
    private let configurationRefreshSleeper: @Sendable (Duration) async throws -> Void

    init(
        loadDefaultConfig: Bool = true,
        startProxyServer: Bool = true,
        driveShareExpander: DriveShareExpander = .shared,
        liveHTTPClient: HTTPClient = .shared,
        configResolver: ConfigResolver = .shared,
        storageManager: StorageManager = .shared,
        applicationLibraryPersistence: (any ApplicationLibraryPersistence)? = nil,
        userPreferences: UserPreferences = .shared,
        providerRuntimeBootstrap: ProviderRuntimeBootstrap? = ProviderRuntimeBootstrap.makeDefault(),
        providerRuntimeRegistrationOverride: (@MainActor @Sendable () async -> Bool)? = nil,
        providerRuntimeStartupOverride: (@MainActor @Sendable () async -> Bool)? = nil,
        providerRuntimeCollapseDelay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(1_500))
        },
        configurationRefreshSleeper: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        catalogRepository: CatalogRepository = .shared
    ) {
        let resolvedLibraryPersistence = applicationLibraryPersistence ?? storageManager
        self.driveShareExpander = driveShareExpander
        self.catalogRepository = catalogRepository
        self.liveHTTPClient = liveHTTPClient
        self.livePlaybackProbe = LivePlaybackProbe(httpClient: liveHTTPClient)
        self.configResolver = configResolver
        self.storageManager = storageManager
        self.fileServiceStore = FileServiceStore(storage: storageManager, preferences: userPreferences)
        self.applicationLibraryPersistence = resolvedLibraryPersistence
        self.historyWriter = HistoryWriteCoordinator(persistence: resolvedLibraryPersistence)
        self.danmakuBindings = DanmakuBindingStore(storage: storageManager)
        self.userPreferences = userPreferences
        self.providerRuntimeBootstrap = providerRuntimeBootstrap
        self.providerRuntimeStartupOverride = providerRuntimeStartupOverride
        self.providerRuntimeCollapseDelay = providerRuntimeCollapseDelay
        self.configurationRefreshSleeper = configurationRefreshSleeper
        self.providerRuntimePendingVersions = userPreferences.providerRuntimePendingVersions
        let storedVodSiteKey = userPreferences.currentVodSiteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredVodHomeSiteKey = storedVodSiteKey.isEmpty ? nil : storedVodSiteKey
        if userPreferences === UserPreferences.shared {
            let migratedPreferenceCount = userPreferences.migrateLegacyPreferenceDomainsIfNeeded()
            if migratedPreferenceCount > 0 {
                print("[PREFERENCES_MIGRATION] restored \(migratedPreferenceCount) values from legacy app domains")
            }
            do {
                try userPreferences.retryCredentialPersistence()
            } catch {
                print("[CREDENTIAL_MIGRATION_DEFERRED] Account storage unavailable; legacy values retained")
            }
        }
        userPreferences.migrateSubtitleDefaultsIfNeeded()
        self.appearanceThemeID = AppAppearanceDefaults.resolvedThemeID(
            storedRawValue: userPreferences.appearanceThemeID
        )

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
                ProxyServer.shared.prefetchedProxyHandler = playbackHandlers.prefetched
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
        lastSearchCredentialRevision = userPreferences.searchCredentialRevision
        searchCredentialsObserver = NotificationCenter.default.publisher(for: UserPreferences.credentialsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let revision = self.userPreferences.searchCredentialRevision
                    guard revision != self.lastSearchCredentialRevision else { return }
                    self.lastSearchCredentialRevision = revision
                    if !self.contentSearchState.sourceScope.isEmpty,
                       self.contentSearchState.sourceScope != self.searchDataScope { self.resetSearchState() }
                    await self.searchEngine.invalidateSearchCache()
                }
            }


        let savedURL = loadDefaultConfig
            ? userPreferences.currentVodConfigUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if !savedURL.isEmpty {
            savedConfigStartupPhase = .preparingExtension
        }

        let runtimeRegistrationTask: Task<Bool, Never>?
        if let providerRuntimeRegistrationOverride {
            runtimeRegistrationTask = Task { @MainActor in
                await providerRuntimeRegistrationOverride()
            }
        } else if let providerRuntimeBootstrap {
            runtimeRegistrationTask = Task { @MainActor [weak self] in
                if await providerRuntimeBootstrap.manager.isDisabled() {
                    self?.providerComponentsDisabled = true
                    self?.providerRuntimeInstalled = []
                    return false
                }
                await providerRuntimeBootstrap.registerInstalledProviders()
                let installed = await providerRuntimeBootstrap.installedManifests()
                self?.providerRuntimeInstalled = installed
                return !installed.isEmpty
            }
        } else {
            runtimeRegistrationTask = nil
            providerRuntimeHasFailure = providerRuntimeStartupOverride == nil
            providerRuntimeStatus = L10n.text("当前构建未配置扩展支持")
        }
        providerRuntimeRegistrationTask = runtimeRegistrationTask
        if let providerRuntimeStartupOverride {
            providerRuntimeBusy = true
            providerRuntimeStatus = L10n.text("正在检查播放扩展")
            providerRuntimeStartupTask = Task { @MainActor [weak self] in
                guard let self else { return }
                self.finishLocalProviderRegistration(await runtimeRegistrationTask?.value ?? false)
                let installationID = self.beginProviderRuntimePresentation()
                self.finishProviderRuntimeStartupOverride(await providerRuntimeStartupOverride(), installationID: installationID)
            }
        } else if let providerRuntimeBootstrap {
            providerRuntimeBusy = true
            providerRuntimeStatus = L10n.text("正在检查播放扩展")
            let shouldDetectProviderProxy = startProxyServer
            providerRuntimeStartupTask = Task { @MainActor [weak self] in
                self?.finishLocalProviderRegistration(await runtimeRegistrationTask?.value ?? false)
                let installationID = self?.providerComponentsDisabled == false
                    ? self?.beginProviderRuntimePresentation() : nil
                if shouldDetectProviderProxy {
                    let proxyPort = await ProxyDetector.shared.detectActiveProxy()
                    await providerRuntimeBootstrap.configureDistributionProxy(port: proxyPort)
                }
                await self?.synchronizeProviderRuntime(using: providerRuntimeBootstrap, installationID: installationID)
            }
        }

        if loadDefaultConfig {
            fileServicesObserver = NotificationCenter.default.publisher(for: .fileServicesDidChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { @MainActor [weak self] in self?.reloadFileServiceSites() } }
            reloadFileServiceSites()
            Task { await MediaLibraryScanner.shared.scanStaleLibraries() }
        }
        // 仅恢复用户保存的配置；首次启动保持空壳，不内置或发现视频源。
        if !savedURL.isEmpty {
            let startupGeneration = configurationLoadGeneration
            initialConfigTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let ready = savedURL.hasPrefix("netvplayer-xtream://") ? true : await self.waitForProviderRuntimeReadiness()
                guard !Task.isCancelled, self.configurationLoadGeneration == startupGeneration else { return }
                guard ready else {
                    self.savedConfigBlockedByProviderRuntime = true
                    self.savedConfigStartupPhase = .failed(self.providerRuntimeStatus)
                    return
                }
                await self.loadConfig(url: savedURL, waitForProviderRuntime: false, restoreSavedConfiguration: true)
            }
        } else if loadDefaultConfig, !userPreferences.currentLiveConfigUrl.isEmpty {
            initialConfigTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadLiveConfiguration(url: self.userPreferences.currentLiveConfigUrl)
            }
        }
    }

    deinit {
        configurationRefreshTask?.cancel()
    }

    func selectAppearanceTheme(_ id: AppAppearanceThemeID) {
        guard appearanceThemeID != id else { return }
        UserPreferences.shared.appearanceThemeID = id.rawValue
        appearanceThemeID = id
    }

    private func finishLocalProviderRegistration(_ hasVerifiedPackages: Bool) {
        guard !providerRuntimeRegistrationResolved else { return }
        providerRuntimeRegistrationResolved = true
        providerRuntimeLocalReady = hasVerifiedPackages
        if providerComponentsDisabled {
            providerRuntimeLocalPackageInvalid = false
            return
        }
        let verifiedVersions = Dictionary(uniqueKeysWithValues: providerRuntimeInstalled.map {
            ($0.manifest.providerID, $0.manifest.version)
        })
        let expectedIDs = Set(userPreferences.providerRuntimeInstalledVersions.keys)
        let hasMissingPackage = !expectedIDs.isSubset(of: Set(verifiedVersions.keys))
        if hasMissingPackage {
            providerRuntimeLocalPackageInvalid = true
            userPreferences.providerRuntimeInitialInstallCompleted = false
        } else if hasVerifiedPackages && !userPreferences.providerRuntimeInitialInstallRecorded {
            userPreferences.providerRuntimeInitialInstallCompleted = true
            userPreferences.providerRuntimeInstalledVersions = verifiedVersions
        } else if !hasVerifiedPackages {
            providerRuntimeLocalPackageInvalid = userPreferences.providerRuntimeInitialInstallCompleted
            userPreferences.providerRuntimeInitialInstallCompleted = false
        }
    }

    private func finishProviderRuntimeStartupOverride(_ succeeded: Bool, installationID: UUID) {
        guard providerInstallation.sessionID == installationID else { return }
        providerRuntimeBusy = false
        providerRuntimeHasFailure = !succeeded
        providerRuntimeLocalReady = succeeded || providerRuntimeLocalReady
        if succeeded {
            userPreferences.providerRuntimeInitialInstallCompleted = true
            providerRuntimeLocalPackageInvalid = false
            providerRuntimeStatus = L10n.text("播放扩展已就绪")
        } else {
            providerRuntimeStatus = providerRuntimeLocalReady
                ? L10n.text("扩展更新检查未完成，继续使用已安装版本")
                : L10n.text("播放扩展安装未完成，请重试")
        }
        finishProviderRuntimePresentation(succeeded: succeeded, installationID: installationID)
    }

    private func beginProviderRuntimePresentation(retrying release: ProviderVersionReference? = nil) -> UUID {
        providerRuntimeCollapseTask?.cancel()
        providerRuntimeCollapseTask = nil
        providerRuntimeProgress = nil
        let installationID = UUID()
        let isInitialInstallation = !userPreferences.providerRuntimeInitialInstallCompleted
            && !providerRuntimeLocalPackageInvalid && !providerComponentsDisabled
            && (providerRuntimeIsConfigured || providerRuntimeStartupOverride != nil)
        if providerInstallation.begin(
            sessionID: installationID,
            isInitialInstallation: isInitialInstallation,
            retrying: release
        ) {
            settingsNavigationDestination = .providers
            selectedTab = .settings
        }
        return installationID
    }

    func setProviderRuntimeDetailsExpanded(_ expanded: Bool) {
        providerRuntimeCollapseTask?.cancel()
        providerRuntimeCollapseTask = nil
        providerInstallation.setDetailsExpanded(expanded)
    }

    private func finishProviderRuntimePresentation(succeeded: Bool, installationID: UUID) {
        guard providerInstallation.sessionID == installationID else { return }
        providerRuntimeCollapseTask?.cancel()
        providerRuntimeCollapseTask = nil
        guard providerInstallation.finish(
            succeeded: succeeded, message: providerRuntimeStatus, sessionID: installationID
        ) else { return }
        let delay = providerRuntimeCollapseDelay
        providerRuntimeCollapseTask = Task { @MainActor [weak self] in
            do { try await delay() } catch { return }
            guard !Task.isCancelled else { return }
            self?.providerInstallation.collapseAfterSuccess(sessionID: installationID)
        }
    }

    private func waitForProviderRuntimeReadiness() async -> Bool {
        let hasVerifiedPackages = await providerRuntimeRegistrationTask?.value ?? false
        finishLocalProviderRegistration(hasVerifiedPackages)
        if userPreferences.providerRuntimeInitialInstallCompleted && providerRuntimeLocalReady {
            return true
        }
        await providerRuntimeStartupTask?.value
        return userPreferences.providerRuntimeInitialInstallCompleted && providerRuntimeLocalReady
    }

    @discardableResult
    func refreshProviderRuntimeCatalog() -> Task<Void, Never>? {
        if let providerRuntimeStartupOverride {
            if providerRuntimeBusy { return providerRuntimeStartupTask }
            providerRuntimeBusy = true
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                let installationID = self.beginProviderRuntimePresentation()
                self.finishProviderRuntimeStartupOverride(await providerRuntimeStartupOverride(), installationID: installationID)
            }
            providerRuntimeStartupTask = task
            return task
        }
        guard providerRuntimeIsConfigured, let bootstrap = providerRuntimeBootstrap else {
            providerRuntimeHasFailure = true
            providerRuntimeStatus = L10n.text("当前构建未配置扩展支持")
            return nil
        }
        if providerRuntimeBusy { return providerRuntimeStartupTask }
        providerRuntimeBusy = true
        providerRuntimeHasFailure = false
        let installationID = beginProviderRuntimePresentation()
        let task = Task { @MainActor [weak self] in
            let proxyPort = await ProxyDetector.shared.detectActiveProxy()
            await bootstrap.configureDistributionProxy(port: proxyPort)
            await self?.synchronizeProviderRuntime(using: bootstrap, installationID: installationID)
        }
        providerRuntimeStartupTask = task
        return task
    }

    func retrySavedConfigStartup() {
        initialConfigTask?.cancel()
        invalidateConfigurationRefresh()
        let startupGeneration = configurationLoadGeneration
        let savedURL = userPreferences.currentVodConfigUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !savedURL.isEmpty else {
            savedConfigStartupPhase = .unconfigured
            return
        }
        savedConfigStartupPhase = .preparingExtension
        if savedURL.hasPrefix("netvplayer-xtream://") || (userPreferences.providerRuntimeInitialInstallCompleted && providerRuntimeLocalReady) {
            initialConfigTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled,
                      self.configurationLoadGeneration == startupGeneration else { return }
                await self.loadConfig(url: savedURL, waitForProviderRuntime: false, restoreSavedConfiguration: true)
            }
            return
        }
        let task = refreshProviderRuntimeCatalog()
        initialConfigTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await task?.value
            guard !Task.isCancelled, self.configurationLoadGeneration == startupGeneration else { return }
            guard self.userPreferences.providerRuntimeInitialInstallCompleted,
                  self.providerRuntimeLocalReady else {
                self.savedConfigBlockedByProviderRuntime = true
                self.savedConfigStartupPhase = .failed(self.providerRuntimeStatus)
                return
            }
            await self.loadConfig(url: savedURL, waitForProviderRuntime: false, restoreSavedConfiguration: true)
        }
    }

    func synchronizeProviderRuntime(using bootstrap: ProviderRuntimeBootstrap, installationID: UUID? = nil) async {
        if await bootstrap.manager.isDisabled() {
            providerComponentsDisabled = true
            providerRuntimeInstalled = []
            providerRuntimeLocalReady = false
            providerRuntimeLocalPackageInvalid = false
            providerRuntimeHasFailure = false
            providerRuntimeProgress = nil
            providerRuntimeCollapseTask?.cancel()
            providerInstallation.clear()
            providerRuntimeStatus = L10n.text("播放扩展已停用，可在扩展支持中重新启用。")
            providerRuntimeBusy = false
            return
        }
        providerRuntimeBusy = true
        providerRuntimeHasFailure = false
        providerRuntimeFailedRelease = nil
        let installationID = installationID ?? beginProviderRuntimePresentation()
        var succeeded = false
        do {
            let result = try await bootstrap.synchronizeAvailableProviders(
                onCatalogLoaded: { [weak self] catalog in
                    await self?.applyProviderRuntimeCatalog(catalog, installationID: installationID)
                },
                onInstallFailure: { [weak self] failure in
                    await self?.applyProviderRuntimeFailure(failure, installationID: installationID)
                },
                progress: { [weak self] progress in
                    await self?.applyProviderRuntimeProgress(progress, installationID: installationID)
                }
            )
            guard providerInstallation.sessionID == installationID else { return }
            if !result.installedOrUpdated.isEmpty {
                await invalidateContentCaches()
            }
            providerRuntimeCatalog = result.catalog
            providerRuntimeInstalled = result.installed
            providerRuntimeLocalReady = !result.installed.isEmpty
            let installedVersions = Dictionary(uniqueKeysWithValues: result.installed.map {
                ($0.manifest.providerID, $0.manifest.version)
            })
            let pending = ProviderRuntimeUpdateState.pendingVersions(
                catalog: result.catalog,
                installedVersions: installedVersions
            )
            succeeded = !result.catalog.isEmpty && result.failures.isEmpty
                && pending.isEmpty && providerRuntimeLocalReady
            if succeeded {
                userPreferences.providerRuntimeInitialInstallCompleted = true
                providerRuntimeLocalPackageInvalid = false
            }
            if userPreferences.providerRuntimeInitialInstallCompleted {
                userPreferences.providerRuntimeInstalledVersions = installedVersions
            }
            providerInstallation.reconcileInstalledVersions(installedVersions, sessionID: installationID)
            providerRuntimePendingVersions = pending
            userPreferences.providerRuntimePendingVersions = pending
            providerRuntimeFailedRelease = result.failures.last?.release
            providerRuntimeHasFailure = !result.failures.isEmpty || !pending.isEmpty
            if !result.failures.isEmpty {
                providerRuntimeStatus = result.installedOrUpdated.isEmpty
                    ? L10n.text("有 {0} 个播放扩展未能更新", ["\(result.failures.count)"])
                    : L10n.text("已更新 {0} 个，失败 {1} 个", ["\(result.installedOrUpdated.count)", "\(result.failures.count)"])
            } else if result.catalog.isEmpty {
                providerRuntimeStatus = L10n.text("暂无可用的播放扩展")
            } else if !pending.isEmpty {
                providerRuntimeStatus = L10n.text("有 {0} 个播放扩展未能启用，请重试。", ["\(pending.count)"])
            } else if result.installedOrUpdated.isEmpty {
                providerRuntimeStatus = L10n.text("播放扩展已是最新")
            } else {
                providerRuntimeStatus = L10n.text("已自动安装或更新 {0} 个支持包", ["\(result.installedOrUpdated.count)"])
            }
        } catch {
            guard providerInstallation.sessionID == installationID else { return }
            providerRuntimeHasFailure = true
            providerRuntimeInstalled = await bootstrap.installedManifests()
            providerRuntimeLocalReady = !providerRuntimeInstalled.isEmpty
            providerRuntimeStatus = providerRuntimeLocalReady && !providerInstallation.isInitialInstallation
                ? L10n.text("无法检查扩展更新，已安装版本仍可使用")
                : providerRuntimeLocalPackageInvalid
                    ? L10n.text("本地扩展不可用，请重新安装")
                    : UserFacingErrorPresenter.message(
                    for: error,
                    context: .extensionOperation(operation: L10n.text("自动准备播放扩展"))
                )
        }
        providerRuntimeProgress = nil
        providerRuntimeBusy = false
        finishProviderRuntimePresentation(succeeded: succeeded, installationID: installationID)
        if savedConfigBlockedByProviderRuntime,
           userPreferences.providerRuntimeInitialInstallCompleted,
           providerRuntimeLocalReady,
           case .failed = savedConfigStartupPhase {
            retrySavedConfigStartup()
        }
    }

    func refreshProviderStorage() async {
        guard let manager = providerRuntimeBootstrap?.manager else { return }
        providerStorageUsage = try? await manager.storageUsage()
        providerComponentsDisabled = await manager.isDisabled()
    }

    func prepareProviderMaintenance(_ mode: ProviderMaintenanceMode) {
        guard !providerRuntimeBusy, let manager = providerRuntimeBootstrap?.manager else { return }
        Task { @MainActor in
            do { self.providerMaintenancePlan = try await manager.prepareMaintenance(mode) }
            catch { self.providerRuntimeStatus = error.localizedDescription; self.providerRuntimeHasFailure = true }
        }
    }

    func executeProviderMaintenance() {
        guard let plan = providerMaintenancePlan, let manager = providerRuntimeBootstrap?.manager else { return }
        providerMaintenancePlan = nil
        providerRuntimeBusy = true
        Task { @MainActor in
            defer { self.providerRuntimeBusy = false }
            do {
                let pending = try await manager.performMaintenance(plan)
                if plan.mode == .uninstall {
                    self.providerRuntimeCollapseTask?.cancel()
                    self.providerInstallation.clear()
                    for document in self.providerRuntimeInstalled {
                        await SpiderReplacementRegistry.shared.removeRemoteBindings(providerID: document.manifest.providerID)
                    }
                    self.providerRuntimeInstalled = []
                    self.providerRuntimeLocalReady = false
                    await self.invalidateContentCaches()
                }
                self.providerRuntimeHasFailure = pending
                self.providerRuntimeStatus = pending ? L10n.text("组件清理尚未完成，请选择恢复维护。") : L10n.text("组件维护完成，账号与用户数据已保留。")
            } catch { self.providerRuntimeHasFailure = true; self.providerRuntimeStatus = error.localizedDescription }
            await self.refreshProviderStorage()
        }
    }

    func recoverProviderMaintenance() {
        guard !providerRuntimeBusy, let manager = providerRuntimeBootstrap?.manager else { return }
        providerRuntimeBusy = true
        Task { @MainActor in
            defer { self.providerRuntimeBusy = false }
            do { try await manager.recoverMaintenance(); self.providerRuntimeStatus = L10n.text("组件维护已恢复。"); self.providerRuntimeHasFailure = false }
            catch { self.providerRuntimeStatus = error.localizedDescription; self.providerRuntimeHasFailure = true }
            await self.refreshProviderStorage()
        }
    }

    func enableProviderComponents() {
        guard !providerRuntimeBusy, let bootstrap = providerRuntimeBootstrap else { return }
        providerRuntimeBusy = true
        Task { @MainActor in
            do {
                try await bootstrap.manager.enableComponents()
                self.providerComponentsDisabled = false
                await self.synchronizeProviderRuntime(using: bootstrap)
            } catch { self.providerRuntimeStatus = error.localizedDescription; self.providerRuntimeHasFailure = true }
            self.providerRuntimeBusy = false
            await self.refreshProviderStorage()
        }
    }

    func installProvider(providerID: String, version: String) {
        guard !providerRuntimeBusy else { return }
        guard let bootstrap = providerRuntimeBootstrap else {
            providerRuntimeHasFailure = true
            providerRuntimeStatus = L10n.text("当前构建未配置签名分发")
            return
        }
        providerRuntimeBusy = true
        providerRuntimeHasFailure = false
        providerRuntimeProgress = nil
        providerRuntimeFailedRelease = nil
        let reference = ProviderVersionReference(providerID: providerID, version: version)
        let installationID = beginProviderRuntimePresentation(retrying: reference)
        Task { @MainActor [weak self] in
            do {
                try await bootstrap.install(providerID: providerID, version: version) { [weak self] progress in
                    await self?.applyProviderRuntimeProgress(progress, installationID: installationID)
                }
                self?.providerRuntimeInstalled = await bootstrap.installedManifests()
                await self?.invalidateContentCaches()
                self?.providerRuntimeStatus = L10n.text("已安装 {0} {1}", ["\(providerID)", "\(version)"])
                self?.providerRuntimeLocalReady = !(self?.providerRuntimeInstalled.isEmpty ?? true)
                if self?.userPreferences.providerRuntimeInitialInstallCompleted == true,
                   let installed = self?.providerRuntimeInstalled {
                    self?.userPreferences.providerRuntimeInstalledVersions = Dictionary(uniqueKeysWithValues: installed.map {
                        ($0.manifest.providerID, $0.manifest.version)
                    })
                }
                self?.providerRuntimePendingVersions.removeValue(forKey: providerID)
                if let pending = self?.providerRuntimePendingVersions {
                    self?.userPreferences.providerRuntimePendingVersions = pending
                }
                if self?.userPreferences.providerRuntimeInitialInstallCompleted == false {
                    await self?.synchronizeProviderRuntime(using: bootstrap)
                } else if let self {
                    self.providerInstallation.reconcileInstalledVersions(
                        Dictionary(uniqueKeysWithValues: self.providerRuntimeInstalled.map {
                            ($0.manifest.providerID, $0.manifest.version)
                        }),
                        sessionID: installationID
                    )
                    let succeeded = self.providerInstallation.readyCount == self.providerInstallation.rows.count
                    self.providerRuntimeHasFailure = !succeeded
                    if !succeeded {
                        self.providerRuntimeStatus = L10n.text("播放扩展安装未完成，请重试")
                    }
                    self.finishProviderRuntimePresentation(succeeded: succeeded, installationID: installationID)
                }
            } catch {
                self?.providerRuntimeHasFailure = true
                self?.providerRuntimeFailedRelease = ProviderVersionReference(
                    providerID: providerID,
                    version: version
                )
                self?.providerRuntimeStatus = UserFacingErrorPresenter.message(
                    for: error,
                    context: .extensionOperation(operation: L10n.text("安装播放扩展"))
                )
                self?.providerInstallation.receiveFailure(
                    reference, message: error.localizedDescription, sessionID: installationID
                )
                self?.finishProviderRuntimePresentation(succeeded: false, installationID: installationID)
            }
            self?.providerRuntimeProgress = nil
            self?.providerRuntimeBusy = false
        }
    }

    private func applyProviderRuntimeCatalog(_ catalog: [ProviderRelease], installationID: UUID) {
        guard providerInstallation.sessionID == installationID else { return }
        providerRuntimeCatalog = catalog
        providerInstallation.receiveCatalog(
            catalog,
            installedVersions: Dictionary(uniqueKeysWithValues: providerRuntimeInstalled.map {
                ($0.manifest.providerID, $0.manifest.version)
            }),
            sessionID: installationID
        )
    }

    private func applyProviderRuntimeFailure(_ failure: ProviderRuntimeSyncFailure, installationID: UUID) {
        guard providerInstallation.sessionID == installationID else { return }
        providerRuntimeHasFailure = true
        providerRuntimeFailedRelease = failure.release
        providerInstallation.receiveFailure(failure.release, message: failure.message, sessionID: installationID)
    }

    private func applyProviderRuntimeProgress(_ progress: ProviderInstallProgress, installationID: UUID) {
        guard providerInstallation.sessionID == installationID else { return }
        providerRuntimeProgress = progress
        providerInstallation.receiveProgress(progress, sessionID: installationID)
        let identity = "\(progress.providerID) \(progress.version)"
        switch progress.phase {
        case .fetchingCatalog:
            providerRuntimeStatus = L10n.text("正在获取组件列表")
        case .downloading:
            if let fraction = progress.fractionCompleted {
                providerRuntimeStatus = L10n.text("正在下载 {0} {1}%", ["\(identity)", "\(Int(fraction * 100))"])
            } else {
                providerRuntimeStatus = L10n.text("正在下载 {0}", ["\(identity)"])
            }
        case .verifyingArchive:
            providerRuntimeStatus = L10n.text("正在校验 {0}", ["\(identity)"])
        case .extracting:
            providerRuntimeStatus = L10n.text("正在解包 {0}", ["\(identity)"])
        case .verifyingPackage:
            providerRuntimeStatus = L10n.text("正在验证签名 {0}", ["\(identity)"])
        case .launching:
            providerRuntimeStatus = L10n.text("正在启动 {0}", ["\(identity)"])
        case .completed:
            providerRuntimeStatus = L10n.text("已安装 {0}", ["\(identity)"])
        }
    }

    private func configurePlayerEngine(_ engine: MPVPlayerEngine, playerState: PlayerState) {
        engine.playerState = playerState
        engine.artworkLoader = { spec in try await PlaybackArtworkLoader.load(spec) }
        engine.playbackFailureDetailsHandler = { [weak self] spec, failure in
            Task { @MainActor in
                self?.handleMPVPlaybackFailure(spec: spec, message: failure.message, failure: failure)
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
        engine.liveConnectionRepairHandler = { [weak self] spec in
            Task { @MainActor in self?.repairLiveConnectionIfNeeded(spec: spec) }
        }
        engine.secondarySubtitleDelayProvider = { UserPreferences.shared.subtitleDelay(for: $0, secondary: true) }
        engine.subtitleDelayProvider = { UserPreferences.shared.subtitleDelay(for: $0) }
        engine.subtitleSettingsProvider = {
            SubtitleRenderSettings(
                fontSize: UserPreferences.shared.subtitleFontSize,
                position: UserPreferences.shared.subtitlePosition,
                overrideSourceStyle: UserPreferences.shared.subtitleOverrideSourceStyle,
                fontName: UserPreferences.shared.subtitleAppearance.fontName,
                appearance: UserPreferences.shared.subtitleAppearance
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
        let rawURL = XtreamLogRedaction.redact(rawURL)
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
            name: L10n.text("屏蔽站点：{0}", ["\(site.name.isEmpty ? site.key : site.name)"])
        )
        do {
            try SourceHygieneStore.shared.addRule(rule)
            reloadSourceHygieneRules()
            sourceDiagnosticExportStatus = L10n.text("已添加治理规则，重新加载配置后生效")
        } catch {
            sourceDiagnosticExportStatus = UserFacingErrorPresenter.message(
                for: error,
                context: .storage(operation: L10n.text("保存视频源屏蔽规则"))
            )
        }
    }

    func clearSourceHygieneRules() {
        do {
            try SourceHygieneStore.shared.clear()
            reloadSourceHygieneRules()
            sourceDiagnosticExportStatus = L10n.text("已清空源治理规则，重新加载配置后恢复")
        } catch {
            sourceDiagnosticExportStatus = UserFacingErrorPresenter.message(
                for: error,
                context: .storage(operation: L10n.text("恢复视频源屏蔽规则"))
            )
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
            sourceDiagnosticExportStatus = L10n.text("已导出诊断：{0}", ["\(url.path)"])
        } catch {
            sourceDiagnosticExportStatus = UserFacingErrorPresenter.message(
                for: error,
                context: .storage(operation: L10n.text("导出诊断文件"))
            )
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
            liveError = L10n.text("当前没有可检测的频道分组。请先加载或切换直播源。")
            return
        }
        let liveName = activeLive?.name ?? "live"
        let groupName = group.name
        let targets = group.channels.flatMap { channel in
            channel.urls.enumerated().map { (channel: channel, index: $0.offset, url: $0.element) }
        }
        guard !targets.isEmpty else {
            liveError = L10n.text("“{0}”没有可检测的线路。请切换分组或直播源。", ["\(group.name)"])
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
    func loadConfig(
        url: String,
        persistUserConfig: Bool = true,
        waitForProviderRuntime: Bool = true,
        restoreSavedConfiguration: Bool = false,
        preparedInput: ResolvedVodInput? = nil
    ) async {
        invalidateConfigurationRefresh()
        let generation = configurationLoadGeneration
        if waitForProviderRuntime && !url.hasPrefix("netvplayer-xtream://") {
            savedConfigStartupPhase = .preparingExtension
            let ready = await waitForProviderRuntimeReadiness()
            guard !Task.isCancelled, generation == configurationLoadGeneration else { return }
            guard ready else {
                configError = providerRuntimeStatus
                savedConfigBlockedByProviderRuntime = true
                savedConfigStartupPhase = .failed(providerRuntimeStatus)
                return
            }
        }
        await invalidateContentCaches()
        guard !Task.isCancelled, generation == configurationLoadGeneration else { return }
        resetSearchState()
        savedConfigBlockedByProviderRuntime = false
        savedConfigStartupPhase = .loading
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
            guard !Task.isCancelled, generation == configurationLoadGeneration else { return }
            let savedConfig = savedConfigs.first {
                $0.type == .vod && $0.url.trimmingCharacters(in: .whitespacesAndNewlines) == url.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let resolvedInput: ResolvedVodInput
            let usesRemoteSource = ["http", "https"].contains(URL(string: url)?.scheme?.lowercased() ?? "")
            if let preparedInput {
                resolvedInput = preparedInput
            } else if restoreSavedConfiguration, usesRemoteSource,
                      let cached = configResolver.cachedVodInput(url: url, cachedConfig: savedConfig) {
                resolvedInput = cached
            } else {
                resolvedInput = try await configResolver.loadVodInput(url: url, cachedConfig: savedConfig)
            }
            guard !Task.isCancelled, generation == configurationLoadGeneration else { return }
            let canonicalURL = resolvedInput.canonicalURL
            self.currentVodInputFingerprint = resolvedInput.fingerprint
            self.currentVodInputKind = resolvedInput.kind
            self.currentVodProviderID = resolvedInput.providerID
            log("[DEBUG_LOGGER] 点播输入识别成功: \(resolvedInput.kind.rawValue), 长度: \(resolvedInput.json.count)")

            do {
                if resolvedInput.usesCachedConfiguration {
                    // Saved snapshots already contain merged arrays; startup must not refetch them.
                    try VodConfig.shared.parse(json: resolvedInput.json, config: resolvedInput.config)
                } else {
                    try await VodConfig.shared.parseResolvingExternalArrays(
                        json: resolvedInput.json,
                        config: resolvedInput.config
                    )
                }
                guard !Task.isCancelled, generation == configurationLoadGeneration else { return }
                log("[DEBUG_LOGGER] 解析成功")
            } catch {
                log("[DEBUG_LOGGER] parse 解析抛出异常: \(error)")
                throw error
            }
            
            // 写入偏好
            if persistUserConfig {
                userPreferences.currentVodConfigUrl = canonicalURL
            }

            self.sites = VodConfig.shared.sites + fileServiceStore.load().services.map { $0.site() }
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
            guard !Task.isCancelled, generation == configurationLoadGeneration else { return }
            self.nativeReplacementSiteKeys = replacementKeys
            self.externalSourceReports = ExternalSourceCompatibilityAuditor
                .reports(configLocation: canonicalURL, sites: self.sites, snapshot: self.configAggregationSnapshot)
                .map { report in
                    guard replacementKeys.contains(report.siteKey), !report.status.isNativeReplacement else {
                        return report
                    }
                    var updated = report
                    updated.status = .native
                    updated.reason = L10n.text("已提供当前系统可用的兼容实现")
                    updated.suggestion = L10n.text("可直接使用；若加载失败，请检查网络或切换视频源")
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
            let sourceNotice = self.configNotice
            if resolvedInput.usesCachedConfiguration {
                self.configNotice = [
                    L10n.text("已恢复上次成功加载的站点配置，正在后台检查更新。"),
                    self.configNotice,
                ].compactMap { $0 }.joined(separator: "\n")
                log("[CONFIG_CACHE] 已恢复同一地址的有效站点配置，站点数: \(self.sites.count)")
            }
            self.contentCatalogState = ContentCatalogCore.resetContent(self.contentCatalogState)
            self.vodError = nil
            self.libraryConfigurationURL = canonicalURL
            if persistUserConfig {
                saveLoadedConfig(url: canonicalURL)
            }
            migrateLibraryIdentityIfPossible()
            
            // 独立直播配置优先；点播刷新不能把用户选中的直播源换回第一项。
            let liveConfigURL = userPreferences.currentLiveConfigUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !liveConfigURL.isEmpty, liveConfigURL != canonicalURL {
                await loadLiveConfiguration(url: liveConfigURL)
                guard !Task.isCancelled, generation == configurationLoadGeneration else { return }
            } else {
                self.lives = LiveConfig.shared.lives
                if let account = userPreferences.xtreamConfigurations.first(where: { $0.url == canonicalURL }) {
                    self.lives.append(Live(name: account.name, url: account.url))
                }
                let selected = LiveConfigurationInput(sources: lives, initialGroups: nil)
                    .selectedSource(preferredName: userPreferences.currentLiveName)
                resetLiveSource(selected)
            }
            
            self.configError = nil
            self.isConfigLoaded = true
            self.savedConfigStartupPhase = .ready
            if resolvedInput.usesCachedConfiguration {
                scheduleConfigurationRefresh(
                    url: canonicalURL, generation: generation,
                    sourceNotice: sourceNotice, previousError: resolvedInput.configurationRefreshError
                )
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
            guard !Task.isCancelled, generation == configurationLoadGeneration else { return }
            if liveConfigURL.isEmpty || liveConfigURL == canonicalURL {
                await loadLiveContentAndResumeIfNeeded()
            }
        } catch {
            guard !Task.isCancelled, generation == configurationLoadGeneration else { return }
            if let configError = error as? ConfigError,
               case .isDepot(let depots) = configError {
                self.availableDepots = depots
                self.externalSourceReports = []
                self.configAggregationSnapshot = ConfigAggregationSnapshot(rootURL: url)
                self.nativeReplacementSiteKeys = []
                self.configError = L10n.text("配置仓库需选择子配置")
                self.isConfigLoaded = false
                self.savedConfigStartupPhase = .failed(self.configError ?? L10n.text("请选择子配置"))
                log("[DEBUG_LOGGER] 配置仓库包含 \(depots.count) 个子配置")
                return
            }
            log("[DEBUG_LOGGER] loadConfig 遭遇总异常: \(error)")
            recordRemoteDiagnosticError(
                "CONFIG_LOAD_FAILED",
                error: error,
                attempt: 0
            )
            self.configError = UserFacingErrorPresenter.message(for: error, context: .configuration)
            self.savedConfigStartupPhase = .failed(self.configError ?? L10n.text("数据源加载失败"))
            self.externalSourceReports = []
            self.configAggregationSnapshot = ConfigAggregationSnapshot(rootURL: url)
            self.nativeReplacementSiteKeys = []
            self.lastFeedbackFailureStage = "Config.load"
            self.lastFeedbackFailureCategory = .config
            self.isConfigLoaded = false
            if restoreSavedConfiguration {
                scheduleConfigurationRefresh(url: url, generation: generation, sourceNotice: nil, previousError: error)
            }
        }
    }

    private func invalidateConfigurationRefresh() {
        configurationLoadGeneration &+= 1
        configurationRefreshTask?.cancel()
        configurationRefreshTask = nil
    }

    private func scheduleConfigurationRefresh(
        url: String, generation: UInt64, sourceNotice: String?, previousError: (any Error)?
    ) {
        guard let sourceURL = URL(string: url),
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""),
              !sourceURL.path.lowercased().hasSuffix(".js.md5") else { return }
        let initialDelay = previousError.flatMap { ConfigurationRecoveryPolicy.retryDelay(after: $0, retryNumber: 0) }
        if let previousError, initialDelay == nil {
            showConfigurationRefreshFailure(previousError, sourceNotice: sourceNotice)
            return
        }
        let resolver = configResolver
        let sleeper = configurationRefreshSleeper
        configurationRefreshTask = Task { @MainActor [weak self] in
            defer {
                if self?.configurationLoadGeneration == generation { self?.configurationRefreshTask = nil }
            }
            var delay = initialDelay
            var retryNumber = previousError == nil ? 0 : 1
            while !Task.isCancelled {
                do {
                    if let delay { try await sleeper(delay) }
                    try Task.checkCancellation()
                    guard self?.configurationLoadGeneration == generation else { return }
                    // No cached fallback here: only an actual successful refresh may replace the saved snapshot.
                    let input = try await resolver.loadVodSnapshot(url: url)
                    try Task.checkCancellation()
                    guard let self, self.configurationLoadGeneration == generation else { return }
                    if !self.isConfigLoaded || self.libraryConfigurationURL != input.canonicalURL
                        || self.currentVodInputFingerprint == nil {
                        self.configurationRefreshTask = nil
                        await self.loadConfig(url: url, waitForProviderRuntime: false, preparedInput: input)
                        return
                    }
                    try self.saveRefreshedConfiguration(input, sourceNotice: sourceNotice)
                    log("[CONFIG_REFRESH] 后台配置更新完成")
                    return
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError),
                          let self, self.configurationLoadGeneration == generation else { return }
                    self.recordRemoteDiagnosticError("CONFIG_REFRESH_FAILED", error: error, attempt: retryNumber)
                    self.showConfigurationRefreshFailure(error, sourceNotice: sourceNotice)
                    guard let nextDelay = ConfigurationRecoveryPolicy.retryDelay(after: error, retryNumber: retryNumber) else { return }
                    retryNumber += 1
                    delay = nextDelay
                }
            }
        }
    }

    private func showConfigurationRefreshFailure(_ error: Error, sourceNotice: String?) {
        let message = UserFacingErrorPresenter.message(for: error, context: .configuration)
        if isConfigLoaded {
            configNotice = [L10n.text("已保留上次成功加载的站点配置。") + message, sourceNotice]
                .compactMap { $0 }.joined(separator: "\n")
        } else {
            configError = message
            savedConfigStartupPhase = .failed(message)
        }
    }

    private func saveRefreshedConfiguration(_ input: ResolvedVodInput, sourceNotice: String?) throws {
        guard input.kind != .nodeJSBundle,
              let data = input.json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VodInputError.unrecognizedContent
        }
        var refreshed = savedConfigs.first { $0.type == .vod && $0.url == input.canonicalURL } ?? input.config
        let previousJSON = refreshed.json.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary }
        refreshed.json = input.json
        refreshed.logo = object["logo"] as? String ?? ""
        refreshed.home = object["home"] as? String ?? ""
        refreshed.parse = object["parse"] as? String ?? ""
        refreshed.notice = object["notice"] as? String ?? ""
        refreshed.danmaku = object["danmaku"] as? String ?? ""
        guard configResolver.cachedVodInput(url: input.canonicalURL, cachedConfig: refreshed) != nil else {
            throw VodInputError.unrecognizedContent
        }
        let changed = previousJSON != object as NSDictionary
        if changed {
            let transition = ApplicationLibraryCore.registerConfig(
                applicationLibraryState, loadedConfig: refreshed, canonicalURL: input.canonicalURL,
                fallbackName: displayName(forConfigURL: input.canonicalURL)
            )
            try applicationLibraryPersistence.saveConfigs(transition.state.configs)
            applicationLibraryState = transition.state
        }
        configNotice = changed
            ? [L10n.text("数据源配置已后台更新，将在下次加载时生效。"), sourceNotice].compactMap { $0 }.joined(separator: "\n")
            : sourceNotice
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

        let currentURL = userPreferences.currentVodConfigUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let removedURL = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.type == .vod, currentURL == removedURL || libraryConfigurationURL == removedURL {
            initialConfigTask?.cancel()
            invalidateConfigurationRefresh()
            if currentURL == removedURL { userPreferences.currentVodConfigUrl = "" }
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
        let backup = try historyWriter.performReplacement { try storageManager.importBackup(from: url) }
        historyClearedThroughGeneration = playbackSessionState.generation
        self.applicationLibraryState = applicationLibraryPersistence.loadApplicationLibrary()
        migrateLibraryIdentityIfPossible()
        self.trackItems = storageManager.loadTracks()
        self.selectedSearchSiteKeys = UserPreferences.shared.defaultSearchSiteKeys
        selectAppearanceTheme(AppAppearanceDefaults.resolvedThemeID(
            storedRawValue: UserPreferences.shared.appearanceThemeID
        ))
        FileServicesState.shared.reload()
        FileServicesState.shared.loadMedia()
        Task {
            await MediaLibraryScanner.shared.cancelAllAndWait()
            await MetadataMatcher.shared.cancelAllAndWait()
            do {
                try await MediaIndex.shared.restoreCatalogState(libraries: FileServiceStore.shared.load().libraries,
                    corrections: FileServiceStore.shared.loadCorrections(), resetScanState: backup.fileServices != nil)
            } catch { FileServicesState.shared.error = error.localizedDescription }
            FileServicesState.shared.loadMedia()
            await MediaLibraryScanner.shared.scanStaleLibraries()
        }
        return backup
    }

    @discardableResult
    func importPlaybackProgress(from url: URL) throws -> PlaybackProgressExport {
        let progress = try historyWriter.performReplacement { try storageManager.importPlaybackProgress(from: url) }
        historyClearedThroughGeneration = playbackSessionState.generation
        self.applicationLibraryState = ApplicationLibraryCore.replacingHistory(
            applicationLibraryState,
            with: applicationLibraryPersistence.loadHistory()
        )
        migrateLibraryIdentityIfPossible()
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
        // Direct web playback has no native detail to restore on exit.
        detailVod = nil
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
            return url.isEmpty ? L10n.text("点播配置") : url
        }
        let path = components.path.split(separator: "/").last.map(String.init) ?? ""
        return path.isEmpty ? host : "\(host)/\(path)"
    }

    /// 切换当前激活的点播源
    func reloadFileServiceSites() {
        let nativeSites = fileServiceStore.load().services.map { $0.site() }
        sites = sites.filter { !$0.api.hasPrefix("netvplayer-files://") } + nativeSites
        if activeSite == nil || (activeSite?.api.hasPrefix("netvplayer-files://") == true && !sites.contains(where: { $0.key == activeSite?.key })) {
            if let site = sites.first(where: { $0.key == userPreferences.currentVodSiteKey }) ?? sites.first {
                activateSite(site); preferredVodHomeSiteKey = site.key
            } else { activeSite = nil; currentSiteName = "选择线路" }
        }
        if !nativeSites.isEmpty { isConfigLoaded = true; savedConfigStartupPhase = .ready }
    }

    func changeSite(site: Site) async {
        if let previous = activeSite, previous.key != site.key, previous.api.hasPrefix("netvplayer-files://"),
           let id = UUID(uuidString: String(previous.api.dropFirst("netvplayer-files://".count))) {
            await MediaLibraryScanner.shared.cancel(serviceID: id)
            await MetadataMatcher.shared.cancel(serviceID: id)
        }
        FileServicesState.shared.cancel()
        invalidateNextEpisodePreload(reason: "site-changed")
        log("[DEBUG_LOGGER] 切换当前点播源 site=\(site.name)")
        libraryHomeRefreshTask?.cancel()
        libraryHomeRefreshTask = nil
        preferredVodHomeSiteKey = site.key
        userPreferences.currentVodSiteKey = site.key
        activateSite(site)
        await loadHomeContent()
    }

    private func activateSite(_ site: Site) {
        vodDataSource.retire(catalog: catalogRepository)
        cancelCloudAuthorization()
        cancelEpisodeListRefresh()
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
    func loadHomeContent(
        retryAttempt: Int = 0,
        forceRefresh: Bool = false,
        invalidateCache: Bool = true
    ) async {
        guard let site = activeSite else {
            log("[DEBUG_LOGGER] loadHomeContent 失败: activeSite 为 nil")
            return
        }
        guard !Task.isCancelled else { return }
        catalogRequestSerial &+= 1
        let requestSerial = catalogRequestSerial
        loadingCatalogCacheKey = nil
        isCatalogRefreshing = false
        let coordinator = vodDataSource
        let sourceScope = vodScope(for: site)
        await coordinator.waitForRetirement()
        let cacheKey = CatalogCacheBaseKey(
            revision: catalogCacheRevision,
            siteKey: site.key,
            kind: .home
        )
        var preserveExisting = displayedCatalogCacheKey == cacheKey && !vods.isEmpty

        if forceRefresh, invalidateCache {
            await catalogRepository.invalidate(cacheKey)
            guard requestSerial == catalogRequestSerial, activeSite?.key == site.key else { return }
        } else if !forceRefresh, retryAttempt == 0 {
            let cached = await catalogRepository.lookup(cacheKey)
            guard requestSerial == catalogRequestSerial, activeSite?.key == site.key else { return }
            if let first = cached.pages.first {
                contentCatalogState = ContentCatalogCore.restoreHome(
                    contentCatalogState,
                    payload: Self.catalogPayload(from: first)
                )
                displayedCatalogCacheKey = cacheKey
                preserveExisting = true
                vodError = nil
                DiagnosticLog.write("[CATALOG_CACHE_HIT] kind=home freshness=\(cached.freshness)")
                switch cached.freshness {
                case .fresh:
                    return
                case .stale:
                    scheduleCatalogRefresh {
                        await self.loadHomeContent(forceRefresh: true, invalidateCache: false)
                    }
                    return
                case .expired, .miss:
                    break
                }
            }
        }

        let generation: UInt64
        if preserveExisting {
            generation = contentCatalogState.generation
            isCatalogRefreshing = true
        } else {
            let loadingState = ContentCatalogCore.beginHome(contentCatalogState)
            contentCatalogState = loadingState
            generation = loadingState.generation
        }
        defer {
            if requestSerial == catalogRequestSerial { isCatalogRefreshing = false }
        }
        self.vodError = nil
        log("[DEBUG_LOGGER] 开始加载站点首页 site=\(site.name), key=\(site.key), type=\(site.siteType)")
        if site.isAndroidCrawlerSource,
           !(await SpiderReplacementRegistry.shared.hasReplacement(for: site)) {
            guard requestSerial == catalogRequestSerial, activeSite?.key == site.key else { return }
            let isCurrent = contentCatalogState.generation == generation
            contentCatalogState = ContentCatalogCore.failHome(
                contentCatalogState,
                generation: generation,
                clearContent: true
            )
            if isCurrent {
                self.vodError = site.unsupportedSourceMessage
            }
            log("[DEBUG_LOGGER] \(site.unsupportedSourceMessage)")
            return
        }

        guard !Task.isCancelled, requestSerial == catalogRequestSerial, activeSite?.key == site.key else { return }
        do {
            let result = try await catalogRepository.result(
                for: cacheKey,
                page: 1,
                forceRefresh: forceRefresh || preserveExisting
            ) {
                try await coordinator.home(site: site, scope: sourceScope)
            }
            guard !Task.isCancelled,
                  activeSite?.key == site.key,
                  requestSerial == catalogRequestSerial,
                  contentCatalogState.generation == generation else { return }
            contentCatalogState = ContentCatalogCore.restoreHome(
                contentCatalogState,
                payload: Self.catalogPayload(from: result)
            )
            displayedCatalogCacheKey = cacheKey
            log("[DEBUG_LOGGER] 首页加载成功! 分类数: \(result.types.count), 影片数: \(result.list.count)")
        } catch {
            log("[DEBUG_LOGGER] 加载首页推荐发生异常: \(error)")
            if let delay = Self.transientPreparationRetryDelayNanoseconds(
                for: error,
                attempt: retryAttempt
            ) {
                log("[CATALOG_LOAD_RETRY] attempt=\(retryAttempt + 1)")
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled,
                      requestSerial == catalogRequestSerial,
                      activeSite?.key == site.key,
                      contentCatalogState.generation == generation else { return }
                await loadHomeContent(
                    retryAttempt: retryAttempt + 1,
                    forceRefresh: true,
                    invalidateCache: invalidateCache
                )
                return
            }
            recordRemoteDiagnosticError(
                "CATALOG_LOAD_FAILED",
                error: error,
                attempt: retryAttempt
            )
            let isCurrent = requestSerial == catalogRequestSerial
                && activeSite?.key == site.key
                && contentCatalogState.generation == generation
            if !preserveExisting {
                contentCatalogState = ContentCatalogCore.failHome(
                    contentCatalogState,
                    generation: generation
                )
            }
            if isCurrent {
                self.vodError = preserveExisting ? nil : UserFacingErrorPresenter.message(
                    for: error,
                    context: .content(sourceName: site.name)
                )
            }
        }
    }

    /// 切换点播分类
    func selectCategory(
        _ category: VodClass,
        forceRefresh: Bool = false,
        invalidateCache: Bool = true
    ) async {
        guard let site = activeSite, !Task.isCancelled else { return }
        if !forceRefresh, selectedCategory?.typeId == category.typeId,
           let currentKey = loadingCatalogCacheKey ?? displayedCatalogCacheKey,
           currentKey.revision == catalogCacheRevision,
           currentKey.siteKey == site.key,
           currentKey.kind == .category(category.typeId) {
            return
        }
        if site.isAllliveGuard, category.typeId == "search" {
            catalogRequestSerial &+= 1
            loadingCatalogCacheKey = nil
            isCatalogRefreshing = false
            self.isDetailPresented = false
            self.isDetailLoading = false
            self.selectedTab = .search
            return
        }
        let transition = ContentCatalogCore.beginCategory(contentCatalogState, category: category)
        await executeCategoryTransition(
            transition,
            site: site,
            forceRefresh: forceRefresh,
            invalidateCache: invalidateCache
        )
    }

    func loadMoreCategoryContentIfNeeded(currentVod vod: Vod) async {
        guard let site = activeSite, let category = selectedCategory,
              displayedCatalogCacheKey != nil, !isCatalogRefreshing else { return }
        let requestSerial = catalogRequestSerial
        if site.isAndroidCrawlerSource,
           !(await SpiderReplacementRegistry.shared.hasReplacement(for: site)) {
            return
        }

        guard requestSerial == catalogRequestSerial, activeSite?.key == site.key else { return }
        let transition = ContentCatalogCore.beginNextPage(
            contentCatalogState,
            triggerVodID: vod.vodId
        )
        contentCatalogState = transition.state
        guard let request = transition.request else { return }

        do {
            let coordinator = vodDataSource
            let sourceScope = vodScope(for: site)
            await coordinator.waitForRetirement()
            let cacheKey = catalogCacheKey(site: site, request: request)
            let sites = self.sites
            let result = try await catalogRepository.result(for: cacheKey, page: request.page) {
                try await coordinator.category(site: site, id: request.categoryID, page: request.page,
                                               selection: request.selection, sites: sites, scope: sourceScope)
            }
            guard !Task.isCancelled, requestSerial == catalogRequestSerial, activeSite?.key == site.key else { return }
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
        site: Site,
        forceRefresh: Bool = false,
        invalidateCache: Bool = false
    ) async {
        guard !Task.isCancelled else { return }
        if case let .invalidTextFilter(name) = transition.failure {
            vodError = L10n.text("{0}筛选值无效", ["\(name)"])
            return
        }
        guard transition.failure == nil else { return }
        guard let request = transition.request else {
            catalogRequestSerial &+= 1
            loadingCatalogCacheKey = nil
            contentCatalogState = transition.state
            isCatalogRefreshing = false
            return
        }
        let coordinator = vodDataSource
        let sourceScope = vodScope(for: site)
        await coordinator.waitForRetirement()
        let cacheKey = catalogCacheKey(site: site, request: request)
        let sameSelection = selectedCategory?.typeId == request.categoryID
            && selectedCategoryFilterValues == request.selection
        // A duplicate click must not retire the request that is already filling this list.
        if !forceRefresh, sameSelection,
           displayedCatalogCacheKey == cacheKey || loadingCatalogCacheKey == cacheKey {
            return
        }
        catalogRequestSerial &+= 1
        let requestSerial = catalogRequestSerial
        loadingCatalogCacheKey = cacheKey
        defer {
            if requestSerial == catalogRequestSerial { loadingCatalogCacheKey = nil }
        }
        isCatalogRefreshing = false
        vodError = nil
        let category = transition.state.selectedCategory ?? VodClass(typeId: request.categoryID)
        var preserveExisting = displayedCatalogCacheKey == cacheKey && !vods.isEmpty

        if forceRefresh, invalidateCache {
            await catalogRepository.invalidate(cacheKey)
            guard requestSerial == catalogRequestSerial, activeSite?.key == site.key else { return }
        } else if !forceRefresh {
            let cached = await catalogRepository.lookup(cacheKey)
            guard !Task.isCancelled, requestSerial == catalogRequestSerial, activeSite?.key == site.key else { return }
            if !cached.pages.isEmpty {
                // The transition carries the newly selected filter combination.
                contentCatalogState = ContentCatalogCore.restoreCategory(
                    transition.state,
                    category: category,
                    payloads: cached.pages.map(Self.catalogPayload(from:))
                )
                displayedCatalogCacheKey = cacheKey
                preserveExisting = true
                DiagnosticLog.write("[CATALOG_CACHE_HIT] kind=category freshness=\(cached.freshness) pages=\(cached.pages.count)")
                switch cached.freshness {
                case .fresh:
                    return
                case .stale:
                    scheduleCatalogRefresh {
                        await self.executeCategoryTransition(transition, site: site, forceRefresh: true)
                    }
                    return
                case .expired, .miss:
                    break
                }
            }
        }

        let generation: UInt64
        if preserveExisting {
            generation = contentCatalogState.generation
            isCatalogRefreshing = true
        } else {
            contentCatalogState = transition.state
            generation = request.generation
        }
        defer {
            if requestSerial == catalogRequestSerial { isCatalogRefreshing = false }
        }

        if site.isAndroidCrawlerSource,
           !(await SpiderReplacementRegistry.shared.hasReplacement(for: site)) {
            guard requestSerial == catalogRequestSerial, activeSite?.key == site.key else { return }
            if !preserveExisting {
                contentCatalogState = ContentCatalogCore.failCategory(contentCatalogState, request: request)
            }
            vodError = preserveExisting ? nil : site.unsupportedSourceMessage
            return
        }

        guard !Task.isCancelled, requestSerial == catalogRequestSerial, activeSite?.key == site.key else { return }
        do {
            let sites = self.sites
            let result = try await catalogRepository.result(
                for: cacheKey,
                page: request.page,
                forceRefresh: forceRefresh || preserveExisting
            ) {
                try await coordinator.category(site: site, id: request.categoryID, page: request.page,
                                               selection: request.selection, sites: sites, scope: sourceScope)
            }
            guard !Task.isCancelled,
                  activeSite?.key == site.key,
                  requestSerial == catalogRequestSerial,
                  contentCatalogState.generation == generation else { return }
            let cached = await catalogRepository.lookup(cacheKey)
            guard !Task.isCancelled,
                  activeSite?.key == site.key,
                  requestSerial == catalogRequestSerial,
                  contentCatalogState.generation == generation else { return }
            contentCatalogState = ContentCatalogCore.restoreCategory(
                contentCatalogState,
                category: category,
                payloads: (cached.pages.isEmpty ? [result] : cached.pages).map(Self.catalogPayload(from:))
            )
            displayedCatalogCacheKey = cacheKey
        } catch {
            let isCurrent = requestSerial == catalogRequestSerial
                && activeSite?.key == site.key
                && contentCatalogState.generation == generation
            guard isCurrent else { return }
            if !preserveExisting {
                contentCatalogState = ContentCatalogCore.failCategory(contentCatalogState, request: request)
            }
            print("[AppState] 加载分类 \(category.typeName) 失败: \(error)")
            vodError = preserveExisting ? nil : UserFacingErrorPresenter.message(
                for: error,
                context: .content(sourceName: site.name)
            )
        }
    }

    func refreshCurrentCatalog() async {
        if activeSite?.api.hasPrefix("netvplayer-files://") == true {
            FileServicesState.shared.refreshCurrentView()
            return
        }
        if let category = selectedCategory {
            await selectCategory(category, forceRefresh: true)
        } else {
            await loadHomeContent(forceRefresh: true)
        }
    }

    private func scheduleCatalogRefresh(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let scheduledSerial = catalogRequestSerial
        catalogRefreshTask?.cancel()
        catalogRefreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.catalogRequestSerial == scheduledSerial else { return }
            // The request owns its loading flag. A retired task must not clear a newer task's flag.
            await operation()
        }
    }

    private func vodScope(for site: Site) -> DataSourceRequestScope {
        vodDataSource.requests.scope(source: librarySourceFingerprint(siteKey: site.key) + "|" + site.key, revision: catalogCacheRevision)
    }

    private func catalogCacheKey(site: Site, request: ContentCatalogRequest) -> CatalogCacheBaseKey {
        CatalogCacheBaseKey(
            revision: catalogCacheRevision,
            siteKey: site.key,
            kind: .category(request.categoryID),
            selection: request.selection
        )
    }

    private func invalidateContentCaches() async {
        invalidateNextEpisodePreload(reason: "content-cache-invalidated")
        vodDataSource.requests.cancelAll()
        catalogCacheRevision &+= 1
        catalogRequestSerial &+= 1
        displayedCatalogCacheKey = nil
        loadingCatalogCacheKey = nil
        catalogRefreshTask?.cancel()
        catalogRefreshTask = nil
        detailPrefetchTask?.cancel()
        detailPrefetchTask = nil
        detailLoadGeneration &+= 1
        isDetailLoading = false
        resetSearchState()
        await searchEngine.invalidateSearchCache()
        await catalogRepository.clear()
        await VodDetailRepository.shared.clear()
        await SpiderReplacementRegistry.shared.clearContentCaches()
        NotificationCenter.default.post(name: .netVplayerCacheDidChange, object: nil)
    }

    func didClearPerformanceCaches() {
        resetSearchState()
        Task { await searchEngine.invalidateSearchCache() }
        invalidateNextEpisodePreload(reason: "performance-cache-cleared")
        vodDataSource.requests.cancelAll()
        catalogCacheRevision &+= 1
        catalogRequestSerial &+= 1
        contentCatalogState.generation &+= 1
        contentCatalogState.isLoading = false
        contentCatalogState.isLoadingMore = false
        libraryHomeRefreshTask?.cancel()
        libraryHomeRefreshTask = nil
        displayedCatalogCacheKey = nil
        loadingCatalogCacheKey = nil
        catalogRefreshTask?.cancel()
        catalogRefreshTask = nil
        isCatalogRefreshing = false
        detailLoadGeneration &+= 1
        isDetailLoading = false
        detailPrefetchTask?.cancel()
        detailPrefetchTask = nil
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
            updated.vodContent = L10n.text("当前未保存{0}授权。", ["\(request.provider.localizedDisplayName)"])
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
        if activeSite?.key != site.key {
            activateSite(site)
        }
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
        isDetailPresented = true
        isDetailLoading = true
        defer { isDetailLoading = false }

        let title = vod.vodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.text("{0}分享", ["\(Self.driveProviderDisplayName(candidate.provider))"])
            : vod.vodName
        let episodes = await importedDriveEpisodes(for: candidate, title: title)
        let playURL = episodes.map { "\(Self.safeEpisodeTitle($0.name))$\($0.url)" }.joined(separator: "#")
        let detail = Vod(
            vodId: candidate.canonicalURL,
            vodName: title,
            vodPic: vod.vodPic,
            vodContent: candidate.support.reason,
            vodRemarks: candidate.support.status == .supported ? Self.driveProviderDisplayName(candidate.provider) : L10n.text("待验证"),
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
        cancelCloudAuthorization()
        cancelEpisodeListRefresh()
        invalidateNextEpisodePreload(reason: "vod-changed")
        guard let site = activeSite else { return }
        detailPrefetchTask?.cancel()
        detailPrefetchTask = nil
        detailLoadGeneration &+= 1
        let loadGeneration = detailLoadGeneration
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
        episodeListState = .loading
        let sourceFingerprint = playbackAuthorizationOrigin.sourceFingerprint
        defer {
            if self.detailLoadGeneration == loadGeneration {
                self.isDetailLoading = false
            }
        }

        let key = VodDetailCacheKey(
            revision: catalogCacheRevision,
            siteKey: site.key,
            vodID: vod.vodId
        )
        let sites = self.sites
        let coordinator = vodDataSource
        let sourceScope = vodScope(for: site)
        let initialResult: Result
        do {
            await coordinator.waitForRetirement()
            initialResult = try await VodDetailRepository.shared.result(for: key) {
                try await coordinator.detail(site: site, id: vod.vodId, sites: sites, scope: sourceScope)
            }
        } catch {
            guard detailLoadGeneration == loadGeneration, !(error is CancellationError), !Task.isCancelled else { return }
            recordSiteHealth(
                eventType: .detail,
                siteKey: site.key,
                siteName: site.name,
                success: false,
                durationMs: durationMilliseconds(since: detailStartedAt),
                errorCategory: .spider,
                host: site.api
            )
            episodeListState = .incomplete
            print("[AppState] 加载详情失败: \(error)")
            return
        }

        guard detailLoadGeneration == loadGeneration,
              activeSite?.key == site.key,
              playbackAuthorizationOrigin.sourceFingerprint == sourceFingerprint else { return }
        let initialDurationMs = durationMilliseconds(since: detailStartedAt)
        recordSiteHealth(
            eventType: .detail,
            siteKey: site.key,
            siteName: site.name,
            success: !initialResult.list.isEmpty,
            durationMs: initialDurationMs,
            errorCategory: initialResult.list.isEmpty ? .source : nil,
            host: site.api
        )
        applyDetailResult(initialResult, site: site, acknowledgeKeepUpdate: acknowledgeKeepUpdate)

        guard isProvisionalDetailResult(initialResult) else { return }
        DiagnosticLog.write(
            "[DETAIL_PROGRESSIVE] site=\(site.key) vod=\(vod.vodId) stage=initial elapsedMs=\(initialDurationMs)"
        )

        await refreshEpisodeList(site: site, vodID: vod.vodId,
            acknowledgeKeepUpdate: acknowledgeKeepUpdate)
    }

    private func cancelEpisodeListRefresh() {
        episodeListRefreshID = UUID()
        episodeListRefreshTask?.cancel()
        episodeListRefreshTask = nil
        if episodeListState == .loading { episodeListState = .incomplete }
        isDetailLoading = false
    }

    func retryEpisodeList() async {
        guard episodeListState == .incomplete, let site = activeSite,
              let vod = detailVod else { return }
        await refreshEpisodeList(site: site, vodID: vod.vodId, acknowledgeKeepUpdate: false)
    }

    private func refreshEpisodeList(site: Site, vodID: String, acknowledgeKeepUpdate: Bool) async {
        cancelEpisodeListRefresh()
        let requestID = episodeListRefreshID
        let origin = playbackAuthorizationOrigin
        let coordinator = vodDataSource
        let sourceScope = vodScope(for: site)
        let key = VodDetailCacheKey(revision: catalogCacheRevision, siteKey: site.key, vodID: vodID)
        let sites = sites
        episodeListState = .loading
        isDetailLoading = true
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.episodeListRefreshTimeout ?? .seconds(12))
            guard !Task.isCancelled, let self, self.episodeListRefreshID == requestID else { return }
            self.cancelEpisodeListRefresh()
        }
        let refresh = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                timeout.cancel()
                if self.episodeListRefreshID == requestID {
                    self.isDetailLoading = false
                    if self.episodeListState == .loading { self.episodeListState = .incomplete }
                    self.episodeListRefreshTask = nil
                }
            }
            // Playback may close the detail sheet while expansion is in flight.
            // Source, film and detail generation remain the owner; the play generation may advance.
            @MainActor func stillOwned() -> Bool {
                let current = self.playbackAuthorizationOrigin
                return !Task.isCancelled && self.episodeListRefreshID == requestID
                    && current.sourceFingerprint == origin.sourceFingerprint
                    && current.detailGeneration == origin.detailGeneration && current.vodID == origin.vodID
                    && (self.isDetailPresented || self.isPlayerPresented)
            }
            while stillOwned() {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    guard stillOwned() else { return }
                    await coordinator.waitForRetirement()
                    let result = try await VodDetailRepository.shared.result(for: key) {
                        try await coordinator.detail(site: site, id: vodID, sites: sites, scope: sourceScope)
                    }
                    guard stillOwned() else { return }
                    self.applyDetailResult(result, site: site, acknowledgeKeepUpdate: acknowledgeKeepUpdate)
                    if self.episodeListState != .loading {
                        if self.episodeListState == .ready, self.playerState.endDisposition == .natural,
                           let spec = self.playerState.currentSpec {
                            self.requestAutoAdvance(for: spec, trigger: "list-restored")
                        }
                        return
                    }
                } catch { return }
            }
        }
        episodeListRefreshTask = refresh
        await refresh.value
    }

    private func applyDetailResult(_ result: Result, site: Site, acknowledgeKeepUpdate: Bool) {
        guard var detail = result.list.first else { episodeListState = .incomplete; return }
        episodeListState = isProvisionalDetailResult(result) ? .loading : .ready
        if detail.siteKey.isEmpty {
            detail.siteKey = site.key
        }
        self.detailVod = detail
        syncKeepRemarks(for: detail, acknowledge: acknowledgeKeepUpdate)

        let visibleLines = VodPlaybackAvailabilityPolicy.visibleLines(in: detail)
        let visibleFlags = visibleLines.map(\.flag)
        let history = PlaybackLinkage.history(for: detail, activeSiteKey: site.key, items: historyItems, sourceFingerprint: librarySourceFingerprint(siteKey: site.key))
        let historyFlag = PlaybackLinkage.preferredFlag(from: history, availableFlags: visibleFlags)
        let preferredFlag = visibleFlags.contains(selectedPlayFlag) ? selectedPlayFlag : historyFlag
        applyPlaybackAvailability(visibleLines: visibleLines, preferredFlag: preferredFlag)
    }

    func updateDetailPrefetch(vod: Vod, site: Site?, hovering: Bool) {
        detailPrefetchTask?.cancel()
        detailPrefetchTask = nil
        guard hovering,
              let site,
              site.key != Self.driveShareImportSiteKey,
              !vod.vodId.isEmpty else { return }

        let coordinator = vodDataSource
        let sourceScope = vodScope(for: site)
        let revision = catalogCacheRevision
        let sites = self.sites
        detailPrefetchTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let key = VodDetailCacheKey(revision: revision, siteKey: site.key, vodID: vod.vodId)
            await coordinator.waitForRetirement()
            await VodDetailRepository.shared.prefetch(key: key) {
                try await coordinator.detail(site: site, id: vod.vodId, sites: sites, scope: sourceScope)
            }
        }
    }

    /// 切换播放线路
    func selectPlayFlag(_ flag: String) {
        if selectedPlayFlag != flag {
            invalidateNextEpisodePreload(reason: "play-flag-changed")
        }
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
        let list = episodeList.map { episodeSortOrder.ordered($0) } ?? displayedPlaybackEpisodes
        let spec = playerState.currentSpec
        return PlaybackSessionCore.episodeContext(
            episodes: list,
            metadataEpisodeURL: spec?.metadata["vod.episodeURL"],
            fallbackPlaybackURL: spec?.url ?? "",
            metadataEpisodeName: spec?.metadata["vod.episodeName"],
            progressText: currentPlaybackProgressText()
        )
    }

    private func playbackPreloadKey(for targetEpisode: Episode) -> PlaybackPreloadKey? {
        guard let site = activeSite,
              let spec = playerState.currentSpec,
              spec.metadata["playback.kind"] != "live" else { return nil }
        let currentEpisodeURL = PlaybackResumePolicy.episodeURL(for: spec)
        guard !currentEpisodeURL.isEmpty, !targetEpisode.url.isEmpty else { return nil }
        return PlaybackPreloadKey(
            siteKey: site.key,
            vodID: detailVod?.vodId ?? spec.metadata["vod.id"] ?? "",
            playFlag: selectedPlayFlag,
            currentEpisodeURL: currentEpisodeURL,
            targetEpisodeURL: targetEpisode.url,
            playbackGeneration: playbackSessionState.generation
        )
    }

    private func requestNextEpisodePreload(
        targetEpisode: Episode,
        decision: PlaybackPreloadDecision,
        trigger: String,
        leadSeconds: Double,
        bufferedAheadSeconds: Double
    ) {
        guard let key = playbackPreloadKey(for: targetEpisode),
              let site = activeSite else { return }
        let vodName = detailVod?.vodName ?? ""
        let sites = self.sites
        let onDiscard: @MainActor @Sendable (PreparedEpisodePlayback) -> Void = { [weak self] prepared in
            self?.discardPreparedPreload(prepared, reason: "preload-discarded")
        }
        let operation: NextEpisodePreloadCoordinator.Operation = { [weak self] requested, reusable in
            guard let self else { return nil }
            return await self.prepareNextEpisodePlayback(
                key: key,
                site: site,
                episode: targetEpisode,
                vodName: vodName,
                sites: sites,
                decision: requested,
                allowsMetadataEssentials: decision == .metadataOnly,
                reusable: reusable
            )
        }
        let didSchedule: Bool
        if decision == .metadataAndMedia {
            let didScheduleMetadata = nextEpisodePreloadCoordinator.request(
                key: key,
                decision: .metadataOnly,
                onDiscard: onDiscard,
                operation: operation
            )
            let didScheduleMedia = nextEpisodePreloadCoordinator.request(
                key: key,
                decision: .metadataAndMedia,
                onDiscard: onDiscard,
                operation: operation
            )
            didSchedule = didScheduleMetadata || didScheduleMedia
        } else {
            didSchedule = nextEpisodePreloadCoordinator.request(
                key: key,
                decision: decision,
                onDiscard: onDiscard,
                operation: operation
            )
        }
        if didSchedule {
            DiagnosticLog.write(
                "[NEXT_PRELOAD] stage=request trigger=\(trigger) decision=\(decision.rawValue) leadSeconds=\(Int(max(0, leadSeconds).rounded())) bufferedAheadSeconds=\(Int(max(0, bufferedAheadSeconds).rounded())) episode=\(targetEpisode.url.hashValue)"
            )
        }
    }

    private func prepareNextEpisodePlayback(
        key: PlaybackPreloadKey,
        site: Site,
        episode: Episode,
        vodName: String,
        sites: [Site],
        decision: PlaybackPreloadDecision,
        allowsMetadataEssentials: Bool,
        reusable: PreparedEpisodePlayback?
    ) async -> PreparedEpisodePlayback? {
        do {
            if var reusable, reusable.key == key {
                if decision == .metadataAndMedia, reusable.decision < decision {
                    reusable = await prewarmPreparedPlayback(reusable)
                }
                startThunderPreloadUpgrade(reusable)
                return reusable
            }

            DiagnosticLog.write(
                "[NEXT_PRELOAD] stage=begin decision=\(decision.rawValue) episode=\(episode.url.hashValue)"
            )
            let result = try await vodDataSource.playback(site: site, flag: key.playFlag, id: episode.url,
                                                         sites: sites, scope: vodScope(for: site))
            var retainedFileLease = false
            defer {
                if !retainedFileLease, let value = result.fileResourceLeaseID, let id = UUID(uuidString: value) {
                    Task { await FileServiceRuntime.shared.releasePlayback(leaseID: id) }
                }
            }
            try Task.checkCancellation()
            guard playbackPreloadKey(for: episode) == key,
                  result.interaction == nil else { return nil }

            let resolvedResult: Result
            if result.playbackCandidates.isEmpty {
                resolvedResult = result
            } else {
                let playable = result.playbackCandidates.filter(\.isPlayable)
                guard playable.count == 1, let candidate = playable.first else {
                    DiagnosticLog.write("[NEXT_PRELOAD] stage=deferred-selection candidates=\(playable.count)")
                    return nil
                }
                resolvedResult = resolvedPlaybackCandidateResult(result, candidate: candidate)
            }

            guard let spec = try await prepareResolvedPlayback(
                result: resolvedResult,
                episode: episode,
                site: site,
                vodID: key.vodID,
                vodName: vodName,
                playFlag: key.playFlag,
                sessionGeneration: key.playbackGeneration,
                enforcesSessionGeneration: false,
                materializesRequiredMedia: false,
                logContext: "NEXT_PRELOAD"
            ) else { return nil }
            try Task.checkCancellation()
            guard playbackPreloadKey(for: episode) == key else {
                releaseLocalStreamRelayIfNeeded(spec: spec, reason: "preload-stale")
                releaseBiliPlaybackCacheIfNeeded(spec: spec, replacingWith: playerState.currentSpec, reason: "preload-stale")
                return nil
            }

            var prepared = PreparedEpisodePlayback(
                key: key,
                site: site,
                episode: episode,
                spec: spec,
                decision: .metadataOnly,
                mediaBytes: 0,
                preparedAt: Date()
            )
            if decision == .metadataAndMedia {
                prepared = await prewarmPreparedPlayback(prepared)
            } else if allowsMetadataEssentials,
                      Self.supportsEarlyMediaPreload(prepared.spec) {
                startMetadataEssentialsPrewarm(prepared.spec)
            }
            DiagnosticLog.write(
                "[NEXT_PRELOAD] stage=ready decision=\(prepared.decision.rawValue) bytes=\(prepared.mediaBytes) episode=\(episode.url.hashValue)"
            )
            retainedFileLease = true
            startThunderPreloadUpgrade(prepared)
            return prepared
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return nil }
            DiagnosticLog.write(
                "[NEXT_PRELOAD] stage=failed errorKind=\((error as NSError).code) episode=\(episode.url.hashValue)"
            )
            return nil
        }
    }

    private func prewarmPreparedPlayback(
        _ prepared: PreparedEpisodePlayback
    ) async -> PreparedEpisodePlayback {
        var warmed = prepared
        guard !Task.isCancelled,
              playbackPreloadKey(for: prepared.episode) == prepared.key else {
            return warmed
        }
        let essentialsTask = nextEpisodeEssentialsTask
        nextEpisodeEssentialsTask = nil
        essentialsTask?.cancel()
        await essentialsTask?.value
        guard !Task.isCancelled, playbackPreloadKey(for: prepared.episode) == prepared.key else { return warmed }

        let activeStreamURL = playerState.currentSpec?.url
        let playbackConcurrency = playerState.currentSpec.flatMap {
            LiveHLSRelayPolicy.playbackConcurrencyDuringPreload(for: $0, essentialsOnly: false)
        }
        let previousConcurrency = activeStreamURL.flatMap {
            guard let playbackConcurrency else { return nil as Int? }
            return ProxyServer.shared.setRemoteStreamParallelConcurrencyLimit(
                forLocalURL: $0,
                limit: playbackConcurrency
            )
        }
        if previousConcurrency != nil, let playbackConcurrency {
            DiagnosticLog.write(
                "[NEXT_PRELOAD] stage=bandwidth-rebalanced currentConcurrency=\(playbackConcurrency) nextConcurrency=24"
            )
        }
        defer {
            if let activeStreamURL, let previousConcurrency {
                _ = ProxyServer.shared.setRemoteStreamParallelConcurrencyLimit(
                    forLocalURL: activeStreamURL,
                    limit: previousConcurrency
                )
            }
        }
        if let snapshot = try? await ProxyServer.shared.prefetchRemoteStream(
            forLocalURL: prepared.spec.url,
            byteLimit: 16 * 1024 * 1024
        ), snapshot.cachedBytes > 0 {
            warmed.decision = .metadataAndMedia
            warmed.mediaBytes = min(snapshot.cachedBytes, 16 * 1024 * 1024)
            return warmed
        }
        if prepared.spec.metadata[LiveHLSRelayPolicy.transportMetadataKey]
            == LiveHLSRelayPolicy.localRelayTransport,
           let result = try? await ProxyPlaybackHandler.prefetchStaticHLS(
            localURL: prepared.spec.url,
            byteLimit: 16 * 1024 * 1024,
            maxSegments: 2
        ) {
            warmed.decision = result.mediaSegments > 0 ? .metadataAndMedia : .metadataOnly
            warmed.mediaBytes = Int64(result.cachedBytes)
            return warmed
        }
        return warmed
    }

    private func startThunderPreloadUpgrade(_ prepared: PreparedEpisodePlayback) {
        guard prepared.decision == .metadataAndMedia, ThunderNextEpisodeCache.isConfigured,
              ThunderNextEpisodeCache.supports(prepared.spec), nextEpisodeThunderKey != prepared.key else { return }
        nextEpisodeThunderTask?.cancel()
        nextEpisodeThunderKey = prepared.key
        nextEpisodeThunderTask = Task { @MainActor [weak self] in
            // Let the ordinary preload publish first; SDK work never delays it.
            await Task.yield()
            guard let self, !Task.isCancelled, self.nextEpisodePreloadCoordinator.currentKey == prepared.key else { return }
            guard let localSpec = await ThunderNextEpisodeCache.shared.prepare(prepared.spec, while: { @MainActor [weak self] in
                self?.nextEpisodePreloadCoordinator.currentKey == prepared.key
            }) else { return }
            let upgraded = PreparedEpisodePlayback(key: prepared.key, site: prepared.site, episode: prepared.episode,
                spec: localSpec, decision: .metadataAndMedia, mediaBytes: localSpec.contentLength ?? 0, preparedAt: prepared.preparedAt)
            guard !Task.isCancelled,
                  let previous = self.nextEpisodePreloadCoordinator.upgradeMediaIfUnconsumed(upgraded, expectedURL: prepared.spec.url) else {
                ThunderNextEpisodeCache.releaseCachedFile(spec: localSpec)
                return
            }
            self.releaseLocalStreamRelayIfNeeded(spec: previous.spec, replacingWith: localSpec, reason: "thunder-preload-ready")
        }
    }

    private func startMetadataEssentialsPrewarm(_ spec: PlaySpec) {
        nextEpisodeEssentialsTask?.cancel()
        let activeURL = playerState.currentSpec?.url
        let playbackConcurrency = playerState.currentSpec.flatMap {
            LiveHLSRelayPolicy.playbackConcurrencyDuringPreload(for: $0, essentialsOnly: true)
        }
        nextEpisodeEssentialsTask = Task {
            guard !Task.isCancelled else { return }
            let previousConcurrency = activeURL.flatMap {
                guard let playbackConcurrency else { return nil as Int? }
                return ProxyServer.shared.setRemoteStreamParallelConcurrencyLimit(forLocalURL: $0, limit: playbackConcurrency)
            }
            defer {
                if let activeURL, let previousConcurrency {
                    _ = ProxyServer.shared.setRemoteStreamParallelConcurrencyLimit(forLocalURL: activeURL, limit: previousConcurrency)
                }
            }
            DiagnosticLog.write(
                "[NEXT_PRELOAD] stage=essentials-started currentConcurrency=\(playbackConcurrency ?? 0) nextConcurrency=4"
            )
            let snapshot = try? await ProxyServer.shared.prefetchRemoteStream(
                forLocalURL: spec.url,
                byteLimit: 3 * 1024 * 1024,
                mode: .essentials
            )
            DiagnosticLog.write(
                "[NEXT_PRELOAD] stage=essentials-ready bytes=\(snapshot?.cachedBytes ?? 0)"
            )
        }
    }

    private func invalidateNextEpisodePreload(reason: String) {
        nextEpisodeThunderTask?.cancel()
        nextEpisodeThunderTask = nil
        nextEpisodeThunderKey = nil
        nextEpisodeEssentialsTask?.cancel()
        nextEpisodeEssentialsTask = nil
        if let activeURL = playerState.currentSpec?.url {
            _ = ProxyServer.shared.setRemoteStreamParallelConcurrencyLimit(
                forLocalURL: activeURL,
                limit: Int.max
            )
        }
        if let prepared = nextEpisodePreloadCoordinator.invalidate() {
            discardPreparedPreload(prepared, reason: reason)
        } else {
            Task {
                await ProxyPlaybackHandler.clearPrefetchedPlaybackResponses()
            }
        }
        DiagnosticLog.write("[NEXT_PRELOAD] stage=invalidated reason=\(reason)")
    }

    private func discardPreparedPreload(_ prepared: PreparedEpisodePlayback, reason: String) {
        releasePreparedPreload(prepared, reason: reason)
        Task {
            await ProxyPlaybackHandler.clearPrefetchedPlaybackResponses()
        }
    }

    private func releasePreparedPreload(_ prepared: PreparedEpisodePlayback, reason: String) {
        releaseLocalStreamRelayIfNeeded(spec: prepared.spec, reason: reason)
        ThunderNextEpisodeCache.releaseCachedFile(
            spec: prepared.spec,
            replacingWith: playerState.currentSpec
        )
        releaseBiliPlaybackCacheIfNeeded(
            spec: prepared.spec,
            replacingWith: playerState.currentSpec,
            reason: reason
        )
    }

    @discardableResult
    func playRelativeEpisode(offset: Int, automaticSelection: Bool = false) async -> Episode? {
        let context = playbackEpisodeContext()
        guard let target = PlaybackSessionCore.relativeEpisode(
            in: displayedPlaybackEpisodes,
            context: context,
            offset: offset
        ) else { return nil }
        await playEpisode(target, automaticSelection: automaticSelection)
        return target
    }

    private func currentPlaybackProgressText() -> String? {
        if playerState.position > 0 {
            let minutes = max(1, Int(playerState.position / 60))
            return L10n.text("已观看 {0} 分钟", ["\(minutes)"])
        }
        return currentDetailHistoryProgressText()
    }

    /// 取消当前的视频加载/解析
    func cancelLoading() async {
        pendingAutoAdvanceID = nil
        episodePreparation = nil
        cancelCloudAuthorization()
        invalidateNextEpisodePreload(reason: "playback-cancelled")
        self.log("[AppState] 用户主动取消当前播放加载任务")
        ParseEngine.shared.cancelCurrentSniff()
        let generation = playbackSessionState.generation
        playbackSessionState = PlaybackSessionCore.cancel(playbackSessionState)
        _ = finishPlaybackStartupTrace(stage: "cancelled", generation: generation)
        self.isPlayerLoading = false
        self.playerLoadingMessage = L10n.text("正在解析视频，请稍候...")
    }

    private func beginPlaybackStartupTrace(
        generation: UInt64,
        siteKey: String,
        startedAt: ContinuousClock.Instant
    ) {
        let now = ContinuousClock.now
        playbackStartupTrace = PlaybackStartupTrace(
            generation: generation,
            siteKey: siteKey,
            startedAt: startedAt,
            lastStageAt: now
        )
        let preloadWaitMs = Self.durationMilliseconds(startedAt.duration(to: now))
        DiagnosticLog.write("[PLAYBACK_STAGE] stage=begin deltaMs=\(preloadWaitMs) totalMs=\(preloadWaitMs)")
    }

    private func recordPlaybackStartupStage(_ stage: String, generation: UInt64) {
        guard var trace = playbackStartupTrace, trace.generation == generation else { return }
        let now = ContinuousClock.now
        let delta = Self.durationMilliseconds(trace.lastStageAt.duration(to: now))
        let total = Self.durationMilliseconds(trace.startedAt.duration(to: now))
        trace.lastStageAt = now
        playbackStartupTrace = trace
        DiagnosticLog.write("[PLAYBACK_STAGE] stage=\(stage) deltaMs=\(delta) totalMs=\(total)")
    }

    @discardableResult
    private func finishPlaybackStartupTrace(
        stage: String,
        siteKey: String? = nil,
        generation: UInt64
    ) -> Int {
        guard let trace = playbackStartupTrace,
              siteKey == nil || trace.siteKey == siteKey,
              trace.generation == generation else { return 0 }
        let total = Self.durationMilliseconds(trace.startedAt.duration(to: .now))
        DiagnosticLog.write("[PLAYBACK_STAGE] stage=\(stage) totalMs=\(total)")
        playbackStartupTrace = nil
        return total
    }

    private static func durationMilliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return max(0, Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000))
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
        lineFallbackApplied: Bool = false,
        verificationResult: PlaybackVerificationResult? = nil,
        preparationRetryAttempt: Int = 0,
        authorizationOrigin: PlaybackAuthorizationOrigin? = nil,
        expectedPlaybackOrigin: PlaybackAuthorizationOrigin? = nil,
        restartFromBeginning: Bool = false
    ) async {
        guard (authorizationOrigin ?? expectedPlaybackOrigin) == nil || (authorizationOrigin ?? expectedPlaybackOrigin) == playbackAuthorizationOrigin,
              !Task.isCancelled else { return }
        guard let site = activeSite else { return }
        if !automaticSelection { pendingAutoAdvanceID = nil }
        let sourceScope = vodScope(for: site)
        if VodPlaybackAvailabilityPolicy.needsMagnetExpansion(episode, site: site) {
            await expandMagnetEpisode(episode, site: site, automaticSelection: automaticSelection)
            return
        }
        // Publish the target before waiting for a preloaded URL or resolving a new one.
        let preparation = EpisodePreparation(
            episode: episode,
            title: [detailVod?.vodName ?? "", episode.name].filter { !$0.isEmpty }.joined(separator: " - ")
        )
        episodePreparation = preparation
        defer {
            if episodePreparation?.id == preparation.id { episodePreparation = nil }
        }
        let transitionStartedAt = ContinuousClock.now
        let preloadKey = playbackPreloadKey(for: episode)
        let preparedPlayback: PreparedEpisodePlayback?
        if !restartFromBeginning, authorizationOrigin == nil, verificationResult == nil,
           !lineFallbackApplied,
           preparationRetryAttempt == 0,
           let preloadKey {
            preparedPlayback = await nextEpisodePreloadCoordinator.consume(key: preloadKey)
        } else {
            preparedPlayback = nil
        }
        guard episodePreparation?.id == preparation.id,
              (authorizationOrigin ?? expectedPlaybackOrigin) == nil || (authorizationOrigin ?? expectedPlaybackOrigin) == playbackAuthorizationOrigin,
              expectedPlaybackOrigin == nil || isPlayerPresented,
              !Task.isCancelled else {
            if let preparedPlayback { discardPreparedPreload(preparedPlayback, reason: "preparation-cancelled") }
            return
        }
        cancelCloudAuthorization()
        if automaticSelection,
           preparedPlayback == nil,
           let preloadKey,
           playbackPreloadKey(for: episode) != preloadKey {
            DiagnosticLog.write("[NEXT_PRELOAD] stage=stale-auto-advance episode=\(episode.url.hashValue)")
            return
        }
        if nextEpisodePreloadCoordinator.currentKey != nil,
           nextEpisodePreloadCoordinator.currentKey != preloadKey {
            invalidateNextEpisodePreload(reason: "different-episode-selected")
        }
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
            restartFromBeginning: restartFromBeginning,
            preferenceKey: preferenceKey
        )
        let generation = playbackSessionState.generation
        beginPlaybackStartupTrace(
            generation: generation,
            siteKey: site.key,
            startedAt: transitionStartedAt
        )
        vodLineFallbackGeneration = lineFallbackApplied ? generation : nil
        
        if isPlayerLoading {
            ParseEngine.shared.cancelCurrentSniff()
        }
        
        self.isPlayerLoading = true
        self.playerLoadingMessage = L10n.text("正在解析视频，请稍候...")
        self.playbackWarningMessage = nil
        self.playbackRouteNotice = nil
        self.playbackErrorAuthProvider = nil
        self.pendingAuthEpisode = nil
        defer {
            if self.playbackSessionState.generation == generation {
                self.isPlayerLoading = false
                self.playerLoadingMessage = L10n.text("正在解析视频，请稍候...")
            }
        }
        
        self.log("[PLAY_EPISODE] 开始播放剧集 title=\(episode.name), url=\(redactedPlaybackURL(episode.url))")
        
        do {
            if let preparedPlayback {
                DiagnosticLog.write(
                    "[NEXT_PRELOAD] stage=hit decision=\(preparedPlayback.decision.rawValue) bytes=\(preparedPlayback.mediaBytes) episode=\(episode.url.hashValue)"
                )
                recordPlaybackStartupStage("preload-hit", generation: generation)
                let didStart = try await commitPreparedPlayback(
                    preparedPlayback.spec,
                    episode: episode,
                    site: site,
                    resumePosition: resumePosition,
                    resumeDuration: resumeDuration,
                    sessionGeneration: generation
                )
                playbackSessionState = didStart
                    ? PlaybackSessionCore.finishStarting(playbackSessionState, generation: generation)
                    : PlaybackSessionCore.fail(playbackSessionState, generation: generation)
                if !didStart {
                    discardPreparedPreload(preparedPlayback, reason: "preload-start-rejected")
                    _ = finishPlaybackStartupTrace(stage: "preload-start-rejected", generation: generation)
                }
                return
            }
            if let verificationResult {
                let data = try JSONEncoder().encode(verificationResult)
                guard let value = String(data: data, encoding: .utf8) else {
                    throw SpiderEngineError.nativeReplacementUnsupported(
                        site: site.key,
                        capability: L10n.text("源站验证结果编码失败")
                    )
                }
                try await SiteApi.shared.action(
                    key: site.key,
                    action: "playback_verification",
                    value: value,
                    sites: self.sites
                )
            }
            // 调用 SiteApi 抓取该剧集对应的播放流地址
            let result = try await vodDataSource.playback(site: site, flag: self.selectedPlayFlag, id: episode.url,
                                                             sites: self.sites, scope: sourceScope)
            var transferredFileLease = false
            defer {
                if !transferredFileLease, let value = result.fileResourceLeaseID, let id = UUID(uuidString: value) {
                    Task { await FileServiceRuntime.shared.releasePlayback(leaseID: id) }
                }
            }
            try Task.checkCancellation()
            recordPlaybackStartupStage("player-content", generation: generation)
            
            self.log("[PLAY_EPISODE] SiteApi 返回 url: \(redactedPlaybackURL(result.url)), needParse: \(result.needParse)")
            let transition = PlaybackSessionCore.receivePlayerResult(
                playbackSessionState,
                generation: generation,
                result: result,
                preferredSignature: nil
            )
            playbackSessionState = transition.state
            guard transition.failure == nil else {
                _ = finishPlaybackStartupTrace(
                    stage: "result-rejected",
                    siteKey: site.key,
                    generation: generation
                )
                return
            }
            try await executePlaybackSessionCommand(transition.command)
            transferredFileLease = true
        } catch {
            let isCurrent = playbackSessionState.generation == generation
            if let preparedPlayback {
                discardPreparedPreload(preparedPlayback, reason: "preload-start-failed")
            }
            if error is CancellationError || Task.isCancelled {
                playbackSessionState = PlaybackSessionCore.fail(playbackSessionState, generation: generation)
                _ = finishPlaybackStartupTrace(stage: "cancelled", generation: generation)
                return
            }
            if isCurrent,
               let delay = Self.transientPreparationRetryDelayNanoseconds(
                   for: error,
                   attempt: preparationRetryAttempt
               ) {
                log("[PLAYBACK_PREPARE_RETRY] attempt=\(preparationRetryAttempt + 1)")
                recordPlaybackStartupStage("prepare-retry", generation: generation)
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled,
                      playbackSessionState.generation == generation else { return }
                await playEpisode(
                    episode,
                    resumePosition: resumePosition,
                    resumeDuration: resumeDuration,
                    automaticSelection: automaticSelection,
                    lineFallbackApplied: lineFallbackApplied,
                    verificationResult: verificationResult,
                    preparationRetryAttempt: preparationRetryAttempt + 1,
                    restartFromBeginning: restartFromBeginning
                )
                return
            }
            playbackSessionState = PlaybackSessionCore.fail(
                playbackSessionState,
                generation: generation
            )
            if isCurrent {
                let startupDuration = finishPlaybackStartupTrace(
                    stage: "prepare-failed",
                    siteKey: site.key,
                    generation: generation
                )
                recordSiteHealth(
                    eventType: .play,
                    siteKey: site.key,
                    siteName: site.name,
                    success: false,
                    durationMs: startupDuration,
                    errorCategory: .player,
                    host: site.api
                )
                self.log("[PLAY_EPISODE] 播放异常失败: \(error)")
                handlePlaybackError(
                    error,
                    episode: episode,
                    preparationRetryAttempt: preparationRetryAttempt
                )
            }
        }
    }

    private func expandMagnetEpisode(_ episode: Episode, site: Site, automaticSelection: Bool) async {
        let generation = detailLoadGeneration
        let flag = selectedPlayFlag
        let vodID = detailVod?.vodId
        isPlayerLoading = true
        playerLoadingMessage = L10n.text("正在读取磁力视频列表，请稍候...")
        defer {
            if detailLoadGeneration == generation {
                isPlayerLoading = false
                playerLoadingMessage = L10n.text("正在解析视频，请稍候...")
            }
        }
        do {
            let files = try await MagnetPlaybackEpisodes.resolve(for: episode.url)
            try Task.checkCancellation()
            guard !files.isEmpty else {
                throw SpiderEngineError.nativeReplacementUnsupported(site: site.key, capability: "磁力未返回可播放的视频文件")
            }
            guard detailLoadGeneration == generation, activeSite?.key == site.key,
                  isDetailPresented, selectedPlayFlag == flag, let detail = detailVod, detail.vodId == vodID,
                  let expanded = VodPlaybackAvailabilityPolicy.expanding(episode, with: files, flag: flag, in: detail) else { return }
            detailVod = expanded
            applyPlaybackAvailability(for: expanded, preferredFlag: flag)
            isPlayerLoading = false
            if files.count == 1 || automaticSelection, let first = files.first {
                await playEpisode(first, automaticSelection: automaticSelection)
            }
        } catch {
            guard !(error is CancellationError), !Task.isCancelled,
                  detailLoadGeneration == generation, activeSite?.key == site.key else { return }
            handlePlaybackError(error, episode: episode, preparationRetryAttempt: 0)
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
        playerLoadingMessage = L10n.text("正在加载字幕并启动播放器...")
        defer {
            if playbackSessionState.generation == generation {
                isPlayerLoading = false
                playerLoadingMessage = L10n.text("正在解析视频，请稍候...")
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
            if error is CancellationError || Task.isCancelled {
                _ = finishPlaybackStartupTrace(stage: "cancelled", generation: generation)
                return
            }
            if isCurrent {
                let startupDuration = finishPlaybackStartupTrace(
                    stage: "candidate-failed",
                    siteKey: request.site.key,
                    generation: generation
                )
                recordSiteHealth(
                    eventType: .play,
                    siteKey: request.site.key,
                    siteName: request.site.name,
                    success: false,
                    durationMs: startupDuration,
                    errorCategory: .player,
                    host: request.site.api
                )
                log("[PLAY_EPISODE] 播放候选启动失败: \(error)")
                handlePlaybackError(error, episode: request.episode)
            }
        }
    }

    func dismissPlaybackSelection() {
        let generation = playbackSessionState.selection?.generation
        playbackSessionState = PlaybackSessionCore.dismissSelection(playbackSessionState)
        if let generation {
            _ = finishPlaybackStartupTrace(stage: "selection-dismissed", generation: generation)
        }
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
                    _ = finishPlaybackStartupTrace(
                        stage: "start-rejected",
                        siteKey: intent.site.key,
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
        guard let prepared = try await prepareResolvedPlayback(
            result: result,
            episode: episode,
            site: site,
            vodID: detailVod?.vodId ?? "",
            vodName: detailVod?.vodName ?? "",
            playFlag: selectedPlayFlag,
            sessionGeneration: sessionGeneration,
            enforcesSessionGeneration: true,
            materializesRequiredMedia: true,
            logContext: "PLAY_EPISODE"
        ) else { return false }
        return try await commitPreparedPlayback(
            prepared,
            episode: episode,
            site: site,
            resumePosition: resumePosition,
            resumeDuration: resumeDuration,
            sessionGeneration: sessionGeneration
        )
    }

    private func prepareResolvedPlayback(
        result: Result,
        episode: Episode,
        site: Site,
        vodID: String,
        vodName: String,
        playFlag: String,
        sessionGeneration: UInt64,
        enforcesSessionGeneration: Bool,
        materializesRequiredMedia: Bool,
        logContext: String
    ) async throws -> PlaySpec? {
            var transferredFileLease = false
            defer {
                if !transferredFileLease, let value = result.fileResourceLeaseID, let id = UUID(uuidString: value) {
                    Task { await FileServiceRuntime.shared.releasePlayback(leaseID: id) }
                }
            }
            guard !enforcesSessionGeneration || playbackSessionState.generation == sessionGeneration else { return nil }
            try Task.checkCancellation()

            var finalSpec = PlaySpec(
                url: result.playUrl + result.url,
                externalAudioURL: result.externalAudioURL,
                contentLength: result.contentLength,
                headers: result.header,
                format: result.format,
                artwork: Self.playbackArtwork(from: result),
                audioFallbackArtwork: Self.audioFallbackArtwork(
                    from: result,
                    episode: episode,
                    detailArtwork: detailVod?.vodPic ?? ""
                ),
                artworkHeaders: site.header,
                drm: result.drm,
                subs: result.subs,
                title: "\(vodName) - \(episode.name)",
                flag: playFlag,
                siteKey: site.key
            )
            finalSpec.metadata["library.sourceFingerprint"] = librarySourceFingerprint(siteKey: site.key)
            finalSpec.metadata["library.configId"] = String(currentLibraryConfiguration?.id ?? 0)
            finalSpec.metadata["vod.name"] = vodName
            finalSpec.metadata["vod.year"] = detailVod?.vodYear ?? ""
            finalSpec.metadata["vod.pic"] = detailVod?.vodPic ?? ""
            finalSpec.metadata["vod.remarks"] = detailVod?.vodRemarks ?? ""
            finalSpec.metadata["vod.siteKey"] = site.key
            finalSpec.metadata["vod.id"] = vodID
            finalSpec.metadata["vod.episodeURL"] = episode.url
            finalSpec.metadata["vod.episodeName"] = episode.name
            if let leaseID = result.fileResourceLeaseID { finalSpec.metadata["files.leaseID"] = leaseID }
            finalSpec.metadata["playback.sessionGeneration"] = String(sessionGeneration)
            if enforcesSessionGeneration, vodLineFallbackGeneration == sessionGeneration {
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
            try Task.checkCancellation()
            guard !enforcesSessionGeneration || playbackSessionState.generation == sessionGeneration else { return nil }
            recordPlaybackStartupStage("source-resolve", generation: sessionGeneration)
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
                try Task.checkCancellation()
                guard !enforcesSessionGeneration || playbackSessionState.generation == sessionGeneration else { return nil }
                if parsedSpec.url == resolveResult.playUrl + resolveResult.url,
                   let failure = ParseEngine.shared.lastFailure {
                    throw failure
                }
                finalSpec = finalSpec.merging(parsedSpec)
                recordPlaybackStartupStage("secondary-parse", generation: sessionGeneration)
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
                let parseConfig = VodConfig.shared.parses.first ?? Parse(name: L10n.text("默认嗅探"), type: 0)
                let sniffedSpec = await ParseEngine.shared.resolve(result: resolveResult, parse: parseConfig)
                try Task.checkCancellation()
                guard !enforcesSessionGeneration || playbackSessionState.generation == sessionGeneration else { return nil }
                if sniffedSpec.url == resolveResult.playUrl + resolveResult.url,
                   let failure = ParseEngine.shared.lastFailure {
                    throw failure
                }
                recordPlaybackStartupStage("web-sniff", generation: sessionGeneration)
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
            
            // Prepare the candidate without replacing the active video's route controller.
            finalSpec = DrivePlaybackRoutePolicy.preparedSpec(finalSpec)

            if materializesRequiredMedia, requiresBiliPlaybackMaterialization(finalSpec) {
                finalSpec = try await materializeBiliPlayback(finalSpec)
                guard !Task.isCancelled,
                      !enforcesSessionGeneration || playbackSessionState.generation == sessionGeneration else {
                    releaseBiliPlaybackCacheIfNeeded(spec: finalSpec, replacingWith: playerState.currentSpec, reason: "playback-cancelled")
                    return nil
                }
                recordPlaybackStartupStage("bili-materialize", generation: sessionGeneration)
            }

            // 标准媒体直连优先交给 libmpv；本地代理只保留给需要中转/改写的场景。
            finalSpec = await proxiedPlaySpec(finalSpec, logContext: logContext)
            guard !Task.isCancelled,
                  !enforcesSessionGeneration || playbackSessionState.generation == sessionGeneration else {
                releaseLocalStreamRelayIfNeeded(spec: finalSpec, replacingWith: playerState.currentSpec, reason: "playback-cancelled")
                releaseBiliPlaybackCacheIfNeeded(spec: finalSpec, replacingWith: playerState.currentSpec, reason: "playback-cancelled")
                return nil
            }
            recordPlaybackStartupStage("proxy-prepare", generation: sessionGeneration)
            
            // 调用内嵌 libmpv 执行实机播放
            guard !finalSpec.url.isEmpty else {
                self.log("[PLAY_EPISODE] 获取到的播放 URL 为空，中止播放")
                return nil
            }
            guard !enforcesSessionGeneration || playbackSessionState.generation == sessionGeneration else { return nil }

            transferredFileLease = true
            return finalSpec
    }

    private func commitPreparedPlayback(
        _ preparedSpec: PlaySpec,
        episode: Episode,
        site: Site,
        resumePosition: Int64?,
        resumeDuration: Int64?,
        sessionGeneration: UInt64
    ) async throws -> Bool {
            guard playbackSessionState.generation == sessionGeneration else { return false }
            var finalSpec = preparedSpec
            finalSpec.metadata["playback.sessionGeneration"] = String(sessionGeneration)
            finalSpec.metadata["playback.sourceFingerprint"] = playbackAuthorizationOrigin.sourceFingerprint
            if requiresBiliPlaybackMaterialization(finalSpec) {
                finalSpec = try await materializeBiliPlayback(finalSpec)
                finalSpec = await proxiedPlaySpec(finalSpec, logContext: "PLAY_EPISODE")
                guard !Task.isCancelled, playbackSessionState.generation == sessionGeneration else {
                    releaseBiliPlaybackCacheIfNeeded(
                        spec: finalSpec,
                        replacingWith: playerState.currentSpec,
                        reason: "playback-cancelled"
                    )
                    return false
                }
            }
            updateDrivePlaybackWarning(for: finalSpec, episode: episode)

            // Commit only after every fallible/awaited preparation step has completed.
            resetDrivePlaybackRoutes()
            finalSpec = activateDrivePlaybackRoutes(for: finalSpec)
            
            // The player replaces the presentation, not the browsing destination.
            // Keep history, favorites, search and home behind the detail round trip.
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
            preparePlaybackStart(
                spec: &finalSpec,
                resumePosition: resumePosition,
                resumeDuration: resumeDuration,
                episodeURL: episode.url,
                openingSkipSeconds: playbackSessionState.intent?.restartFromBeginning == true ? 0 : skipSettings.openingSeconds
            )
            playerState.endDisposition = nil
            MPVPlayerEngine.vod.speed = UserPreferences.shared.defaultPlaybackSpeed
            MPVPlayerEngine.vod.stop()
            recordPlaybackStartupStage("mpv-submit", generation: sessionGeneration)
            await play(spec: finalSpec)
            return true
    }

    static func playbackArtwork(from result: Result) -> String {
        result.artwork
    }

    static func audioFallbackArtwork(from result: Result, episode: Episode, detailArtwork: String) -> String {
        guard result.artwork.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let fileNames = [
            DriveFileReference.parse(episode.url)?.fileName ?? "",
            episode.name,
            URL(string: episode.url)?.lastPathComponent ?? "",
            URL(string: result.url)?.lastPathComponent ?? ""
        ]
        // A filename prepares the fallback; mpv must still confirm the actual media has no video.
        guard fileNames.contains(where: {
            DriveMediaClassifier.isPlayableAudio(name: $0, formatType: result.format, isDirectory: false, isFile: true)
        }) else { return "" }
        let episodeArtwork = (episode.artwork ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artwork = episodeArtwork.isEmpty ? detailArtwork.trimmingCharacters(in: .whitespacesAndNewlines) : episodeArtwork
        return artwork.isEmpty ? PlaybackArtworkLoader.placeholderSource : artwork
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

    func handlePlaybackError(
        _ error: Error,
        episode: Episode,
        preparationRetryAttempt: Int = 0
    ) {
        let isSourceFailure = error is DriveEngineError || error is PlaybackInteractionRequiredError
        lastFeedbackFailureStage = isSourceFailure ? "Source.resolve" : "Player.prepare"
        lastFeedbackFailureCategory = isSourceFailure ? .source : .player
        playbackErrorMessage = UserFacingErrorPresenter.message(for: error, context: .playback)
        playbackErrorAuthProvider = nil

        if let interactionError = error as? PlaybackInteractionRequiredError {
            playbackVerificationRequest = PlaybackVerificationRequest(
                interaction: interactionError.interaction,
                episode: episode
            )
            isPlaybackErrorPresented = false
            return
        }

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

        recordRemoteDiagnosticError(
            "PLAYBACK_PREPARE_FAILED",
            error: error,
            attempt: preparationRetryAttempt
        )
        isPlaybackErrorPresented = true
    }

    static func transientPreparationRetryDelayNanoseconds(for error: Error, attempt: Int) -> UInt64? {
        guard attempt == 0 else { return nil }

        if let driveError = error as? DriveEngineError,
           case .api(_, let statusCode, _, _) = driveError {
            if DriveEngineError.invalidatesSavedRecord(driveError) {
                return 500_000_000
            }
            if statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode) {
                return 500_000_000
            }
        }
        if let httpError = error as? HTTPError,
           case .httpError(let statusCode, _) = httpError {
            if statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode) {
                return 500_000_000
            }
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        let code = URLError.Code(rawValue: nsError.code)
        let retryableCodes: Set<URLError.Code> = [
            .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable,
        ]
        return retryableCodes.contains(code) ? 500_000_000 : nil
    }

    private func recordRemoteDiagnosticError(_ code: String, error: Error, attempt: Int) {
        guard let measurements = Self.remoteDiagnosticMeasurements(for: error, attempt: attempt) else { return }
        let fields = measurements.keys.sorted().map { "\($0)=\(measurements[$0]!)" }.joined(separator: " ")
        DiagnosticLog.write("[\(code)] \(fields)")
    }

    static func remoteDiagnosticMeasurements(for error: Error, attempt: Int) -> [String: Int]? {
        let nsError = error as NSError
        guard !(error is CancellationError),
              !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return nil }

        var measurements = [
            "attempt": attempt,
            "errorCode": nsError.code,
            "errorKind": 0,
            "expected": 0,
        ]
        if error is SpiderEngineError {
            measurements["errorKind"] = 1
            measurements["expected"] = 1
        } else if let driveError = error as? DriveEngineError {
            measurements["errorKind"] = 2
            switch driveError {
            case .api(let provider, let statusCode, let providerCode, _):
                measurements["provider"] = Self.driveProviderDiagnosticCode(provider)
                measurements["status"] = statusCode
                if let providerCode { measurements["code"] = providerCode }
            default:
                measurements["expected"] = 1
            }
        } else if error is HTTPError {
            measurements["errorKind"] = 3
        } else if nsError.domain == NSURLErrorDomain {
            measurements["errorKind"] = 4
        } else if error is ConfigError
                    || error is VodInputError
                    || error is DecoderError
                    || error is MacCMSPayloadError
                    || error is DecodingError {
            measurements["errorKind"] = 6
            measurements["expected"] = 1
        }
        return measurements
    }

    private static func driveProviderDiagnosticCode(_ provider: DriveProvider) -> Int {
        switch provider {
        case .quark: return 1
        case .uc: return 2
        case .ali: return 3
        case .p115: return 4
        case .pikpak: return 5
        case .baidu: return 6
        case .cloud123: return 7
        case .xunlei: return 8
        case .mobile: return 9
        case .tianyi: return 10
        case .alist: return 11
        case .webdav: return 12
        case .bilibili: return 13
        case .unknown: return 0
        }
    }

    func completePlaybackVerification(_ result: PlaybackVerificationResult) {
        guard let request = playbackVerificationRequest else { return }
        playbackVerificationRequest = nil
        Task { @MainActor in
            await playEpisode(request.episode, verificationResult: result)
        }
    }

    func cancelPlaybackVerification() {
        playbackVerificationRequest = nil
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

    func dismissPlaybackRouteNotice() {
        playbackRouteNotice = nil
    }

    func updateDrivePlaybackWarning(for spec: PlaySpec, episode: Episode) {
        guard let plan = spec.drivePlaybackPlan,
              let unavailableReason = plan.unavailableReason else {
            playbackWarningMessage = nil
            return
        }

        if plan.reauthenticationRequired {
            playbackWarningMessage = L10n.text("{0}备用线路需要重新授权，当前线路仍会继续尝试播放。", ["\(plan.provider.localizedDisplayName)"])
            playbackErrorAuthProvider = plan.provider
            pendingAuthEpisode = episode
            log("[DRIVE_PLAYBACK_WARNING] provider=\(plan.provider.localizedDisplayName) reason=\(unavailableReason) authRequired=true")
        } else {
            playbackWarningMessage = L10n.text("{0}备用线路暂不可用，当前线路仍会继续尝试播放。", ["\(plan.provider.localizedDisplayName)"])
            playbackErrorAuthProvider = nil
            pendingAuthEpisode = nil
            log("[DRIVE_PLAYBACK_WARNING] provider=\(plan.provider.localizedDisplayName) reason=\(unavailableReason) authRequired=false")
        }
    }

    func requestCloudAuth(_ provider: DriveProvider) {
        cloudAuthRequest = CloudAuthRequest(provider: provider, pendingEpisodeURL: pendingAuthEpisode?.url,
                                          resume: pendingAuthorization)
    }

    func requestCloudAuthFromSettings(_ provider: DriveProvider) {
        pendingAuthEpisode = nil
        playbackErrorAuthProvider = nil
        cloudAuthRequest = CloudAuthRequest(provider: provider)
    }

    private var playbackAuthorizationOrigin: PlaybackAuthorizationOrigin {
        let siteKey = activeSite?.key ?? ""
        // Imported shares and unsaved sources still need a provider identity;
        // the empty fingerprint is reserved for legacy library migration only.
        let fingerprint = activeSite.map {
            LibrarySourceIdentity.fingerprint(configurationURL: libraryConfigurationURL.isEmpty
                ? "netvplayer:transient" : libraryConfigurationURL, site: $0)
        } ?? ""
        return PlaybackAuthorizationOrigin(generation: playbackSessionState.generation,
            detailGeneration: detailLoadGeneration, sourceFingerprint: fingerprint,
            siteKey: siteKey, vodID: detailVod?.vodId ?? "", flag: selectedPlayFlag)
    }

    func cancelCloudAuthorization() {
        cloudAuthAttempt = nil
        pendingAuthorization = nil
        cloudAuthRequest = nil
    }

    private func checkCloudAuthAttempt(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard let active = cloudAuthAttempt, active.id == attempt,
              active.requestID == nil || cloudAuthRequest?.id == active.requestID else { throw CancellationError() }
        if active.requestID != nil, let resume = cloudAuthRequest?.resume {
            guard resume.id == pendingAuthorization?.id, resume.origin == playbackAuthorizationOrigin else { throw CancellationError() }
        }
    }

    func completeCloudAuth(credential: CloudCredential, requestID: UUID? = nil) async throws -> CloudAuthCompletion {
        let request = requestID.flatMap { id in cloudAuthRequest.flatMap { $0.id == id ? $0 : nil } }
        guard requestID == nil || (request?.provider == credential.provider && request != nil) else { throw CancellationError() }
        // A duplicate credential callback cannot start a second validation/resolve.
        guard requestID == nil || cloudAuthAttempt?.requestID != requestID else { throw CancellationError() }
        let attempt = UUID()
        cloudAuthAttempt = (attempt, requestID)
        let reference = request?.resume.flatMap { DriveFileReference.parse($0.episode.url) }
        defer { if cloudAuthAttempt?.id == attempt { cloudAuthAttempt = nil } }
        do {
            let completion: CloudAuthCompletion
            if let operation = cloudAuthCredentialOperation {
                completion = try await operation(credential, reference, request?.resume != nil)
            } else {
                completion = try await performCloudAuth(credential: credential, reference: reference,
                    resumingPlayback: request?.resume != nil, attempt: attempt)
            }
            try checkCloudAuthAttempt(attempt)
            if completion.shouldDismiss, let request, cloudAuthRequest?.id == request.id {
                let resume = request.resume.flatMap { candidate in
                    candidate.id == pendingAuthorization?.id && candidate.origin == playbackAuthorizationOrigin
                        ? candidate : nil
                }
                // Claim and retire before awaiting playback. No later callback can reuse it.
                cloudAuthRequest = nil
                if let resume {
                    clearPlaybackError()
                    await playEpisode(resume.episode, resumePosition: resume.resumePosition,
                        resumeDuration: resume.resumeDuration, automaticSelection: resume.automaticSelection,
                        authorizationOrigin: resume.origin, restartFromBeginning: resume.restartFromBeginning)
                }
            }
            return completion
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DiagnosticLog.recordError("CLOUD_AUTH_FAILED", error: error)
            throw error
        }
    }

    private func performCloudAuth(credential: CloudCredential, reference: DriveFileReference?,
                                  resumingPlayback: Bool, attempt: UUID) async throws -> CloudAuthCompletion {
        switch credential.provider {
        case .quark:
            switch credential.kind {
            case .cookie:
                return try await completeQuarkCookieAuth(credential, reference: reference, attempt: attempt)
            case .refreshToken, .accessToken:
                return try await completeQuarkTVAuth(credential, attempt: attempt)
            default:
                throw DriveEngineError.unsupported(L10n.text("夸克授权暂不支持 {0} 凭证。", ["\(credential.kind.rawValue)"]))
            }
        case .uc:
            switch credential.kind {
            case .cookie:
                return try await completeUCCookieAuth(credential, reference: reference, attempt: attempt)
            case .refreshToken, .accessToken:
                return try await completeUCTVAuth(credential, resumingPlayback: resumingPlayback, attempt: attempt)
            case .shareToken:
                return try await completeUCFongMiAuth(credential, resumingPlayback: resumingPlayback, attempt: attempt)
            default:
                throw DriveEngineError.unsupported(L10n.text("UC 授权暂不支持 {0} 凭证。", ["\(credential.kind.rawValue)"]))
            }
        case .ali:
            return try await completeAliAuth(credential)
        case .p115:
            switch credential.kind {
            case .cookie:
                return try await completeP115CookieAuth(credential, attempt: attempt)
            default:
                throw DriveEngineError.unsupported(L10n.text("115 授权暂只支持 Cookie。"))
            }
        case .pikpak:
            return try await completePikPakAuth(credential)
        case .baidu:
            guard credential.kind == .cookie else {
                throw DriveEngineError.unsupported(L10n.text("百度网盘授权只支持扫码或 Cookie。"))
            }
            return try await completeBaiduAuth(credential, attempt: attempt)
        default:
            throw DriveEngineError.unsupported(L10n.text("{0} 授权暂未适配。", ["\(credential.provider.localizedDisplayName)"]))
        }
    }

    func validateAndSaveCloudCookie(provider: DriveProvider, cookie: String) async throws {
        let credential = CloudCredential.cookie(provider: provider, value: cookie)
        _ = try await completeCloudAuth(credential: credential)
    }

    private func completeQuarkCookieAuth(_ credential: CloudCredential, reference: DriveFileReference?, attempt: UUID) async throws -> CloudAuthCompletion {
        let validated = try await QuarkCookieDriver().validate(credential, reference: reference)
        try checkCloudAuthAttempt(attempt)
        UserPreferences.shared.quarkCookie = validated.secret.trimmingCharacters(in: .whitespacesAndNewlines)

        try UserPreferences.shared.checkCredentialPersistence()

        return .dismiss(L10n.text("夸克 Cookie 验证成功，已保存。"), credentialsValidated: true)
    }

    private func completeBaiduAuth(_ credential: CloudCredential, attempt: UUID) async throws -> CloudAuthCompletion {
        let validated = try await BaiduDriveClient().validate(credential)
        try checkCloudAuthAttempt(attempt)
        UserPreferences.shared.baiduCookie = validated.secret.trimmingCharacters(in: .whitespacesAndNewlines)

        try UserPreferences.shared.checkCredentialPersistence()
        return .dismiss(L10n.text("百度网盘登录验证成功，已保存并继续播放。"), credentialsValidated: true)
    }

    private func completeQuarkTVAuth(_ credential: CloudCredential, attempt: UUID) async throws -> CloudAuthCompletion {
        let validated = try await QuarkTVDriver().validate(credential, reference: nil)
        try checkCloudAuthAttempt(attempt)
        UserPreferences.shared.quarkTVDeviceID = validated.deviceID ?? ""
        UserPreferences.shared.quarkTVQueryToken = validated.queryToken ?? ""
        UserPreferences.shared.quarkTVRefreshToken = validated.refreshToken ?? ""
        UserPreferences.shared.quarkTVAccessToken = validated.accessToken ?? ""

        try UserPreferences.shared.checkCredentialPersistence()
        return .stay(L10n.text("QuarkTV Token 已保存。请继续扫码获取 Cookie，公开分享完整播放会使用 Cookie。"), credentialsValidated: true)
    }

    private func completeUCCookieAuth(_ credential: CloudCredential, reference: DriveFileReference?, attempt: UUID) async throws -> CloudAuthCompletion {
        let validated = try await UCCookieDriver().validate(credential, reference: reference)
        try checkCloudAuthAttempt(attempt)
        UserPreferences.shared.ucCookie = validated.secret.trimmingCharacters(in: .whitespacesAndNewlines)

        try UserPreferences.shared.checkCredentialPersistence()

        return .dismiss(L10n.text("UC Cookie 验证成功，已保存。"), credentialsValidated: true)
    }

    private func completeUCTVAuth(_ credential: CloudCredential, resumingPlayback: Bool, attempt: UUID) async throws -> CloudAuthCompletion {
        let validated = try await QuarkTVDriver(provider: .uc).validate(credential, reference: nil)
        try checkCloudAuthAttempt(attempt)
        UserPreferences.shared.ucTVDeviceID = validated.deviceID ?? ""
        UserPreferences.shared.ucTVQueryToken = validated.queryToken ?? ""
        UserPreferences.shared.ucTVRefreshToken = validated.refreshToken ?? ""
        UserPreferences.shared.ucTVAccessToken = validated.accessToken ?? ""

        if resumingPlayback {
            try UserPreferences.shared.checkCredentialPersistence()
            return .stay(L10n.text("UCTV Token 已保存；UC 分享播放仍需要 Cookie。请继续网页扫码，完成后会优先播放原文件。"), credentialsValidated: true)
        }

        try UserPreferences.shared.checkCredentialPersistence()

        return .dismiss(L10n.text("UCTV Token 验证成功，已保存。"), credentialsValidated: true)
    }

    private func completeUCFongMiAuth(_ credential: CloudCredential, resumingPlayback: Bool, attempt: UUID) async throws -> CloudAuthCompletion {
        let validated = try await UCFongMiQRLoginClient().validate(credential)
        try checkCloudAuthAttempt(attempt)
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
            throw DriveEngineError.unsupported(L10n.text("UC 专用播放授权缺少用途信息。"))
        }

        UserPreferences.shared.ucFongMiFixtureID = validated.metadata[UCFongMiCredentialMetadataKey.fixtureID] ?? ""
        UserPreferences.shared.ucFongMiEvidenceStatus = validated.metadata[UCFongMiCredentialMetadataKey.evidenceStatus] ?? ""

        if UCFongMiQRLoginKind(rawValue: kind) == .playback,
           resumingPlayback,
           !UserPreferences.shared.ucCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try UserPreferences.shared.checkCredentialPersistence()
            return .dismiss(L10n.text("UC 专用播放授权已保存，正在重试播放。"), credentialsValidated: true)
        }

        try UserPreferences.shared.checkCredentialPersistence()
        return .stay(L10n.text("UC 专用播放授权已保存；普通分享播放仍优先使用网页授权。"), credentialsValidated: true)
    }

    private func completeAliAuth(_ credential: CloudCredential) async throws -> CloudAuthCompletion {
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

        try UserPreferences.shared.checkCredentialPersistence()
        return .dismiss(L10n.text("阿里云盘 Token 已保存，将在播放时校验。"))
    }

    private func completeP115CookieAuth(_ credential: CloudCredential, attempt: UUID) async throws -> CloudAuthCompletion {
        let validated = try await P115DriveClient().validate(credential)
        try checkCloudAuthAttempt(attempt)
        UserPreferences.shared.p115Cookie = validated.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if let accessToken = validated.metadata["access_token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accessToken.isEmpty {
            UserPreferences.shared.p115AccessToken = accessToken
        }

        try UserPreferences.shared.checkCredentialPersistence()
        return .dismiss(L10n.text("115 Cookie 验证成功，已保存并继续播放。"), credentialsValidated: true)
    }

    private func completePikPakAuth(_ credential: CloudCredential) async throws -> CloudAuthCompletion {
        UserPreferences.shared.pikpakAccessToken = credential.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? credential.metadata["access_token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        UserPreferences.shared.pikpakRefreshToken = credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? credential.metadata["refresh_token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        UserPreferences.shared.pikpakDeviceID = credential.deviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? credential.metadata["device_id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        try UserPreferences.shared.checkCredentialPersistence()
        return .dismiss(L10n.text("PikPak Token 已保存，将在播放时校验。"))
    }


    private func releaseLocalStreamRelayIfNeeded(
        spec: PlaySpec?,
        replacingWith replacement: PlaySpec? = nil,
        reason: String
    ) {
        guard let spec else { return }
        if let leaseID = spec.metadata["files.leaseID"], leaseID != replacement?.metadata["files.leaseID"], let id = UUID(uuidString: leaseID) {
            Task { await FileServiceRuntime.shared.releasePlayback(leaseID: id) }
        }
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
        ThunderNextEpisodeCache.releaseCachedFile(spec: spec)
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
            log("[DRIVE_CLEANUP] 跳过自动删除，\(provider.localizedDisplayName)临时文件缺少文件 ID")
            return
        }

        let cleanupIdentity = cacheKey.isEmpty ? "\(driveID):\(fileID)" : cacheKey
        let cleanupKey = "\(provider.rawValue):\(cleanupIdentity)"
        guard !driveCleanupInFlight.contains(cleanupKey) else { return }
        guard let credential = Self.cloudCredential(for: provider) else {
            log("[DRIVE_CLEANUP] 跳过自动删除，\(provider.localizedDisplayName)授权为空 fileID=\(fileID)")
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
                self.log("[DRIVE_CLEANUP] 已清理\(provider.localizedDisplayName)临时转存文件 fileID=\(fileID)")
            } catch {
                self.log("[DRIVE_CLEANUP] 清理\(provider.localizedDisplayName)临时转存文件失败 fileID=\(fileID), error=\(error.localizedDescription)")
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
           var relaySpec = LiveHLSRelayPolicy.localStreamRelaySpec(
               from: spec,
               bufferConfiguration: RemoteStreamBufferConfiguration(
                   initialChunkSize: 512 * 1024,
                   chunkSize: 1 * 1024 * 1024,
                   prefetchWindowSize: 2 * 1024 * 1024,
                   maxBytes: 8 * 1024 * 1024,
                   maxConcurrentPrefetches: 1
               )
           ) {
            relaySpec.format = "mp4"
            self.log("[\(logContext)] B站合并 MP4 使用可续传 Range 代理: \(redactedPlaybackURL(relaySpec.url))")
            return relaySpec
        }
        let relayMode: RemoteStreamRelayMode = PlaybackProxyPolicy.shouldUseChunkedRangeRelay(
            for: spec,
            enabled: UserPreferences.shared.chunkedRangeRelayEnabled
        ) ? .chunked : .buffered
        if (relayMode == .chunked || PlaybackProxyPolicy.shouldUseRemoteStreamProxy(for: spec)),
           let streamSpec = LiveHLSRelayPolicy.localStreamRelaySpec(from: spec, relayMode: relayMode) {
            let providerLabel = driveProviderLabel(for: spec)
            let modeLabel = relayMode == .chunked ? L10n.text("分片 Range") : L10n.text("缓冲")
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
        guard activeLive != nil else { return }
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

    /// 加载外层直播配置或单个 M3U/TXT，不改写配置内的源地址。
    @discardableResult
    func loadLiveConfiguration(url: String) async -> Bool {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID()
        liveConfigurationRequestID = requestID
        isLoadingLiveConfiguration = true
        liveConfigurationError = nil
        defer {
            if liveConfigurationRequestID == requestID { isLoadingLiveConfiguration = false }
        }
        do {
            let input = try await liveDataSource.configuration(url: url, resolver: configResolver)
            guard liveConfigurationRequestID == requestID, !Task.isCancelled else { return false }
            guard let selected = input.selectedSource(preferredName: userPreferences.currentLiveName) else {
                throw LiveConfigurationInput.InputError.noSources
            }
            lives = input.sources
            userPreferences.currentLiveConfigUrl = url
            isLoadingLiveConfiguration = false
            await changeLive(selected, initialGroups: input.initialGroups)
            return liveConfigurationRequestID == requestID && !Task.isCancelled
        } catch {
            guard liveConfigurationRequestID == requestID, !Task.isCancelled else { return false }
            liveConfigurationError = error is LiveConfigurationInput.InputError
                ? L10n.text("配置中没有可用的直播源，请检查地址。")
                : L10n.text("直播配置加载失败，请检查地址或网络后重试。")
            return false
        }
    }

    /// 切源时使旧列表请求、重试和节目单失效，避免晚到的响应覆盖新选择。
    private func resetLiveSource(_ live: Live?) {
        liveDataSource.contentRequests.cancelAll()
        cancelLivePlaybackAttempts()
        if livePlayerState.currentSpec != nil { MPVPlayerEngine.live.stop() }
        liveContentRequestID = nil
        isLoadingLive = false
        liveEpgTask?.cancel()
        liveEpgRequestID = UUID()
        liveEpgRequestKey = ""
        isLoadingLiveEpg = false
        if let live { LiveConfig.shared.setCurrent(live) }
        self.activeLive = live
        self.channelGroups = []
        self.selectedGroup = nil
        self.selectedChannel = nil
        self.currentChannelUrlIndex = 0
        self.liveContentLoadedAt = nil
        self.liveEpgData = nil
        self.liveEpgError = nil
        self.liveEpgAvailability = .unconfigured
        self.liveError = nil
        self.livePlayerState.errorMessage = nil
    }

    /// 切换直播配置内的具体源；独立保存选择，重启后仍可恢复。
    func changeLive(_ live: Live, initialGroups: [ChannelGroup]? = nil) async {
        resetLiveSource(live)
        userPreferences.currentLiveName = live.name
        if let initialGroups {
            applyLiveGroups(initialGroups, live: live)
            if isLivePlayerPresented { await resumeSelectedLiveChannelIfNeeded() }
        } else {
            await loadLiveContentAndResumeIfNeeded()
        }
    }

    private func applyLiveGroups(_ groups: [ChannelGroup], live: Live) {
        channelGroups = groups.map { $0.applying(live: live) }
        restoreLiveSelection(groups: channelGroups)
        liveContentLoadedAt = Date()
        liveError = nil
    }

    /// 加载当前直播配置的频道列表
    @discardableResult
    func loadLiveContent() async -> Bool {
        guard let live = activeLive, !isLoadingLive else { return false }
        let requestID = UUID()
        liveContentRequestID = requestID
        self.isLoadingLive = true
        defer {
            if liveContentRequestID == requestID { self.isLoadingLive = false }
        }
        func isCurrentRequest() -> Bool {
            liveContentRequestID == requestID && !Task.isCancelled
                && activeLive?.name == live.name && activeLive?.url == live.url
        }
        let scope = liveDataSource.contentRequests.scope(source: live.name + "|" + live.url)
        let nativeGroups: (@Sendable () async throws -> [ChannelGroup])?
        if live.url.hasPrefix("netvplayer-xtream://"),
           let account = userPreferences.xtreamConfigurations.first(where: { $0.url == live.url }) {
            nativeGroups = {
                guard let provider = await SpiderReplacementRegistry.shared.nativeProvider(for: try account.site()) as? XtreamSiteProvider else {
                    throw LiveDataSourceCoordinator.ContentError.empty
                }
                await provider.clearContentCache()
                return try await provider.liveGroups()
            }
        } else { nativeGroups = nil }
        do {
            let result = try await liveDataSource.content(live: live, client: liveHTTPClient, scope: scope, nativeGroups: nativeGroups)
            guard isCurrentRequest() else { return false }
            applyLiveGroups(result.groups, live: live)
            log("[LIVE_CONTENT_REFRESHED] groups=\(result.groups.count) attempt=\(result.attempt) bytes=\(result.bytes) status=\(result.status)")
            return true
        } catch {
            guard isCurrentRequest(), !(error is CancellationError) else { return false }
            if error is LiveDataSourceCoordinator.ContentError {
                liveError = L10n.text("直播源“{0}”未返回可用频道，请重试或切换直播源。", [live.name])
            } else {
                let transport = error as? LiveDataSourceCoordinator.TransportError
                recordRemoteDiagnosticError("LIVE_CONTENT_REFRESH_FAILED", error: transport?.underlying ?? error, attempt: transport?.attempt ?? 0)
                liveError = L10n.text("直播源“{0}”加载失败，请检查网络或切换直播源。", [live.name])
            }
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

    func makeLiveEpgLoader() -> LiveEPGLoader {
        LiveEPGLoader(accounts: userPreferences.xtreamConfigurations)
    }

    /// EPG runs independently from playback and owns both a source key and a request generation.
    func loadLiveEpg(for channel: Channel, forceRefresh: Bool = false) async {
        let requestKey = "\(activeLive?.url ?? "")|\(channel.epg)|\(liveEpgChannelKey(for: channel))|\(channel.urls)"
        let requestID = UUID()
        let sourceURL = activeLive?.url
        let keepExistingData = liveEpgRequestKey == requestKey
        liveEpgTask?.cancel()
        liveEpgRequestID = requestID
        liveEpgRequestKey = requestKey
        if !keepExistingData { liveEpgData = nil }
        liveEpgError = nil
        isLoadingLiveEpg = true
        let loader = makeLiveEpgLoader()
        let now = Date()
        let window = DateInterval(start: now, end: now.addingTimeInterval(12 * 3_600))
        let task = Task {
            await loader.load(channel: channel, window: window, forceRefresh: forceRefresh)
        }
        liveEpgTask = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, liveEpgRequestID == requestID, activeLive?.url == sourceURL,
              selectedChannel?.id == channel.id, selectedChannel?.urls == channel.urls else { return }
        liveEpgTask = nil
        isLoadingLiveEpg = false
        if result.availability != .unavailable || !keepExistingData { liveEpgData = result.data }
        liveEpgAvailability = result.availability
        liveEpgError = result.message
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

        let message = self.liveError ?? L10n.text("频道“{0}”没有可用线路。请切换直播源。", ["\(channel.name)"])
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

        let message = self.liveError ?? L10n.text("频道“{0}”的线路 {1} 不可用。请切换线路或直播源。", ["\(channel.name)", "\(index + 1)"])
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

        restoreCachedLiveSelectionIfNeeded()
        guard var channel = selectedChannel else { return }
        guard !channel.urls.isEmpty else {
            let message = L10n.text("频道“{0}”没有可用线路。请切换频道。", ["\(channel.name)"])
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

    func restoreCachedLiveSelectionIfNeeded() {
        guard selectedChannel == nil, !channelGroups.isEmpty else { return }
        restoreLiveSelection(groups: channelGroups)
    }

    static func restoredLiveSelection(
        groups: [ChannelGroup],
        savedGroupName: String,
        savedChannelName: String,
        savedURLIndex: Int
    ) -> (group: ChannelGroup?, channel: Channel?, urlIndex: Int) {
        let group = groups.first { $0.name == savedGroupName } ?? groups.first
        guard var channel = group?.channels.first(where: { $0.name == savedChannelName })
            ?? group?.channels.first else {
            return (group, nil, 0)
        }

        channel.currentUrlIndex = min(max(savedURLIndex, 0), max(channel.urls.count - 1, 0))
        return (group, channel, channel.currentUrlIndex)
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
        hlsRecoverySlots.invalidate(live: true)
        hlsRecoveryTasks.removeValue(forKey: true)?.cancel()
        liveFallbackTask?.cancel()
        liveFallbackTask = nil
        livePendingFailureTask?.cancel()
        livePendingFailureTask = nil
        livePlaybackSessionID = UUID()
        livePlaybackLoadingID = nil
        isLivePlaybackLoading = false
        livePlaybackLoadingMessage = L10n.text("正在检查当前频道线路，请稍候。")
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
        livePlaybackLoadingMessage = L10n.text("正在检查当前频道线路，请稍候。")
        defer {
            if livePlaybackLoadingID == loadingID {
                livePlaybackLoadingID = nil
                isLivePlaybackLoading = false
                livePlaybackLoadingMessage = L10n.text("正在检查当前频道线路，请稍候。")
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
            livePlaybackLoadingMessage = L10n.text("正在检查 {0} 线路 {1}。", ["\(attempt.channel.name)", "\(attempt.urlIndex + 1)"])
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
        liveError = lastMessage ?? L10n.text("当前没有可用线路。请切换直播源。")
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
            livePlaybackLoadingMessage = L10n.text("正在探测 {0} 线路 {1}。", ["\(channel.name)", "\(urlIndex + 1)"])
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
                liveError = L10n.text("频道“{0}”的线路 {1} 已过期，正在刷新频道列表。", ["\(channel.name)", "\(urlIndex + 1)"])
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

            if probe.isPlayable, probe.isHLS {
                spec.format = "hls"
                if let finalURL = probe.finalURL {
                    spec.url = finalURL.absoluteString
                }
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
            livePlaybackLoadingMessage = L10n.text("线路已就绪，正在启动播放器。")
            await play(spec: spec)
            return .started
        } catch {
            guard Self.shouldContinueLivePlayback(
                sessionID: sessionID,
                currentSessionID: livePlaybackSessionID,
                isLivePlayerPresented: isLivePlayerPresented
            ) else { return .failed }
            liveError = UserFacingErrorPresenter.message(
                for: error,
                context: .live(channelName: channel.name, lineNumber: urlIndex + 1)
            )
            self.log("[\(logContext)] 直播播放预处理失败: \(error.localizedDescription)")
            return .failed
        }
    }

    private func liveProbeFailureMessage(channel: String, urlIndex: Int, statusCode: Int, hasMoreAttempts: Bool) -> String {
        if hasMoreAttempts {
            return L10n.text("频道“{0}”的线路 {1} 暂时不可用（错误码 {2}），正在尝试下一线路。", ["\(channel)", "\(urlIndex + 1)", "\(statusCode)"])
        }
        return L10n.text("频道“{0}”的线路 {1} 暂时不可用（错误码 {2}）。请切换线路或直播源。", ["\(channel)", "\(urlIndex + 1)", "\(statusCode)"])
    }

    private func driveProviderLabel(for spec: PlaySpec) -> String {
        spec.drivePlaybackPlan?.provider.localizedDisplayName
            ?? DriveProvider(rawValue: spec.metadata[DrivePlaybackMetadataKey.provider] ?? "")?.localizedDisplayName
            ?? L10n.text("网盘")
    }

    private func ownsPlaybackFailure(_ spec: PlaySpec, live: Bool) -> Bool {
        let current = (live ? livePlayerState : playerState).currentSpec
        return current?.url == spec.url
            && current?.metadata["playback.sessionGeneration"] == spec.metadata["playback.sessionGeneration"]
            && current?.metadata["live.sessionID"] == spec.metadata["live.sessionID"]
            && (live ? (isLivePlayerPresented && spec.metadata["live.sessionID"] == livePlaybackSessionID.uuidString) : isPlayerPresented)
    }

    func handleMPVPlaybackFailure(spec: PlaySpec?, message: String, failure: MPVPlaybackFailure? = nil) {
        if let spec, spec.drivePlaybackPlan != nil,
           !drivePlaybackSessionController.acceptsAttempt(for: spec) { return }
        if let spec, let failure, HLSMediaTypeRecovery.eligible(spec, failure: failure) {
            let live = spec.metadata["playback.kind"] == "live"
            guard ownsPlaybackFailure(spec, live: live),
                  let requestID = hlsRecoverySlots.claim(live: live) else { return }
            hlsRecoveryTasks[live] = Task { @MainActor [weak self] in
                guard let self else { return }
                let detected = (try? await HLSMediaTypeRecovery.prepare(spec)) == true
                guard !Task.isCancelled, self.hlsRecoverySlots.complete(requestID, live: live) else { return }
                self.hlsRecoveryTasks[live] = nil
                guard self.ownsPlaybackFailure(spec, live: live) else { return }
                if detected {
                    self.log("[HLS_TYPE_RECOVERY] confirmed HLS; retrying once")
                    await self.play(spec: HLSMediaTypeRecovery.recovering(spec))
                } else {
                    var exhausted = spec
                    exhausted.metadata[HLSMediaTypeRecovery.attemptedKey] = "true"
                    self.handleMPVPlaybackFailure(spec: exhausted, message: message, failure: failure)
                }
            }
            return
        }
        if let spec, HLSRecovery.eligible(spec),
           (spec.metadata["playback.kind"] == "live" ? livePlayerState.position : playerState.position) < 1 {
            let live = spec.metadata["playback.kind"] == "live"
            let state = live ? livePlayerState : playerState
            guard state.currentSpec?.url == spec.url,
                  state.currentSpec?.metadata["playback.sessionGeneration"] == spec.metadata["playback.sessionGeneration"],
                  state.currentSpec?.metadata["live.sessionID"] == spec.metadata["live.sessionID"],
                  live ? (isLivePlayerPresented && spec.metadata["live.sessionID"] == livePlaybackSessionID.uuidString) : isPlayerPresented else { return }
            guard let requestID = hlsRecoverySlots.claim(live: live) else { return }
            hlsRecoveryTasks[live] = Task { @MainActor [weak self] in
                guard let self else { return }
                let playlist = try? await HLSRecovery.prepare(spec)
                guard !Task.isCancelled, self.hlsRecoverySlots.isCurrent(requestID, live: live) else { return }
                guard self.hlsRecoverySlots.complete(requestID, live: live) else { return }
                self.hlsRecoveryTasks[live] = nil
                let isLive = spec.metadata["playback.kind"] == "live"
                let current = isLive ? self.livePlayerState.currentSpec : self.playerState.currentSpec
                guard current?.url == spec.url,
                      current?.metadata["live.sessionID"] == spec.metadata["live.sessionID"],
                      current?.metadata["playback.sessionGeneration"] == spec.metadata["playback.sessionGeneration"],
                      isLive ? self.isLivePlayerPresented : self.isPlayerPresented else { return }
                var retry = spec
                retry.metadata[HLSRecovery.attemptedKey] = "true"
                if let playlist,
                   let relayed = ProxyPlaybackHandler.recoveryPlaylist(playlist, baseURL: spec.url, headers: spec.headers),
                   let resource = ProxyServer.shared.registerRecoveryPlaylist(relayed) {
                    retry.url = resource.url
                    retry.format = "hls"
                    retry.metadata["hls.recoveryCacheKey"] = resource.key
                    retry.mpvOptions["demuxer-lavf-format"] = "hls"
                    self.log("[HLS_RECOVERY] bounded master selected with associated renditions")
                    await self.play(spec: retry)
                } else {
                    self.handleMPVPlaybackFailure(spec: retry, message: message, failure: failure)
                }
            }
            return
        }

        if let spec, spec.metadata["playback.kind"] != "live",
           let trace = playbackStartupTrace,
           spec.metadata["playback.sessionGeneration"].flatMap(UInt64.init) != trace.generation {
            return
        }
        lastFeedbackFailureStage = "Player.mpv"
        lastFeedbackFailureCategory = spec?.metadata["playback.kind"] == "live" ? .live : .player
        if spec?.metadata["playback.kind"] != "live" {
            playerState.errorMessage = UserFacingErrorPresenter.playbackMessage(from: message)
        }
        if let spec, spec.metadata["playback.kind"] != "live" {
            let startupDuration = spec.metadata["playback.sessionGeneration"].flatMap(UInt64.init).map {
                finishPlaybackStartupTrace(stage: "mpv-failed", siteKey: spec.siteKey, generation: $0)
            } ?? 0
            recordSiteHealth(
                eventType: .play,
                siteKey: spec.siteKey,
                siteName: siteName(for: spec.siteKey),
                success: false,
                durationMs: startupDuration,
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

        if let spec, spec.metadata["playback.kind"] != "live" {
            recordPlaybackRecoveryFailure(for: spec, message: message)
            return
        }

        guard let spec,
              spec.metadata["playback.kind"] == "live",
              spec.metadata["live.sessionID"] == livePlaybackSessionID.uuidString else {
            return
        }

        let channelName = spec.metadata["live.channelName"] ?? selectedChannel?.name ?? L10n.text("直播频道")
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
            if pendingDrivePlaybackRouteID == spec.metadata[DrivePlaybackRoutePolicy.selectionIDMetadataKey] {
                pendingDrivePlaybackRouteID = nil
                pendingDrivePlaybackNotice = nil
            }
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
                let routeTitle = DrivePlaybackRoutePolicy.title(for: nextSpec) ?? provider.localizedDisplayName
                let quality = candidate.quality.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let qualitySuffix = quality.isEmpty ? "" : "（\(quality)）"
                _ = await self.beginDrivePlaybackRouteSwitch(
                    to: nextSpec,
                    routeTitle: routeTitle,
                    positionSeconds: self.playerState.position,
                    reason: candidate.id == failedCandidateID
                        ? L10n.text("{0}线路失效，刷新后重试", ["\(provider.localizedDisplayName)"])
                        : L10n.text("{0}当前线路播放失败", ["\(provider.localizedDisplayName)"]),
                    notice: DrivePlaybackRouteNotice(
                        kind: candidate.id == failedCandidateID ? .routeRecovery : .automaticFallback,
                        message: candidate.id == failedCandidateID
                            ? L10n.text("已刷新“{0}”线路并恢复播放。", ["\(routeTitle)"])
                            : L10n.text("已自动切换到“{0}”线路{1}，以恢复播放。", ["\(routeTitle)", "\(qualitySuffix)"])
                    ),
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
                recordPlaybackRecoveryFailure(for: spec, message: message)
                presentDrivePlaybackTerminalError(for: spec)
            }
        }
    }

    private func recordPlaybackRecoveryFailure(for spec: PlaySpec, message: String) {
        let provider = spec.drivePlaybackPlan?.provider
            ?? DriveProvider(rawValue: spec.metadata[DrivePlaybackMetadataKey.provider] ?? "")
            ?? .unknown
        let route = Self.driveRouteDiagnosticCode(
            spec.metadata[DrivePlaybackMetadataKey.route]
                ?? DrivePlaybackRoutePolicy.candidate(for: spec)?.providerRoute
                ?? ""
        )
        let measurements = MPVPlayerEngine.failureDiagnosticMeasurements(for: message)
        let detail = measurements.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        DiagnosticLog.write(
            "[PLAYBACK_RECOVERY_FAILED] errorKind=5 provider=\(Self.driveProviderDiagnosticCode(provider)) route=\(route) \(detail)"
        )
    }

    private static func driveRouteDiagnosticCode(_ route: String) -> Int {
        switch route {
        case DrivePlaybackRoute.ucOriginalProxy: return 1
        case DrivePlaybackRoute.ucOpenAPIStreaming: return 2
        case DrivePlaybackRoute.ucSmartPlay: return 3
        case DrivePlaybackRoute.streamVariant: return 4
        case DrivePlaybackRoute.personalTranscode: return 5
        case DrivePlaybackRoute.originalDownload: return 6
        case DrivePlaybackRoute.shareFallback: return 7
        default: return 0
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
        if let spec, spec.metadata["playback.kind"] == "live",
           isLivePlayerPresented, isCurrentLivePlaybackSpec(spec, sessionID: livePlaybackSessionID),
           livePlayerState.isBuffering, !livePlayerState.isMediaLoading, !livePlayerState.isSeeking {
            processConfirmedMPVPlaybackFailure(spec: spec, message: "connection ended (cache stall)")
            return
        }
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
                    message: L10n.text("{0}播放缓存停滞", ["\(plan.provider.localizedDisplayName)"])
                )
            }
            return
        }

    }

    private func repairLiveConnectionIfNeeded(spec: PlaySpec?) {
        guard let spec, isLivePlayerPresented, liveFallbackTask == nil,
              isCurrentLivePlaybackSpec(spec, sessionID: livePlaybackSessionID),
              let repaired = LivePlaybackBufferPolicy.shortConnectionSpec(from: spec) else { return }
        let sessionID = livePlaybackSessionID
        log("[LIVE_CONNECTION_REPAIR] attempt=1 session=\(sessionID.uuidString)")
        liveFallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.liveFallbackTask = nil }
            guard self.isLivePlayerPresented, self.isCurrentLivePlaybackSpec(spec, sessionID: sessionID) else { return }
            await self.play(spec: repaired)
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
        let channelName = spec.metadata["live.channelName"] ?? selectedChannel?.name ?? L10n.text("直播频道")
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
            if spec.drivePlaybackPlan != nil,
               !drivePlaybackSessionController.acceptsAttempt(for: spec) { return }
            let generation = spec.metadata["playback.sessionGeneration"].flatMap(UInt64.init)
            if let trace = playbackStartupTrace, generation != trace.generation { return }
            isPlayerLoading = false
            // libmpv reports its first valid time-pos here; this is playback progress,
            // not a renderer acknowledgement that a frame reached the display.
            let startupDuration = generation.map {
                finishPlaybackStartupTrace(stage: "mpv-first-progress", siteKey: spec.siteKey, generation: $0)
            } ?? 0
            if spec.drivePlaybackPlan != nil {
                _ = drivePlaybackSessionController.confirmStarted(spec: spec)
            }
            confirmDrivePlaybackRouteStarted(spec: spec)
            recordSiteHealth(
                eventType: .play,
                siteKey: spec.siteKey,
                siteName: siteName(for: spec.siteKey),
                success: true,
                durationMs: startupDuration,
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
        let channelName = spec.metadata["live.channelName"] ?? selectedChannel?.name ?? L10n.text("直播频道")
        let transport = spec.metadata[LiveHLSRelayPolicy.transportMetadataKey] ?? "live"
        log("[LIVE_PLAYBACK_STARTED] channel=\(channelName) transport=\(transport)")
    }

    var activeDrivePlaybackRouteLabel: String? {
        guard let selectedDrivePlaybackRouteID else { return nil }
        return drivePlaybackRoutes.first(where: { $0.id == selectedDrivePlaybackRouteID })?.title
    }

    @discardableResult
    func configureDrivePlaybackRoutes(for spec: PlaySpec) -> PlaySpec {
        activateDrivePlaybackRoutes(for: DrivePlaybackRoutePolicy.preparedSpec(spec))
    }

    private func activateDrivePlaybackRoutes(for spec: PlaySpec) -> PlaySpec {
        var prepared = spec
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
        pendingDrivePlaybackNotice = nil
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
                    reason: L10n.text("用户手动选择线路"),
                    notice: DrivePlaybackRouteNotice(
                        kind: .manualSelection,
                        message: L10n.text("已切换到“{0}”线路。", ["\(route.title)"])
                    ),
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
        notice: DrivePlaybackRouteNotice,
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
        pendingDrivePlaybackNotice = notice
        playbackRouteNotice = nil
        playerState.errorMessage = nil
        isPlaybackErrorPresented = false
        playerState.drivePlaybackStatus = L10n.text("正在切换 {0}", ["\(routeTitle)"])
        log("[\(logContext)] \(reason)，切换到 \(routeTitle): \(redactedPlaybackURL(prepared.url))")

        var playable = await proxiedPlaySpec(prepared, logContext: logContext)
        let resumeMilliseconds = Int64(max(0, positionSeconds) * 1000)
        let durationMilliseconds = playerState.duration.isFinite && playerState.duration > 0
            ? Int64(playerState.duration * 1_000)
            : nil
        let episodeURL = PlaybackResumePolicy.episodeURL(for: prepared)
        let skipSettings = VodSkipSettingsStore.shared.settings(for: prepared.metadata)
        preparePlaybackStart(
            spec: &playable,
            resumePosition: resumeMilliseconds > 0 ? resumeMilliseconds : nil,
            resumeDuration: durationMilliseconds,
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
        playbackRouteNotice = pendingDrivePlaybackNotice
        pendingDrivePlaybackNotice = nil
        let title = DrivePlaybackRoutePolicy.title(for: spec) ?? selectionID
        log("[DRIVE_PLAYBACK_ROUTE_STARTED] route=\(title) notice=\(playbackRouteNotice.map { String(describing: $0.kind) } ?? "none")")
    }

    private func resetDrivePlaybackRoutes() {
        drivePlaybackSessionController.cancel()
        drivePlaybackRoutes = []
        selectedDrivePlaybackRouteID = nil
        pendingDrivePlaybackRouteID = nil
        pendingDrivePlaybackNotice = nil
    }

    private func presentDrivePlaybackTerminalError(for spec: PlaySpec) {
        guard playerState.currentSpec?.drivePlaybackSessionGeneration == spec.drivePlaybackSessionGeneration,
              let plan = spec.drivePlaybackPlan else {
            return
        }
        isPlayerLoading = false
        playerState.isMediaLoading = false
        playbackRouteNotice = nil
        pendingDrivePlaybackRouteID = nil
        pendingDrivePlaybackNotice = nil
        playerState.drivePlaybackStatus = nil
        if plan.reauthenticationRequired {
            playerState.errorMessage = L10n.text("{0}登录已失效，请重新授权后重试。", ["\(plan.provider.localizedDisplayName)"])
            playbackErrorAuthProvider = plan.provider
            pendingAuthEpisode = episodeForCurrentPlayback(in: episodes)
        } else {
            playerState.errorMessage = L10n.text("{0}原片和兼容线路均播放失败，请重试或切换来源。", ["\(plan.provider.localizedDisplayName)"])
            playbackErrorAuthProvider = nil
        }
        let route = DrivePlaybackRoutePolicy.candidate(for: spec)?.providerRoute ?? "-"
        log("[DRIVE_PLAYBACK_TERMINAL] provider=\(plan.provider.rawValue) route=\(route)")
    }

    private func play(spec: PlaySpec) async {
        var spec = spec
        if UserPreferences.shared.proxyMode == 1 { spec.metadata["network.explicitDirect"] = "true" }
        let isLive = spec.metadata["playback.kind"] == "live"
        if !isLive, spec.drivePlaybackPlan != nil {
            guard let submitted = drivePlaybackSessionController.prepareSubmission(for: spec) else { return }
            spec = submitted
        }
        hlsRecoverySlots.invalidate(live: isLive)
        hlsRecoveryTasks.removeValue(forKey: isLive)?.cancel()
        let currentSpec = spec.metadata["playback.kind"] == "live"
            ? livePlayerState.currentSpec
            : playerState.currentSpec
        if let key = currentSpec?.metadata["hls.recoveryCacheKey"], key != spec.metadata["hls.recoveryCacheKey"] {
            ProxyServer.shared.removeRecoveryPlaylist(key)
        }
        releaseLocalStreamRelayIfNeeded(
            spec: currentSpec,
            replacingWith: spec,
            reason: "playback-replaced"
        )
        ThunderNextEpisodeCache.releaseCachedFile(spec: currentSpec, replacingWith: spec)
        releaseBiliPlaybackCacheIfNeeded(
            spec: currentSpec,
            replacingWith: spec,
            reason: "playback-replaced"
        )
        if spec.metadata["playback.kind"] != "live" {
            cancelDanmakuSelection()
            if spec.danmakuAttachment == nil { spec.danmakuAttachment = danmakuBindings.attachment(for: spec) }
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
        danmakuRenderRevision = UUID()
        guard UserPreferences.shared.danmakuEnabled else {
            currentDanmakuCues = []
            lastDanmakuParseDiagnostic = nil
            lastDanmakuRenderStatus = L10n.text("弹幕已关闭")
            return
        }
        guard let attachment = spec?.danmakuAttachment else {
            currentDanmakuCues = []
            lastDanmakuParseDiagnostic = nil
            lastDanmakuRenderStatus = L10n.text("暂无弹幕附件")
            return
        }
        guard let payload = DanmakuEngine.shared.cachedPayload(cacheKey: attachment.trackCacheKey),
              let track = DanmakuEngine.shared.cachedTrack(cacheKey: attachment.trackCacheKey) else {
            currentDanmakuCues = []
            lastDanmakuParseDiagnostic = nil
            playerState.danmakuStatus = L10n.text("弹幕缓存缺失")
            lastDanmakuRenderStatus = L10n.text("弹幕缓存缺失")
            return
        }
        let result = DanmakuPayloadParser.parseWithDiagnostic(payload: payload, format: track.format)
        lastDanmakuParseDiagnostic = result.diagnostic
        currentDanmakuCues = result.cues
        let status: String
        if let failure = result.diagnostic.failureCategory {
            status = L10n.text("弹幕解析失败：{0}", ["\(failure.rawValue)"])
        } else if result.cues.isEmpty {
            status = L10n.text("弹幕解析为空")
        } else if result.diagnostic.truncatedCount > 0 {
            status = L10n.text("弹幕渲染限流：已加载 {0} 条，截断 {1} 条", ["\(result.cues.count)", "\(result.diagnostic.truncatedCount)"])
        } else {
            status = L10n.text("弹幕已加载 {0} 条", ["\(result.cues.count)"])
        }
        playerState.danmakuStatus = status
        lastDanmakuRenderStatus = status
    }

    func manualSearchDanmakuForCurrentPlayback() async {
        guard UserPreferences.shared.danmakuEnabled else {
            playerState.danmakuStatus = L10n.text("弹幕已关闭")
            return
        }
        guard isPlayerPresented, let spec = playerState.currentSpec else { return }
        let generation = playbackSessionState.generation
        let requestID = UUID()
        danmakuRequestID = requestID
        danmakuCandidates = []
        let sourceURL = (spec.danmaku.isEmpty ? (VodConfig.shared.config?.danmaku ?? "") : spec.danmaku)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceURL.isEmpty else {
            playerState.danmakuStatus = L10n.text("暂无弹幕源")
            return
        }
        let title = spec.metadata["vod.name"] ?? detailVod?.vodName ?? spec.title
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            playerState.danmakuStatus = L10n.text("缺少弹幕搜索标题")
            return
        }
        playerState.danmakuStatus = L10n.text("正在手动搜索弹幕...")
        let source = DanmakuSource(
            id: DanmakuEngine.sourceIdentity(sourceURL),
            name: L10n.text("配置弹幕源"),
            apiURL: sourceURL,
            enabled: true,
            parserType: .xml
        )
        let matches = await danmakuSearchOperation(
            DanmakuSearchRequest(title: title,
                episode: Self.danmakuEpisodeNumber(spec.metadata["vod.episodeName"] ?? ""),
                year: spec.metadata["vod.year"].flatMap(Int.init), siteKey: spec.siteKey,
                manualKeyword: [title, spec.metadata["vod.episodeName"] ?? ""].filter { !$0.isEmpty }.joined(separator: " ")),
            [source]
        )
        guard !Task.isCancelled, isPlayerPresented,
              UserPreferences.shared.danmakuEnabled,
              danmakuRequestID == requestID,
              playbackSessionState.generation == generation,
              let current = playerState.currentSpec,
              current.url == spec.url, current.siteKey == spec.siteKey,
              current.metadata["playback.sessionGeneration"] == spec.metadata["playback.sessionGeneration"] else { return }
        guard !matches.isEmpty else {
            playerState.danmakuStatus = L10n.text("未找到可用弹幕")
            return
        }
        danmakuCandidateOwner = (requestID, current.url, current.metadata["playback.sessionGeneration"])
        danmakuCandidates = Array(matches.prefix(24))
        playerState.danmakuStatus = L10n.text("请选择与当前季集或版本对应的弹幕。")
    }

    func selectDanmakuCandidate(_ match: DanmakuMatch) async {
        guard isPlayerPresented, UserPreferences.shared.danmakuEnabled,
              let owner = danmakuCandidateOwner, owner.id == danmakuRequestID,
              danmakuCandidates.contains(where: { $0.id == match.id }),
              let initial = playerState.currentSpec, initial.url == owner.url,
              initial.metadata["playback.sessionGeneration"] == owner.session else { return }
        let selectionID = UUID()
        danmakuRequestID = selectionID
        danmakuCandidateOwner = (selectionID, owner.url, owner.session)
        playerState.danmakuStatus = L10n.text("正在加载所选弹幕…")
        do { try await DanmakuEngine.shared.loadCandidate(match) }
        catch {
            if danmakuRequestID == selectionID { playerState.danmakuStatus = L10n.text("所选弹幕加载失败，请重试或选择其他候选。") }
            return
        }
        guard !Task.isCancelled, isPlayerPresented, danmakuRequestID == selectionID,
              UserPreferences.shared.danmakuEnabled,
              var current = playerState.currentSpec, current.url == owner.url,
              current.metadata["playback.sessionGeneration"] == owner.session else { return }
        current.danmakuAttachment = DanmakuAttachment(
            sourceID: match.track.sourceName,
            trackCacheKey: match.track.cacheKey,
            offsetMs: UserPreferences.shared.danmakuOffsetMs,
            style: DanmakuAttachmentStyle(
                opacity: UserPreferences.shared.danmakuOpacity,
                fontSize: UserPreferences.shared.danmakuFontSize
            )
        )
        playerState.currentSpec = current
        try? danmakuBindings.save(current.danmakuAttachment, for: current)
        cancelDanmakuSelection()
        refreshDanmakuOverlay(for: current)
    }

    func cancelDanmakuSelection() {
        danmakuRequestID = UUID()
        danmakuCandidateOwner = nil
        danmakuCandidates = []
    }

    func updateCurrentDanmakuOffset(_ milliseconds: Int) {
        guard var spec = playerState.currentSpec, var attachment = spec.danmakuAttachment else { return }
        attachment.offsetMs = min(60_000, max(-60_000, milliseconds))
        spec.danmakuAttachment = attachment
        playerState.currentSpec = spec
        try? danmakuBindings.save(attachment, for: spec)
    }

    func removeCurrentDanmakuBinding() {
        guard var spec = playerState.currentSpec else { return }
        try? danmakuBindings.save(nil, for: spec)
        spec.danmakuAttachment = nil
        playerState.currentSpec = spec
        cancelDanmakuSelection()
        refreshDanmakuOverlay(for: spec)
    }

    func importDanmakuForCurrentPlayback() async {
        guard isPlayerPresented, let spec = playerState.currentSpec else { return }
        let id = UUID()
        danmakuRequestID = id
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let match = try await Task.detached(priority: .userInitiated) { try DanmakuEngine.shared.importFile(url) }.value
            guard !Task.isCancelled, isPlayerPresented, danmakuRequestID == id,
                  let current = playerState.currentSpec, current.url == spec.url,
                  current.metadata["playback.sessionGeneration"] == spec.metadata["playback.sessionGeneration"] else { return }
            danmakuCandidateOwner = (id, current.url, current.metadata["playback.sessionGeneration"])
            danmakuCandidates = [match]
            await selectDanmakuCandidate(match)
        } catch {
            guard danmakuRequestID == id else { return }
            playerState.danmakuStatus = L10n.text("无法导入弹幕，请选择不超过 4 MB 的有效 XML 或 JSON 文件。")
        }
    }

    private static func danmakuEpisodeNumber(_ name: String) -> Int? {
        let pattern = #"(?i)(?:E|第)?(\d{1,4})(?:集|话)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return nil }
        return Int(name[range])
    }

    func playbackDiagnosticLines(for spec: PlaySpec) -> [String] {
        var lines: [String] = []
        func append(_ title: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                lines.append("\(title)：\(trimmed)")
            }
        }
        append(L10n.text("路线"), spec.metadata[DrivePlaybackMetadataKey.route])
        if let plan = spec.drivePlaybackPlan {
            append(L10n.text("候选线路"), plan.candidates.map(\.providerRoute).joined(separator: " → "))
        }
        append("Relay", spec.metadata["stream.relayMode"])
        append("WebHome", spec.metadata["webhome.method"] ?? lastWebHomeBridgeMethod)
        append(L10n.text("弹幕"), lastDanmakuRenderStatus ?? playerState.danmakuStatus)
        if let diagnostic = lastDanmakuParseDiagnostic {
            append(L10n.text("弹幕解析"), "format=\(diagnostic.format.rawValue) size=\(diagnostic.rawSizeBytes) parsed=\(diagnostic.parsedCount) returned=\(diagnostic.returnedCount) truncated=\(diagnostic.truncatedCount)")
        }
        let fixture = [
            spec.metadata["drive.fixtureProvider"],
            spec.metadata["drive.fixtureScenario"]
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " / ")
        append("Fixture", fixture.isEmpty ? lastDriveFixtureDiagnostic : fixture)
        append(L10n.text("样本状态"), spec.metadata[DrivePlaybackMetadataKey.fixtureStatus] ?? spec.metadata["drive.sampleStatus"])
        append(L10n.text("UC 选择原因"), spec.metadata[DrivePlaybackMetadataKey.selectedReason])
        append(L10n.text("UC 候选摘要"), spec.metadata[DrivePlaybackMetadataKey.candidateSummary])
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

    private func preparePlaybackStart(
        spec: inout PlaySpec,
        resumePosition: Int64?,
        resumeDuration: Int64?,
        episodeURL: String,
        openingSkipSeconds: Int
    ) {
        spec.initialStartPositionSeconds = nil
        if MPVInitialStartPolicy.supportsFileLocalStart(for: spec),
           let position = MPVInitialStartPolicy.positionMilliseconds(
                resumePosition: resumePosition,
                resumeDuration: resumeDuration,
                openingSkipSeconds: openingSkipSeconds
           ) {
            cancelPendingPlaybackStart()
            spec.initialStartPositionSeconds = Double(position) / 1_000
            log("[PLAYBACK_START_LOAD_OPTION] episode=\(episodeURL.hashValue) positionMs=\(position)")
            return
        }
        setPendingPlaybackStart(
            resumePosition: resumePosition,
            episodeURL: episodeURL,
            openingSkipSeconds: openingSkipSeconds
        )
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
            return L10n.text("频道“{0}”的播放线路处理失败。请重试或切换线路。", ["\(channelName)"])
        }
        if transport == LiveHLSRelayPolicy.localStreamRelayTransport {
            return L10n.text("频道“{0}”的播放线路处理失败。请重试或切换线路。", ["\(channelName)"])
        }
        if lower.contains("404") || lower.contains("not found") {
            return L10n.text("频道“{0}”的直播地址已失效。请刷新频道列表或切换线路。", ["\(channelName)"])
        }
        if lower.contains("403") || lower.contains("401") || lower.contains("expired") || lower.contains("signature") || lower.contains("鉴权") {
            return L10n.text("频道“{0}”的直播地址已过期。请刷新频道列表或切换线路。", ["\(channelName)"])
        }
        if lower.contains("502") || lower.contains("tls") || lower.contains("proxy") || lower.contains("io error") || lower.contains("connection reset") {
            return L10n.text("频道“{0}”连接失败。请检查网络和代理设置后重试。", ["\(channelName)"])
        }
        return L10n.text("频道“{0}”当前线路无法播放。请重试或切换线路。", ["\(channelName)"])
    }

    private func logLiveProbe(channel: Channel, urlIndex: Int, result: LiveProbeResult) {
        let source = activeLive?.name ?? "live"
        let compactPrefix = result.bodyPrefix
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        self.log("[LIVE_PROBE] source=\(source) channel=\(channel.name) urlIndex=\(urlIndex) status=\(result.statusCode) contentType=\(result.contentType) bodyPrefix=\(compactPrefix)")
    }

    private func normalizedLivePlaySpec(channel: Channel, url: String, logContext: String) async throws -> PlaySpec {
        if url.hasPrefix("xtr1.") {
            let reference = try XtreamResource(url)
            guard let account = userPreferences.xtreamConfigurations.first(where: { $0.id == reference.accountID }),
                  let provider = await SpiderReplacementRegistry.shared.nativeProvider(for: try account.site()) else { throw XtreamError.authorizationRequired }
            let result = try await provider.playerContent(site: account.site(), flag: "Xtream", id: url)
            return PlaySpec(url: result.url, format: result.format, metadata: ["xtream.resource": url], title: channel.name, flag: "Xtream", siteKey: account.url)
        }
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
            let parseConfig = VodConfig.shared.parses.first ?? Parse(name: L10n.text("默认嗅探"), type: 0)
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
        let selection = Self.restoredLiveSelection(
            groups: groups,
            savedGroupName: userPreferences.currentLiveGroupName,
            savedChannelName: userPreferences.currentLiveChannelName,
            savedURLIndex: userPreferences.currentLiveChannelUrlIndex
        )
        selectedGroup = selection.group
        selectedChannel = selection.channel
        currentChannelUrlIndex = selection.urlIndex
    }

    private func persistLiveSelection(channel: Channel, urlIndex: Int) {
        userPreferences.currentLiveName = activeLive?.name ?? ""
        userPreferences.currentLiveGroupName = selectedGroup?.name ?? ""
        userPreferences.currentLiveChannelName = channel.name
        userPreferences.currentLiveChannelUrlIndex = urlIndex
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
        guard let spec = playerState.currentSpec, spec.metadata["playback.kind"] != "live" else { return }
        guard let vod = detailVod ?? spec.metadata["vod.id"].map({ Vod(vodId: $0) }) else { return }
        let generation = spec.metadata["playback.sessionGeneration"].flatMap(UInt64.init)
            ?? playbackSessionState.generation
        
        let siteKey = spec.metadata["vod.siteKey"] ?? (vod.siteKey.isEmpty ? (activeSite?.key ?? "") : vod.siteKey)
        let vodID = spec.metadata["vod.id"] ?? vod.vodId
        let fingerprint = spec.metadata["library.sourceFingerprint"] ?? librarySourceFingerprint(siteKey: siteKey)
        let historyKey = PlaybackLinkage.vodKey(siteKey: siteKey, vodId: vodID, sourceFingerprint: fingerprint)
        guard canRecordHistory(key: historyKey, generation: generation) else { return }
        let episodeURL = spec.metadata["vod.episodeURL"] ?? spec.url
        let driveMetadata = drivePlaybackMetadata(for: spec, episodeURL: episodeURL)
        let history = History(
            key: historyKey,
            siteKey: siteKey,
            vodId: vodID,
            vodPic: spec.metadata["vod.pic"] ?? vod.vodPic,
            vodName: spec.metadata["vod.name"] ?? vod.vodName,
            vodFlag: spec.flag.isEmpty ? selectedPlayFlag : spec.flag,
            vodRemarks: spec.metadata["vod.remarks"] ?? vod.vodRemarks,
            episodeUrl: episodeURL,
            episodeName: spec.metadata["vod.episodeName"] ?? "",
            position: Int64(playerState.position * 1000),
            duration: Int64(playerState.duration * 1000),
            driveProvider: driveMetadata.provider,
            driveReferenceURL: driveMetadata.referenceURL,
            driveRoute: driveMetadata.route,
            configId: spec.metadata["library.configId"].flatMap(Int.init) ?? currentLibraryConfiguration?.id ?? 0,
            sourceFingerprint: fingerprint,
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
        let writer = historyWriter
        let ticket = writer.reserve()
        historySaveTask?.cancel()
        historySaveTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = try? writer.save(snapshot, ticket: ticket)
        }
    }

    private func canRecordHistory(key: String, generation: UInt64) -> Bool {
        if let cleared = historyClearedThroughGeneration, generation <= cleared { return false }
        if let deleted = historyDeletedThroughGeneration[key], generation <= deleted { return false }
        return true
    }

    func handleMPVPlaybackPosition(spec: PlaySpec?, positionSeconds: Double) {
        guard let spec, spec.metadata["playback.kind"] != "live" else { return }
        evaluateNextEpisodePreload(spec: spec, positionSeconds: positionSeconds)
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

    func evaluateNextEpisodePreload(spec: PlaySpec, positionSeconds: Double) {
        guard spec.metadata["playback.kind"] != "live" else { return }
        let context = playbackEpisodeContext()
        let skipSettings = VodSkipSettingsStore.shared.settings(for: spec.metadata)
        if let targetEpisode = context.nextEpisode {
            let safeEndingSkip = min(max(0, Double(skipSettings.endingSeconds)), playerState.duration)
            let transitionPoint = max(0, playerState.duration - safeEndingSkip)
            let leadSeconds = max(0, transitionPoint - positionSeconds)
            let bufferedAheadSeconds = max(0, playerState.bufferedUntil - positionSeconds)
            let thunderPreloadReady = ThunderNextEpisodeCache.shouldStartPreload(
                for: spec,
                positionSeconds: positionSeconds,
                bufferedUntilSeconds: playerState.bufferedUntil,
                isLoading: isPlayerLoading,
                isSeeking: playerState.isSeeking
            )
            let decision: PlaybackPreloadDecision = thunderPreloadReady
                ? .metadataAndMedia
                : PlaybackPreloadPolicy.decision(
                    positionSeconds: positionSeconds,
                    durationSeconds: playerState.duration,
                    bufferedUntilSeconds: playerState.bufferedUntil,
                    endingSkipSeconds: skipSettings.endingSeconds,
                    hasNextEpisode: true,
                    isLoading: isPlayerLoading,
                    isSeeking: playerState.isSeeking,
                    allowsEarlyMediaPreload: Self.supportsEarlyMediaPreload(spec)
                )
            let coversTransition = playerState.bufferedUntil
                >= transitionPoint - PlaybackPreloadPolicy.bufferedToleranceSeconds
            let trigger: String
            switch decision {
            case .metadataAndMedia:
                trigger = thunderPreloadReady
                    ? "thunder-full-file"
                    : (coversTransition ? "buffered-window" : "buffered-ahead-window")
            case .metadataOnly:
                trigger = leadSeconds > PlaybackPreloadPolicy.metadataFallbackWindowSeconds
                    ? "early-metadata-window"
                    : "fallback-window"
            case .none:
                trigger = "none"
            }
            if decision != .none {
                requestNextEpisodePreload(
                    targetEpisode: targetEpisode,
                    decision: decision,
                    trigger: trigger,
                    leadSeconds: leadSeconds,
                    bufferedAheadSeconds: bufferedAheadSeconds
                )
            }
        }
    }

    static func supportsEarlyMediaPreload(_ spec: PlaySpec) -> Bool {
        let profile = PlaybackTransferPolicy.profile(for: spec)
        return profile.context.isOriginal || [.smb, .webdav, .alist, .seekableResource].contains(profile.context.connection)
            || LiveHLSRelayPolicy.nextEpisodePreloadLayout(for: spec) != .standard
    }

    func toggleVodPlayback() async {
        guard !isPreparingVodPlayback else { return }
        if playerState.hasEnded {
            await replayCurrentEpisode()
        } else if playerState.isPlaying {
            MPVPlayerEngine.vod.pause()
        } else {
            MPVPlayerEngine.vod.resume()
        }
    }

    func replayCurrentEpisode() async {
        guard !isPreparingVodPlayback, isPlayerPresented,
              let spec = playerState.currentSpec, ownsPlaybackContext(spec),
              let episode = episodeForCurrentPlayback(in: episodes) else { return }
        clearPlaybackError()
        await playEpisode(episode, resumePosition: 0, restartFromBeginning: true)
    }

    private func ownsPlaybackContext(_ spec: PlaySpec) -> Bool {
        isPlayerPresented && spec.metadata["vod.siteKey"] == activeSite?.key
            && spec.metadata["vod.id"] == detailVod?.vodId
            && spec.flag == selectedPlayFlag
            && spec.metadata["playback.sessionGeneration"] == String(playbackSessionState.generation)
            && spec.metadata["playback.sourceFingerprint"] == playbackAuthorizationOrigin.sourceFingerprint
    }

    func handleMPVPlaybackEnded(spec: PlaySpec?) {
        guard let spec, spec.metadata["playback.kind"] != "live" else { return }
        requestAutoAdvance(for: spec, trigger: "natural-eof")
    }

    private func requestAutoAdvance(for spec: PlaySpec, trigger: String) {
        let episodeURL = PlaybackResumePolicy.episodeURL(for: spec)
        guard episodeListState == .ready, ownsPlaybackContext(spec),
              playerState.currentSpec?.metadata["playback.sessionGeneration"] == spec.metadata["playback.sessionGeneration"] else { return }
        let origin = playbackAuthorizationOrigin
        let context = playbackEpisodeContext()
        let transition = PlaybackSessionCore.requestAutoAdvance(
            playbackSessionState,
            episodeURL: episodeURL,
            context: context,
            isLoading: isPlayerLoading
        )
        playbackSessionState = transition.state
        guard let targetEpisode = transition.targetEpisode else { return }

        // Claim the UI transition before yielding to preloaded metadata resolution.
        let requestID = UUID()
        pendingAutoAdvanceID = requestID
        saveCurrentPlaybackProgress()
        log("[PLAYBACK_AUTO_ADVANCE] episode=\(episodeURL.hashValue) trigger=\(trigger) navigationCount=\(context.total) hasNext=\(context.hasNext) target=\(context.nextEpisode?.name ?? "")")
        Task { @MainActor in
            defer {
                if self.pendingAutoAdvanceID == requestID { self.pendingAutoAdvanceID = nil }
            }
            guard self.pendingAutoAdvanceID == requestID,
                  self.isPlayerPresented, self.playbackAuthorizationOrigin == origin else { return }
            await self.playEpisode(targetEpisode, automaticSelection: true, expectedPlaybackOrigin: origin)
        }
    }

    func attachSubtitleForCurrentPlayback(_ sub: Sub, slot: SubtitleSlot) {
        guard isPlayerPresented, var spec = playerState.currentSpec, spec.metadata["playback.kind"] != "live" else { return }
        if !spec.subs.contains(where: { $0.id == sub.id }) { spec.subs.append(sub) }
        playerState.currentSpec = spec
        MPVPlayerEngine.vod.loadExternalSubtitle(sub, select: true, slot: slot)
        saveTrackPreference(type: slot == .primary ? .subtitle : .secondarySubtitle,
                            id: "external:" + sub.id, name: sub.name, format: sub.format)
    }

    func saveTrackPreference(type: TrackType, id: String, name: String, format: String) {
        guard let spec = playerState.currentSpec else { return }
        let key = PlaybackLinkage.trackPreferenceKey(for: spec)
        trackItems.removeAll { $0.key == key && $0.type == type }
        let sub = spec.subs.first { "external:" + $0.id == id || ($0.name == name && $0.format == format) }
        let selectionID = sub.map { SubtitleMediaIdentity.externalIdentifier(for: $0) } ?? id
        trackItems.append(Track(key: key, type: type, selectionId: selectionID, name: name.isEmpty ? id : name, format: format, isSelected: true))
        try? storageManager.saveTracks(trackItems)
    }

    @discardableResult
    private func restoreTrackPreferences(for spec: PlaySpec) -> Bool {
        if let secondary = PlaybackLinkage.trackPreference(type: .secondarySubtitle, for: spec, in: trackItems) {
            restoreSubtitlePreference(secondary, slot: .secondary, spec: spec)
        }
        if let audio = PlaybackLinkage.trackPreference(type: .audio, for: spec, in: trackItems) {
            let id = audio.selectionId.isEmpty ? audio.name : audio.selectionId
            if !id.isEmpty {
                MPVPlayerEngine.vod.selectAudioTrack(id: id)
                log("[TRACK_RESTORE] audio id=\(id) name=\(audio.name)")
            }
        }

        guard let subtitle = PlaybackLinkage.trackPreference(type: .subtitle, for: spec, in: trackItems) else { return false }
        return restoreSubtitlePreference(subtitle, slot: .primary, spec: spec)
    }

    @discardableResult
    private func restoreSubtitlePreference(_ preference: Track, slot: SubtitleSlot, spec: PlaySpec) -> Bool {
        let id = preference.selectionId.isEmpty ? preference.name : preference.selectionId
        guard !id.isEmpty else { return false }
        if id == PlaybackLinkage.disabledSubtitleTrackID {
            MPVPlayerEngine.vod.selectSubtitleTrack(id: "no", slot: slot)
            return true
        }
        if id.hasPrefix("external:") || id.hasPrefix("external-name:") {
            guard let sub = spec.subs.first(where: {
                "external:" + $0.id == id || SubtitleMediaIdentity.externalIdentifier(for: $0) == id
            }) else { return false }
            MPVPlayerEngine.vod.loadExternalSubtitle(sub, select: true, slot: slot)
            return true
        }
        MPVPlayerEngine.vod.selectSubtitleTrack(id: id, slot: slot, matchingName: preference.name, matchingFormat: preference.format)
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
        let historyKey = PlaybackLinkage.vodKey(siteKey: siteKey, vodId: vod.vodId, sourceFingerprint: librarySourceFingerprint(siteKey: siteKey))
        guard canRecordHistory(key: historyKey, generation: playbackSessionState.generation) else { return }
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
            configId: currentLibraryConfiguration?.id ?? 0,
            sourceFingerprint: librarySourceFingerprint(siteKey: siteKey),
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
    func playHistory(_ original: History) async {
        guard let context = await prepareLibraryNavigation(configID: original.configId, fingerprint: original.sourceFingerprint, siteKey: original.siteKey) else { return }
        let item = original.sourceFingerprint.isEmpty
            ? LibraryIdentityMigration.bind(original, configuration: context.config, site: context.site) : original
        if item.key != original.key {
            var migrated = applicationLibraryState
            migrated.history.removeAll { $0.key == original.key || $0.key == item.key }
            migrated.history.insert(item, at: 0)
            guard persistMigratedLibrary(migrated) else { return }
        }
        let intent = ApplicationLibraryCore.historyPlaybackIntent(history: item, sites: sites)
        if let matchingSite = intent.site {
            activateSiteForLibraryNavigation(matchingSite)
        }

        await selectVod(intent.vod)

        guard detailVod?.vodId == item.vodId,
              (detailVod?.siteKey.isEmpty == true ? activeSite?.key : detailVod?.siteKey) == item.siteKey,
              item.sourceFingerprint == librarySourceFingerprint(siteKey: item.siteKey) else { return }

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

        let storedIdentity = PlaybackLinkage.vodIdentity(from: item.key)
        guard let context = await prepareLibraryNavigation(
            configID: item.configId, fingerprint: item.sourceFingerprint,
            siteKey: item.sourceFingerprint.isEmpty ? "" : storedIdentity.siteKey,
            legacyKey: item.sourceFingerprint.isEmpty ? item.key : nil
        ) else { return }
        let identity = item.sourceFingerprint.isEmpty
            ? LibrarySourceIdentity.legacyIdentity(key: item.key, sites: [context.site]).map { (siteKey: $0.siteKey, vodId: $0.vodID) } ?? storedIdentity
            : storedIdentity
        guard !identity.siteKey.isEmpty, !identity.vodId.isEmpty else { return }

        if item.sourceFingerprint.isEmpty {
            let bound = LibraryIdentityMigration.bind(item, vodID: identity.vodId, configuration: context.config, site: context.site)
            var migrated = applicationLibraryState
            migrated.keeps.removeAll { $0.type == .vod && ($0.key == item.key || $0.key == bound.key) }
            migrated.keeps.insert(bound, at: 0)
            guard persistMigratedLibrary(migrated) else { return }
        }

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
            try historyWriter.clear()
            applicationLibraryState = transition.state
            historyClearedThroughGeneration = playbackSessionState.generation
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
            try historyWriter.replace(with: transition.state.history)
            applicationLibraryState = transition.state
            historyDeletedThroughGeneration[item.key] = playbackSessionState.generation
        } catch {
            log("[APPLICATION_LIBRARY] 删除历史失败: \(error.localizedDescription)")
        }
    }

    /// 切换点播收藏状态
    func toggleKeep(vod: Vod) {
        let siteKey = vod.siteKey.isEmpty ? (activeSite?.key ?? "") : vod.siteKey
        let key = PlaybackLinkage.vodKey(siteKey: siteKey, vodId: vod.vodId, sourceFingerprint: librarySourceFingerprint(siteKey: siteKey))
        
        let history = PlaybackLinkage.history(for: vod, activeSiteKey: siteKey, items: historyItems, sourceFingerprint: librarySourceFingerprint(siteKey: siteKey))
        let keep = Keep(
            key: key,
            siteName: activeSite?.name ?? L10n.text("点播源"),
            vodName: vod.vodName,
            vodPic: vod.vodPic,
            vodRemarks: vod.vodRemarks,
            type: .vod,
            driveProvider: history?.driveProvider ?? "",
            driveReferenceURL: history?.driveReferenceURL ?? "",
            driveRoute: history?.driveRoute ?? "",
            configId: currentLibraryConfiguration?.id ?? 0,
            sourceFingerprint: librarySourceFingerprint(siteKey: siteKey)
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
        let key = PlaybackLinkage.vodKey(siteKey: activeSite?.key ?? "", vodId: vodId, sourceFingerprint: librarySourceFingerprint(siteKey: activeSite?.key ?? ""))
        return ApplicationLibraryCore.containsKeep(
            applicationLibraryState,
            key: key,
            type: .vod
        )
    }

    func currentDetailHistory() -> History? {
        guard let vod = detailVod else { return nil }
        return PlaybackLinkage.history(for: vod, activeSiteKey: activeSite?.key ?? "", items: historyItems, sourceFingerprint: librarySourceFingerprint(siteKey: vod.siteKey.isEmpty ? (activeSite?.key ?? "") : vod.siteKey))
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
        let key = PlaybackLinkage.vodKey(siteKey: siteKey, vodId: vod.vodId, sourceFingerprint: librarySourceFingerprint(siteKey: siteKey))
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
            liveError = L10n.text("收藏频道“{0}”已不在当前直播源中。请重新选择频道。", ["\(item.vodName)"])
            return
        }
        selectedGroup = match.group
        await playChannel(match.channel)
    }

    // MARK: - 搜索接口

    func resetSearchState() {
        activeSearchID = UUID()
        activeSearchTask?.cancel()
        activeSearchTask = nil
        activeSearchKey = nil
        searchSnapshotPublisher?.cancel()
        searchSnapshotPublisher = nil
        searchContinuationTasks.values.forEach { $0.cancel() }
        searchContinuationTasks = [:]
        contentSearchState = ContentSearchCore.reset(contentSearchState)
    }

    private var searchDataScope: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let searchSources = sites.filter { $0.key != Self.driveShareImportSiteKey }
        let sources = ((try? encoder.encode(searchSources)) ?? Data()).base64EncodedString()
        let runtimeVersions = providerRuntimeInstalled.map {
            $0.manifest.providerID + ":" + $0.manifest.version
        }.sorted()
        // The active site affects search priority, not source eligibility. Opening
        // another source's detail must preserve the search and its page cursors.
        let material = [searchSessionNamespace, libraryConfigurationURL, String(catalogCacheRevision),
            String(userPreferences.searchCredentialRevision), sources]
            + selectedSearchSiteKeys.sorted() + runtimeVersions
        let data = (try? JSONEncoder().encode(material)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The app owns the operation so replacing a view's waiter does not cancel an identical query.
    func search(keyword rawKeyword: String, forceRefresh: Bool = false) async {
        let keyword = rawKeyword.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !Task.isCancelled else { return }
        let scope = searchDataScope
        let key = keyword + "\u{0}" + scope
        if !forceRefresh, activeSearchKey == key, let task = activeSearchTask {
            await task.value
            return
        }
        resetSearchState()
        activeSearchKey = key
        let requestID = activeSearchID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeSearchID == requestID {
                    self.activeSearchTask = nil
                    self.activeSearchKey = nil
                }
            }
            await self.performSearch(keyword: keyword, scope: scope, forceRefresh: forceRefresh)
        }
        activeSearchTask = task
        await task.value
    }

    private func performSearch(keyword: String, scope: String, forceRefresh: Bool) async {
        let searchStartedAt = ContinuousClock.now
        var loggedFirstUsefulResult = false
        if let candidate = SourceManager.externalDriveCandidate(for: keyword) {
            contentSearchState = ContentSearchCore.resolved(contentSearchState, keyword: keyword,
                results: [driveShareImportResult(for: candidate)])
            selectedTab = .search
            return
        }
        contentSearchState = ContentSearchCore.begin(contentSearchState, keyword: keyword, sourceScope: scope)
        let generation = contentSearchState.generation
        var working = contentSearchState
        let publisher = SearchSnapshotPublisher { [weak self] snapshot in
            guard let self, self.contentSearchState.generation == generation,
                  self.searchDataScope == scope else { return }
            self.contentSearchState = snapshot
        }
        searchSnapshotPublisher = publisher
        defer {
            if contentSearchState.generation == generation, searchDataScope == scope, !Task.isCancelled {
                publisher.submit(ContentSearchCore.finish(working, generation: generation))
                publisher.flush()
                searchSnapshotPublisher = nil
            } else {
                publisher.cancel()
                if contentSearchState.generation == generation { resetSearchState() }
            }
        }
        let searchableSites = await searchSitesForCurrentPreference()
        guard !Task.isCancelled, contentSearchState.generation == generation, searchDataScope == scope else { return }
        working = ContentSearchCore.updateSiteOrder(working, generation: generation, siteOrder: searchableSites.map(\.key))
        let stream = searchEngine.search(keyword: keyword, sites: searchableSites,
            cacheScope: scope, bypassCache: forceRefresh)
        for await result in stream {
            guard !Task.isCancelled, contentSearchState.generation == generation, searchDataScope == scope else { return }
            if !result.isCached {
                recordSiteHealth(eventType: .search, siteKey: result.siteKey, siteName: result.siteName,
                    success: result.error == nil, durationMs: result.durationMs, errorCategory: result.errorCategory)
            }
            working = ContentSearchCore.ingest(working, generation: generation, result: result)
            publisher.submit(working)
            if !loggedFirstUsefulResult, !result.vods.isEmpty {
                loggedFirstUsefulResult = true
                DiagnosticLog.write("[SEARCH_FIRST_USEFUL_RESULT] durationMs=\(Self.durationMilliseconds(searchStartedAt.duration(to: .now))) site=\(result.siteKey)")
            }
        }
        if let summary = ContentSearchCore.summary(working, generation: generation), !Task.isCancelled {
            DiagnosticLog.write("[SEARCH_COMPLETE] durationMs=\(Self.durationMilliseconds(searchStartedAt.duration(to: .now))) totalResults=\(summary.totalResults) errorCount=\(summary.errorCount)")
        }
    }

    func loadMoreSearchResults(siteKey: String) {
        guard !contentSearchState.isLoading,
              contentSearchState.sourceScope == searchDataScope,
              let cursor = contentSearchState.cursors[siteKey], cursor.canRequest,
              let site = sites.first(where: { $0.key == siteKey }) else { return }
        let generation = contentSearchState.generation
        let scope = searchDataScope
        contentSearchState = ContentSearchCore.beginContinuation(contentSearchState, siteKey: siteKey)
        searchContinuationTasks[siteKey] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.contentSearchState = ContentSearchCore.cancelContinuation(self.contentSearchState, generation: generation, siteKey: siteKey)
                if self.contentSearchState.generation == generation { self.searchContinuationTasks[siteKey] = nil }
            }
            for await result in searchEngine.search(keyword: cursor.keyword, sites: [site], page: String(cursor.nextPage), cacheScope: scope, bypassCache: cursor.status == .retryable) {
                guard !Task.isCancelled, self.contentSearchState.generation == generation,
                      self.searchDataScope == scope else { return }
                self.contentSearchState = ContentSearchCore.receivePage(self.contentSearchState, generation: generation, requestedPage: cursor.nextPage, result: result)
                if !result.isCached {
                    self.recordSiteHealth(eventType: .search, siteKey: site.key, siteName: site.name,
                        success: result.error == nil, durationMs: result.durationMs, errorCategory: result.errorCategory)
                }
            }
        }
    }

    private func driveShareImportResult(for candidate: ExternalDriveCandidate) -> SearchResult {
        let providerName = Self.driveProviderDisplayName(candidate.provider)
        let isSupported = candidate.support.status == .supported
        let vod = Vod(
            vodId: candidate.canonicalURL,
            vodName: L10n.text("{0}分享", ["\(providerName)"]),
            vodPic: Self.driveProviderImage(candidate.provider),
            vodContent: candidate.support.reason,
            vodRemarks: isSupported ? providerName : L10n.text("待验证"),
            typeName: L10n.text("网盘分享"),
            siteKey: Self.driveShareImportSiteKey
        )
        return SearchResult(
            siteName: L10n.text("网盘分享"),
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
            name: L10n.text("网盘分享"),
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
        let name = safeEpisodeTitle(title.isEmpty ? L10n.text("不可用") : title)
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
        case "quark": return L10n.text("夸克网盘")
        case "uc": return L10n.text("UC网盘")
        case "ali": return L10n.text("阿里云盘")
        case "115", "p115": return L10n.text("115网盘")
        case "pikpak": return "PikPak"
        case "baidu": return L10n.text("百度网盘")
        case "cloud123": return L10n.text("123 网盘")
        case "xunlei", "thunder": return L10n.text("迅雷云盘")
        case "mobile": return L10n.text("中国移动云盘")
        case "tianyi": return L10n.text("天翼云盘")
        default: return L10n.text("网盘")
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
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let allLiveKeys: Set<String> = ["alllive", "alllive_huya", "alllive_douyu", "虎牙js", "斗鱼js"]
        return api.trimmingCharacters(in: .whitespacesAndNewlines) == "csp_AllliveGuard"
            || allLiveKeys.contains(normalizedKey)
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
        "原创", "新6V", "看球", "吃瓜", "alllive", "有声小说", "Aid",
        "YpanSo", "BpanSo", "抠搜", "UC", "cc"
    ]
}

extension AppState {
    var currentLibraryConfiguration: Config? {
        savedConfigs.first { $0.type == .vod && $0.url == libraryConfigurationURL }
    }

    func librarySourceFingerprint(siteKey: String) -> String {
        guard let site = sites.first(where: { $0.key == siteKey }) ?? (activeSite?.key == siteKey ? activeSite : nil) else { return "" }
        if site.api.hasPrefix("netvplayer-files://") { return LibrarySourceIdentity.fingerprint(configurationURL: site.api, site: site) }
        return LibrarySourceIdentity.fingerprint(configurationURL: libraryConfigurationURL, site: site)
    }

    private func migrateLibraryIdentityIfPossible() {
        guard let configuration = currentLibraryConfiguration else { return }
        let migrated = LibraryIdentityMigration.migrate(applicationLibraryState, configuration: configuration, sites: sites)
        let changed = migrated.history != historyItems || zip(migrated.keeps, keepItems).contains { $0.key != $1.key }
            || migrated.keeps.count != keepItems.count
        if changed { _ = persistMigratedLibrary(migrated) }
    }

    @discardableResult
    private func persistMigratedLibrary(_ migrated: ApplicationLibraryState) -> Bool {
        let previous = applicationLibraryState
        do {
            try historyWriter.performReplacement {
                do {
                    try applicationLibraryPersistence.saveKeeps(migrated.keeps)
                    try applicationLibraryPersistence.saveHistory(migrated.history)
                } catch {
                    try? applicationLibraryPersistence.saveKeeps(previous.keeps)
                    try? applicationLibraryPersistence.saveHistory(previous.history)
                    throw error
                }
            }
            applicationLibraryState = migrated
            return true
        } catch {
            log("[APPLICATION_LIBRARY] identity migration failed: \(error.localizedDescription)")
            return false
        }
    }

    private func prepareLibraryNavigation(configID: Int, fingerprint: String, siteKey: String, legacyKey: String? = nil) async -> (site: Site, config: Config)? {
        if siteKey.hasPrefix("files-") {
            reloadFileServiceSites()
            guard let site = sites.first(where: { $0.key == siteKey }),
                  fingerprint.isEmpty || fingerprint == librarySourceFingerprint(siteKey: siteKey) else {
                _ = await AppDialogCenter.shared.present(
                    title: L10n.text("文件来源不可用"),
                    message: L10n.text("历史和收藏已保留，请在设置中恢复原来的文件服务。"),
                    confirmTitle: L10n.text("知道了"), allowsCancel: false
                )
                return nil
            }
            return (site, Config.vod(url: site.api))
        }
        let configurations = savedConfigs.filter { $0.type == .vod }
        var configuration = configurations.first { $0.id == configID && configID > 0 }
        if configuration == nil, fingerprint.isEmpty {
            if configurations.count == 1 {
                configuration = configurations.first
            } else if configurations.count > 1 {
                guard let selection = await AppDialogCenter.shared.present(
                    title: L10n.text("请选择这条记录的原始配置"),
                    message: L10n.text("旧记录没有保存来源。选择后将绑定到该配置，避免跨源续播。"),
                    confirmTitle: L10n.text("打开"),
                    choices: configurations.map { $0.name.isEmpty ? L10n.text("点播配置") + " #\($0.id)" : $0.name }
                ) else { return nil }
                configuration = configurations[selection]
            }
        }
        if let configuration, configuration.url != libraryConfigurationURL {
            await loadConfig(url: configuration.url, persistUserConfig: false)
            guard libraryConfigurationURL == configuration.url, isConfigLoaded else { return nil }
        }
        let resolvedKey = legacyKey.flatMap { LibrarySourceIdentity.legacyIdentity(key: $0, sites: sites)?.siteKey } ?? siteKey
        guard let site = sites.first(where: { $0.key == resolvedKey }),
              fingerprint.isEmpty || fingerprint == librarySourceFingerprint(siteKey: resolvedKey) else {
            _ = await AppDialogCenter.shared.present(
                title: L10n.text("记录的原始来源已不可用"),
                message: L10n.text("请恢复原始配置，或在当前来源重新选择影片。"),
                confirmTitle: L10n.text("知道了"), allowsCancel: false
            )
            return nil
        }
        return (site, configuration ?? currentLibraryConfiguration ?? Config.vod(url: libraryConfigurationURL))
    }
}
