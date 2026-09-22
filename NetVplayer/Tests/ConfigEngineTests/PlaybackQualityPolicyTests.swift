import Testing
import Foundation
import Models
import DriveEngine
@testable import ProxyServer
@testable import PlayerEngine
@testable import NetVplayerApp

@Test func testMPVPlaybackKindsUseDedicatedEngineInstances() {
    #expect(MPVPlayerEngine.vod !== MPVPlayerEngine.live)
    #expect(MPVPlayerEngine.vod.videoSurface == .vod)
    #expect(MPVPlayerEngine.live.videoSurface == .live)
    #expect(MPVPlayerEngine.shared === MPVPlayerEngine.vod)
}

@Test func testMPVInitializationUsesInterleavedFloatForCoreAudioHotplugSafety() {
    let options = Dictionary(uniqueKeysWithValues: MPVPlayerEngine.initializationOptions.map {
        ($0.name, $0.value)
    })
    #expect(options["audio-format"] == "float")
    #expect(options["vo"] == "libmpv")
    #expect(options["hwdec"] == "videotoolbox-copy")
}

@Test func testMPVErrorsExposeStablePrivateDataFreeFailureKinds() {
    #expect(MPVPlayerEngine.diagnosticErrorKind(for: "libmpv 初始化失败") == 1)
    #expect(MPVPlayerEngine.diagnosticErrorKind(for: "本地视频流启动失败，Range 无法完成") == 2)
    #expect(MPVPlayerEngine.diagnosticErrorKind(for: "本地 stream relay 拉流失败") == 3)
    #expect(MPVPlayerEngine.diagnosticErrorKind(for: "mpv 外部音轨加载失败") == 4)
    #expect(MPVPlayerEngine.diagnosticErrorKind(for: "demux format error") == 5)
    #expect(MPVPlayerEngine.diagnosticErrorKind(for: "mpv 事件错误") == 6)
    #expect(MPVPlayerEngine.diagnosticErrorKind(for: "unknown") == 0)
}

@Test @MainActor func testPlaybackPreparationRetriesOnlyOneTransientFailure() {
    let retryable = DriveEngineError.api(
        provider: .quark,
        statusCode: 503,
        code: 429,
        message: "temporary"
    )
    let terminal = DriveEngineError.api(
        provider: .quark,
        statusCode: 401,
        code: 401,
        message: "expired"
    )

    #expect(AppState.transientPreparationRetryDelayNanoseconds(for: retryable, attempt: 0) == 500_000_000)
    #expect(AppState.transientPreparationRetryDelayNanoseconds(for: retryable, attempt: 1) == nil)
    #expect(AppState.transientPreparationRetryDelayNanoseconds(for: terminal, attempt: 0) == nil)
    #expect(AppState.transientPreparationRetryDelayNanoseconds(
        for: URLError(.networkConnectionLost),
        attempt: 0
    ) == 500_000_000)
}

@Test func testPlaybackDisplaySleepControllerTracksPlaybackWithoutLeakingActivities() {
    final class ActivityToken: NSObject {}

    var beginCount = 0
    var endedTokens: [NSObjectProtocol] = []
    let token = ActivityToken()
    let controller = PlaybackDisplaySleepController(
        beginActivity: {
            beginCount += 1
            return token
        },
        endActivity: { endedTokens.append($0) }
    )

    #expect(PlaybackDisplaySleepController.activityOptions.contains(.idleDisplaySleepDisabled))
    #expect(controller.setPlaybackActive(true))
    #expect(!controller.setPlaybackActive(true))
    #expect(beginCount == 1)
    #expect(controller.setPlaybackActive(false))
    #expect(!controller.setPlaybackActive(false))
    #expect(endedTokens.count == 1)
    #expect(endedTokens.first === token)
}

@Test func testMPVPlaybackLifecycleControlsDisplaySleepPrevention() {
    final class ActivityToken: NSObject {}

    var beginCount = 0
    var endCount = 0
    let controller = PlaybackDisplaySleepController(
        beginActivity: {
            beginCount += 1
            return ActivityToken()
        },
        endActivity: { _ in endCount += 1 }
    )
    let engine = MPVPlayerEngine(
        videoSurface: .vod,
        stopResourcePolicy: .fullDestroy,
        displaySleepController: controller
    )

    engine.resume()
    engine.resume()
    #expect(beginCount == 1)
    engine.pause()
    engine.pause()
    #expect(endCount == 1)
    engine.resume()
    #expect(beginCount == 2)
    engine.stop()
    engine.stop()
    #expect(endCount == 2)
}

@Test func testMPVStopResourcePolicyDefaultsToFullDestroyAndSupportsWarmRollback() {
    #expect(MPVStopResourcePolicy.configured(environment: [:]) == .fullDestroy)
    #expect(MPVStopResourcePolicy.configured(environment: [
        "NETVPLAYER_MPV_STOP_RESOURCE_POLICY": "warm-stop"
    ]) == .warmStop)
    #expect(MPVStopResourcePolicy.configured(environment: [
        "NETVPLAYER_MPV_STOP_RESOURCE_POLICY": "invalid"
    ]) == .fullDestroy)
}

@Test func testMPVRenderRequestGateCoalescesWithoutDroppingFollowUp() {
    var gate = MPVRenderRequestGate()

    let scheduledInitial = gate.request()
    let scheduledDuplicate = gate.request()
    #expect(scheduledInitial)
    #expect(!scheduledDuplicate)
    #expect(gate.hasPendingRequest)
    let preparedInitial = gate.prepareForDisplay()
    let scheduledFollowUp = gate.completeDisplay()
    #expect(preparedInitial)
    #expect(scheduledFollowUp)
    #expect(gate.isScheduled)
    let preparedFollowUp = gate.prepareForDisplay()
    let scheduledThird = gate.completeDisplay()
    #expect(preparedFollowUp)
    #expect(!scheduledThird)
    #expect(!gate.isScheduled)
}

