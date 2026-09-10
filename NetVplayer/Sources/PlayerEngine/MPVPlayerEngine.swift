// PlayerEngine/MPVPlayerEngine.swift
// 内嵌 libmpv 播放引擎，主要用于网盘大文件点播。

import AppKit
import Darwin
import DriveEngine
import Foundation
import Models
import MPVShim

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
        return drivePlaybackCacheStallThreshold
    }
}

struct MPVPlaybackLoadEventTracker {
    private(set) var hasActiveLoad = false
    private(set) var expectsReplacedEndFile = false

    mutating func prepareForLoad() {
        expectsReplacedEndFile = hasActiveLoad
    }

    mutating func markLoadIssued() {
        hasActiveLoad = true
    }

    mutating func cancelPreparedLoad() {
        expectsReplacedEndFile = false
    }

    mutating func markFileLoaded() {
        expectsReplacedEndFile = false
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
    }
}

public final class MPVPlayerEngine: @unchecked Sendable {
    public static let vod = MPVPlayerEngine(videoSurface: .vod)
    public static let live = MPVPlayerEngine(videoSurface: .live)

    /// Compatibility alias for call sites that have not yet declared a playback kind.
    public static var shared: MPVPlayerEngine { vod }

    public let videoSurface: MPVVideoSurface
    public let stopResourcePolicy: MPVStopResourcePolicy

    public var playerState: PlayerState?
    public var playbackFailureHandler: ((PlaySpec?, String) -> Void)?
    public var playbackStartedHandler: ((PlaySpec?) -> Void)?
    public var playbackPositionHandler: ((PlaySpec?, Double) -> Void)?
    public var playbackEndedHandler: ((PlaySpec?) -> Void)?
    public var playbackStallHandler: ((PlaySpec?, Double) -> Void)?
    public var playbackStallRecoveryHandler: ((PlaySpec?) -> Void)?
    public var subtitleSettingsProvider: @Sendable () -> SubtitleRenderSettings = { SubtitleRenderSettings() }

    public private(set) var status: PlayerStatus = .idle

    private let lock = NSLock()
    private let contextCreationLock = NSLock()
    private var context: OpaquePointer?
    private var eventTask: Task<Void, Never>?
    private var attachedViewID: Int64?
    private weak var renderView: MPVOpenGLVideoView?
    private var pendingSpec: PlaySpec?
    private var currentSpeed: Float = 1.0
    private var currentVolume: Float = 1.0
    private var currentVideoAspectMode: PlayerVideoAspectMode = .fit
    private var lastPositionMs: Int64 = 0
    private var lastDurationMs: Int64 = 0
    private var lastLoadDiagnostic: String?
    private var playbackStartedNotified = false
    private var currentFileLoaded = false
    private var loadEventTracker = MPVPlaybackLoadEventTracker()
    private var pauseRequested = false
    private var isPausedForCache = false
    private var postSeekEndGuard = PlaybackPostSeekEndGuard()
    private var cacheStallStart: Date?
    private var cacheStallTask: Task<Void, Never>?
    private var cacheStallNotified = false
    private var startupWatchdogTask: Task<Void, Never>?
    private var renderRequestGate = MPVRenderRequestGate()
    private var pendingExternalAudioURL: String?
    private var temporarySubtitleFiles: [URL] = []
    private static let defaultLocalStreamStartupTimeout: TimeInterval = 60
    private static let loadFileReplyUserdata: UInt64 = 1
    private static let firstSubtitleReplyUserdata: UInt64 = 2
    private static let externalAudioReplyUserdata: UInt64 = 10_000
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

    private init(
        videoSurface: MPVVideoSurface,
        stopResourcePolicy: MPVStopResourcePolicy = .configured()
    ) {
        self.videoSurface = videoSurface
        self.stopResourcePolicy = stopResourcePolicy
    }

    deinit {
        eventTask?.cancel()
        startupWatchdogTask?.cancel()
        Self.removeTemporarySubtitleFiles(temporarySubtitleFiles)
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
            setError("libmpv 初始化失败: \(error.localizedDescription)")
        }
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
        DiagnosticLog.write("[MPV_PLAY] url=\(Self.redactedURL(spec.url)), headers=\(Self.redactedHeaders(spec.headers)), mpvOptions=\(Self.redactedMPVOptions(spec.mpvOptions)), title=\(spec.title)")

