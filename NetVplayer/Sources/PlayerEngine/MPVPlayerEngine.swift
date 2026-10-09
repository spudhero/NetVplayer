// PlayerEngine/MPVPlayerEngine.swift
// 内嵌 libmpv 播放引擎，主要用于网盘大文件点播。

import AppKit
import CryptoKit
import Darwin
import DriveEngine
import Foundation
import Models
import MPVShim
import ProxyServer
import Storage

private let mpvRenderUpdateCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
    guard let pointer else { return }
    let engine = Unmanaged<MPVPlayerEngine>.fromOpaque(pointer).takeUnretainedValue()
    engine.requestRender()
}

public enum MPVVideoSurface: String, Sendable {
    case vod
    case live
}

public enum MPVStopResourcePolicy: String, Sendable {
    case warmStop = "warm-stop"
    case fullDestroy = "full-destroy"

    static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        guard let value = environment["NETVPLAYER_MPV_STOP_RESOURCE_POLICY"]?.lowercased() else {
            return .fullDestroy
        }
        return Self(rawValue: value) ?? .fullDestroy
    }
}

struct MPVLifecycleBenchmarkSample: Codable, Sendable {
    let policy: String
    let round: Int
    let firstFrameMilliseconds: Double?
    let stopMilliseconds: Double
    let rebuildMilliseconds: Double
    let rssAfterStopBytes: UInt64
    let rssAfterSixtySecondsBytes: UInt64?
}

struct MPVLifecycleBenchmarkReport: Codable, Sendable {
    let mediaPath: String
    let rounds: Int
    let samples: [MPVLifecycleBenchmarkSample]
}

public struct MPVVideoSurfaceAttachmentLease: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var isActive = false

    public init() {}

    public mutating func activate() -> UInt64 {
        generation &+= 1
        isActive = true
        return generation
    }

    public mutating func deactivate() {
        generation &+= 1
        isActive = false
    }

    public func accepts(generation: UInt64) -> Bool {
        isActive && self.generation == generation
    }
}

struct MPVRenderRequestGate: Sendable {
    private(set) var isScheduled = false
    private(set) var hasPendingRequest = false
    private(set) var isSuspended = false

    mutating func request() -> Bool {
        guard !isSuspended, !isScheduled else {
            hasPendingRequest = true
            return false
        }
        isScheduled = true
        return true
    }

    mutating func prepareForDisplay() -> Bool {
        guard isScheduled else { return false }
        guard !isSuspended else {
            isScheduled = false
            hasPendingRequest = true
            return false
        }
        return true
    }

    mutating func completeDisplay() -> Bool {
        guard isScheduled else { return false }
        isScheduled = false
        guard hasPendingRequest, !isSuspended else { return false }
        hasPendingRequest = false
        isScheduled = true
        return true
    }

    mutating func setSuspended(_ suspended: Bool) -> Bool {
        isSuspended = suspended
        guard !suspended, hasPendingRequest, !isScheduled else { return false }
        hasPendingRequest = false
        isScheduled = true
        return true
    }

    mutating func reset() {
        isScheduled = false
        hasPendingRequest = false
        isSuspended = false
    }
}

enum MPVPlaybackActivityPolicy {
    static let playbackRestartEventID: Int32 = 21
    static let propertyChangeEventID: Int32 = 22
    static let firstProgressThreshold = 0.05
    static let defaultCacheStallThreshold: TimeInterval = 8
    static let drivePlaybackCacheStallThreshold: TimeInterval = 20

    static func shouldEndMediaLoading(eventID: Int32, positionSeconds: Double? = nil) -> Bool {
        guard eventID == propertyChangeEventID,
              let positionSeconds,
              positionSeconds.isFinite else {
            return false
        }
        return positionSeconds > firstProgressThreshold
    }

    static func shouldAcceptTimePosition(isCurrentFileLoaded: Bool) -> Bool {
        isCurrentFileLoaded
    }

    static func normalizedCacheSpeed(_ value: Int64, hasValue: Bool) -> Int64? {
        guard hasValue, value > 0 else { return nil }
        return value
    }

    static func normalizedCacheBufferingProgress(_ value: Int64, hasValue: Bool) -> Double? {
        guard hasValue, value >= 0 else { return nil }
        return min(1, Double(value) / 100)
    }

    static func shouldExposeBuffering(isPausedForCache: Bool, pauseRequested: Bool) -> Bool {
        isPausedForCache && !pauseRequested
    }

    static func cacheStallThreshold(for spec: PlaySpec?) -> TimeInterval {
        guard let spec, spec.drivePlaybackPlan != nil else {
            return defaultCacheStallThreshold
        }
        if DrivePlaybackRoutePolicy.candidate(for: spec)?.kind == .original,
           DrivePlaybackFallbackPolicy.fallbackSpec(for: spec, positionSeconds: 0) != nil {
            return defaultCacheStallThreshold
        }
        return drivePlaybackCacheStallThreshold
    }
}

/// Repeated short stalls can make an original stream unusable without ever
/// reaching the continuous-stall deadline. Count only normal playback stalls.
struct DrivePlaybackStallWindow {
    private var recovered: [(at: TimeInterval, duration: TimeInterval)] = []

    mutating func record(duration: TimeInterval, at now: TimeInterval) {
        prune(at: now)
        guard duration.isFinite, duration >= 1 else { return }
        recovered.append((now, min(duration, 20)))
    }

    mutating func threshold(for spec: PlaySpec?, at now: TimeInterval) -> TimeInterval {
        prune(at: now)
        let normal = MPVPlaybackActivityPolicy.cacheStallThreshold(for: spec)
        guard let spec,
              DrivePlaybackRoutePolicy.candidate(for: spec)?.kind == .original,
              DrivePlaybackFallbackPolicy.fallbackSpec(for: spec, positionSeconds: 0) != nil,
              recovered.count >= 2 else { return normal }
        return max(1, min(normal, 12 - recovered.reduce(0) { $0 + $1.duration }))
    }

    private mutating func prune(at now: TimeInterval) {
        recovered.removeAll { now - $0.at > 45 || $0.at > now }
    }
}

enum MPVSeekModePolicy {
    static let precise = "absolute+exact"
    static let streaming = "absolute+keyframes"

    static func commandMode(for spec: PlaySpec?, targetSeconds: Double? = nil, durationSeconds: Double? = nil) -> String {
        if let targetSeconds, let durationSeconds,
           targetSeconds.isFinite, durationSeconds.isFinite, durationSeconds > 0,
           targetSeconds >= durationSeconds { return precise }
        guard let spec else { return precise }
        if DrivePlaybackRoutePolicy.candidate(for: spec)?.transport == .hlsRelay {
            return streaming
        }
        switch spec.metadata[DrivePlaybackMetadataKey.route] {
        case DrivePlaybackRoute.personalTranscode, DrivePlaybackRoute.ucSmartPlay:
            return streaming
        default:
            return precise
        }
    }

    static func shouldShowLoading(pauseRequested: Bool) -> Bool {
        !pauseRequested
    }
}

public enum MPVInitialStartPolicy {
    public static func supportsFileLocalStart(for spec: PlaySpec) -> Bool {
        spec.metadata["playback.kind"] != "live"
    }

    public static func positionMilliseconds(
        resumePosition: Int64?,
        resumeDuration: Int64?,
        openingSkipSeconds: Int
    ) -> Int64? {
        let normalizedResume = resumePosition.flatMap { $0 > 0 ? $0 : nil }
        if let resumeDuration, resumeDuration > 0 {
            return PlaybackStartPolicy.normalizedStartPositionMilliseconds(
                resumePosition: normalizedResume,
                openingSkipSeconds: openingSkipSeconds,
                durationSeconds: Double(resumeDuration) / 1_000
            )
        }
        guard normalizedResume == nil, openingSkipSeconds > 0 else { return nil }
        let (milliseconds, overflow) = Int64(openingSkipSeconds).multipliedReportingOverflow(by: 1_000)
        return overflow ? nil : milliseconds
    }

    static func loadFileOptions(for spec: PlaySpec) -> String? {
        guard let start = spec.initialStartPositionSeconds,
              start.isFinite,
              start > 0 else { return nil }
        return "start=\(start)"
    }

    static func recoverySpec(
        for spec: PlaySpec,
        durationSeconds: Double,
        isCurrentFileLoaded: Bool,
        playbackStarted: Bool,
        reachedEOF: Bool
    ) -> PlaySpec? {
        guard supportsFileLocalStart(for: spec), !playbackStarted,
              isCurrentFileLoaded || reachedEOF,
              let start = spec.initialStartPositionSeconds,
              start.isFinite, start > 0 else { return nil }
        let startIsPastEnd = durationSeconds.isFinite && durationSeconds > 0
            && (start >= Double(Int64.max) / 1_000
                || PlaybackResumePolicy.normalizedRestorePositionMilliseconds(
                    position: Int64(start * 1_000),
                    durationSeconds: durationSeconds
                ) == nil)
        guard startIsPastEnd || reachedEOF else { return nil }
        var recovered = spec
        // Removing the file-local start bounds recovery to one load, even if the file is empty.
        recovered.initialStartPositionSeconds = nil
        return recovered
    }
}

final class PlaybackDisplaySleepController: @unchecked Sendable {
    typealias ActivityToken = NSObjectProtocol

    static let activityOptions: ProcessInfo.ActivityOptions = [
        .idleDisplaySleepDisabled,
        .idleSystemSleepDisabled,
        .userInitiated,
    ]

    private let lock = NSLock()
    private let beginActivity: () -> ActivityToken
    private let endActivity: (ActivityToken) -> Void
    private var activityToken: ActivityToken?

    convenience init(processInfo: ProcessInfo = .processInfo) {
        self.init(
            beginActivity: {
                processInfo.beginActivity(
                    options: Self.activityOptions,
                    reason: L10n.text("NetVplayer 正在播放视频")
                )
            },
            endActivity: { processInfo.endActivity($0) }
        )
    }

    init(
        beginActivity: @escaping () -> ActivityToken,
        endActivity: @escaping (ActivityToken) -> Void
    ) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    @discardableResult
    func setPlaybackActive(_ isActive: Bool) -> Bool {
        if isActive {
            lock.lock()
            defer { lock.unlock() }
            guard activityToken == nil else { return false }
            activityToken = beginActivity()
            return true
        }

        lock.lock()
        let token = activityToken
        activityToken = nil
        lock.unlock()
        guard let token else { return false }
        endActivity(token)
        return true
    }

    deinit {
        setPlaybackActive(false)
    }
}

struct MPVPlaybackLoadEventTracker {
    private(set) var hasActiveLoad = false
    private(set) var expectsReplacedEndFile = false
    private(set) var awaitsLoadStart = false

    mutating func prepareForLoad() {
        expectsReplacedEndFile = hasActiveLoad
        awaitsLoadStart = true
    }

    mutating func markLoadIssued() {
        hasActiveLoad = true
    }

    mutating func cancelPreparedLoad() {
        expectsReplacedEndFile = false
        awaitsLoadStart = false
    }

    mutating func markFileStarted() {
        awaitsLoadStart = false
        expectsReplacedEndFile = false
    }

    func shouldIgnorePriorLoadEvent(_ eventID: Int32) -> Bool {
        // Native events still belong to the retired stream until START_FILE.
        // Command replies remain eligible so a rejected new load still fails.
        awaitsLoadStart && [2, 7, 8, 20, 21, 22].contains(eventID)
    }

    mutating func markFileLoaded() {
        expectsReplacedEndFile = false
        awaitsLoadStart = false
    }

    mutating func consumeEndFile() -> Bool {
        if expectsReplacedEndFile {
            expectsReplacedEndFile = false
            return true
        }
        hasActiveLoad = false
        return false
    }

    mutating func reset() {
        hasActiveLoad = false
        expectsReplacedEndFile = false
        awaitsLoadStart = false
    }
}

public final class MPVPlayerEngine: @unchecked Sendable {
    public static let vod = MPVPlayerEngine(videoSurface: .vod)
    public static let live = MPVPlayerEngine(videoSurface: .live)

    static let initializationOptions: [(name: String, value: String)] = [
        ("terminal", "no"),
        ("msg-level", "all=info"),
        ("idle", "yes"),
        ("keep-open", "no"),
        ("osc", "no"),
        ("ytdl", "no"),
        ("input-default-bindings", "no"),
        ("input-vo-keyboard", "no"),
        ("hwdec", "videotoolbox-copy"),
        ("vo", "libmpv"),
        // mpv 0.41 can retain a CoreAudio hotplug callback when floatp initialization fails.
        ("audio-format", "float"),
    ]

    /// Compatibility alias for call sites that have not yet declared a playback kind.
    public static var shared: MPVPlayerEngine { vod }

    public let videoSurface: MPVVideoSurface
    public let stopResourcePolicy: MPVStopResourcePolicy

    public var playerState: PlayerState? {
        didSet { publishAudioPreference() }
    }
    public var playbackFailureHandler: ((PlaySpec?, String) -> Void)?
    public var playbackFailureDetailsHandler: ((PlaySpec?, MPVPlaybackFailure) -> Void)?
    public var playbackStartedHandler: ((PlaySpec?) -> Void)?
    public var playbackPositionHandler: ((PlaySpec?, Double) -> Void)?
    public var playbackEndedHandler: ((PlaySpec?) -> Void)?
    public var playbackStallHandler: ((PlaySpec?, Double) -> Void)?
    public var playbackStallRecoveryHandler: ((PlaySpec?) -> Void)?
    public var liveConnectionRepairHandler: ((PlaySpec?) -> Void)?
    public var artworkLoader: (@Sendable (PlaySpec) async throws -> Data)?
    public var subtitleSettingsProvider: @Sendable () -> SubtitleRenderSettings = { SubtitleRenderSettings() }
    private var pendingSubtitleMatches: [SubtitleSlot: (name: String, format: String)] = [:]
    private var pendingSubtitleSelections: [SubtitleSlot: String] = [:]
    private var preparedSubtitleSources: [String: String] = [:]
    public var secondarySubtitleDelayProvider: @Sendable (PlaySpec) -> Double = { _ in 0 }
    private var currentSubtitleFormat: SubtitleTrackFormat = .text
    public var subtitleDelayProvider: @Sendable (PlaySpec) -> Double = { _ in 0 }

    public private(set) var status: PlayerStatus = .idle