@Test func testMPVRenderRequestGateDefersDuringLiveResize() {
    var gate = MPVRenderRequestGate()

    let scheduledOnSuspend = gate.setSuspended(true)
    let scheduledDuringResize = gate.request()
    #expect(!scheduledOnSuspend)
    #expect(!scheduledDuringResize)
    #expect(gate.hasPendingRequest)
    let scheduledOnResume = gate.setSuspended(false)
    let preparedAfterResize = gate.prepareForDisplay()
    let scheduledFollowUp = gate.completeDisplay()
    #expect(scheduledOnResume)
    #expect(preparedAfterResize)
    #expect(!scheduledFollowUp)
}

@Test func testMPVMaterializesInlineASSSubtitleForLibMPV() throws {
    let contents = "[Script Info]\n[Events]\nDialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,歌词"
    let sub = Sub(
        name: "歌词",
        url: "data:text/plain;base64,\(Data(contents.utf8).base64EncodedString())",
        lang: "zh",
        format: "ass"
    )
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let materialized = try MPVPlayerEngine.materializedSubtitleFile(for: sub, directory: root)
    let file = try #require(materialized)

    #expect(file.pathExtension == "ass")
    #expect(try String(contentsOf: file, encoding: .utf8) == contents)
}

@Test func testMPVOnlyTreatsSubtitleCommandRepliesAsNonfatalAttachments() {
    #expect(!MPVPlayerEngine.isSubtitleReplyUserdata(1))
    #expect(MPVPlayerEngine.isSubtitleReplyUserdata(2))
    #expect(MPVPlayerEngine.isSubtitleReplyUserdata(9_999))
    #expect(!MPVPlayerEngine.isSubtitleReplyUserdata(10_000))
}

@Test func testPlaySpecArtworkSurvivesEmptyOverridesAndAcceptsExplicitReplacement() {
    let base = PlaySpec(url: "https://media.example.test/song.m4a", artwork: "https://img.example.test/cover.jpg")

    #expect(base.merging(PlaySpec(url: "https://media.example.test/resolved.m4a")).artwork == base.artwork)
    #expect(base.merging(PlaySpec(artwork: "https://img.example.test/new-cover.jpg")).artwork == "https://img.example.test/new-cover.jpg")
}

@Test func testMPVLocalStreamStartupFailureClassifiesOnlyActionablePreFirstFrameErrors() {
    var localStream = PlaySpec(url: "http://127.0.0.1:9978/stream/uc-178")
    localStream.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.localStreamRelayTransport

    #expect(MPVPlayerEngine.localStreamStartupFailure(
        logText: "mkv: Failed to seek when reading header element.",
        spec: localStream,
        playbackStarted: false
    ) != nil)
    #expect(MPVPlayerEngine.localStreamStartupFailure(
        logText: "http: Error reading HTTP response: Immediate exit requested",
        spec: localStream,
        playbackStarted: false
    ) == nil)
    #expect(MPVPlayerEngine.localStreamStartupFailure(
        logText: "mkv: Failed to seek when reading header element.",
        spec: localStream,
        playbackStarted: true
    ) == nil)

    let remote = PlaySpec(url: "https://media.example.test/stream/uc-178")
    #expect(MPVPlayerEngine.localStreamStartupFailure(
        logText: "mkv: Failed to seek when reading header element.",
        spec: remote,
        playbackStarted: false
    ) == nil)
}

@Test func testMPVLocalStreamStartupWatchdogEligibilityRequiresZeroProgress() {
    let localStream = PlaySpec(url: "http://localhost:9978/stream/uc-178")

    #expect(MPVPlayerEngine.shouldFireLocalStreamStartupWatchdog(
        spec: localStream,
        playbackStarted: false,
        positionMilliseconds: 0,
        durationMilliseconds: 0,
        alreadyFailed: false
    ))
    #expect(!MPVPlayerEngine.shouldFireLocalStreamStartupWatchdog(
        spec: localStream,
        playbackStarted: true,
        positionMilliseconds: 0,
        durationMilliseconds: 0,
        alreadyFailed: false
    ))
    #expect(!MPVPlayerEngine.shouldFireLocalStreamStartupWatchdog(
        spec: localStream,
        playbackStarted: false,
        positionMilliseconds: 100,
        durationMilliseconds: 0,
        alreadyFailed: false
    ))
    #expect(!MPVPlayerEngine.shouldFireLocalStreamStartupWatchdog(
        spec: localStream,
        playbackStarted: false,
        positionMilliseconds: 0,
        durationMilliseconds: 1_000,
        alreadyFailed: false
    ))
    #expect(!MPVPlayerEngine.shouldFireLocalStreamStartupWatchdog(
        spec: localStream,
        playbackStarted: false,
        positionMilliseconds: 0,
        durationMilliseconds: 0,
        alreadyFailed: true
    ))
}

@Test func testMPVPlaybackStartEventPreservesExplicitPauseAndRejectsStaleStates() {
    #expect(MPVPlayerEngine.acceptsPlaybackStartEvent(status: .loading))
    #expect(MPVPlayerEngine.acceptsPlaybackStartEvent(status: .playing))
    #expect(MPVPlayerEngine.acceptsPlaybackStartEvent(status: .paused))
    #expect(!MPVPlayerEngine.acceptsPlaybackStartEvent(status: .idle))
    #expect(!MPVPlayerEngine.acceptsPlaybackStartEvent(status: .error("failed")))

    #expect(MPVPlayerEngine.shouldMarkPlayingAfterStartEvent(status: .loading))
    #expect(MPVPlayerEngine.shouldMarkPlayingAfterStartEvent(status: .playing))
    #expect(!MPVPlayerEngine.shouldMarkPlayingAfterStartEvent(status: .paused))
    #expect(!MPVPlayerEngine.shouldMarkPlayingAfterStartEvent(status: .idle))
    #expect(!MPVPlayerEngine.shouldMarkPlayingAfterStartEvent(status: .error("failed")))
}