        let aspectMode = withLock { currentVideoAspectMode }
        let didPrepareState = await MainActor.run { () -> Bool in
            guard self.withLock({
                Self.acceptsVideoSurfaceAttachment(
                    activeSurface: self.videoSurface,
                    requestedSurface: requestedSurface
                )
            }) else { return false }
            playerState?.currentSpec = spec
            playerState?.errorMessage = nil
            playerState?.isPlaying = false
            playerState?.position = 0
            playerState?.duration = 0
            playerState?.bufferedUntil = 0
            playerState?.isMediaLoading = true
            playerState?.isBuffering = false
            playerState?.cacheSpeedBytesPerSecond = nil
            playerState?.cacheBufferingProgress = nil
            playerState?.videoAspectMode = aspectMode
            playerState?.audioTracks = []
            playerState?.subtitleTracks = Self.subtitleTracks(from: spec.subs)
            playerState?.selectedAudioTrackID = nil
            playerState?.selectedSubtitleTrackID = nil
            playerState?.subtitleStatus = spec.subs.isEmpty ? nil : "发现 \(spec.subs.count) 条外挂字幕"
            playerState?.drivePlaybackStatus = DrivePlaybackDisplayPolicy.statusText(for: spec)
            playerState?.drmStatus = Self.drmStatus(for: spec.drm)
            if spec.danmakuAttachment != nil {
                playerState?.danmakuStatus = "弹幕缓存已附加"
            } else {
                playerState?.danmakuStatus = spec.danmaku.isEmpty ? nil : "弹幕源已识别，等待手动搜索"
            }
            return true
        }
        guard didPrepareState else { return }
        let didResetPlaybackState = withLock { () -> Bool in
            guard Self.acceptsVideoSurfaceAttachment(
                activeSurface: videoSurface,
                requestedSurface: requestedSurface
            ) else { return false }
            lastLoadDiagnostic = nil
            playbackStartedNotified = false
            currentFileLoaded = false
            pauseRequested = false
            isPausedForCache = false
            postSeekEndGuard.reset()
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
                self.withLock {
                    self.loadEventTracker.prepareForLoad()
                }
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
            setError("mpv 播放失败: \(error.localizedDescription)")
        }
    }

    public func pause() {
        lock.lock()
        let activeContext = context
        pauseRequested = true
        status = .paused
        cacheStallStart = nil
        cacheStallTask?.cancel()
        cacheStallTask = nil
        lock.unlock()

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

        if let activeContext {
            nv_mpv_set_property_flag(activeContext, "pause", 0)
        }
        Task { @MainActor in
            self.playerState?.isPlaying = true
        }
    }

    public func seek(to position: Int64) {
        lock.lock()
        let activeContext = context
        let durationSeconds = lastDurationMs > 0 ? Double(lastDurationMs) / 1000 : 0
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
            postSeekEndGuard.begin(targetSeconds: seconds)
        }
        let result = nv_mpv_command3(activeContext, "seek", "\(seconds)", "absolute+exact")
        guard result >= 0 else {
            withLock {
                postSeekEndGuard.reset()
            }
            DiagnosticLog.write("[MPV_SEEK_ERROR] targetSeconds=\(seconds) code=\(result)")
            return
        }
        DiagnosticLog.write("[MPV_SEEK] targetSeconds=\(seconds)")
    }

    public func stop() {
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
        let subtitleFiles = temporarySubtitleFiles
        temporarySubtitleFiles = []
        pendingExternalAudioURL = nil
        pendingSpec = nil
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
        cacheStallStart = nil
        cacheStallTask?.cancel()
        cacheStallTask = nil
        cacheStallNotified = false
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        lock.unlock()

        if let activeContext {
            nv_mpv_command1(activeContext, "stop")
            if stopResourcePolicy == .fullDestroy {
                retiredEventTask?.cancel()
                retireContext(
                    activeContext,
                    eventTask: retiredEventTask,
                    renderView: retiredRenderView
                )
            }
        }
        Self.removeTemporarySubtitleFiles(subtitleFiles)
        Task { @MainActor in
            self.playerState?.currentSpec = nil
            self.playerState?.errorMessage = nil
            self.playerState?.isPlaying = false
            self.playerState?.position = 0
            self.playerState?.duration = 0
            self.playerState?.bufferedUntil = 0
            self.playerState?.isMediaLoading = false
            self.playerState?.isBuffering = false
            self.playerState?.cacheSpeedBytesPerSecond = nil
            self.playerState?.cacheBufferingProgress = nil
            self.playerState?.audioTracks = []
            self.playerState?.subtitleTracks = []
            self.playerState?.selectedAudioTrackID = nil
            self.playerState?.selectedSubtitleTrackID = nil
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
    ) {
        let contextValue = UInt(bitPattern: context)
        Task { @MainActor in
            guard let retiredContext = OpaquePointer(bitPattern: contextValue) else { return }
            renderView?.makeOpenGLContextCurrent()
            _ = nv_mpv_free_render_context(retiredContext)
            await eventTask?.value
            nv_mpv_destroy(retiredContext)
            DiagnosticLog.write("[MPV_DESTROY] surface=\(self.videoSurface.rawValue) policy=\(self.stopResourcePolicy.rawValue)")
        }
    }

    public func setVolume(_ volume: Float) {
        lock.lock()
        currentVolume = volume
        let activeContext = context
        lock.unlock()

        if let activeContext {
            nv_mpv_set_property_double(activeContext, "volume", Double(volume * 100))
        }
        Task { @MainActor in
            self.playerState?.volume = volume
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

    public func selectSubtitleTrack(id: String) {
        setStringProperty("sid", value: id, label: "select subtitle track")
        reapplySubtitleStyle(stage: "select")
        Task { @MainActor in
            self.playerState?.selectedSubtitleTrackID = id
            self.playerState?.subtitleStatus = id == "no" ? "字幕已关闭" : "已选择字幕 \(id)"
        }
        DiagnosticLog.write("[MPV_TRACK] selected subtitle id=\(id)")
    }

    public func disableSubtitle() {
        selectSubtitleTrack(id: "no")
    }

    public func loadExternalSubtitle(_ sub: Sub, select: Bool = true) {
        lock.lock()
        let activeContext = context
        lock.unlock()
        guard let activeContext, !sub.url.isEmpty else { return }

        let title = sub.name.isEmpty ? (URL(string: sub.url)?.lastPathComponent ?? "外挂字幕") : sub.name
        guard let source = preparedSubtitleSource(for: sub, title: title) else { return }
        let code = nv_mpv_command4(activeContext, "sub-add", source, select ? "select" : "auto", title)
        if code < 0 {
            let message = "加载外挂字幕失败: \(Self.cString(nv_mpv_last_error(activeContext)))"
            DiagnosticLog.write("[MPV_SUBTITLE_ERROR] \(message)")
            Task { @MainActor in
                self.playerState?.subtitleStatus = message
            }
            return
        }

        let trackID = "external:\(sub.id)"
        Task { @MainActor in
            if self.playerState?.subtitleTracks.contains(where: { $0.id == trackID }) == false {
                self.playerState?.subtitleTracks.append(Self.trackInfo(from: sub))
            }
            if select {
                self.playerState?.selectedSubtitleTrackID = trackID
            }
            self.playerState?.subtitleStatus = "已加载外挂字幕：\(title)"
        }
        DiagnosticLog.write("[MPV_SUBTITLE] loaded=\(Self.redactedURL(sub.url)) select=\(select)")
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
            throw MPVPlayerEngineError.initialization("无法创建 libmpv context")
        }
        guard !Self.cString(nv_mpv_loaded_library_path(created)).isEmpty else {
            let message = Self.cString(nv_mpv_last_error(created))
            nv_mpv_destroy(created)
            throw MPVPlayerEngineError.initialization(message)
        }

        try check(nv_mpv_set_option_string(created, "terminal", "no"), context: created, action: "set option terminal=no")
        try check(nv_mpv_set_option_string(created, "msg-level", "all=info"), context: created, action: "set option msg-level=all=info")
        try check(nv_mpv_set_option_string(created, "idle", "yes"), context: created, action: "set option idle=yes")
        try check(nv_mpv_set_option_string(created, "keep-open", "no"), context: created, action: "set option keep-open=no")
        try check(nv_mpv_set_option_string(created, "osc", "no"), context: created, action: "set option osc=no")
        try check(nv_mpv_set_option_string(created, "ytdl", "no"), context: created, action: "set option ytdl=no")
        try check(nv_mpv_set_option_string(created, "input-default-bindings", "no"), context: created, action: "set option input-default-bindings=no")
        try check(nv_mpv_set_option_string(created, "input-vo-keyboard", "no"), context: created, action: "set option input-vo-keyboard=no")
        try check(nv_mpv_set_option_string(created, "hwdec", "videotoolbox-copy"), context: created, action: "set option hwdec=videotoolbox-copy")
        try check(nv_mpv_set_option_string(created, "vo", "libmpv"), context: created, action: "set option vo=libmpv")
        try check(nv_mpv_request_log_messages(created, "info"), context: created, action: "request mpv logs")
        try check(nv_mpv_initialize(created), context: created, action: "initialize libmpv")
        try check(nv_mpv_observe_double(created, 1, "time-pos"), context: created, action: "observe time-pos")
        try check(nv_mpv_observe_double(created, 2, "duration"), context: created, action: "observe duration")
        try check(nv_mpv_observe_flag(created, 3, "pause"), context: created, action: "observe pause")
        try check(nv_mpv_observe_flag(created, 4, "paused-for-cache"), context: created, action: "observe paused-for-cache")
        try check(nv_mpv_observe_double(created, 5, "demuxer-cache-time"), context: created, action: "observe demuxer-cache-time")
        try check(nv_mpv_observe_int64(created, 6, "cache-speed"), context: created, action: "observe cache-speed")
        try check(nv_mpv_observe_int64(created, 7, "cache-buffering-state"), context: created, action: "observe cache-buffering-state")

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
            throw MPVPlayerEngineError.initialization("libmpv context 尚未初始化")
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
            throw MPVPlayerEngineError.initialization("libmpv context 尚未初始化")
        }

        try check(nv_mpv_free_render_context(activeContext), context: activeContext, action: "free libmpv render context")
        try ensureRenderContext()
        DiagnosticLog.write("[MPV_RENDER_RESET] render context rebuilt before loadfile")
    }

    private func load(spec: PlaySpec) throws {
        lock.lock()
        let activeContext = context
        let staleSubtitleFiles = temporarySubtitleFiles
        temporarySubtitleFiles = []
        lock.unlock()
        Self.removeTemporarySubtitleFiles(staleSubtitleFiles)
        guard let activeContext else {
            throw MPVPlayerEngineError.initialization("libmpv context 尚未初始化")
        }

        try check(nv_mpv_clear_http_headers(activeContext), context: activeContext, action: "clear http-header-fields")
        let userAgent = Self.headerValue(named: "User-Agent", in: spec.headers) ?? PlaybackProxyPolicy.defaultHTTPUserAgent
        let referrer = Self.headerValue(named: "Referer", in: spec.headers) ?? ""
        try check(nv_mpv_set_property_string(activeContext, "user-agent", userAgent), context: activeContext, action: "set property user-agent")
        try check(nv_mpv_set_property_string(activeContext, "referrer", referrer), context: activeContext, action: "set property referrer")

        resetStringProperty("demuxer-lavf-format", context: activeContext)
        resetStringProperty("demuxer-lavf-o", context: activeContext)
        resetStringProperty("stream-lavf-o", context: activeContext)
        resetStringProperty("http-proxy", context: activeContext)
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
        if !spec.artwork.isEmpty {
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
        let mpvOptions = PlayerSubtitlePolicy.mergedMPVOptions(
            sourceOptions: spec.mpvOptions,
            settings: subtitleSettingsProvider()
        )
        try applyMPVOptions(mpvOptions, context: activeContext, stage: "load")

        for header in Self.headerFields(from: spec.headers) {
            try check(nv_mpv_append_http_header(activeContext, header), context: activeContext, action: "append http header \(Self.redactedHeaderField(header))")
        }
        try check(nv_mpv_set_property_double(activeContext, "speed", Double(currentSpeed)), context: activeContext, action: "set property speed")
        try check(nv_mpv_set_property_double(activeContext, "volume", Double(currentVolume * 100)), context: activeContext, action: "set property volume")
        try check(nv_mpv_set_property_flag(activeContext, "pause", 0), context: activeContext, action: "set property pause=no")
        try applyVideoAspectMode(currentVideoAspectMode, context: activeContext, stage: "load")
        withLock {
            pendingExternalAudioURL = spec.externalAudioURL.isEmpty ? nil : spec.externalAudioURL
        }
        try check(
            nv_mpv_command3_async(activeContext, Self.loadFileReplyUserdata, "loadfile", spec.url, "replace"),
            context: activeContext,
            action: "loadfile async"
        )
        for (index, sub) in spec.subs.enumerated() where !sub.url.isEmpty {
            let title = sub.name.isEmpty ? "外挂字幕 \(index + 1)" : sub.name
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
                    self.playerState?.subtitleStatus = "\(title)加载失败"
                }
            }
        }
    }

    private func startEventLoop(context: OpaquePointer) {
        eventTask?.cancel()
        let contextValue = UInt(bitPattern: context)
        eventTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let activeContext = OpaquePointer(bitPattern: contextValue) else { return }
            while !Task.isCancelled {
                var event = NVMPVEvent()
                let code = nv_mpv_wait_event(activeContext, 0.1, &event)
                guard code == 0 else { continue }
                guard !Task.isCancelled,
                      let self,
                      self.withLock({ self.context == activeContext }) else {
                    break
                }
                let snapshot = MPVEventSnapshot(event)
                await self.handle(event: snapshot)
            }
        }
    }

    @MainActor
    private func handle(event: MPVEventSnapshot) {
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
            if disposition == .failed {
                let diagnostic = withLock { lastLoadDiagnostic }
                setError(diagnostic ?? "mpv 播放结束但返回错误: \(event.errorString ?? "unknown")")
            } else {
                withLock {
                    status = .idle
                }
                playerState?.isPlaying = false
                clearPlaybackActivity()
                if disposition == .natural {
                    playbackEndedHandler?(spec)
                }
            }
        case 2:
            guard let text = event.logText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
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
                       message.contains("loading failed") || message.contains("mpv 播放结束但返回错误") {
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
                    "外部音轨"
                )
                if code < 0 {
                    DiagnosticLog.write("[MPV_AUDIO_ERROR] \(Self.cString(nv_mpv_last_error(activeContext)))")
                } else {
                    DiagnosticLog.write("[MPV_AUDIO] attached external track: \(Self.redactedURL(audioURL))")
                }
            }
        case Self.commandReplyEventID:
            guard event.error < 0 else { return }
            let errorText = event.errorString ?? "unknown"
            if Self.isSubtitleReplyUserdata(event.replyUserdata) {
                let subtitleIndex = Int(event.replyUserdata - Self.firstSubtitleReplyUserdata)
                let subtitle = playerState?.currentSpec?.subs.indices.contains(subtitleIndex) == true
                    ? playerState?.currentSpec?.subs[subtitleIndex]
                    : nil
                let title = subtitle.flatMap { $0.name.isEmpty ? nil : $0.name } ?? "外挂字幕"
                playerState?.subtitleStatus = "\(title)加载失败"
                DiagnosticLog.write("[MPV_SUBTITLE_ERROR] reply=\(event.replyUserdata) title=\(title) error=\(errorText)")
                return
            }
            if event.replyUserdata == Self.externalAudioReplyUserdata {
                setError("mpv 外部音轨加载失败: \(errorText)")
            } else {
                setError("mpv 事件错误: \(errorText)")
            }
        case MPVPlaybackActivityPolicy.playbackRestartEventID:
            withLock {
                postSeekEndGuard.markPlaybackRestarted()
            }
        case MPVPlaybackActivityPolicy.propertyChangeEventID:
            handlePropertyChange(event)
        default:
            if event.error < 0 {
                setError("mpv 事件错误: \(event.errorString ?? "unknown")")
            }
        }
    }

    @MainActor
    private func handlePropertyChange(_ event: MPVEventSnapshot) {
        switch event.propertyName {
        case "time-pos":
            guard event.doubleValue.isFinite else { return }
            guard MPVPlaybackActivityPolicy.shouldAcceptTimePosition(
                isCurrentFileLoaded: withLock { currentFileLoaded }
            ) else {
                DiagnosticLog.write("[MPV_STALE_TIME_POS_IGNORED] waiting for current FILE_LOADED")
                return
            }
            let seconds = max(0, event.doubleValue)
            lock.lock()
            lastPositionMs = Int64(seconds * 1000)
            postSeekEndGuard.observePosition(seconds)
            lock.unlock()
            playerState?.position = seconds
            playbackPositionHandler?(playerState?.currentSpec, seconds)
            if MPVPlaybackActivityPolicy.shouldEndMediaLoading(
                eventID: MPVPlaybackActivityPolicy.propertyChangeEventID,
                positionSeconds: seconds
            ) {
                cancelStartupWatchdog()
                markPlaybackStartedIfNeeded()
                markMediaReady()
            }
        case "duration":
            guard event.doubleValue.isFinite else { return }
            let seconds = max(0, event.doubleValue)
            lock.lock()
            lastDurationMs = Int64(seconds * 1000)
            lock.unlock()
            playerState?.duration = seconds
            if seconds > 0 {
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
        case "paused-for-cache":
            handleCachePause(isPausedForCache: event.flagValue != 0)
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
                let startedAt = Date()
                let stallThreshold = MPVPlaybackActivityPolicy.cacheStallThreshold(for: playerState?.currentSpec)
                cacheStallStart = startedAt
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
            if cacheStallStart != nil {
                DiagnosticLog.write("[MPV_CACHE_STALL] recovered")
            }
            cacheStallStart = nil
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
        let stallThreshold = MPVPlaybackActivityPolicy.cacheStallThreshold(for: playerState?.currentSpec)
        guard !cacheStallNotified,
              let cacheStallStart,
              Date().timeIntervalSince(cacheStallStart) >= stallThreshold else {
            return
        }
        cacheStallNotified = true
        let positionSeconds = Double(position) / 1000
        DiagnosticLog.write("[MPV_CACHE_STALL] threshold=\(stallThreshold)s position=\(positionSeconds)")
        playbackStallHandler?(playerState?.currentSpec, positionSeconds)
    }

    private func setError(_ message: String) {
        lock.lock()
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        status = .error(message)
        lock.unlock()
        DiagnosticLog.write("[MPV_ERROR] \(message)")
        Task { @MainActor in
            let spec = self.playerState?.currentSpec
            self.playerState?.errorMessage = message
            self.playerState?.isPlaying = false
            self.clearPlaybackActivity()
            self.playbackFailureHandler?(spec, message)
        }
    }

    @MainActor
    private func markMediaReady() {
        playerState?.isMediaLoading = false
    }

    @MainActor
    private func clearPlaybackActivity() {
        playerState?.bufferedUntil = 0
        playerState?.isMediaLoading = false
        playerState?.isBuffering = false
        playerState?.cacheSpeedBytesPerSecond = nil
        playerState?.cacheBufferingProgress = nil
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
        guard Self.isLocalStreamSpec(spec) else { return }
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
        failLocalStreamStartupIfNeeded("本地视频流启动超时，原片在 \(timeout) 秒内未返回可播放数据。")
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
            return "本地视频流启动失败，原片尾部定位请求未能完成。"
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
        isLocalStreamSpec(spec)
            && !playbackStarted
            && positionMilliseconds <= 0
            && durationMilliseconds <= 0
            && !alreadyFailed
    }

    static func localStreamStartupTimeout(for spec: PlaySpec) -> TimeInterval {
        let provider = spec.metadata[DrivePlaybackMetadataKey.provider]
        let route = spec.metadata[DrivePlaybackMetadataKey.route]
        if provider == DriveProvider.p115.rawValue && route == DrivePlaybackRoute.originalDownload {
            return 120
        }
        return defaultLocalStreamStartupTimeout
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

    private func resetStringProperty(_ name: String, context: OpaquePointer) {
        let code = nv_mpv_set_property_string(context, name, "")
        if code < 0 {
            DiagnosticLog.write("[MPV_OPTION_RESET_SKIP] \(name): \(Self.cString(nv_mpv_last_error(context)))")
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
            throw MPVPlayerEngineError.command("字幕 data URL 缺少内容分隔符")
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
            throw MPVPlayerEngineError.command("字幕 data URL 无法解码")
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
        guard sub.url.lowercased().hasPrefix("data:") else { return sub.url }
        do {
            guard let fileURL = try Self.materializedSubtitleFile(for: sub) else { return sub.url }
            withLock {
                temporarySubtitleFiles.append(fileURL)
            }
            DiagnosticLog.write("[MPV_SUBTITLE_MATERIALIZED] title=\(title) format=\(sub.format)")
            return fileURL.path
        } catch {
            DiagnosticLog.write("[MPV_SUBTITLE_ERROR] title=\(title) error=\(error.localizedDescription)")
            Task { @MainActor in
                self.playerState?.subtitleStatus = "\(title)加载失败"
            }
            return nil
        }
    }

    private static func removeTemporarySubtitleFiles(_ files: [URL]) {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func applyMPVOptions(_ options: [String: String], context: OpaquePointer, stage: String) throws {
        DiagnosticLog.write("[MPV_SUBTITLE_STYLE] stage=\(stage) \(Self.subtitleStyleDiagnostic(from: options))")
        for (name, value) in options.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            try check(nv_mpv_set_property_string(context, name, value), context: context, action: "set property \(name)=\(Self.redactedLogText(value))")
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

        let options = PlayerSubtitlePolicy.mpvOptions(for: subtitleSettingsProvider())
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
            return "Widevine DRM 已识别，但 macOS 首版暂不支持授权播放"
        }
        if type.contains("clearkey") || !drm.key.isEmpty {
            return "ClearKey DRM 元数据已识别，播放兼容性取决于 mpv/源站"
        }
        return "DRM 元数据已识别，类型：\(drm.type.isEmpty ? "未知" : drm.type)"
    }

    static func diagnosticMessage(forMPVLog text: String, currentSpec: PlaySpec? = nil) -> String? {
        let lower = text.lowercased()
        if lower.contains("http error 500 internal server error") {
            return "代理拉流失败：本地代理返回 500。请检查源站是否拒绝、代理规则是否直连，或切换到可用线路。"
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
            return "代理拉流失败：本地代理没有成功打开上游地址。请切换线路或检查代理/网络设置。"
        }
        return nil
    }

    private static func loadFailureDiagnostic(for spec: PlaySpec?) -> String {
        let transport = spec?.metadata[LiveHLSRelayPolicy.transportMetadataKey] ?? ""
        switch transport {
        case LiveHLSRelayPolicy.localRelayTransport:
            return "本地 HLS relay 拉流失败：上游连接被中断或分片请求失败，请切换线路。"
        case LiveHLSRelayPolicy.localStreamRelayTransport:
            return "本地 stream relay 拉流失败：上游连接被中断或不支持分段转发，请切换线路。"
        default:
            break
        }

        if let spec, PlaybackProxyPolicy.bypassReason(for: spec) == .directHLS {
            return "直播 HLS 直连加载失败：源站连接被中断，通常是网络路径、源站防护或签名失效导致。已允许本地 relay 兜底。"
        }
        if let spec, PlaybackProxyPolicy.bypassReason(for: spec) == .directMedia {
            return "直播媒体直连加载失败：源站连接被中断，通常是网络路径、源站防护或格式不稳定导致。已允许本地 stream relay 兜底。"
        }
        return "直连媒体加载失败：源站连接被中断，请切换线路或检查网络。"
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
        var value = text
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
            throw MPVPlayerEngineError.initialization("生命周期基准至少需要 5 轮")
        }
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw MPVPlayerEngineError.initialization("生命周期基准媒体不存在: \(mediaURL.path)")
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
                throw MPVPlayerEngineError.initialization("生命周期基准无法创建 OpenGL 播放面")
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

    init(_ event: NVMPVEvent) {
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