    private let lock = NSLock()
    private let contextCreationLock = NSLock()
    private var context: OpaquePointer?
    private var eventTask: Task<Void, Never>?
    private var renderRetirementTask: Task<Void, Never>?
    private var attachedViewID: Int64?
    private weak var renderView: MPVOpenGLVideoView?
    private var pendingSpec: PlaySpec?
    private var activeSpec: PlaySpec?
    private var currentSpeed: Float = 1.0
    private let audioPreferences: PlaybackAudioPreferenceStore
    private var audioPreferenceObserver: NSObjectProtocol?
    private var currentVideoAspectMode: PlayerVideoAspectMode = .fit
    private var lastPositionMs: Int64 = 0
    private var lastDurationMs: Int64 = 0
    private var lastLoadDiagnostic: String?
    private var lastHTTPFailureStatus: Int?
    private var playbackFailureNotified = false
    private var playbackStartedNotified = false
    private var currentFileLoaded = false
    private var loadEventTracker = MPVPlaybackLoadEventTracker()
    private var pauseRequested = false
    private var isPausedForCache = false
    private var postSeekEndGuard = PlaybackPostSeekEndGuard()
    private var seekActivity = PlaybackSeekActivity()
    private var cacheStallStart: Date?
    private var cacheStallTimeoutInterval: TimeInterval?
    private var cacheStallTask: Task<Void, Never>?
    private var cacheStallNotified = false
    private var liveStallWindow = LivePlaybackStallWindow()
    private var driveStallWindow = DrivePlaybackStallWindow()
    private var liveReuseFailureObserved = false
    private var liveConnectionRepairRequested = false
    private var cacheStallEligible = false
    private let backgroundBudgetSession = UUID().uuidString
    private var startupWatchdogTask: Task<Void, Never>?
    @MainActor private var seekTransferTask: Task<Void, Never>?
    private var renderRequestGate = MPVRenderRequestGate()
    private var pendingExternalAudioURL: String?
    private var mediaOptionDefaults: [String: String] = [:]
    private var temporarySubtitleFiles: [URL] = []
    private var artworkTask: Task<Void, Never>?
    private var temporaryArtworkFiles: [URL] = []
    private let displaySleepController: PlaybackDisplaySleepController
    private static let defaultLocalStreamStartupTimeout: TimeInterval = 60
    private static let loadFileReplyUserdata: UInt64 = 1
    private static let firstSubtitleReplyUserdata: UInt64 = 2
    private static let externalAudioReplyUserdata: UInt64 = 10_000
    private static let artworkReplyUserdata: UInt64 = 10_001
    private static let audioMuteReplyUserdata: UInt64 = 10_002
    private static let audioVolumeReplyUserdata: UInt64 = 10_003
    private static let propertyReplyEventID: Int32 = 4
    private static let commandReplyEventID: Int32 = 5

    enum EndFileReason: Int32 {
        case eof = 0
        case restarted = 1
        case stopped = 2
        case quit = 3
        case error = 4
        case redirect = 5
    }