@Test func testMPVMediaLoadingEndsOnlyWhenPlaybackCanRender() {
    #expect(!MPVPlaybackActivityPolicy.shouldAcceptTimePosition(isCurrentFileLoaded: false))
    #expect(MPVPlaybackActivityPolicy.shouldAcceptTimePosition(isCurrentFileLoaded: true))
    #expect(!MPVPlaybackActivityPolicy.shouldEndMediaLoading(eventID: 8))
    #expect(!MPVPlaybackActivityPolicy.shouldEndMediaLoading(eventID: 21))
    #expect(!MPVPlaybackActivityPolicy.shouldEndMediaLoading(eventID: 22, positionSeconds: 0.05))
    #expect(MPVPlaybackActivityPolicy.shouldEndMediaLoading(eventID: 22, positionSeconds: 0.051))
    #expect(!MPVPlaybackActivityPolicy.shouldEndMediaLoading(eventID: 22, positionSeconds: .nan))
}

@Test func testMPVSeekUsesKeyframesForDriveTranscodeStreams() {
    let direct = PlaySpec(url: "https://media.example.test/video.mp4")
    #expect(MPVSeekModePolicy.commandMode(for: direct) == MPVSeekModePolicy.precise)

    var transcode = PlaySpec(url: "https://media.example.test/transcode.m3u8")
    transcode.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.personalTranscode
    #expect(MPVSeekModePolicy.commandMode(for: transcode) == MPVSeekModePolicy.streaming)

    var ucSmart = PlaySpec(url: "https://media.example.test/uc-smart.m3u8")
    ucSmart.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.ucSmartPlay
    #expect(MPVSeekModePolicy.commandMode(for: ucSmart) == MPVSeekModePolicy.streaming)

    var relayed = PlaySpec(url: "http://127.0.0.1:9978/proxy/quark.m3u8")
    relayed.drivePlaybackPlan = DrivePlaybackPlan(
        provider: .quark,
        asset: DrivePlaybackAssetIdentity(provider: .quark, shareID: "share", sourceFileID: "file"),
        candidates: [
            DrivePlaybackCandidate(
                id: "quark:relay",
                providerRoute: DrivePlaybackRoute.streamVariant,
                kind: .transcode,
                transport: .hlsRelay,
                url: relayed.url
            )
        ]
    )
    #expect(MPVSeekModePolicy.commandMode(for: relayed) == MPVSeekModePolicy.streaming)
    #expect(MPVSeekModePolicy.shouldShowLoading(pauseRequested: false))
    #expect(!MPVSeekModePolicy.shouldShowLoading(pauseRequested: true))
}

@Test func testMPVInitialStartLoadsVodAtTheTargetPosition() {
    var direct = PlaySpec(url: "https://media.example.test/video.mp4")
    direct.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
    #expect(MPVInitialStartPolicy.supportsFileLocalStart(for: direct))

    var live = direct
    live.metadata["playback.kind"] = "live"
    #expect(!MPVInitialStartPolicy.supportsFileLocalStart(for: live))

    var transcode = PlaySpec(url: "https://media.example.test/transcode.m3u8")
    transcode.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.personalTranscode
    #expect(MPVInitialStartPolicy.supportsFileLocalStart(for: transcode))
    #expect(MPVInitialStartPolicy.positionMilliseconds(
        resumePosition: nil,
        resumeDuration: nil,
        openingSkipSeconds: 120
    ) == 120_000)
    #expect(MPVInitialStartPolicy.positionMilliseconds(
        resumePosition: 95_000,
        resumeDuration: 1_800_000,
        openingSkipSeconds: 120
    ) == 120_000)
    #expect(MPVInitialStartPolicy.positionMilliseconds(
        resumePosition: 240_000,
        resumeDuration: 1_800_000,
        openingSkipSeconds: 120
    ) == 240_000)
    #expect(MPVInitialStartPolicy.positionMilliseconds(
        resumePosition: 95_000,
        resumeDuration: nil,
        openingSkipSeconds: 120
    ) == nil)

    transcode.initialStartPositionSeconds = 120
    #expect(MPVInitialStartPolicy.loadFileOptions(for: transcode) == "start=120.0")
    transcode.initialStartPositionSeconds = .nan
    #expect(MPVInitialStartPolicy.loadFileOptions(for: transcode) == nil)
}

@Test func testPostSeekGuardKeepsLoadingUntilTheSeekedFrameArrives() {
    var guardState = PlaybackPostSeekEndGuard()
    #expect(guardState.canPresentFrame(at: 0.1))

    guardState.begin(targetSeconds: 120)
    #expect(!guardState.canPresentFrame(at: 0.2))
    guardState.observePosition(0.2)
    #expect(!guardState.canPresentFrame(at: 0.3))
    guardState.observePosition(120)
    #expect(!guardState.canPresentFrame(at: 120))
    guardState.markPlaybackRestarted()
    #expect(!guardState.canPresentFrame(at: 80))
    #expect(guardState.canPresentFrame(at: 110))

    guardState.begin(targetSeconds: 5)
    guardState.observePosition(120)
    #expect(!guardState.canPresentFrame(at: 120))
    guardState.markPlaybackRestarted()
    #expect(guardState.canPresentFrame(at: 4))
}

@Test func testMPVInitialStartRecoversOnceWhenTheActualFileIsShorterThanTheSkip() throws {
    let spec = PlaySpec(
        url: "https://media.example.test/short.mp4",
        headers: ["Referer": "https://media.example.test"],
        initialStartPositionSeconds: 120,
        metadata: ["vod.episodeURL": "short-episode"]
    )
    let recovered = try #require(MPVInitialStartPolicy.recoverySpec(
        for: spec, durationSeconds: 60, isCurrentFileLoaded: true,
        playbackStarted: false, reachedEOF: false
    ))
    #expect(recovered.initialStartPositionSeconds == nil)
    #expect(recovered.url == spec.url)
    #expect(recovered.headers == spec.headers)
    #expect(recovered.metadata == spec.metadata)
    #expect(MPVInitialStartPolicy.loadFileOptions(for: recovered) == nil)
    #expect(MPVInitialStartPolicy.recoverySpec(
        for: recovered, durationSeconds: 60, isCurrentFileLoaded: true,
        playbackStarted: false, reachedEOF: true
    ) == nil)
}

@Test func testMPVInitialStartKeepsValidStartsAndIgnoresStaleDurationNotifications() {
    var spec = PlaySpec(url: "https://media.example.test/video.mp4", initialStartPositionSeconds: 120)
    #expect(MPVInitialStartPolicy.recoverySpec(
        for: spec, durationSeconds: 1_800, isCurrentFileLoaded: true,
        playbackStarted: false, reachedEOF: false
    ) == nil)
    #expect(MPVInitialStartPolicy.recoverySpec(
        for: spec, durationSeconds: 0, isCurrentFileLoaded: true,
        playbackStarted: false, reachedEOF: false
    ) == nil)
    #expect(MPVInitialStartPolicy.recoverySpec(
        for: spec, durationSeconds: 60, isCurrentFileLoaded: false,
        playbackStarted: false, reachedEOF: false
    ) == nil)
    #expect(MPVInitialStartPolicy.recoverySpec(
        for: spec, durationSeconds: 60, isCurrentFileLoaded: true,
        playbackStarted: true, reachedEOF: true
    ) == nil)
    spec.metadata["playback.kind"] = "live"
    #expect(MPVInitialStartPolicy.recoverySpec(
        for: spec, durationSeconds: 60, isCurrentFileLoaded: true,
        playbackStarted: false, reachedEOF: true
    ) == nil)
}

@Test func testMPVInitialStartCanRecoverWhenEOFArrivesWithoutDuration() throws {
    let spec = PlaySpec(url: "https://media.example.test/short.mp4", initialStartPositionSeconds: 120)
    let recovered = try #require(MPVInitialStartPolicy.recoverySpec(
        for: spec, durationSeconds: 0, isCurrentFileLoaded: false,
        playbackStarted: false, reachedEOF: true
    ))
    #expect(recovered.initialStartPositionSeconds == nil)

    var tracker = MPVPlaybackLoadEventTracker()
    tracker.markLoadIssued()
    tracker.markFileLoaded()
    // A duration-triggered retry replaces an active load; its old EOF must be ignored.
    tracker.prepareForLoad()
    tracker.markLoadIssued()
    let ignoredReplacement = tracker.consumeEndFile()
    #expect(ignoredReplacement)
    tracker.markFileLoaded()
    let ignoredCurrent = tracker.consumeEndFile()
    #expect(!ignoredCurrent)
    // An EOF-triggered retry starts after the old load ended, with no replacement EOF to skip.
    tracker.prepareForLoad()
    tracker.markLoadIssued()
    let ignoredRecovery = tracker.consumeEndFile()
    #expect(!ignoredRecovery)
}

@Test func testPostSeekLoadingWaitsForRestartAfterPositionProgress() {
    var guardState = PlaybackPostSeekEndGuard()
    guardState.begin(targetSeconds: 40)
    for position in [40.0, 41, 42, 43] {
        guardState.observePosition(position)
    }
    #expect(!guardState.isProtecting)
    #expect(!guardState.canPresentFrame(at: 43))

    guardState.markPlaybackRestarted()
    #expect(guardState.canPresentFrame(at: 40))
    guardState.markFramePresented()
    #expect(guardState.canPresentFrame(at: 40))
}

@Test func testMPVCacheMetricsRejectUnavailableValuesAndClampProgress() {
    #expect(MPVPlaybackActivityPolicy.normalizedCacheSpeed(1_024, hasValue: true) == 1_024)
    #expect(MPVPlaybackActivityPolicy.normalizedCacheSpeed(0, hasValue: true) == nil)
    #expect(MPVPlaybackActivityPolicy.normalizedCacheSpeed(-1, hasValue: true) == nil)
    #expect(MPVPlaybackActivityPolicy.normalizedCacheSpeed(1_024, hasValue: false) == nil)

    #expect(MPVPlaybackActivityPolicy.normalizedCacheBufferingProgress(0, hasValue: true) == 0)
    #expect(MPVPlaybackActivityPolicy.normalizedCacheBufferingProgress(45, hasValue: true) == 0.45)
    #expect(MPVPlaybackActivityPolicy.normalizedCacheBufferingProgress(140, hasValue: true) == 1)
    #expect(MPVPlaybackActivityPolicy.normalizedCacheBufferingProgress(-1, hasValue: true) == nil)
    #expect(MPVPlaybackActivityPolicy.normalizedCacheBufferingProgress(45, hasValue: false) == nil)
}

@Test func testMPVCachePauseDoesNotTreatExplicitPauseAsBuffering() {
    #expect(MPVPlaybackActivityPolicy.shouldExposeBuffering(
        isPausedForCache: true,
        pauseRequested: false
    ))
    #expect(!MPVPlaybackActivityPolicy.shouldExposeBuffering(
        isPausedForCache: true,
        pauseRequested: true
    ))
    #expect(!MPVPlaybackActivityPolicy.shouldExposeBuffering(
        isPausedForCache: false,
        pauseRequested: false
    ))
}