    public var position: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return lastPositionMs
    }

    public var speed: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return currentSpeed
        }
        set {
            lock.lock()
            currentSpeed = newValue
            let activeContext = context
            lock.unlock()

            if let activeContext {
                nv_mpv_set_property_double(activeContext, "speed", Double(newValue))
            }
            Task { @MainActor in
                self.playerState?.speed = newValue
            }
        }
    }

    init(
        videoSurface: MPVVideoSurface,
        stopResourcePolicy: MPVStopResourcePolicy = .configured(),
        displaySleepController: PlaybackDisplaySleepController = PlaybackDisplaySleepController(),
        audioPreferences: PlaybackAudioPreferenceStore = .shared
    ) {
        self.videoSurface = videoSurface
        self.stopResourcePolicy = stopResourcePolicy
        self.displaySleepController = displaySleepController
        self.audioPreferences = audioPreferences
        self.audioPreferenceObserver = NotificationCenter.default.addObserver(
            forName: PlaybackAudioPreferenceStore.didChange, object: audioPreferences, queue: nil
        ) { [weak self] _ in self?.applyAudioPreference() }
    }

    deinit {
        displaySleepController.setPlaybackActive(false)
        if let audioPreferenceObserver { NotificationCenter.default.removeObserver(audioPreferenceObserver) }
        eventTask?.cancel()
        startupWatchdogTask?.cancel()
        artworkTask?.cancel()
        Self.removeTemporarySubtitleFiles(temporarySubtitleFiles)
        Self.removeTemporarySubtitleFiles(temporaryArtworkFiles)
        if let context {
            nv_mpv_destroy(context)
        }
    }

    static func acceptsVideoSurfaceAttachment(
        activeSurface: MPVVideoSurface,
        requestedSurface: MPVVideoSurface
    ) -> Bool {
        activeSurface == requestedSurface
    }

    static func acceptsVideoViewRender(activeViewID: Int64?, requestedViewID: Int64) -> Bool {
        activeViewID == requestedViewID
    }

    static func videoSurface(for spec: PlaySpec) -> MPVVideoSurface {
        spec.metadata["playback.kind"] == "live" ? .live : .vod
    }

    @MainActor
    public func attach(to view: MPVOpenGLVideoView, surface: MPVVideoSurface) {
        let viewID = Self.viewID(for: view)
        let accepted = withLock { () -> Bool in
            guard Self.acceptsVideoSurfaceAttachment(
                activeSurface: videoSurface,
                requestedSurface: surface
            ) else {
                return false
            }
            attachedViewID = viewID
            renderView = view
            return true
        }
        guard accepted else {
            DiagnosticLog.write(
                "[MPV_ATTACH_IGNORED] requested=\(surface.rawValue), engine=\(videoSurface.rawValue)"
            )
            return
        }

        do {
            view.makeOpenGLContextCurrent()
            try ensureContext()
            try ensureRenderContext()
            view.requestOpenGLDisplay()
            let pendingSpec = withLock { () -> PlaySpec? in
                guard attachedViewID == viewID, videoSurface == surface else { return nil }
                defer { self.pendingSpec = nil }
                return self.pendingSpec
            }
            if let pendingSpec {
                Task {
                    await self.play(spec: pendingSpec)
                }
            }
        } catch {
            setError(L10n.text("libmpv 初始化失败: {0}", ["\(error.localizedDescription)"]))
        }
    }

    @MainActor
    public func reportUnavailableVideoSurface(_ surface: MPVVideoSurface) {
        guard videoSurface == surface else { return }
        DiagnosticLog.write("[MPV_SURFACE_UNAVAILABLE] surface=\(surface.rawValue)")
        setError(L10n.text("暂时无法创建视频画面，请重试播放。"))
    }

    @MainActor
    public func detach(from view: MPVOpenGLVideoView) {
        let viewID = Self.viewID(for: view)
        lock.lock()
        if attachedViewID == viewID {
            attachedViewID = nil
            renderView = nil
            renderRequestGate.reset()
        }
        lock.unlock()
    }

    @MainActor
    public func detachAndReleaseOpenGLResources(from view: MPVOpenGLVideoView) async {
        let viewID = Self.viewID(for: view)
        detach(from: view)
        let retirement = withLock { () -> (Task<Void, Never>?, Bool) in
            (renderRetirementTask, context == nil)
        }
        guard retirement.1 else { return }
        await retirement.0?.value
        let canRelease = withLock {
            context == nil && attachedViewID != viewID
        }
        guard canRelease, !view.isPlaybackSurfaceActive else { return }
        view.releaseOpenGLResources()
    }

    @MainActor
    public func setRenderSuspended(_ suspended: Bool, for view: MPVOpenGLVideoView) {
        let viewID = Self.viewID(for: view)
        let shouldSchedule = withLock { () -> Bool in
            guard attachedViewID == viewID else { return false }
            return renderRequestGate.setSuspended(suspended)
        }
        if shouldSchedule {
            scheduleRenderDisplay()
        }
    }

    @MainActor
    public func render(in view: MPVOpenGLVideoView) {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return }

        let viewID = Self.viewID(for: view)
        let renderState = withLock { (context, attachedViewID) }
        guard Self.acceptsVideoViewRender(
            activeViewID: renderState.1,
            requestedViewID: viewID
        ) else {
            return
        }
        let activeContext = renderState.0
        guard let activeContext else { return }

        view.makeOpenGLContextCurrent()
        view.updateOpenGLContext()
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let width = max(1, Int((view.bounds.width * scale).rounded(.toNearestOrAwayFromZero)))
        let height = max(1, Int((view.bounds.height * scale).rounded(.toNearestOrAwayFromZero)))
        nv_mpv_render(activeContext, 0, Int32(width), Int32(height), 1)
        view.flushOpenGLBuffer()
        nv_mpv_report_swap(activeContext)
    }

    public func play(spec: PlaySpec) async {
        let requestedSurface = Self.videoSurface(for: spec)
        guard withLock({
            Self.acceptsVideoSurfaceAttachment(
                activeSurface: videoSurface,
                requestedSurface: requestedSurface
            )
        }) else {
            DiagnosticLog.write("[MPV_PLAY_IGNORED] inactiveSurface=\(requestedSurface.rawValue)")
            return
        }
        DiagnosticLog.write("[MPV_PLAY] url=\(Self.redactedURL(spec.url)), headers=\(Self.redactedHeaders(spec.headers)), mpvOptionNames=\(spec.mpvOptions.keys.filter { MPVOptionPolicy.accepts(name: $0, value: "") }.sorted()), title=\(spec.title)")

        let aspectMode = withLock { currentVideoAspectMode }
        let didPrepareState = await MainActor.run { () -> Bool in
            guard self.withLock({
                Self.acceptsVideoSurfaceAttachment(
                    activeSurface: self.videoSurface,
                    requestedSurface: requestedSurface
                )
            }) else { return false }
            self.withLock { self.loadEventTracker.prepareForLoad() }
            playerState?.currentSpec = spec
            playerState?.endDisposition = nil
            cancelSeekTransferMetrics()
            playerState?.errorMessage = nil
            playerState?.mpvOptionDiagnostics = []
            playerState?.chapters = []
            playerState?.chapterOwnerID = nil
            playerState?.containerEditions = []
            playerState?.currentContainerEditionID = nil
            playerState?.isPlaying = false
            playerState?.position = 0
            playerState?.duration = 0
            playerState?.bufferedUntil = 0
            playerState?.isMediaLoading = true
            playerState?.isSeeking = false
            playerState?.isBuffering = false
            playerState?.cacheSpeedBytesPerSecond = nil
            playerState?.cacheBufferingProgress = nil
            playerState?.videoAspectMode = aspectMode
            playerState?.audioTracks = []
            playerState?.subtitleTracks = Self.subtitleTracks(from: spec.subs)
            playerState?.selectedAudioTrackID = nil
            playerState?.selectedSubtitleTrackID = nil
            playerState?.selectedSecondarySubtitleTrackID = nil
            playerState?.secondarySubtitleDelaySeconds = SubtitleMediaIdentity.normalizedDelay(self.secondarySubtitleDelayProvider(spec))
            playerState?.subtitleDelaySeconds = SubtitleMediaIdentity.normalizedDelay(self.subtitleDelayProvider(spec))
            playerState?.subtitleStatus = spec.subs.isEmpty ? nil : L10n.text("发现 {0} 条外挂字幕", ["\(spec.subs.count)"])
            playerState?.drivePlaybackStatus = DrivePlaybackDisplayPolicy.statusText(for: spec)
            playerState?.drmStatus = Self.drmStatus(for: spec.drm)
            if spec.danmakuAttachment != nil {
                playerState?.danmakuStatus = L10n.text("弹幕缓存已附加")
            } else {
                playerState?.danmakuStatus = spec.danmaku.isEmpty ? nil : L10n.text("弹幕源已识别，等待手动搜索")
            }
            return true
        }
        guard didPrepareState else { return }
        let didResetPlaybackState = withLock { () -> Bool in
            guard Self.acceptsVideoSurfaceAttachment(
                activeSurface: videoSurface,
                requestedSurface: requestedSurface
            ) else { return false }
            activeSpec = spec
            artworkTask?.cancel()
            artworkTask = nil
            currentSubtitleFormat = .text
            pendingSubtitleSelections.removeAll()
            pendingSubtitleMatches.removeAll()
            preparedSubtitleSources.removeAll()
            lastPositionMs = 0
            lastDurationMs = 0
            lastLoadDiagnostic = nil
            lastHTTPFailureStatus = nil
            playbackFailureNotified = false
            playbackStartedNotified = false
            currentFileLoaded = false
            pauseRequested = false
            isPausedForCache = false
            postSeekEndGuard.reset()
            seekActivity.resetMedia()
            if let start = spec.initialStartPositionSeconds,
               start.isFinite,
               start > 0 {
                postSeekEndGuard.begin(targetSeconds: start)
            }
            startupWatchdogTask?.cancel()
            startupWatchdogTask = nil
            cacheStallStart = nil
            cacheStallTask?.cancel()
            cacheStallTask = nil
            cacheStallNotified = false
            return true
        }
        guard didResetPlaybackState else { return }

        do {
            let didLoad = try await MainActor.run { () throws -> Bool in
                guard self.withLock({
                    Self.acceptsVideoSurfaceAttachment(
                        activeSurface: self.videoSurface,
                        requestedSurface: requestedSurface
                    )
                }) else { return false }
                guard let view = self.withLock({ self.renderView }) else {
                    self.withLock {
                        if Self.acceptsVideoSurfaceAttachment(
                            activeSurface: self.videoSurface,
                            requestedSurface: requestedSurface
                        ) {
                            self.pendingSpec = spec
                            self.status = .loading
                        }
                    }
                    return false
                }
                view.makeOpenGLContextCurrent()
                try self.ensureContext()
                try self.rebuildRenderContextForNewLoad()
                do {
                    try self.load(spec: spec)
                    self.withLock {
                        self.loadEventTracker.markLoadIssued()
                    }
                } catch {
                    self.withLock {
                        self.loadEventTracker.cancelPreparedLoad()
                    }
                    throw error
                }
                return true
            }
            guard didLoad else {
                DiagnosticLog.write(
                    "[MPV_PLAY_DEFERRED] surface=\(requestedSurface.rawValue) waiting for active video surface"
                )
                return
            }
            let didMarkPlaying = withLock { () -> Bool in
                guard Self.acceptsVideoSurfaceAttachment(
                    activeSurface: videoSurface,
                    requestedSurface: requestedSurface
                ) else { return false }
                status = .playing
                return true
            }
            guard didMarkPlaying else { return }
            updateDisplaySleepPrevention()
            startLocalStreamStartupWatchdog(for: spec)
            await MainActor.run {
                guard self.withLock({
                    Self.acceptsVideoSurfaceAttachment(
                        activeSurface: self.videoSurface,
                        requestedSurface: requestedSurface
                    )
                }) else { return }
                self.playerState?.isPlaying = true
            }
        } catch {
            guard withLock({
                Self.acceptsVideoSurfaceAttachment(
                    activeSurface: videoSurface,
                    requestedSurface: requestedSurface
                )
            }) else {
                DiagnosticLog.write("[MPV_PLAY_ERROR_IGNORED] inactiveSurface=\(requestedSurface.rawValue)")
                return
            }
            setError(L10n.text("mpv 播放失败: {0}", ["\(error.localizedDescription)"]))
        }
    }

    public func pause() {
        PlaybackBackgroundBudget.shared.remove(session: backgroundBudgetSession)
        lock.lock()
        let activeContext = context
        pauseRequested = true
        driveStallWindow = DrivePlaybackStallWindow()
        status = .paused
        cacheStallStart = nil
        cacheStallTask?.cancel()
        cacheStallTask = nil
        lock.unlock()

        updateDisplaySleepPrevention()

        if let activeContext {
            nv_mpv_set_property_flag(activeContext, "pause", 1)
        }
        Task { @MainActor in
            self.playerState?.isPlaying = false
            self.playerState?.isBuffering = false
            self.playerState?.cacheBufferingProgress = nil
        }
    }

    public func resume() {
        lock.lock()
        let activeContext = context
        pauseRequested = false
        status = .playing
        lock.unlock()

        updateDisplaySleepPrevention()

        if let activeContext {
            nv_mpv_set_property_flag(activeContext, "pause", 0)
        }
        Task { @MainActor in
            self.playerState?.isPlaying = true
        }
    }

    @MainActor
    public func seek(to position: Int64) {
        // Event reads and commands both run on MainActor. Retire every queued
        // native event before assigning a new seek owner; never relabel old events.
        guard drainPendingEvents(limit: 4_096) else {
            DiagnosticLog.write("[MPV_SEEK_SKIP] native event queue has not drained")
            return
        }
        lock.lock()
        let activeContext = context
        let durationSeconds = lastDurationMs > 0 ? Double(lastDurationMs) / 1000 : 0
        let spec = activeSpec
        let shouldShowLoading = MPVSeekModePolicy.shouldShowLoading(pauseRequested: pauseRequested)
        let seekURL = activeSpec?.url
        lock.unlock()

        guard let activeContext else { return }
        guard let seconds = PlayerSeekPolicy.normalizedSeekSeconds(
            positionMilliseconds: position,
            durationSeconds: durationSeconds
        ) else {
            DiagnosticLog.write("[MPV_SEEK_SKIP] item is not seekable, positionMs=\(position), durationSeconds=\(durationSeconds)")
            return
        }
        withLock {
            seekActivity.begin()
            driveStallWindow = DrivePlaybackStallWindow()
            postSeekEndGuard.begin(targetSeconds: seconds)
        }
        let seekMode = MPVSeekModePolicy.commandMode(for: spec, targetSeconds: seconds, durationSeconds: durationSeconds)
        if shouldShowLoading {
            playerState?.bufferedUntil = 0
            playerState?.cacheSpeedBytesPerSecond = nil
            playerState?.cacheBufferingProgress = nil
            playerState?.isMediaLoading = true
            playerState?.isBuffering = false
            startSeekTransferMetrics(for: seekURL)
        } else {
            cancelSeekTransferMetrics()
        }
        playerState?.isSeeking = true
        let result = nv_mpv_command3(activeContext, "seek", "\(seconds)", seekMode)
        guard result >= 0 else {
            withLock {
                postSeekEndGuard.reset()
                seekActivity.finish(owner: seekActivity.owner)
            }
            playerState?.isMediaLoading = false
            playerState?.isSeeking = false
            cancelSeekTransferMetrics()
            DiagnosticLog.write("[MPV_SEEK_ERROR] targetSeconds=\(seconds) code=\(result)")
            return
        }
        DiagnosticLog.write("[MPV_SEEK] targetSeconds=\(seconds) mode=\(seekMode)")
    }

    public func stop() {
        PlaybackBackgroundBudget.shared.remove(session: backgroundBudgetSession)
        lock.lock()
        let activeContext = context
        let retiredEventTask: Task<Void, Never>?
        let retiredRenderView: MPVOpenGLVideoView?
        if stopResourcePolicy == .fullDestroy {
            context = nil
            retiredEventTask = eventTask
            eventTask = nil
            retiredRenderView = renderView
            renderRequestGate.reset()
        } else {
            retiredEventTask = nil
            retiredRenderView = nil
        }
        artworkTask?.cancel()
        artworkTask = nil
        let subtitleFiles = temporarySubtitleFiles + temporaryArtworkFiles
        temporarySubtitleFiles = []
        temporaryArtworkFiles = []
        pendingExternalAudioURL = nil
        pendingSpec = nil
        activeSpec = nil
        status = .idle
        lastPositionMs = 0
        lastDurationMs = 0
        lastLoadDiagnostic = nil
        playbackStartedNotified = false
        currentFileLoaded = false
        loadEventTracker.reset()
        pauseRequested = false
        isPausedForCache = false
        postSeekEndGuard.reset()
        seekActivity.resetMedia()
        cacheStallStart = nil
        cacheStallTask?.cancel()
        cacheStallTask = nil
        cacheStallNotified = false
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        lock.unlock()

        updateDisplaySleepPrevention()

        if let activeContext {
            nv_mpv_command1(activeContext, "stop")
            if stopResourcePolicy == .fullDestroy {
                retiredEventTask?.cancel()
                let retirementTask = retireContext(
                    activeContext,
                    eventTask: retiredEventTask,
                    renderView: retiredRenderView
                )
                withLock {
                    renderRetirementTask = retirementTask
                }
            }
        }
        Self.removeTemporarySubtitleFiles(subtitleFiles)
        Task { @MainActor in
            self.cancelSeekTransferMetrics()
            self.playerState?.currentSpec = nil
            self.playerState?.endDisposition = nil
            self.playerState?.errorMessage = nil
            self.playerState?.isPlaying = false
            self.playerState?.position = 0
            self.playerState?.duration = 0
            self.playerState?.bufferedUntil = 0
            self.playerState?.isMediaLoading = false
            self.playerState?.isSeeking = false
            self.playerState?.isBuffering = false
            self.playerState?.cacheSpeedBytesPerSecond = nil
            self.playerState?.cacheBufferingProgress = nil
            self.playerState?.audioTracks = []
            self.playerState?.subtitleTracks = []
            self.playerState?.chapters = []
            self.playerState?.chapterOwnerID = nil
            self.playerState?.containerEditions = []
            self.playerState?.currentContainerEditionID = nil
            self.playerState?.selectedAudioTrackID = nil
            self.playerState?.selectedSubtitleTrackID = nil
            self.playerState?.selectedSecondarySubtitleTrackID = nil
            self.playerState?.secondarySubtitleDelaySeconds = 0
            self.playerState?.subtitleDelaySeconds = 0
            self.playerState?.subtitleStatus = nil
            self.playerState?.drivePlaybackStatus = nil
            self.playerState?.drmStatus = nil
            self.playerState?.danmakuStatus = nil
        }
    }

    private func retireContext(
        _ context: OpaquePointer,
        eventTask: Task<Void, Never>?,
        renderView: MPVOpenGLVideoView?
    ) -> Task<Void, Never> {
        let contextValue = UInt(bitPattern: context)
        return Task { @MainActor in
            guard let retiredContext = OpaquePointer(bitPattern: contextValue) else { return }
            renderView?.makeOpenGLContextCurrent()
            _ = nv_mpv_free_render_context(retiredContext)
            await eventTask?.value
            nv_mpv_destroy(retiredContext)
            DiagnosticLog.write("[MPV_DESTROY] surface=\(self.videoSurface.rawValue) policy=\(self.stopResourcePolicy.rawValue)")
        }
    }

    public func setVolume(_ volume: Float) {
        audioPreferences.setVolume(volume)
    }

    public func setMuted(_ muted: Bool) { audioPreferences.setMuted(muted) }
    public func toggleMute() { audioPreferences.toggleMute() }

    private func applyAudioPreference() {
        withLock {
            guard let context else { return }
            let preference = audioPreferences.snapshot
            // Render callbacks also acquire this lock. Never wait for the mpv core
            // while holding it: the core may be waiting for that render callback.
            let muteCode = nv_mpv_set_property_flag_async(context, Self.audioMuteReplyUserdata, "mute", preference.isMuted ? 1 : 0)
            let volumeCode = nv_mpv_set_property_double_async(context, Self.audioVolumeReplyUserdata, "volume", Double(preference.volume * 100))
            if muteCode < 0 || volumeCode < 0 {
                DiagnosticLog.write("[MPV_AUDIO_PREFERENCE_ERROR] enqueue mute=\(muteCode) volume=\(volumeCode)")
            }
        }
        publishAudioPreference()
    }

    private func publishAudioPreference() {
        Task { @MainActor in
            let preference = self.audioPreferences.snapshot
            self.playerState?.volume = preference.volume
            self.playerState?.isMuted = preference.isMuted
        }
    }

    public func setVideoAspectMode(_ mode: PlayerVideoAspectMode) {
        lock.lock()
        currentVideoAspectMode = mode
        let activeContext = context
        lock.unlock()

        if let activeContext {
            do {
                try applyVideoAspectMode(mode, context: activeContext, stage: "manual")
            } catch {
                DiagnosticLog.write("[MPV_ASPECT_ERROR] \(error.localizedDescription)")
            }
        }
        Task { @MainActor in
            self.playerState?.videoAspectMode = mode
        }
    }

    public func selectAudioTrack(id: String) {
        setStringProperty("aid", value: id, label: "select audio track")
        Task { @MainActor in
            self.playerState?.selectedAudioTrackID = id
        }
        DiagnosticLog.write("[MPV_TRACK] selected audio id=\(id)")
    }

    public func selectSubtitleTrack(id: String, slot: SubtitleSlot = .primary, matchingName: String? = nil, matchingFormat: String = "") {
        let mediaID = withLock { seekActivity.owner.mediaID }
        Task { @MainActor in
            guard self.withLock({ self.seekActivity.owner.mediaID == mediaID }) else { return }
            if id == "no" { self.applySubtitleSelection(id: "no", slot: slot); return }
            self.withLock {
                self.pendingSubtitleSelections[slot] = id
                self.pendingSubtitleMatches[slot] = matchingName.map { ($0, matchingFormat) }
            }
            self.refreshSubtitleTracks()
        }
    }

    public func disableSubtitle() { selectSubtitleTrack(id: "no") }

    public func loadExternalSubtitle(_ sub: Sub, select: Bool = true, slot: SubtitleSlot = .primary) {
        guard let activeContext = withLock({ context }), !sub.url.isEmpty else { return }
        let mediaID = withLock { seekActivity.owner.mediaID }
        withLock {
            if var spec = activeSpec, !spec.subs.contains(where: { $0.id == sub.id }) {
                spec.subs.append(sub); activeSpec = spec
            }
        }
        let alreadyAdded = withLock { preparedSubtitleSources[sub.id] != nil }
        let title = sub.name.isEmpty ? L10n.text("外挂字幕") : sub.name
        guard let source = preparedSubtitleSource(for: sub, title: title) else { return }
        if !alreadyAdded {
            let code = nv_mpv_command4(activeContext, "sub-add", source, "auto", title)
            if code < 0 {
                withLock { preparedSubtitleSources.removeValue(forKey: sub.id) }
                DiagnosticLog.write("[MPV_SUBTITLE_ERROR] attachment failed")
                return
            }
        }
        Task { @MainActor in
            guard self.withLock({ self.seekActivity.owner.mediaID == mediaID }) else { return }
            if select {
                self.withLock {
                    self.pendingSubtitleSelections[slot] = "external:" + sub.id
                    self.pendingSubtitleMatches.removeValue(forKey: slot)
                }
            }
            self.refreshSubtitleTracks()
        }
    }

    @MainActor
    private func applySubtitleSelection(id: String, slot: SubtitleSlot) {
        let other: SubtitleSlot = slot == .primary ? .secondary : .primary
        let otherID = other == .primary ? playerState?.selectedSubtitleTrackID : playerState?.selectedSecondarySubtitleTrackID
        if id != "no", id == otherID { applySubtitleSelection(id: "no", slot: other) }
        setStringProperty(slot == .primary ? "sid" : "secondary-sid", value: id, label: "select subtitle")
        if slot == .secondary {
            setStringProperty("secondary-sub-visibility", value: id == "no" ? "no" : "yes", label: "secondary subtitle visibility")
            playerState?.selectedSecondarySubtitleTrackID = id == "no" ? nil : id
        } else {
            playerState?.selectedSubtitleTrackID = id == "no" ? nil : id
            withLock { currentSubtitleFormat = playerState?.subtitleTracks.first { $0.id == id }?.subtitleKind ?? .text }
        }
        withLock {
            pendingSubtitleSelections.removeValue(forKey: slot)
            pendingSubtitleMatches.removeValue(forKey: slot)
        }
        reapplySubtitleStyle(stage: "select")
    }

    @MainActor
    public func seekToChapter(id: Int, owner: UUID) {
        guard withLock({ seekActivity.owner.mediaID == owner }),
              playerState?.chapterOwnerID == owner,
              let chapter = playerState?.chapters.first(where: { $0.id == id }),
              chapter.seconds.isFinite, chapter.seconds >= 0,
              chapter.seconds < Double(Int64.max) / 1_000 else { return }
        seek(to: Int64(chapter.seconds * 1_000))
    }

    @MainActor
    private func refreshChapters() {
        guard withLock({ currentFileLoaded }) else { return }
        let chapters = nativePropertyJSON("chapter-list") ?? "[]"
        let editions = nativePropertyJSON("edition-list") ?? "[]"
        playerState?.chapters = (try? PlayerChapterPolicy.chapters(json: chapters, duration: playerState?.duration ?? 0)) ?? []
        playerState?.containerEditions = (try? PlayerChapterPolicy.editions(json: editions)) ?? []
        playerState?.currentContainerEditionID = nativePropertyJSON("current-edition").flatMap(Int.init)
        playerState?.chapterOwnerID = withLock { seekActivity.owner.mediaID }
    }

    @MainActor
    func nativePropertyJSON(_ name: String) -> String? {
        guard let activeContext = withLock({ context }), let value = nv_mpv_copy_property_json(activeContext, name) else { return nil }
        defer { nv_mpv_free_string(value) }
        return String(cString: value)
    }

    @MainActor
    private func refreshSubtitleTracks() {
        guard let activeContext = withLock({ currentFileLoaded ? context : nil }),
              let json = nv_mpv_copy_property_json(activeContext, "track-list") else { return }
        defer { nv_mpv_free_string(json) }
        guard let snapshot = try? MPVTrackListParser.parse(json: String(cString: json)) else { return }
        playerState?.audioTracks = snapshot.audioTracks
        playerState?.selectedAudioTrackID = snapshot.selectedAudioTrackID
        playerState?.subtitleTracks = snapshot.subtitleTracks
        playerState?.selectedSubtitleTrackID = snapshot.selectedSubtitleTrackID
        playerState?.selectedSecondarySubtitleTrackID = snapshot.selectedSecondarySubtitleTrackID
        let sources = withLock { preparedSubtitleSources }
        for slot in [SubtitleSlot.primary, .secondary] {
            guard let desired = withLock({ pendingSubtitleSelections[slot] }) else { continue }
            let match = withLock { pendingSubtitleMatches[slot] }
            var id: String? = snapshot.subtitleTracks.first { $0.id == desired && (match == nil || match?.name == desired || $0.displayName == match?.name) }?.id
            if id == nil, let match {
                id = snapshot.subtitleTracks.first { $0.displayName == match.name && $0.format == match.format }?.id
            }
            if desired.hasPrefix("external:"), let source = sources[String(desired.dropFirst(9))] {
                id = snapshot.externalTrackIDs.first { Self.subtitleSourceKey($0.key) == Self.subtitleSourceKey(source) }?.value
            }
            if let id { applySubtitleSelection(id: id, slot: slot) }
        }
        withLock { currentSubtitleFormat = playerState?.subtitleTracks.first { $0.id == playerState?.selectedSubtitleTrackID }?.subtitleKind ?? .text }
        reapplySubtitleStyle(stage: "tracks")
    }

    private static func subtitleSourceKey(_ source: String) -> String {
        if let url = URL(string: source), url.isFileURL { return url.standardizedFileURL.path }
        return source
    }

    public func setSubtitleDelay(_ seconds: Double, slot: SubtitleSlot = .primary) {
        let value = SubtitleMediaIdentity.normalizedDelay(seconds)
        let mediaID = withLock { seekActivity.owner.mediaID }
        setStringProperty(slot == .primary ? "sub-delay" : "secondary-sub-delay", value: String(value), label: "subtitle delay")
        Task { @MainActor in
            guard self.withLock({ self.seekActivity.owner.mediaID == mediaID }) else { return }
            if slot == .primary { self.playerState?.subtitleDelaySeconds = value }
            else { self.playerState?.secondarySubtitleDelaySeconds = value }
        }
    }

    public func refreshSubtitleStyle() {
        reapplySubtitleStyle(stage: "manual")
    }

    private func ensureContext() throws {
        contextCreationLock.lock()
        defer { contextCreationLock.unlock() }

        lock.lock()
        let existingContext = context
        lock.unlock()
        if existingContext != nil { return }

        guard let created = nv_mpv_create() else {
            throw MPVPlayerEngineError.initialization(L10n.text("无法创建 libmpv context"))
        }
        guard !Self.cString(nv_mpv_loaded_library_path(created)).isEmpty else {
            let message = Self.cString(nv_mpv_last_error(created))
            nv_mpv_destroy(created)
            throw MPVPlayerEngineError.initialization(message)
        }

        for option in Self.initializationOptions {
            try check(
                nv_mpv_set_option_string(created, option.name, option.value),
                context: created,
                action: "set option \(option.name)=\(option.value)"
            )
        }
        let logLevel = Self.networkDiagnosticsEnabled ? "trace" : "info"
        try check(nv_mpv_request_log_messages(created, logLevel), context: created, action: "request mpv logs")
        try check(nv_mpv_initialize(created), context: created, action: "initialize libmpv")
        try check(nv_mpv_observe_double(created, 1, "time-pos"), context: created, action: "observe time-pos")
        try check(nv_mpv_observe_double(created, 2, "duration"), context: created, action: "observe duration")
        try check(nv_mpv_observe_flag(created, 3, "pause"), context: created, action: "observe pause")
        try check(nv_mpv_observe_flag(created, 4, "paused-for-cache"), context: created, action: "observe paused-for-cache")
        try check(nv_mpv_observe_double(created, 5, "demuxer-cache-time"), context: created, action: "observe demuxer-cache-time")
        try check(nv_mpv_observe_int64(created, 6, "cache-speed"), context: created, action: "observe cache-speed")
        try check(nv_mpv_observe_int64(created, 7, "cache-buffering-state"), context: created, action: "observe cache-buffering-state")
        try check(nv_mpv_observe_flag(created, 8, "seeking"), context: created, action: "observe seeking")
        try check(nv_mpv_observe_change(created, 9, "track-list"), context: created, action: "observe track-list")
        try check(nv_mpv_observe_change(created, 10, "sid"), context: created, action: "observe sid")
        try check(nv_mpv_observe_change(created, 11, "secondary-sid"), context: created, action: "observe secondary-sid")
        try check(nv_mpv_observe_change(created, 12, "chapter-list"), context: created, action: "observe chapter-list")
        try check(nv_mpv_observe_change(created, 13, "edition-list"), context: created, action: "observe edition-list")

        lock.lock()
        context = created
        lock.unlock()

        DiagnosticLog.write("[MPV_INIT] loaded=\(Self.cString(nv_mpv_loaded_library_path(created)))")
        startEventLoop(context: created)
    }

    @MainActor
    private func ensureRenderContext() throws {
        lock.lock()
        let activeContext = context
        lock.unlock()
        guard let activeContext else {
            throw MPVPlayerEngineError.initialization(L10n.text("libmpv context 尚未初始化"))
        }
        try check(
            nv_mpv_create_render_context(activeContext, mpvRenderUpdateCallback, Unmanaged.passUnretained(self).toOpaque()),
            context: activeContext,
            action: "create libmpv render context"
        )
    }

    @MainActor
    private func rebuildRenderContextForNewLoad() throws {
        lock.lock()
        let activeContext = context
        lock.unlock()
        guard let activeContext else {
            throw MPVPlayerEngineError.initialization(L10n.text("libmpv context 尚未初始化"))
        }

        try check(nv_mpv_free_render_context(activeContext), context: activeContext, action: "free libmpv render context")
        try ensureRenderContext()
        DiagnosticLog.write("[MPV_RENDER_RESET] render context rebuilt before loadfile")
    }

    private func load(spec: PlaySpec) throws {
        withLock {
            liveStallWindow = LivePlaybackStallWindow()
            driveStallWindow = DrivePlaybackStallWindow()
            liveReuseFailureObserved = false
            liveConnectionRepairRequested = false
        }
        let profile = PlaybackTransferPolicy.profile(for: spec)
        if profile.context.connection == .local {
            PlaybackBackgroundBudget.shared.remove(session: backgroundBudgetSession)
        } else {
            PlaybackBackgroundBudget.shared.update(session: backgroundBudgetSession, bufferedAhead: 0,
                isLoading: true, isSeeking: false, isBuffering: false)
        }
        DiagnosticLog.write("[PLAYBACK_TRANSFER_LOAD] surface=\(videoSurface.rawValue) version=\(PlaybackTransferProfile.version) profile=\(profile.diagnosticName)")
        let inputDigest = SHA256.hash(data: Data(spec.url.utf8))
            .map { String(format: "%02x", $0) }.joined()
        DiagnosticLog.write("[MPV_INPUT] sha256=\(inputDigest)")
        lock.lock()
        let activeContext = context
        let staleSubtitleFiles = temporarySubtitleFiles + temporaryArtworkFiles
        temporarySubtitleFiles = []
        temporaryArtworkFiles = []
        lock.unlock()
        Self.removeTemporarySubtitleFiles(staleSubtitleFiles)
        guard let activeContext else {
            throw MPVPlayerEngineError.initialization(L10n.text("libmpv context 尚未初始化"))
        }

        try check(nv_mpv_clear_http_headers(activeContext), context: activeContext, action: "clear http-header-fields")
        let userAgent = Self.headerValue(named: "User-Agent", in: spec.headers) ?? PlaybackProxyPolicy.defaultHTTPUserAgent
        let referrer = Self.headerValue(named: "Referer", in: spec.headers) ?? ""
        try check(nv_mpv_set_property_string(activeContext, "user-agent", userAgent), context: activeContext, action: "set property user-agent")
        try check(nv_mpv_set_property_string(activeContext, "referrer", referrer), context: activeContext, action: "set property referrer")

        // Restore every option changed for the previous media before merging the new plan.
        for (name, value) in mediaOptionDefaults.sorted(by: { $0.key < $1.key }) {
            try check(nv_mpv_set_property_string(activeContext, name, value), context: activeContext,
                      action: "restore media option \(name)")
            mediaOptionDefaults[name] = nil
        }
        let clearArtworkCode = nv_mpv_command4(
            activeContext,
            "change-list",
            "cover-art-files",
            "clr",
            ""
        )
        if clearArtworkCode < 0 {
            DiagnosticLog.write("[MPV_ARTWORK_CLEAR_ERROR] \(Self.cString(nv_mpv_last_error(activeContext)))")
        }
        if !spec.artwork.isEmpty, artworkLoader == nil {
            let artworkCode = nv_mpv_command4(
                activeContext,
                "change-list",
                "cover-art-files",
                "append",
                spec.artwork
            )
            if artworkCode < 0 {
                DiagnosticLog.write("[MPV_ARTWORK_ERROR] \(Self.cString(nv_mpv_last_error(activeContext)))")
            } else {
                DiagnosticLog.write("[MPV_ARTWORK] attached cover: \(Self.redactedURL(spec.artwork))")
            }
        }
        let audioPreference = audioPreferences.snapshot
        var userOptions = PlayerSubtitlePolicy.mpvOptions(for: subtitleSettingsProvider())
        userOptions.merge([
            "speed": String(currentSpeed), "volume": String(audioPreference.volume * 100),
            "mute": audioPreference.isMuted ? "yes" : "no",
            "video-aspect-override": currentVideoAspectMode.mpvVideoAspectOverride,
            "panscan": String(currentVideoAspectMode.mpvPanscan)
        ]) { _, user in user }
        let sessionOptions = [
            "sid": "auto", "secondary-sid": "no", "secondary-sub-visibility": "no", "pause": "no",
            "sub-delay": String(SubtitleMediaIdentity.normalizedDelay(subtitleDelayProvider(spec))),
            "secondary-sub-delay": String(SubtitleMediaIdentity.normalizedDelay(secondarySubtitleDelayProvider(spec)))
        ]
        let plan = MPVOptionPolicy.resolve(spec: spec, user: userOptions, session: sessionOptions)
        try applyMPVOptions(plan, context: activeContext, stage: "load")

        for header in Self.headerFields(from: spec.headers) {
            try check(nv_mpv_append_http_header(activeContext, header), context: activeContext, action: "append http header \(Self.redactedHeaderField(header))")
        }
        try check(nv_mpv_set_property_double(activeContext, "speed", Double(currentSpeed)), context: activeContext, action: "set property speed")
        try check(nv_mpv_set_property_flag(activeContext, "mute", audioPreference.isMuted ? 1 : 0), context: activeContext, action: "restore mute")
        try check(nv_mpv_set_property_double(activeContext, "volume", Double(audioPreference.volume * 100)), context: activeContext, action: "restore volume")
        publishAudioPreference()
        try check(nv_mpv_set_property_flag(activeContext, "pause", 0), context: activeContext, action: "set property pause=no")
        try applyVideoAspectMode(currentVideoAspectMode, context: activeContext, stage: "load")
        withLock {
            pendingExternalAudioURL = spec.externalAudioURL.isEmpty ? nil : spec.externalAudioURL
        }
        if let options = MPVInitialStartPolicy.loadFileOptions(for: spec) {
            DiagnosticLog.write("[MPV_LOAD_START] options=\(options)")
            try check(
                nv_mpv_command5_async(
                    activeContext,
                    Self.loadFileReplyUserdata,
                    "loadfile",
                    spec.url,
                    "replace",
                    "-1",
                    options
                ),
                context: activeContext,
                action: "loadfile async with file-local options"
            )
        } else {
            try check(
                nv_mpv_command3_async(activeContext, Self.loadFileReplyUserdata, "loadfile", spec.url, "replace"),
                context: activeContext,
                action: "loadfile async"
            )
        }
        for (index, sub) in spec.subs.enumerated() where !sub.url.isEmpty {
            let title = sub.name.isEmpty ? L10n.text("外挂字幕 {0}", ["\(index + 1)"]) : sub.name
            guard let source = preparedSubtitleSource(for: sub, title: title) else { continue }
            let code = nv_mpv_command4_async(
                activeContext,
                Self.firstSubtitleReplyUserdata + UInt64(index),
                "sub-add",
                source,
                index == 0 ? "select" : "auto",
                title
            )
            if code < 0 {
                let errorText = Self.cString(nv_mpv_last_error(activeContext))
                DiagnosticLog.write("[MPV_SUBTITLE_ERROR] \(title): \(errorText)")
                Task { @MainActor in
                    self.playerState?.subtitleStatus = L10n.text("{0}加载失败", ["\(title)"])
                }
            }
        }
    }

    private func startEventLoop(context: OpaquePointer) {
        eventTask?.cancel()
        let contextValue = UInt(bitPattern: context)
        eventTask = Task { @MainActor [weak self] in
            guard let activeContext = OpaquePointer(bitPattern: contextValue) else { return }
            while !Task.isCancelled {
                guard let self,
                      self.withLock({ self.context == activeContext }) else {
                    break
                }
                let drained = self.drainPendingEvents(limit: 64)
                // Native reads never block the UI. A bounded batch yields to
                // user input even when mpv is producing a burst of log events.
                if drained { try? await Task.sleep(for: .milliseconds(self.withLock { self.activeSpec == nil ? 100 : 20 })) }
                else { await Task.yield() }
            }
        }
    }

    @MainActor
    @discardableResult
    private func drainPendingEvents(limit: Int) -> Bool {
        guard let activeContext = withLock({ context }) else { return true }
        for _ in 0..<limit {
            guard withLock({ context == activeContext }) else { return true }
            var event = NVMPVEvent()
            guard nv_mpv_wait_event(activeContext, 0, &event) == 0, event.event_id != 0 else { return true }
            let owner = withLock { seekActivity.owner }
            handle(event: MPVEventSnapshot(event, owner: owner))
        }
        return false
    }

    @MainActor
    private func handle(event: MPVEventSnapshot) {
        guard withLock({ seekActivity.owner.mediaID == event.owner.mediaID }) else { return }
        if event.eventID == 6 { // MPV_EVENT_START_FILE owns subsequent native events.
            withLock { loadEventTracker.markFileStarted() }
            return
        }
        if withLock({ loadEventTracker.shouldIgnorePriorLoadEvent(event.eventID) }) {
            if event.eventID == 7 {
                _ = withLock { loadEventTracker.consumeEndFile() }
                DiagnosticLog.write("[MPV_REPLACED_END_FILE_IGNORED] reason=\(event.endFileReason) error=\(event.endFileError)")
            }
            return
        }
        if event.eventID == 20 || event.eventID == MPVPlaybackActivityPolicy.playbackRestartEventID
            || event.propertyName == "seeking" || event.propertyName == "time-pos" {
            guard withLock({ seekActivity.owner == event.owner }) else { return }
        }
        switch event.eventID {
        case 0:
            return
        case 7:
            let spec = playerState?.currentSpec
            let isReplacedLoadEndFile = withLock {
                loadEventTracker.consumeEndFile()
            }
            if isReplacedLoadEndFile {
                DiagnosticLog.write(
                    "[MPV_REPLACED_END_FILE_IGNORED] reason=\(event.endFileReason) error=\(event.endFileError)"
                )
                return
            }
            let currentStatus = withLock { status }
            guard Self.shouldApplyEndFileState(
                reason: event.endFileReason,
                error: event.endFileError,
                status: currentStatus
            ) else {
                DiagnosticLog.write(
                    "[MPV_END_FILE_IGNORED] reason=\(event.endFileReason) error=\(event.endFileError) status=\(currentStatus)"
                )
                return
            }
            if event.endFileReason == EndFileReason.eof.rawValue, event.endFileError >= 0,
               recoverInvalidInitialStartIfNeeded(reachedEOF: true) {
                return
            }
            let endState = withLock { () -> (
                playbackStarted: Bool,
                isPausedForCache: Bool,
                positionSeconds: Double,
                durationSeconds: Double,
                isProtectedByUserSeek: Bool,
                isUserSeekToBoundary: Bool
            ) in
                let positionSeconds = Double(lastPositionMs) / 1_000
                let durationSeconds = Double(lastDurationMs) / 1_000
                let isProtectedByUserSeek = postSeekEndGuard.isProtecting
                    && !postSeekEndGuard.didPlayToEndAfterSeek(
                        positionSeconds: positionSeconds,
                        durationSeconds: durationSeconds
                    )
                let isUserSeekToBoundary = postSeekEndGuard.isBoundarySeek(
                    positionSeconds: positionSeconds,
                    durationSeconds: durationSeconds
                )
                postSeekEndGuard.reset()
                return (
                    playbackStartedNotified,
                    isPausedForCache,
                    positionSeconds,
                    durationSeconds,
                    isProtectedByUserSeek,
                    isUserSeekToBoundary
                )
            }
            let disposition = PlaybackAutoAdvancePolicy.endDisposition(
                reason: event.endFileReason,
                error: event.endFileError,
                isReplacingMedia: false,
                playbackStarted: endState.playbackStarted,
                isPausedForCache: endState.isPausedForCache,
                positionSeconds: endState.positionSeconds,
                durationSeconds: endState.durationSeconds,
                isProtectedByUserSeek: endState.isProtectedByUserSeek,
                isUserSeekToBoundary: endState.isUserSeekToBoundary
            )
            DiagnosticLog.write(
                "[MPV_END_FILE_DISPOSITION] disposition=\(disposition) reason=\(event.endFileReason) error=\(event.endFileError)"
            )
            DiagnosticLog.write("[MPV_END_FILE] code=\(event.endFileReason) errorCode=\(event.endFileError)")
            playerState?.endDisposition = disposition
            if disposition == .failed {
                let diagnostic = withLock { lastLoadDiagnostic }
                setError(diagnostic ?? L10n.text("mpv 播放结束但返回错误: {0}", ["\(event.errorString ?? "unknown")"]), nativeError: event.endFileError)
            } else {
                withLock {
                    status = .idle
                }
                playerState?.isPlaying = false
                updateDisplaySleepPrevention()
                clearPlaybackActivity()
                if disposition == .natural {
                    playbackEndedHandler?(spec)
                }
            }
        case 2:
            guard let text = event.logText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            if playerState?.currentSpec?.metadata["playback.kind"] == "live",
               LivePlaybackBufferPolicy.indicatesConnectionReuseFailure(text) {
                withLock { liveReuseFailureObserved = true }
                // A network timeout can report the reuse error only after the
                // stall timer fired. Reevaluate this same stall immediately.
                _ = requestLiveConnectionRepairIfNeeded(requiringExpiredStall: true)
            }
            if let status = Self.httpFailureStatus(forMPVLog: text) {
                withLock { lastHTTPFailureStatus = status }
                DiagnosticLog.write("[MPV_HTTP_ERROR] status=\(status)")
            }
            if Self.networkDiagnosticsEnabled, let diagnostic = Self.networkDiagnostic(text) {
                DiagnosticLog.write("[MPV_HTTP] \(diagnostic)")
            }
            let parsedTrack = MPVTrackLogParser.parsedTrack(from: text)
            if Self.shouldWriteMPVLog(level: event.logLevel, parsedTrack: parsedTrack) {
                DiagnosticLog.write("[MPV_LOG] [\(event.logLevel ?? "-")] \(event.logPrefix ?? "-"): \(Self.redactedLogText(text))")
            }
            if let parsedTrack {
                handleParsedTrackLog(parsedTrack)
            }
            let playbackStarted = withLock { playbackStartedNotified }
            if let failure = Self.localStreamStartupFailure(
                logText: text,
                spec: playerState?.currentSpec,
                playbackStarted: playbackStarted
            ) {
                failLocalStreamStartupIfNeeded(failure)
                return
            }
            if let diagnostic = Self.diagnosticMessage(forMPVLog: text, currentSpec: playerState?.currentSpec) {
                var shouldUpdateGenericLoadError = false
                withLock {
                    if lastLoadDiagnostic == nil {
                        lastLoadDiagnostic = diagnostic
                    }
                    if case .error(let message) = status,
                       message.contains("loading failed") || message.contains(L10n.text("mpv 播放结束但返回错误")) {
                        shouldUpdateGenericLoadError = true
                    }
                }
                if shouldUpdateGenericLoadError {
                    setError(diagnostic)
                }
            }
        case 8:
            // FILE_LOADED only means demuxing was accepted; the first media request can still fail.
            let externalAudio = withLock { () -> (context: OpaquePointer?, url: String?) in
                currentFileLoaded = true
                loadEventTracker.markFileLoaded()
                defer { pendingExternalAudioURL = nil }
                return (context, pendingExternalAudioURL)
            }
            if let activeContext = externalAudio.context, let audioURL = externalAudio.url {
                let code = nv_mpv_command4_async(
                    activeContext,
                    Self.externalAudioReplyUserdata,
                    "audio-add",
                    audioURL,
                    "select",
                    L10n.text("外部音轨")
                )
                if code < 0 {
                    DiagnosticLog.write("[MPV_AUDIO_ERROR] \(Self.cString(nv_mpv_last_error(activeContext)))")
                } else {
                    DiagnosticLog.write("[MPV_AUDIO] attached external track: \(Self.redactedURL(audioURL))")
                }
            }
            refreshSubtitleTracks()
            refreshChapters()
            attachAudioFallbackArtworkIfNeeded()
        case Self.propertyReplyEventID:
            guard event.error < 0,
                  event.replyUserdata == Self.audioMuteReplyUserdata || event.replyUserdata == Self.audioVolumeReplyUserdata else { return }
            DiagnosticLog.write("[MPV_AUDIO_PREFERENCE_ERROR] reply=\(event.replyUserdata) error=\(event.errorString ?? "unknown")")
        case Self.commandReplyEventID:
            guard event.error < 0 else { return }
            let errorText = event.errorString ?? "unknown"
            if event.replyUserdata == Self.artworkReplyUserdata {
                DiagnosticLog.write("[MPV_ARTWORK_ERROR] error=\(errorText)")
                return
            }
            if Self.isSubtitleReplyUserdata(event.replyUserdata) {
                let subtitleIndex = Int(event.replyUserdata - Self.firstSubtitleReplyUserdata)
                let subtitle = playerState?.currentSpec?.subs.indices.contains(subtitleIndex) == true
                    ? playerState?.currentSpec?.subs[subtitleIndex]
                    : nil
                let title = subtitle.flatMap { $0.name.isEmpty ? nil : $0.name } ?? L10n.text("外挂字幕")
                playerState?.subtitleStatus = L10n.text("{0}加载失败", ["\(title)"])
                DiagnosticLog.write("[MPV_SUBTITLE_ERROR] reply=\(event.replyUserdata) title=\(title) error=\(errorText)")
                return
            }
            if event.replyUserdata == Self.externalAudioReplyUserdata {
                setError(L10n.text("mpv 外部音轨加载失败: {0}", ["\(errorText)"]))
            } else {
                setError(L10n.text("mpv 事件错误: {0}", ["\(errorText)"]))
            }
        case 20: // MPV_EVENT_SEEK
            withLock { seekActivity.observeSeek(owner: event.owner) }
        case MPVPlaybackActivityPolicy.playbackRestartEventID:
            withLock {
                if !seekActivity.isPending || seekActivity.observeRestart(owner: event.owner) {
                    postSeekEndGuard.markPlaybackRestarted()
                }
            }
            completeOwnedSeekIfReady()
        case MPVPlaybackActivityPolicy.propertyChangeEventID:
            handlePropertyChange(event)
        default:
            if event.error < 0 {
                setError(L10n.text("mpv 事件错误: {0}", ["\(event.errorString ?? "unknown")"]))
            }
        }
    }

    @MainActor
    private func attachAudioFallbackArtworkIfNeeded() {
        let playback = withLock { (context, activeSpec, seekActivity.owner.mediaID) }
        guard let activeContext = playback.0, let spec = playback.1,
              !spec.artwork.isEmpty || !spec.audioFallbackArtwork.isEmpty else { return }
        guard hasAudioOnlyMediaTracks() else { return }
        if let artworkLoader {
            let task = Task { @MainActor [weak self] in
                do {
                    let data = try await artworkLoader(spec)
                    try Task.checkCancellation()
                    guard let self, self.withLock({ self.seekActivity.owner.mediaID == playback.2 && self.currentFileLoaded }),
                          let currentContext = self.withLock({ self.context }) else { return }
                    // A late image must never replace video or an embedded cover discovered meanwhile.
                    guard self.hasAudioOnlyMediaTracks() else { return }
                    let file = FileManager.default.temporaryDirectory
                        .appendingPathComponent("netvplayer-artwork-\(UUID().uuidString).png")
                    try data.write(to: file, options: .atomic)
                    self.withLock { self.temporaryArtworkFiles.append(file) }
                    let code = nv_mpv_command5_async(currentContext, Self.artworkReplyUserdata,
                        "video-add", file.path, "select+attached-picture", "", "")
                    DiagnosticLog.write(code < 0 ? "[MPV_ARTWORK_ERROR] local artwork command failed" : "[MPV_ARTWORK] submitted decoded local cover")
                } catch is CancellationError {
                    // Replacing or stopping playback owns cancellation; it is not an image error.
                } catch {
                    DiagnosticLog.write("[MPV_ARTWORK_ERROR] artwork preparation failed")
                }
            }
            withLock { artworkTask?.cancel(); artworkTask = task }
            return
        }
        guard spec.artwork.isEmpty else { return }
        let code = nv_mpv_command5_async(
            activeContext,
            Self.artworkReplyUserdata,
            "video-add",
            spec.audioFallbackArtwork,
            "select+attached-picture",
            "",
            ""
        )
        if code < 0 {
            DiagnosticLog.write("[MPV_ARTWORK_ERROR] \(Self.cString(nv_mpv_last_error(activeContext)))")
        } else {
            DiagnosticLog.write("[MPV_ARTWORK] attached audio fallback cover: \(Self.redactedURL(spec.audioFallbackArtwork))")
        }
    }

    @MainActor
    func hasAudioOnlyMediaTracks() -> Bool {
        guard let context = withLock({ context }) else { return false }
        var audio: Int64 = 0
        var video: Int64 = 0
        return nv_mpv_get_media_track_counts(context, &audio, &video) >= 0 && audio > 0 && video == 0
    }

    @MainActor
    private func handlePropertyChange(_ event: MPVEventSnapshot) {
        defer { updatePlaybackBackgroundBudget() }
        switch event.propertyName {
        case "chapter-list", "edition-list":
            refreshChapters()
        case "track-list", "sid", "secondary-sid":
            refreshSubtitleTracks()
        case "time-pos":
            guard event.hasPropertyValue, event.doubleValue.isFinite else { return }
            guard MPVPlaybackActivityPolicy.shouldAcceptTimePosition(
                isCurrentFileLoaded: withLock { currentFileLoaded }
            ) else {
                DiagnosticLog.write("[MPV_STALE_TIME_POS_IGNORED] waiting for current FILE_LOADED")
                return
            }
            let seconds = max(0, event.doubleValue)
            lock.lock()
            lastPositionMs = Int64(seconds * 1000)
            let isWaitingForCache = isPausedForCache
            let confirmedSeek = seekActivity.isReady(owner: event.owner, pausedForCache: isWaitingForCache)
            let canPresentFrame = (!seekActivity.isPending || confirmedSeek)
                && postSeekEndGuard.canPresentFrame(at: seconds, confirmedSeek: confirmedSeek)
            postSeekEndGuard.observePosition(seconds)
            lock.unlock()
            playerState?.position = seconds
            playbackPositionHandler?(playerState?.currentSpec, seconds)
            if MPVPlaybackActivityPolicy.shouldEndMediaLoading(
                eventID: MPVPlaybackActivityPolicy.propertyChangeEventID,
                positionSeconds: seconds
            ), canPresentFrame, !isWaitingForCache {
                withLock {
                    postSeekEndGuard.markFramePresented()
                    seekActivity.finish(owner: event.owner)
                }
                cancelStartupWatchdog()
                markPlaybackStartedIfNeeded()
                markMediaReady()
            }
        case "duration":
            guard event.hasPropertyValue, event.doubleValue.isFinite else { return }
            let seconds = max(0, event.doubleValue)
            lock.lock()
            lastDurationMs = Int64(seconds * 1000)
            lock.unlock()
            playerState?.duration = seconds
            refreshChapters()
            if recoverInvalidInitialStartIfNeeded(durationSeconds: seconds) { return }
            if Self.shouldCancelStartupWatchdogAfterDuration(for: playerState?.currentSpec, seconds: seconds) {
                cancelStartupWatchdog()
            }
        case "pause":
            let isPaused = event.flagValue != 0
            let shouldApply = withLock { () -> Bool in
                guard Self.shouldApplyPauseProperty(
                    isPaused: isPaused,
                    status: status,
                    pauseRequested: pauseRequested
                ) else { return false }
                status = isPaused ? .paused : .playing
                return true
            }
            guard shouldApply else {
                DiagnosticLog.write("[MPV_PAUSE_EVENT_IGNORED] paused=\(isPaused)")
                return
            }
            playerState?.isPlaying = !isPaused
            updateDisplaySleepPrevention()
        case "paused-for-cache":
            handleCachePause(isPausedForCache: event.flagValue != 0)
            completeOwnedSeekIfReady()
        case "seeking":
            withLock { seekActivity.observeSeeking(event.flagValue != 0, owner: event.owner) }
            completeOwnedSeekIfReady()
        case "demuxer-cache-time":
            playerState?.bufferedUntil = event.doubleValue.isFinite ? max(0, event.doubleValue) : 0
        case "cache-speed":
            playerState?.cacheSpeedBytesPerSecond = MPVPlaybackActivityPolicy.normalizedCacheSpeed(
                event.int64Value,
                hasValue: event.hasPropertyValue
            )
        case "cache-buffering-state":
            playerState?.cacheBufferingProgress = MPVPlaybackActivityPolicy.normalizedCacheBufferingProgress(
                event.int64Value,
                hasValue: event.hasPropertyValue
            )
        default:
            break
        }
    }

    @MainActor
    private func completeOwnedSeekIfReady() {
        let ready = withLock { () -> Bool in
            let owner = seekActivity.owner
            guard seekActivity.isReady(owner: owner, pausedForCache: isPausedForCache) else { return false }
            postSeekEndGuard.markFramePresented()
            seekActivity.finish(owner: owner)
            return true
        }
        if ready { markMediaReady() }
    }

    @MainActor
    private func recoverInvalidInitialStartIfNeeded(
        durationSeconds: Double = 0,
        reachedEOF: Bool = false
    ) -> Bool {
        let recovered = withLock { () -> PlaySpec? in
            guard context != nil, Self.acceptsPlaybackStartEvent(status: status),
                  let activeSpec,
                  let recovered = MPVInitialStartPolicy.recoverySpec(
                    for: activeSpec,
                    durationSeconds: durationSeconds,
                    isCurrentFileLoaded: currentFileLoaded,
                    playbackStarted: playbackStartedNotified,
                    reachedEOF: reachedEOF
                  ) else { return nil }
            self.activeSpec = recovered
            currentFileLoaded = false
            lastPositionMs = 0
            lastDurationMs = 0
            lastLoadDiagnostic = nil
            postSeekEndGuard.reset()
            seekActivity.resetMedia()
            isPausedForCache = false
            cacheStallStart = nil
            cacheStallTask?.cancel()
            cacheStallTask = nil
            cacheStallNotified = false
            loadEventTracker.prepareForLoad()
            return recovered
        }
        guard let recovered else { return false }
        DiagnosticLog.write("[MPV_LOAD_START_RECOVERY] durationSeconds=\(durationSeconds) eof=\(reachedEOF)")
        cancelSeekTransferMetrics()
        playerState?.currentSpec = recovered
        playerState?.position = 0
        playerState?.duration = 0
        playerState?.bufferedUntil = 0
        playerState?.isMediaLoading = true
        playerState?.isSeeking = false
        playerState?.isBuffering = false
        playerState?.cacheSpeedBytesPerSecond = nil
        playerState?.cacheBufferingProgress = nil
        do {
            try load(spec: recovered)
            withLock { loadEventTracker.markLoadIssued() }
            if let pausedContext = withLock({ pauseRequested ? context : nil }) {
                nv_mpv_set_property_flag(pausedContext, "pause", 1)
            }
            startLocalStreamStartupWatchdog(for: recovered)
        } catch {
            withLock { loadEventTracker.cancelPreparedLoad() }
            setError(L10n.text("播放器重新加载失败: {0}", ["\(error.localizedDescription)"]))
        }
        return true
    }

    @MainActor
    private func handleCachePause(isPausedForCache: Bool) {
        let pauseRequested = withLock { () -> Bool in
            self.isPausedForCache = isPausedForCache
            return self.pauseRequested
        }
        let isBuffering = MPVPlaybackActivityPolicy.shouldExposeBuffering(
            isPausedForCache: isPausedForCache,
            pauseRequested: pauseRequested
        )
        playerState?.isBuffering = isBuffering

        if isBuffering {
            if cacheStallStart == nil {
                cacheStallEligible = playerState?.isMediaLoading == false && playerState?.isSeeking == false
                    && !withLock { seekActivity.isPending }
                let startedAt = Date()
                let spec = playerState?.currentSpec
                let stallThreshold = withLock { driveStallWindow.threshold(for: spec, at: ProcessInfo.processInfo.systemUptime) }
                cacheStallStart = startedAt
                cacheStallTimeoutInterval = stallThreshold
                DiagnosticLog.write("[MPV_CACHE_STALL] started threshold=\(stallThreshold)s")
                cacheStallTask?.cancel()
                cacheStallTask = Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(stallThreshold * 1_000_000_000))
                    } catch {
                        return
                    }
                    guard self.cacheStallStart == startedAt else { return }
                    self.notifyCacheStallIfNeeded()
                }
                return
            }
            notifyCacheStallIfNeeded()
        } else {
            let shouldNotifyRecovery = cacheStallNotified
            let recoveredSpec = playerState?.currentSpec
            if let started = cacheStallStart {
                let duration = Date().timeIntervalSince(started)
                DiagnosticLog.write("[MPV_CACHE_STALL] recovered durationSeconds=\(String(format: "%.3f", duration)) surface=\(videoSurface.rawValue) eligible=\(cacheStallEligible && !pauseRequested)")
                if cacheStallEligible, !pauseRequested,
                   recoveredSpec?.metadata["playback.kind"] != "live",
                   recoveredSpec?.drivePlaybackPlan != nil {
                    withLock { driveStallWindow.record(duration: duration, at: ProcessInfo.processInfo.systemUptime) }
                }
                if cacheStallEligible, !pauseRequested,
                   recoveredSpec?.metadata["playback.kind"] == "live",
                   withLock({ liveStallWindow.record(duration: duration, at: ProcessInfo.processInfo.systemUptime) }),
                   withLock({ liveReuseFailureObserved }) {
                    _ = requestLiveConnectionRepairIfNeeded()
                }
            }
            cacheStallStart = nil
            cacheStallTimeoutInterval = nil
            cacheStallTask?.cancel()
            cacheStallTask = nil
            cacheStallNotified = false
            playerState?.cacheBufferingProgress = nil
            if shouldNotifyRecovery {
                playbackStallRecoveryHandler?(recoveredSpec)
            }
        }
    }

    @MainActor
    private func notifyCacheStallIfNeeded() {
        let stallThreshold = cacheStallTimeoutInterval ?? MPVPlaybackActivityPolicy.cacheStallThreshold(for: playerState?.currentSpec)
        guard !cacheStallNotified,
              let cacheStallStart,
              Date().timeIntervalSince(cacheStallStart) >= stallThreshold else {
            return
        }
        cacheStallNotified = true
        let positionSeconds = Double(position) / 1000
        DiagnosticLog.write("[MPV_CACHE_STALL] threshold=\(stallThreshold)s position=\(positionSeconds)")
        if !requestLiveConnectionRepairIfNeeded(requiringExpiredStall: true) {
            playbackStallHandler?(playerState?.currentSpec, positionSeconds)
        }
    }

    @MainActor
    private func requestLiveConnectionRepairIfNeeded(requiringExpiredStall: Bool = false) -> Bool {
        guard cacheStallEligible, let spec = playerState?.currentSpec,
              !withLock({ pauseRequested }), playerState?.isSeeking == false,
              liveConnectionRepairHandler != nil,
              LivePlaybackBufferPolicy.shortConnectionSpec(from: spec) != nil else { return false }
        if requiringExpiredStall {
            guard playerState?.isBuffering == true, let started = cacheStallStart,
                  Date().timeIntervalSince(started) >= MPVPlaybackActivityPolicy.cacheStallThreshold(for: spec) else { return false }
        }
        let requested = withLock { () -> Bool in
            guard liveReuseFailureObserved, !liveConnectionRepairRequested else { return false }
            liveConnectionRepairRequested = true
            return true
        }
        guard requested else { return false }
        liveConnectionRepairHandler?(spec)
        return true
    }

    @MainActor
    private func updatePlaybackBackgroundBudget() {
        let state = withLock { () -> (PlaySpec?, Bool, Bool, Bool) in
            let active: Bool = switch status { case .idle, .error: false; default: true }
            return (activeSpec, pauseRequested, active, seekActivity.isPending)
        }
        guard let spec = state.0, !state.1, let playerState,
              PlaybackTransferPolicy.profile(for: spec).context.connection != .local,
              state.2 else {
            PlaybackBackgroundBudget.shared.remove(session: backgroundBudgetSession)
            return
        }
        PlaybackBackgroundBudget.shared.update(session: backgroundBudgetSession,
            bufferedAhead: playerState.bufferedUntil - playerState.position,
            isLoading: playerState.isMediaLoading, isSeeking: playerState.isSeeking || state.3,
            isBuffering: playerState.isBuffering)
    }

    private func setError(_ message: String, nativeError: Int32? = nil) {
        lock.lock()
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        status = .error(message)
        let failedSpec = activeSpec ?? pendingSpec
        let failedMediaID = seekActivity.owner.mediaID
        let shouldNotify = !playbackFailureNotified
        playbackFailureNotified = true
        let failure = MPVPlaybackFailure(message: message, nativeError: nativeError,
                                         httpStatus: lastHTTPFailureStatus, playbackStarted: playbackStartedNotified)
        lock.unlock()
        updateDisplaySleepPrevention()
        DiagnosticLog.write("[MPV_ERROR] errorKind=\(Self.diagnosticErrorKind(for: message)) \(message)")
        Task { @MainActor in
            guard self.withLock({ self.seekActivity.owner.mediaID == failedMediaID }) else { return }
            let current = self.playerState?.currentSpec
            if let failedSpec {
                guard current?.url == failedSpec.url,
                      current?.drivePlaybackSessionGeneration == failedSpec.drivePlaybackSessionGeneration,
                      current?.metadata[DrivePlaybackSessionController.attemptMetadataKey]
                        == failedSpec.metadata[DrivePlaybackSessionController.attemptMetadataKey],
                      current?.metadata["playback.sessionGeneration"] == failedSpec.metadata["playback.sessionGeneration"],
                      current?.metadata["live.sessionID"] == failedSpec.metadata["live.sessionID"] else { return }
            }
            self.playerState?.errorMessage = message
            self.playerState?.isPlaying = false
            self.clearPlaybackActivity()
            if shouldNotify {
                self.playbackFailureHandler?(failedSpec ?? current, message)
                self.playbackFailureDetailsHandler?(failedSpec ?? current, failure)
            }
        }
    }

    @MainActor
    private func markMediaReady() {
        cancelSeekTransferMetrics()
        playerState?.isMediaLoading = false
        playerState?.isSeeking = false
    }

    @MainActor
    private func clearPlaybackActivity() {
        PlaybackBackgroundBudget.shared.remove(session: backgroundBudgetSession)
        cancelSeekTransferMetrics()
        playerState?.bufferedUntil = 0
        playerState?.isMediaLoading = false
        playerState?.isSeeking = false
        playerState?.isBuffering = false
        playerState?.cacheSpeedBytesPerSecond = nil
        playerState?.cacheBufferingProgress = nil
    }

    @MainActor
    private func startSeekTransferMetrics(for url: String?) {
        cancelSeekTransferMetrics()
        guard let url else { return }
        seekTransferTask = Task { @MainActor [weak self] in
            guard let self,
                  let baseline = await ProxyServer.shared.remoteStreamBufferSnapshot(forLocalURL: url),
                  !Task.isCancelled else { return }
            playerState?.seekReceivedBytes = 0
            playerState?.seekTransferSpeedBytesPerSecond = 0
            var sampler = PlaybackTransferRateSampler(
                receivedBytes: baseline.receivedBytes,
                at: ProcessInfo.processInfo.systemUptime
            )
            var lastLoggedAt: TimeInterval = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
                guard let snapshot = await ProxyServer.shared.remoteStreamBufferSnapshot(forLocalURL: url),
                      !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let sample = sampler.sample(receivedBytes: snapshot.receivedBytes, at: now)
                playerState?.seekReceivedBytes = sample.receivedBytes
                playerState?.seekTransferSpeedBytesPerSecond = sample.bytesPerSecond
                if now - lastLoggedAt >= 2 {
                    DiagnosticLog.write("[MPV_SEEK_TRANSFER] receivedBytes=\(sample.receivedBytes) bytesPerSecond=\(sample.bytesPerSecond)")
                    lastLoggedAt = now
                }
            }
        }
    }

    @MainActor
    private func cancelSeekTransferMetrics() {
        seekTransferTask?.cancel()
        seekTransferTask = nil
        playerState?.seekReceivedBytes = nil
        playerState?.seekTransferSpeedBytesPerSecond = nil
    }

    private func updateDisplaySleepPrevention() {
        let enabled = withLock {
            if case .playing = status { return true }
            return false
        }
        guard displaySleepController.setPlaybackActive(enabled) else { return }
        DiagnosticLog.write(
            "[MPV_DISPLAY_SLEEP] prevented=\(enabled) surface=\(videoSurface.rawValue)"
        )
    }

    @MainActor
    private func markPlaybackStartedIfNeeded() {
        var shouldNotify = false
        var shouldMarkPlaying = false
        var acceptsStartEvent = false
        lock.lock()
        acceptsStartEvent = Self.acceptsPlaybackStartEvent(status: status)
        if acceptsStartEvent {
            startupWatchdogTask?.cancel()
            startupWatchdogTask = nil
            shouldMarkPlaying = Self.shouldMarkPlayingAfterStartEvent(status: status)
            if shouldMarkPlaying {
                status = .playing
            }
            if !playbackStartedNotified {
                playbackStartedNotified = true
                shouldNotify = true
            }
        }
        lock.unlock()

        guard acceptsStartEvent else { return }
        playerState?.errorMessage = nil
        if shouldMarkPlaying {
            playerState?.isPlaying = true
        }

        guard shouldNotify else { return }
        reapplySubtitleStyle(stage: "started")
        let spec = playerState?.currentSpec
        DiagnosticLog.write("[MPV_STARTED] url=\(Self.redactedURL(spec?.url ?? ""))")
        playbackStartedHandler?(spec)
    }

    static func acceptsPlaybackStartEvent(status: PlayerStatus) -> Bool {
        switch status {
        case .loading, .playing, .paused:
            return true
        case .idle, .error:
            return false
        }
    }

    static func shouldMarkPlayingAfterStartEvent(status: PlayerStatus) -> Bool {
        switch status {
        case .loading, .playing:
            return true
        case .idle, .paused, .error:
            return false
        }
    }

    static func shouldApplyEndFileState(
        reason: Int32,
        error _: Int32,
        status: PlayerStatus
    ) -> Bool {
        switch EndFileReason(rawValue: reason) {
        case .restarted, .redirect:
            return false
        case .stopped:
            if case .idle = status {
                return true
            }
            return false
        case .eof, .quit, .error, .none:
            return true
        }
    }

    static func shouldApplyPauseProperty(
        isPaused: Bool,
        status: PlayerStatus,
        pauseRequested: Bool
    ) -> Bool {
        guard isPaused == pauseRequested else { return false }
        switch status {
        case .loading, .playing, .paused:
            return true
        case .idle, .error:
            return false
        }
    }

    private func startLocalStreamStartupWatchdog(for spec: PlaySpec) {
        guard Self.isLocalStreamSpec(spec) || Self.isAutomaticOriginalStreamSpec(spec) else { return }
        let timeout = Self.localStreamStartupTimeout(for: spec)
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            self?.fireLocalStreamStartupWatchdog(for: spec)
        }
        lock.lock()
        startupWatchdogTask?.cancel()
        startupWatchdogTask = task
        lock.unlock()
    }

    private func cancelStartupWatchdog() {
        lock.lock()
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        lock.unlock()
    }

    private func fireLocalStreamStartupWatchdog(for spec: PlaySpec) {
        let state = withLock { () -> (Bool, Int64, Int64, Bool) in
            let alreadyFailed: Bool
            if case .error = status {
                alreadyFailed = true
            } else {
                alreadyFailed = false
            }
            return (playbackStartedNotified, lastPositionMs, lastDurationMs, alreadyFailed)
        }
        guard Self.shouldFireLocalStreamStartupWatchdog(
            spec: spec,
            playbackStarted: state.0,
            positionMilliseconds: state.1,
            durationMilliseconds: state.2,
            alreadyFailed: state.3
        ) else {
            return
        }
        let timeout = Int(Self.localStreamStartupTimeout(for: spec))
        let automaticOriginal = Self.isAutomaticOriginalStreamSpec(spec)
        DiagnosticLog.write("[MPV_STARTUP_TIMEOUT] timeoutSeconds=\(timeout) automaticOriginal=\(automaticOriginal)")
        let message = automaticOriginal
            ? L10n.text("原片启动超时，{0} 秒内未开始播放。", ["\(timeout)"])
            : L10n.text("本地视频流启动超时，原片在 {0} 秒内未返回可播放数据。", ["\(timeout)"])
        failLocalStreamStartupIfNeeded(message)
    }

    private func failLocalStreamStartupIfNeeded(_ message: String) {
        let shouldFail = withLock { () -> Bool in
            if playbackStartedNotified { return false }
            if case .error = status { return false }
            return true
        }
        guard shouldFail else { return }
        setError(message)
    }

    static func localStreamStartupFailure(
        logText: String,
        spec: PlaySpec?,
        playbackStarted: Bool
    ) -> String? {
        guard let spec, isLocalStreamSpec(spec), !playbackStarted else { return nil }
        let normalized = logText.lowercased()
        if normalized.contains("failed to seek when reading header element") {
            return L10n.text("本地视频流启动失败，原片尾部定位请求未能完成。")
        }
        return nil
    }

    static func shouldFireLocalStreamStartupWatchdog(
        spec: PlaySpec,
        playbackStarted: Bool,
        positionMilliseconds: Int64,
        durationMilliseconds: Int64,
        alreadyFailed: Bool
    ) -> Bool {
        guard !playbackStarted, !alreadyFailed else { return false }
        // The requested resume position and an early duration notification do
        // not prove that media has started. Automatic original routes must
        // still recover when no real playback-start notification arrives.
        if isAutomaticOriginalStreamSpec(spec) {
            return true
        }
        return isLocalStreamSpec(spec) && positionMilliseconds <= 0 && durationMilliseconds <= 0
    }

    static func localStreamStartupTimeout(for spec: PlaySpec) -> TimeInterval {
        if isAutomaticOriginalStreamSpec(spec) {
            return MPVPlaybackActivityPolicy.defaultCacheStallThreshold
        }
        let provider = spec.metadata[DrivePlaybackMetadataKey.provider]
        let route = spec.metadata[DrivePlaybackMetadataKey.route]
        if provider == DriveProvider.p115.rawValue && route == DrivePlaybackRoute.originalDownload {
            return 120
        }
        return defaultLocalStreamStartupTimeout
    }

    static func shouldCancelStartupWatchdogAfterDuration(for spec: PlaySpec?, seconds: Double) -> Bool {
        seconds > 0 && !(spec.map(isAutomaticOriginalStreamSpec) ?? false)
    }

    private static func isAutomaticOriginalStreamSpec(_ spec: PlaySpec) -> Bool {
        guard let scheme = URL(string: spec.url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return DrivePlaybackRoutePolicy.candidate(for: spec)?.kind == .original
            && DrivePlaybackFallbackPolicy.fallbackSpec(for: spec, positionSeconds: 0) != nil
    }

    private static func isLocalStreamSpec(_ spec: PlaySpec) -> Bool {
        guard let components = URLComponents(string: spec.url),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            return false
        }
        return components.path == "/stream" || components.path.hasPrefix("/stream/")
    }

    private func check(_ code: Int32, context: OpaquePointer, action: String) throws {
        guard code >= 0 else {
            throw MPVPlayerEngineError.command("\(action): \(Self.cString(nv_mpv_last_error(context)))")
        }
    }

    static func isSubtitleReplyUserdata(_ value: UInt64) -> Bool {
        value >= firstSubtitleReplyUserdata && value < externalAudioReplyUserdata
    }

    static func materializedSubtitleFile(
        for sub: Sub,
        directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL? {
        guard sub.url.lowercased().hasPrefix("data:") else { return nil }
        guard let comma = sub.url.firstIndex(of: ",") else {
            throw MPVPlayerEngineError.command(L10n.text("字幕 data URL 缺少内容分隔符"))
        }

        let descriptor = String(sub.url[sub.url.index(sub.url.startIndex, offsetBy: 5)..<comma])
        let payload = String(sub.url[sub.url.index(after: comma)...])
        let data: Data?
        if descriptor.lowercased().split(separator: ";").contains("base64") {
            data = Data(base64Encoded: payload)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, !data.isEmpty else {
            throw MPVPlayerEngineError.command(L10n.text("字幕 data URL 无法解码"))
        }

        let format = sub.format.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pathExtension = ["ass", "ssa", "srt", "vtt"].contains(format) ? format : "txt"
        let subtitleDirectory = directory.appendingPathComponent("NetVplayerSubtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: subtitleDirectory, withIntermediateDirectories: true)
        let fileURL = subtitleDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func preparedSubtitleSource(for sub: Sub, title: String) -> String? {
        if let source = withLock({ preparedSubtitleSources[sub.id] }) { return source }
        guard sub.url.lowercased().hasPrefix("data:") else {
            withLock { preparedSubtitleSources[sub.id] = sub.url }
            return sub.url
        }
        do {
            guard let fileURL = try Self.materializedSubtitleFile(for: sub) else { return sub.url }
            withLock {
                temporarySubtitleFiles.append(fileURL)
                preparedSubtitleSources[sub.id] = fileURL.path
            }
            DiagnosticLog.write("[MPV_SUBTITLE_MATERIALIZED] title=\(title) format=\(sub.format)")
            return fileURL.path
        } catch {
            DiagnosticLog.write("[MPV_SUBTITLE_ERROR] title=\(title) error=\(error.localizedDescription)")
            Task { @MainActor in
                self.playerState?.subtitleStatus = L10n.text("{0}加载失败", ["\(title)"])
            }
            return nil
        }
    }

    private static func removeTemporarySubtitleFiles(_ files: [URL]) {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func applyMPVOptions(_ plan: [String: MPVEffectiveOption], context: OpaquePointer, stage: String) throws {
        DiagnosticLog.write("[MPV_SUBTITLE_STYLE] stage=\(stage) \(Self.subtitleStyleDiagnostic(from: plan.mapValues(\.value)))")
        var diagnostics: [MPVOptionDiagnostic] = []
        for (name, option) in plan.sorted(by: { $0.key < $1.key }) {
            guard MPVOptionPolicy.accepts(name: name, value: option.value) else {
                diagnostics.append(.init(name: "<invalid>", origin: option.origin, status: .rejected))
                continue
            }
            // The option namespace avoids expanded/OSD property representations.
            let pointer = nv_mpv_copy_property_string(context, "options/" + name)
            let original = pointer.map { String(cString: $0) }
            if let pointer { nv_mpv_free_string(pointer) }
            guard let original else {
                diagnostics.append(.init(name: name, origin: option.origin, status: .rejected))
                DiagnosticLog.write("[MPV_OPTION_REJECTED] name=\(name) origin=\(option.origin.rawValue) reason=unavailable")
                continue
            }
            let code = nv_mpv_set_property_string(context, name, option.value)
            if code < 0 {
                diagnostics.append(.init(name: name, origin: option.origin, status: .rejected))
                DiagnosticLog.write("[MPV_OPTION_REJECTED] name=\(name) origin=\(option.origin.rawValue) code=\(code)")
                if option.origin != .source { try check(code, context: context, action: "apply managed option \(name)") }
                continue
            }
            mediaOptionDefaults[name] = original
            diagnostics.append(.init(name: name, origin: option.origin, status: .applied))
            DiagnosticLog.write("[MPV_OPTION_APPLIED] name=\(name) origin=\(option.origin.rawValue)")
        }
        let snapshot = Dictionary(diagnostics.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.name < $1.name }
        let owner = withLock { seekActivity.owner.mediaID }
        Task { @MainActor in
            guard self.withLock({ self.seekActivity.owner.mediaID == owner }) else { return }
            self.playerState?.mpvOptionDiagnostics = snapshot
        }
    }

    private func applyVideoAspectMode(_ mode: PlayerVideoAspectMode, context: OpaquePointer, stage: String) throws {
        try check(
            nv_mpv_set_property_string(context, "video-aspect-override", mode.mpvVideoAspectOverride),
            context: context,
            action: "set property video-aspect-override=\(mode.mpvVideoAspectOverride)"
        )
        try check(
            nv_mpv_set_property_double(context, "panscan", mode.mpvPanscan),
            context: context,
            action: "set property panscan=\(mode.mpvPanscan)"
        )
        DiagnosticLog.write("[MPV_ASPECT] stage=\(stage) mode=\(mode.rawValue) video-aspect-override=\(mode.mpvVideoAspectOverride) panscan=\(mode.mpvPanscan)")
    }

    private func reapplySubtitleStyle(stage: String) {
        lock.lock()
        let activeContext = context
        lock.unlock()
        guard let activeContext else { return }

        let options = PlayerSubtitlePolicy.mpvOptions(for: subtitleSettingsProvider(), trackFormat: withLock { currentSubtitleFormat })
        DiagnosticLog.write("[MPV_SUBTITLE_STYLE] stage=\(stage) \(Self.subtitleStyleDiagnostic(from: options))")
        for (name, value) in options.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            let code = nv_mpv_set_property_string(activeContext, name, value)
            if code < 0 {
                DiagnosticLog.write("[MPV_PROPERTY_ERROR] subtitle style \(name): \(Self.cString(nv_mpv_last_error(activeContext)))")
            }
        }
    }

    private func setStringProperty(_ name: String, value: String, label: String) {
        lock.lock()
        let activeContext = context
        lock.unlock()
        guard let activeContext else { return }
        let code = nv_mpv_set_property_string(activeContext, name, value)
        if code < 0 {
            DiagnosticLog.write("[MPV_PROPERTY_ERROR] \(label): \(Self.cString(nv_mpv_last_error(activeContext)))")
        }
    }

    @MainActor
    private func handleParsedTrackLog(_ parsed: MPVParsedTrackLog) {
        if withLock({ currentFileLoaded }) {
            refreshSubtitleTracks()
            return
        }
        switch parsed.track.kind {
        case .audio:
            playerState?.audioTracks = Self.upserting(parsed.track, into: playerState?.audioTracks ?? [])
            if parsed.isSelected {
                playerState?.selectedAudioTrackID = parsed.track.id
            }
        case .subtitle:
            playerState?.subtitleTracks = Self.upserting(parsed.track, into: playerState?.subtitleTracks ?? [])
            if parsed.isSelected {
                playerState?.selectedSubtitleTrackID = parsed.track.id
                withLock { currentSubtitleFormat = parsed.track.subtitleKind }
                reapplySubtitleStyle(stage: "track-detected")
            }
        }
        DiagnosticLog.write("[MPV_TRACK_DETECTED] kind=\(parsed.track.kind.rawValue) id=\(parsed.track.id) language=\(parsed.track.language) format=\(parsed.track.format) selected=\(parsed.isSelected)")
    }

    fileprivate func requestRender() {
        let shouldSchedule = withLock {
            renderRequestGate.request()
        }
        guard shouldSchedule else { return }
        scheduleRenderDisplay()
    }

    private func scheduleRenderDisplay() {
        DispatchQueue.main.async { [weak self] in
            self?.performScheduledRender()
        }
    }

    @MainActor
    private func performScheduledRender() {
        let state = withLock { () -> (Bool, MPVOpenGLVideoView?) in
            (renderRequestGate.prepareForDisplay(), renderView)
        }
        guard state.0 else { return }
        state.1?.displayOpenGL()
        let shouldScheduleFollowUp = withLock {
            renderRequestGate.completeDisplay()
        }
        if shouldScheduleFollowUp {
            scheduleRenderDisplay()
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func viewID(for view: NSView) -> Int64 {
        let pointer = Unmanaged.passUnretained(view).toOpaque()
        return Int64(bitPattern: UInt64(UInt(bitPattern: pointer)))
    }

    private static func headerFields(from headers: [String: String]) -> [String] {
        headers
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { item in
                item.key.caseInsensitiveCompare("Host") != .orderedSame
                    && item.key.caseInsensitiveCompare("Range") != .orderedSame
            }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
    }

    private static func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func subtitleTracks(from subs: [Sub]) -> [PlayerTrackInfo] {
        subs.map(trackInfo(from:))
    }

    private static func trackInfo(from sub: Sub) -> PlayerTrackInfo {
        PlayerTrackInfo(
            id: "external:\(sub.id)",
            kind: .subtitle,
            name: sub.name,
            language: sub.lang,
            format: sub.format,
            isExternal: true
        )
    }

    private static func upserting(_ track: PlayerTrackInfo, into tracks: [PlayerTrackInfo]) -> [PlayerTrackInfo] {
        var updated = tracks
        if let index = updated.firstIndex(where: { $0.id == track.id && $0.kind == track.kind }) {
            updated[index] = track
        } else {
            updated.append(track)
        }
        return updated
    }

    private static func drmStatus(for drm: Drm?) -> String? {
        guard let drm else { return nil }
        let type = drm.type.lowercased()
        if type.contains("widevine") {
            return L10n.text("Widevine DRM 已识别，但 macOS 首版暂不支持授权播放")
        }
        if type.contains("clearkey") || !drm.key.isEmpty {
            return L10n.text("ClearKey DRM 元数据已识别，播放兼容性取决于 mpv/源站")
        }
        return L10n.text("DRM 元数据已识别，类型：{0}", ["\(drm.type.isEmpty ? "未知" : drm.type)"])
    }

    static func diagnosticMessage(forMPVLog text: String, currentSpec: PlaySpec? = nil) -> String? {
        let lower = text.lowercased()
        if lower.contains("http error 500 internal server error") {
            return L10n.text("代理拉流失败：本地代理返回 500。请检查源站是否拒绝、代理规则是否直连，或切换到可用线路。")
        }
        if let status = httpFailureStatus(forMPVLog: text) {
            return L10n.text("媒体请求失败（HTTP {0}），请重新打开内容或切换线路。", [String(status)])
        }
        if lower.contains("httpproxy: stream ends prematurely")
            || lower.contains("error reading http response: end of file")
            || lower.contains("error reading http response: connection reset by peer")
            || lower.contains("tls: io error: end of file")
            || lower.contains("tls: io error: input/output error")
            || lower.contains("tls: io error: connection reset by peer")
            || lower.contains("unexpected_eof")
            || lower.contains("ssl_error")
            || lower.contains("secure connection") {
            return loadFailureDiagnostic(for: currentSpec)
        }
        if lower.contains("failed to open http://127.0.0.1")
            || lower.contains("failed to open http://localhost") {
            return L10n.text("代理拉流失败：本地代理没有成功打开上游地址。请切换线路或检查代理/网络设置。")
        }
        return nil
    }

    static func httpFailureStatus(forMPVLog text: String) -> Int? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = line.range(
            of: #"(?i)^(?:https?:\s*)?HTTP error [45][0-9]{2}(?=\s|$)"#,
            options: .regularExpression
        ) else { return nil }
        return Int(line[range].suffix(3))
    }

    public static func failureDiagnosticMeasurements(for message: String) -> [String: Int] {
        var result = ["failureKind": diagnosticErrorKind(for: message)]
        if let range = message.range(of: #"\bHTTP [45][0-9]{2}\b"#, options: .regularExpression),
           let status = Int(message[range].suffix(3)) {
            result["status"] = status
        }
        return result
    }

    static func diagnosticErrorKind(for message: String) -> Int {
        let normalized = message.lowercased()
        if normalized.contains(L10n.text("初始化失败").lowercased()) || normalized.contains("initialization") {
            return 1
        }
        if normalized.contains(L10n.text("本地视频流启动失败").lowercased())
            || normalized.contains("local video stream failed")
            || normalized.contains("range")
            || normalized.contains("failed to seek when reading header") {
            return 2
        }
        if normalized.contains(L10n.text("代理拉流失败").lowercased())
            || normalized.contains(L10n.text("relay 拉流失败").lowercased())
            || normalized.contains(L10n.text("直连媒体加载失败").lowercased())
            || normalized.contains("proxy streaming failed")
            || normalized.contains("relay streaming failed")
            || normalized.contains("direct media loading failed")
            || normalized.contains("http")
            || normalized.contains("tls")
            || normalized.contains("connection") {
            return 3
        }
        if normalized.contains(L10n.text("外部音轨").lowercased())
            || normalized.contains("external audio") {
            return 4
        }
        if normalized.contains("decode")
            || normalized.contains("demux")
            || normalized.contains("format")
            || normalized.contains(L10n.text("解码").lowercased())
            || normalized.contains(L10n.text("格式").lowercased()) {
            return 5
        }
        if normalized.contains(L10n.text("事件错误").lowercased())
            || normalized.contains("event error") {
            return 6
        }
        return 0
    }

    private static func loadFailureDiagnostic(for spec: PlaySpec?) -> String {
        let transport = spec?.metadata[LiveHLSRelayPolicy.transportMetadataKey] ?? ""
        switch transport {
        case LiveHLSRelayPolicy.localRelayTransport:
            return L10n.text("本地 HLS relay 拉流失败：上游连接被中断或分片请求失败，请切换线路。")
        case LiveHLSRelayPolicy.localStreamRelayTransport:
            return L10n.text("本地 stream relay 拉流失败：上游连接被中断或不支持分段转发，请切换线路。")
        default:
            break
        }

        if let spec, PlaybackProxyPolicy.bypassReason(for: spec) == .directHLS {
            return L10n.text("直播 HLS 直连加载失败：源站连接被中断，通常是网络路径、源站防护或签名失效导致。已允许本地 relay 兜底。")
        }
        if let spec, PlaybackProxyPolicy.bypassReason(for: spec) == .directMedia {
            return L10n.text("直播媒体直连加载失败：源站连接被中断，通常是网络路径、源站防护或格式不稳定导致。已允许本地 stream relay 兜底。")
        }
        return L10n.text("直连媒体加载失败：源站连接被中断，请切换线路或检查网络。")
    }

    private static let networkDiagnosticsEnabled = ProcessInfo.processInfo.environment["NETVPLAYER_MPV_NETWORK_DIAGNOSTICS"] == "1"

    static func networkDiagnostic(_ text: String) -> String? {
        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let allowedHeaders: Set<String> = ["host", "user-agent", "referer", "range", "connection", "accept", "icy-metadata"]
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if let first = lines.first, let marker = first.range(of: ": request: ") {
            let request = first[marker.upperBound...].split(separator: " ")
            guard request.count == 3, ["GET", "HEAD", "CONNECT"].contains(String(request[0])) else { return nil }
            let headers = lines.dropFirst().compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = line[..<colon].lowercased()
                guard allowedHeaders.contains(name) else { return nil }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return "\(name)=\(digest(value))"
            }
            return "method=\(request[0]) target=\(digest(String(request[1]))) headers=[\(headers.joined(separator: ","))]"
        }
        if lines.count == 1, let colon = text.firstIndex(of: ":") {
            let name = text[..<colon].lowercased()
            if allowedHeaders.contains(name) {
                let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                return "header \(name)=\(digest(value))"
            }
        }
        if let range = text.range(of: #"(?:https|http|httpproxy): header='HTTP/[0-9.]+ [0-9]{3}"#, options: .regularExpression) {
            return String(text[range])
        }
        return nil
    }

    private static func shouldWriteMPVLog(level: String?, parsedTrack: MPVParsedTrackLog?) -> Bool {
        if parsedTrack != nil { return true }
        switch level?.lowercased() {
        case "warn", "error", "fatal":
            return true
        default:
            return false
        }
    }

    private static func cString(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer)
    }

    private static func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, item in
            if item.key.caseInsensitiveCompare("Cookie") == .orderedSame
                || item.key.caseInsensitiveCompare("Authorization") == .orderedSame {
                result[item.key] = "<redacted>"
            } else {
                result[item.key] = item.value
            }
        }
    }

    private static func redactedMPVOptions(_ options: [String: String]) -> [String: String] {
        options.reduce(into: [:]) { result, item in
            result[item.key] = redactedLogText(item.value)
        }
    }

    private static func subtitleStyleDiagnostic(from options: [String: String]) -> [String: String] {
        let keys = [
            "sub-ass-override",
            "secondary-sub-ass-override",
            "sub-font-size",
            "sub-scale",
            "sub-scale-by-window",
            "sub-scale-with-window",
            "sub-pos",
            "sub-use-margins",
            "sub-ass-force-margins",
            "sub-ass-use-video-data",
            "secondary-sid",
            "secondary-sub-visibility"
        ]
        return keys.reduce(into: [:]) { result, key in
            if let value = options[key] {
                result[key] = value
            }
        }
    }

    private static func redactedHeaderField(_ header: String) -> String {
        guard let colon = header.firstIndex(of: ":") else { return header }
        let name = String(header[..<colon])
        if name.caseInsensitiveCompare("Cookie") == .orderedSame
            || name.caseInsensitiveCompare("Authorization") == .orderedSame {
            return "\(name): <redacted>"
        }
        return header
    }

    static func redactedURL(_ url: String) -> String {
        let url = XtreamLogRedaction.redact(url)
        if url.lowercased().hasPrefix("data:"),
           let separator = url.firstIndex(of: ",") {
            let descriptor = url[..<separator]
            let payloadLength = url.distance(from: url.index(after: separator), to: url.endIndex)
            return "\(descriptor),<redacted \(payloadLength) chars>"
        }
        guard var components = URLComponents(string: url) else { return url }
        components.queryItems = components.queryItems?.map { item in
            switch item.name.lowercased() {
            case "auth_key", "token", "signature", "ut", "ct", "ork", "ud", "dfi", "sp", "mt",
                 "ossaccesskeyid", "callback", "callback-var", "h64", "u64", "security-token",
                 "x-oss-access-key-id", "x-oss-credential", "x-oss-security-token", "x-oss-signature",
                 "upsig", "sign", "trid", "traceid", "e", "oi", "mid", "buvid", "qn_dyeid":
                return URLQueryItem(name: item.name, value: "<redacted>")
            default:
                return item
            }
        }
        return components.string ?? url
    }

    static func redactedLogText(_ text: String) -> String {
        var value = XtreamLogRedaction.redact(text)
        let replacements = [
            (#"(?i)Cookie:\s*[^\r\n]+"#, "Cookie: <redacted>"),
            (#"(?i)Authorization:\s*[^\r\n]+"#, "Authorization: <redacted>"),
            (#"(?i)(auth_key|token|signature|ct|ork|ud|dfi|sp|mt|ossaccesskeyid|callback|callback-var|h64|u64|security-token|x-oss-access-key-id|x-oss-credential|x-oss-security-token|x-oss-signature|upsig|sign|trid|traceid|e|oi|mid|buvid|qn_dyeid)=([^&\s]+)"#, "$1=<redacted>")
        ]
        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return value
    }
}

extension MPVPlayerEngine {
    @MainActor
    static func runLifecycleBenchmark(
        mediaURL: URL,
        rounds: Int = 5,
        postStopDelay: Duration = .milliseconds(500),
        longRSSDelay: Duration = .seconds(60)
    ) async throws -> MPVLifecycleBenchmarkReport {
        guard rounds >= 5 else {
            throw MPVPlayerEngineError.initialization(L10n.text("生命周期基准至少需要 5 轮"))
        }
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw MPVPlayerEngineError.initialization(L10n.text("生命周期基准媒体不存在: {0}", ["\(mediaURL.path)"]))
        }

        var samples: [MPVLifecycleBenchmarkSample] = []
        let spec = PlaySpec(url: mediaURL.absoluteString, title: "Lifecycle benchmark")
        for policy in [MPVStopResourcePolicy.fullDestroy, .warmStop] {
            let engine = MPVPlayerEngine(videoSurface: .vod, stopResourcePolicy: policy)
            let playerState = PlayerState()
            engine.playerState = playerState
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            guard let view = MPVOpenGLVideoView(engine: engine, surface: .vod) else {
                throw MPVPlayerEngineError.initialization(L10n.text("生命周期基准无法创建 OpenGL 播放面"))
            }
            view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
            window.contentView = view
            window.orderFrontRegardless()
            view.makeOpenGLContextCurrent()
            try engine.ensureContext()
            try engine.ensureRenderContext()

            for round in 1...rounds {
                var firstFrameAt: ContinuousClock.Instant?
                let clock = ContinuousClock()
                engine.playbackStartedHandler = { _ in
                    firstFrameAt = firstFrameAt ?? clock.now
                }
                let playbackStart = clock.now
                await engine.play(spec: spec)
                while firstFrameAt == nil,
                      clock.now - playbackStart < .seconds(10) {
                    try await Task.sleep(for: .milliseconds(50))
                }
                let firstFrameMilliseconds = firstFrameAt.map {
                    Double(playbackStart.duration(to: $0).components.attoseconds) / 1e15
                        + Double(playbackStart.duration(to: $0).components.seconds) * 1_000
                }

                let stopStart = clock.now
                engine.stop()
                let stopMilliseconds = Double(
                    stopStart.duration(to: clock.now).components.seconds
                ) * 1_000 + Double(
                    stopStart.duration(to: clock.now).components.attoseconds
                ) / 1e15
                try await Task.sleep(for: postStopDelay)
                let rssAfterStopBytes = residentMemoryBytes()

                var rssAfterSixtySecondsBytes: UInt64?
                if round == rounds {
                    try await Task.sleep(for: longRSSDelay)
                    rssAfterSixtySecondsBytes = residentMemoryBytes()
                }

                let rebuildStart = clock.now
                view.makeOpenGLContextCurrent()
                try engine.ensureContext()
                try engine.ensureRenderContext()
                let rebuildMilliseconds = Double(
                    rebuildStart.duration(to: clock.now).components.seconds
                ) * 1_000 + Double(
                    rebuildStart.duration(to: clock.now).components.attoseconds
                ) / 1e15
                samples.append(
                    MPVLifecycleBenchmarkSample(
                        policy: policy.rawValue,
                        round: round,
                        firstFrameMilliseconds: firstFrameMilliseconds,
                        stopMilliseconds: stopMilliseconds,
                        rebuildMilliseconds: rebuildMilliseconds,
                        rssAfterStopBytes: rssAfterStopBytes,
                        rssAfterSixtySecondsBytes: rssAfterSixtySecondsBytes
                    )
                )
            }
            engine.stop()
            engine.detach(from: view)
            window.orderOut(nil)
        }
        return MPVLifecycleBenchmarkReport(
            mediaPath: mediaURL.path,
            rounds: rounds,
            samples: samples
        )
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

private enum MPVPlayerEngineError: Error, LocalizedError {
    case initialization(String)
    case command(String)

    var errorDescription: String? {
        switch self {
        case .initialization(let message), .command(let message):
            return message
        }
    }
}

private struct MPVEventSnapshot: Sendable {
    let owner: PlaybackEventOwner
    let eventID: Int32
    let error: Int32
    let replyUserdata: UInt64
    let endFileError: Int32
    let endFileReason: Int32
    let propertyName: String
    let errorString: String?
    let logPrefix: String?
    let logLevel: String?
    let logText: String?
    let doubleValue: Double
    let flagValue: Int32
    let int64Value: Int64
    let hasPropertyValue: Bool

    init(_ event: NVMPVEvent, owner: PlaybackEventOwner) {
        self.owner = owner
        eventID = event.event_id
        error = event.error
        replyUserdata = event.reply_userdata
        endFileError = event.end_file_error
        endFileReason = event.end_file_reason
        propertyName = event.property_name.map { String(cString: $0) } ?? ""
        errorString = event.error_string.map { String(cString: $0) }
        logPrefix = event.log_prefix.map { String(cString: $0) }
        logLevel = event.log_level.map { String(cString: $0) }
        logText = event.log_text.map { String(cString: $0) }
        doubleValue = event.double_value
        flagValue = event.flag_value
        int64Value = event.int64_value
        hasPropertyValue = event.format != 0
    }
}