@Test func testCloudOriginalPlaybackUsesLowLatencyBufferingAndLongerStallGrace() throws {
    var quark = PlaySpec(
        url: "https://dl-pc-zb.pds.quark.cn/path/video.mkv",
        metadata: [
            DrivePlaybackMetadataKey.provider: DriveProvider.quark.rawValue,
            DrivePlaybackMetadataKey.route: DrivePlaybackRoute.originalDownload,
            DrivePlaybackMetadataKey.fid: "quark-file"
        ]
    )
    quark.drivePlaybackPlan = QuarkDrivePlaybackAdapter().playbackPlan(
        primaryURL: quark.url,
        primaryHeaders: [:],
        primaryMetadata: quark.metadata
    )
    quark.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.localStreamRelayTransport

    let quarkBuffer = LiveHLSRelayPolicy.remoteStreamBufferConfiguration(for: quark)
    #expect(quarkBuffer.initialChunkSize == 4 * 1024 * 1024)
    #expect(quarkBuffer.chunkSize == 4 * 1024 * 1024)
    #expect(quarkBuffer.prefetchWindowSize == 32 * 1024 * 1024)
    #expect(MPVPlaybackActivityPolicy.cacheStallThreshold(for: quark) == 20)

    var p115 = quark
    p115.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.p115.rawValue
    let p115Buffer = LiveHLSRelayPolicy.remoteStreamBufferConfiguration(for: p115)
    #expect(p115Buffer.initialChunkSize == 512 * 1024)
    #expect(p115Buffer.chunkSize == 512 * 1024)

    var ali = quark
    ali.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.ali.rawValue
    ali.drivePlaybackPlan = AliDrivePlaybackAdapter().playbackPlan(
        primaryURL: ali.url,
        primaryHeaders: [:],
        primaryMetadata: ali.metadata
    )
    let aliBuffer = LiveHLSRelayPolicy.remoteStreamBufferConfiguration(for: ali)
    #expect(aliBuffer.initialChunkSize == 1 * 1024 * 1024)
    #expect(aliBuffer.chunkSize == 1 * 1024 * 1024)
    ali.metadata[LiveHLSRelayPolicy.transportMetadataKey] = LiveHLSRelayPolicy.localRelayTransport
    #expect(MPVPlaybackActivityPolicy.cacheStallThreshold(for: ali) == 20)

    var direct = quark
    direct.metadata[LiveHLSRelayPolicy.transportMetadataKey] = nil
    direct.drivePlaybackPlan = nil
    #expect(MPVPlaybackActivityPolicy.cacheStallThreshold(for: direct) == 8)
}

@Test func testP115OriginalLocalStreamGetsExtendedStartupGrace() {
    var p115 = PlaySpec(
        url: "http://localhost:9978/stream?id=p115-original",
        metadata: [
            DrivePlaybackMetadataKey.provider: DriveProvider.p115.rawValue,
            DrivePlaybackMetadataKey.route: DrivePlaybackRoute.originalDownload
        ]
    )
    let ordinary = PlaySpec(url: "http://localhost:9978/stream?id=ordinary")

    #expect(MPVPlayerEngine.localStreamStartupTimeout(for: p115) == 120)
    #expect(MPVPlayerEngine.localStreamStartupTimeout(for: ordinary) == 60)

    p115.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.personalTranscode
    #expect(MPVPlayerEngine.localStreamStartupTimeout(for: p115) == 60)
}

@Test func testMPVEndFileStateRejectsEventsFromReplacedPlayback() {
    #expect(!MPVPlayerEngine.shouldApplyEndFileState(
        reason: MPVPlayerEngine.EndFileReason.restarted.rawValue,
        error: -13,
        status: .playing
    ))
    #expect(!MPVPlayerEngine.shouldApplyEndFileState(
        reason: MPVPlayerEngine.EndFileReason.redirect.rawValue,
        error: 0,
        status: .loading
    ))
    #expect(!MPVPlayerEngine.shouldApplyEndFileState(
        reason: MPVPlayerEngine.EndFileReason.stopped.rawValue,
        error: 0,
        status: .playing
    ))
    #expect(!MPVPlayerEngine.shouldApplyEndFileState(
        reason: MPVPlayerEngine.EndFileReason.stopped.rawValue,
        error: 0,
        status: .paused
    ))
}

@Test func testMPVEndFileStateStillAppliesRealStopsAndNaturalEnds() {
    #expect(MPVPlayerEngine.shouldApplyEndFileState(
        reason: MPVPlayerEngine.EndFileReason.stopped.rawValue,
        error: 0,
        status: .idle
    ))
    #expect(MPVPlayerEngine.shouldApplyEndFileState(
        reason: MPVPlayerEngine.EndFileReason.eof.rawValue,
        error: 0,
        status: .playing
    ))
    #expect(MPVPlayerEngine.shouldApplyEndFileState(
        reason: 99,
        error: -13,
        status: .playing
    ))
}

@Test func testPlaybackEndDispositionSeparatesNaturalSeekCacheAndFailurePaths() {
    let natural = PlaybackAutoAdvancePolicy.endDisposition(
        reason: 0,
        error: 0,
        isReplacingMedia: false,
        playbackStarted: true,
        isPausedForCache: false,
        positionSeconds: 98,
        durationSeconds: 100,
        isProtectedByUserSeek: false
    )
    #expect(natural == .natural)

    #expect(PlaybackAutoAdvancePolicy.endDisposition(
        reason: 0,
        error: 0,
        isReplacingMedia: false,
        playbackStarted: true,
        isPausedForCache: false,
        positionSeconds: 0,
        durationSeconds: 0,
        isProtectedByUserSeek: false
    ) == .natural)
    #expect(PlaybackAutoAdvancePolicy.endDisposition(
        reason: 0,
        error: 0,
        isReplacingMedia: false,
        playbackStarted: true,
        isPausedForCache: false,
        positionSeconds: 40,
        durationSeconds: 100,
        isProtectedByUserSeek: false
    ) == .premature)
    #expect(PlaybackAutoAdvancePolicy.endDisposition(
        reason: 0,
        error: 0,
        isReplacingMedia: false,
        playbackStarted: true,
        isPausedForCache: true,
        positionSeconds: 98,
        durationSeconds: 100,
        isProtectedByUserSeek: false
    ) == .premature)
    #expect(PlaybackAutoAdvancePolicy.endDisposition(
        reason: 0,
        error: 0,
        isReplacingMedia: false,
        playbackStarted: true,
        isPausedForCache: false,
        positionSeconds: 98,
        durationSeconds: 100,
        isProtectedByUserSeek: true,
        isUserSeekToBoundary: true
    ) == .userSeekBoundary)
    #expect(PlaybackAutoAdvancePolicy.endDisposition(
        reason: 0,
        error: 0,
        isReplacingMedia: false,
        playbackStarted: true,
        isPausedForCache: false,
        positionSeconds: 40,
        durationSeconds: 100,
        isProtectedByUserSeek: true
    ) == .premature)
    #expect(PlaybackAutoAdvancePolicy.endDisposition(
        reason: 2,
        error: 0,
        isReplacingMedia: false,
        playbackStarted: true,
        isPausedForCache: false,
        positionSeconds: 40,
        durationSeconds: 100,
        isProtectedByUserSeek: false
    ) == .stopped)
    #expect(PlaybackAutoAdvancePolicy.endDisposition(
        reason: 4,
        error: -13,
        isReplacingMedia: false,
        playbackStarted: true,
        isPausedForCache: false,
        positionSeconds: 40,
        durationSeconds: 100,
        isProtectedByUserSeek: false
    ) == .failed)
    #expect(PlaybackAutoAdvancePolicy.endDisposition(
        reason: 0,
        error: 0,
        isReplacingMedia: true,
        playbackStarted: true,
        isPausedForCache: false,
        positionSeconds: 98,
        durationSeconds: 100,
        isProtectedByUserSeek: false
    ) == .ignored)
}

@Test func testPostSeekEndGuardRequiresContinuousPlaybackBeforeNaturalEOF() {
    var guardState = PlaybackPostSeekEndGuard()
    guardState.begin(targetSeconds: 40)
    #expect(guardState.isProtecting)
    #expect(!guardState.isBoundarySeek(positionSeconds: 40, durationSeconds: 100))

    guardState.markPlaybackRestarted()
    guardState.observePosition(40)
    guardState.observePosition(41)
    guardState.observePosition(42)
    #expect(guardState.isProtecting)
    guardState.observePosition(43)
    #expect(!guardState.isProtecting)

    guardState.begin(targetSeconds: 98)
    #expect(guardState.isBoundarySeek(positionSeconds: 98, durationSeconds: 100))
    guardState.begin(targetSeconds: .nan)
    #expect(!guardState.isProtecting)
}

@Test func testPostSeekEndGuardRejectsJumpsAndCanRecoverWithoutRestartEvent() {
    var guardState = PlaybackPostSeekEndGuard()
    guardState.begin(targetSeconds: 40)
    guardState.markPlaybackRestarted()
    guardState.observePosition(40)
    guardState.observePosition(46)
    guardState.observePosition(45)
    #expect(guardState.isProtecting)
    guardState.observePosition(46)
    guardState.observePosition(47)
    guardState.observePosition(48)
    #expect(!guardState.isProtecting)

    guardState.begin(targetSeconds: 20)
    guardState.observePosition(20)
    guardState.observePosition(21)
    guardState.observePosition(22)
    guardState.observePosition(23)
    #expect(!guardState.isProtecting)
}

@Test func testMPVLoadEventTrackerConsumesOnlyTheReplacedLoadsEndFile() {
    var tracker = MPVPlaybackLoadEventTracker()

    tracker.prepareForLoad()
    tracker.markLoadIssued()
    #expect(!tracker.expectsReplacedEndFile)

    tracker.prepareForLoad()
    tracker.markLoadIssued()
    #expect(tracker.expectsReplacedEndFile)
    let consumedReplacement = tracker.consumeEndFile()
    #expect(consumedReplacement)
    let consumedTwice = tracker.consumeEndFile()
    #expect(!consumedTwice)

    tracker.prepareForLoad()
    tracker.markLoadIssued()
    tracker.prepareForLoad()
    tracker.markLoadIssued()
    #expect(tracker.expectsReplacedEndFile)
    tracker.markFileLoaded()
    let consumedLoadedFile = tracker.consumeEndFile()
    #expect(!consumedLoadedFile)

    tracker.reset()
    #expect(!tracker.hasActiveLoad)
    #expect(!tracker.expectsReplacedEndFile)
}

@Test func testMPVPausePropertyFollowsLatestCommandIntent() {
    #expect(MPVPlayerEngine.shouldApplyPauseProperty(
        isPaused: true,
        status: .paused,
        pauseRequested: true
    ))
    #expect(MPVPlayerEngine.shouldApplyPauseProperty(
        isPaused: false,
        status: .playing,
        pauseRequested: false
    ))
    #expect(!MPVPlayerEngine.shouldApplyPauseProperty(
        isPaused: true,
        status: .playing,
        pauseRequested: false
    ))
    #expect(!MPVPlayerEngine.shouldApplyPauseProperty(
        isPaused: false,
        status: .paused,
        pauseRequested: true
    ))
    #expect(!MPVPlayerEngine.shouldApplyPauseProperty(
        isPaused: false,
        status: .idle,
        pauseRequested: false
    ))
}

@Test func testMPVVideoSurfaceOwnershipRejectsStaleWindowAttachments() {
    #expect(MPVPlayerEngine.acceptsVideoSurfaceAttachment(
        activeSurface: .vod,
        requestedSurface: .vod
    ))
    #expect(!MPVPlayerEngine.acceptsVideoSurfaceAttachment(
        activeSurface: .vod,
        requestedSurface: .live
    ))
    #expect(MPVPlayerEngine.acceptsVideoSurfaceAttachment(
        activeSurface: .live,
        requestedSurface: .live
    ))
    #expect(!MPVPlayerEngine.acceptsVideoSurfaceAttachment(
        activeSurface: .live,
        requestedSurface: .vod
    ))

    #expect(MPVPlayerEngine.acceptsVideoViewRender(
        activeViewID: 42,
        requestedViewID: 42
    ))
    #expect(!MPVPlayerEngine.acceptsVideoViewRender(
        activeViewID: 42,
        requestedViewID: 7
    ))
    #expect(!MPVPlayerEngine.acceptsVideoViewRender(
        activeViewID: nil,
        requestedViewID: 42
    ))

    var liveSpec = PlaySpec(url: "https://live.example.test/channel.m3u8")
    liveSpec.metadata["playback.kind"] = "live"
    #expect(MPVPlayerEngine.videoSurface(for: liveSpec) == .live)
    #expect(MPVPlayerEngine.videoSurface(
        for: PlaySpec(url: "https://vod.example.test/movie.m3u8")
    ) == .vod)
}

@Test func testMPVVideoSurfaceAttachmentLeaseReactivatesCachedWindowSafely() {
    var lease = MPVVideoSurfaceAttachmentLease()

    let firstOpen = lease.activate()
    #expect(lease.accepts(generation: firstOpen))

    lease.deactivate()
    #expect(!lease.accepts(generation: firstOpen))

    let reopenedWindow = lease.activate()
    #expect(reopenedWindow != firstOpen)
    #expect(lease.accepts(generation: reopenedWindow))
    #expect(!lease.accepts(generation: firstOpen))
}

@Test func testDrivePlaybackDisplayPolicyShowsOriginalAndTranscodeStatus() {
    var original = PlaySpec(url: "https://cdn.example.test/original.mp4")
    original.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.quark.rawValue
    original.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
    original.metadata[DrivePlaybackMetadataKey.qualityLabel] = "原画"

    var transcode = PlaySpec(url: "https://cdn.example.test/1080.m3u8")
    transcode.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.ali.rawValue
    transcode.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.personalTranscode
    transcode.metadata[DrivePlaybackMetadataKey.qualityLabel] = "1080P"

    var fourKTranscode = PlaySpec(url: "https://cdn.example.test/4k.m3u8")
    fourKTranscode.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.pikpak.rawValue
    fourKTranscode.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.personalTranscode
    fourKTranscode.metadata[DrivePlaybackMetadataKey.qualityLabel] = "4K"

    var ucStreaming = PlaySpec(url: "https://video-play-p-zb.cdn.yun.cn/BYBpKJL0/4k.mp4?auth_key=abc")
    ucStreaming.metadata[DrivePlaybackMetadataKey.provider] = DriveProvider.uc.rawValue
    ucStreaming.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.ucOpenAPIStreaming
    ucStreaming.metadata[DrivePlaybackMetadataKey.qualityLabel] = "4k"

    #expect(DrivePlaybackDisplayPolicy.statusText(for: original) == "原片")
    #expect(DrivePlaybackDisplayPolicy.statusText(for: transcode) == "转码 1080P")
    #expect(DrivePlaybackDisplayPolicy.statusText(for: fourKTranscode) == "4K 转码")
    #expect(DrivePlaybackDisplayPolicy.statusText(for: ucStreaming) == "4K")
    #expect(DrivePlaybackDisplayPolicy.statusText(for: PlaySpec(url: "https://media.example.test/video.mp4")) == nil)
}

@Test func testDrivePlaybackFallbackPolicyBuildsTranscodeSpecFromOriginalMetadata() {
    let originalHeaders = ["Cookie": "kps=test", "Referer": "https://pan.quark.cn"]
    let mpvOptions = ["http-proxy": "http://127.0.0.1:7890"]
    var original = PlaySpec(
        url: "https://cdn.example.test/original.mp4",
        headers: originalHeaders,
        mpvOptions: mpvOptions,
        title: "Hero Movie - 01"
    )
    original.drivePlaybackPlan = DrivePlaybackPlan(
        provider: .quark,
        asset: DrivePlaybackAssetIdentity(provider: .quark, shareID: "share", sourceFileID: "file"),
        candidates: [
            DrivePlaybackCandidate(
                id: "quark:original",
                providerRoute: DrivePlaybackRoute.originalDownload,
                kind: .original,
                transport: .localRangeProxy,
                url: original.url,
                headers: originalHeaders,
                mpvOptions: mpvOptions,
                quality: DrivePlaybackQuality(value: "Origin", label: "原画")
            ),
            DrivePlaybackCandidate(
                id: "quark:smart",
                providerRoute: DrivePlaybackRoute.personalTranscode,
                kind: .transcode,
                transport: .hlsRelay,
                url: "https://cdn.example.test/transcode-1080.m3u8",
                headers: originalHeaders,
                mpvOptions: mpvOptions,
                quality: DrivePlaybackQuality(value: "FHD", label: "1080P", width: 1920, height: 1080)
            )
        ]
    )
    original = DrivePlaybackRoutePolicy.preparedSpec(original)

    let fallback = DrivePlaybackFallbackPolicy.fallbackSpec(for: original, positionSeconds: 82.4)

    #expect(fallback?.url == "https://cdn.example.test/transcode-1080.m3u8")
    #expect(fallback?.headers["Cookie"] == "kps=test")
    #expect(fallback?.mpvOptions["http-proxy"] == "http://127.0.0.1:7890")
    #expect(fallback?.title == "Hero Movie - 01")
    #expect(fallback?.metadata[DrivePlaybackMetadataKey.route] == DrivePlaybackRoute.personalTranscode)
    #expect(fallback?.metadata[DrivePlaybackMetadataKey.quality] == "FHD")
    #expect(fallback?.metadata[DrivePlaybackMetadataKey.qualityLabel] == "1080P")
    #expect(fallback?.metadata[DrivePlaybackMetadataKey.width] == "1920")
    #expect(fallback?.metadata[DrivePlaybackMetadataKey.height] == "1080")
    #expect(DrivePlaybackRoutePolicy.candidate(for: fallback!)?.transport == .hlsRelay)
}

@Test func testDrivePlaybackFallbackPolicyBuildsSmartPlaySpecFromUCOpenAPIStreaming() {
    var streaming = PlaySpec(
        url: "https://video-play-p-zb.cdn.yun.cn/BYBpKJL0/4k.mp4?auth_key=abc",
        headers: [
            "User-Agent": "Mozilla/5.0 (Linux; U; Android 13) Mobile Safari/533.1",
            "Referer": "https://drive.uc.cn/"
        ],
        fallbackHeaders: [
            "Cookie": "__puus=token",
            "Origin": "https://drive.uc.cn",
            "Referer": "https://drive.uc.cn/s/share-token",
            "User-Agent": "uc-cloud-drive/2.5.20"
        ],
        title: "Hero Movie - 01"
    )
    streaming.drivePlaybackPlan = DrivePlaybackPlan(
        provider: .uc,
        asset: DrivePlaybackAssetIdentity(provider: .uc, shareID: "share", sourceFileID: "file"),
        candidates: [
            DrivePlaybackCandidate(
                id: "uc:streaming",
                providerRoute: DrivePlaybackRoute.ucOpenAPIStreaming,
                kind: .streaming,
                transport: .direct,
                url: streaming.url,
                headers: streaming.headers,
                quality: DrivePlaybackQuality(value: "4k", label: "4K")
            ),
            DrivePlaybackCandidate(
                id: "uc:smart",
                providerRoute: DrivePlaybackRoute.ucSmartPlay,
                kind: .transcode,
                transport: .direct,
                url: "https://video-play-c-zb.drive.uc.cn/qv/hash/media.m3u8?auth_key=low",
                quality: DrivePlaybackQuality(value: "low", label: "流畅")
            )
        ]
    )
    streaming = DrivePlaybackRoutePolicy.preparedSpec(streaming)

    #expect(DrivePlaybackFallbackPolicy.shouldFallbackAfterDirectPlaybackFailure(
        spec: streaming,
        message: "mpv 播放结束但返回错误: loading failed"
    ))
    #expect(DrivePlaybackFallbackPolicy.shouldFallbackAfterDirectPlaybackFailure(
        spec: streaming,
        message: "ffmpeg: https: HTTP error 403 Forbidden"
    ))
    #expect(!DrivePlaybackFallbackPolicy.shouldFallbackAfterDirectPlaybackFailure(
        spec: streaming,
        message: "network stalled"
    ))

    let fallback = DrivePlaybackFallbackPolicy.fallbackSpec(for: streaming, positionSeconds: 12.6)

    #expect(fallback?.url == "https://video-play-c-zb.drive.uc.cn/qv/hash/media.m3u8?auth_key=low")
    #expect(fallback?.headers.isEmpty == true)
    #expect(fallback?.fallbackHeaders.isEmpty == true)
    #expect(fallback?.title == "Hero Movie - 01")
    #expect(fallback?.metadata[DrivePlaybackMetadataKey.route] == DrivePlaybackRoute.ucSmartPlay)
    #expect(fallback?.metadata[DrivePlaybackMetadataKey.quality] == "low")
    #expect(fallback?.metadata[DrivePlaybackMetadataKey.qualityLabel] == "流畅")
    #expect(DrivePlaybackRoutePolicy.candidate(for: fallback!)?.transport == .direct)
}

@Test func testDrivePlaybackFallbackPolicyDoesNotLeakOriginalHeadersToUCPersonalTranscode() {
    var original = PlaySpec(
        url: "http://127.0.0.1:9978/stream?id=uc-original",
        headers: [
            "Cookie": "uc_cookie=account",
            "Referer": "https://drive.uc.cn/s/share"
        ]
    )
    original.drivePlaybackPlan = DrivePlaybackPlan(
        provider: .uc,
        asset: DrivePlaybackAssetIdentity(provider: .uc, shareID: "share", sourceFileID: "file"),
        candidates: [
            DrivePlaybackCandidate(
                id: "uc:original",
                providerRoute: DrivePlaybackRoute.ucOriginalProxy,
                kind: .original,
                transport: .localRangeProxy,
                url: original.url,
                headers: original.headers
            ),
            DrivePlaybackCandidate(
                id: "uc:smart",
                providerRoute: DrivePlaybackRoute.personalTranscode,
                kind: .transcode,
                transport: .direct,
                url: "https://video-play-c-zb.drive.uc.cn/qv/saved/media.m3u8?auth_key=personal"
            )
        ]
    )
    original = DrivePlaybackRoutePolicy.preparedSpec(original)

    let fallback = DrivePlaybackFallbackPolicy.fallbackSpec(for: original, positionSeconds: 0)

    #expect(fallback?.headers.isEmpty == true)
    #expect(fallback?.metadata[DrivePlaybackMetadataKey.route] == DrivePlaybackRoute.personalTranscode)
}

@Test func testDrivePlaybackFallbackPolicySkipsTranscodeAndAlreadyAppliedSpecs() {
    var transcode = PlaySpec(url: "https://cdn.example.test/transcode-1080.m3u8")
    transcode.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.personalTranscode

    var alreadyApplied = PlaySpec(url: "https://cdn.example.test/original.mp4")
    alreadyApplied.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.originalDownload
    alreadyApplied.metadata["drive.fallback.applied"] = "true"

    #expect(DrivePlaybackFallbackPolicy.fallbackSpec(for: transcode, positionSeconds: 0) == nil)
    #expect(DrivePlaybackFallbackPolicy.fallbackSpec(for: alreadyApplied, positionSeconds: 0) == nil)
}
