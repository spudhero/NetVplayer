import Foundation
import Testing
import DriveEngine
import Models
@testable import PlayerEngine
@testable import NetVplayerApp

private actor FakeThunderDownloadRuntime: ThunderDownloadRuntime {
    let data: Data
    let delay: Duration

    init(data: Data, delay: Duration = .zero) {
        self.data = data
        self.delay = delay
    }

    func download(
        _ request: ThunderDownloadRequest,
        configuration _: ThunderDownloadConfiguration
    ) async throws -> ThunderDownloadResult {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        try data.write(to: request.destinationURL)
        return ThunderDownloadResult(
            fileURL: request.destinationURL,
            downloadedBytes: Int64(data.count)
        )
    }
}

private final class ThunderRuntimeFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let runtime: any ThunderDownloadRuntime
    private var creationCount = 0

    init(runtime: any ThunderDownloadRuntime) {
        self.runtime = runtime
    }

    func make() -> any ThunderDownloadRuntime {
        lock.lock()
        creationCount += 1
        lock.unlock()
        return runtime
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return creationCount
    }
}

@Test func thunderNextEpisodeCacheRetainsNativeRuntimeAcrossDownloads() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("thunder-runtime-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let libraryURL = root.appendingPathComponent("libdk.dylib")
    try Data().write(to: libraryURL)
    let configuration = ThunderDownloadConfiguration(
        appID: "app-id",
        loginToken: "login-token",
        libraryURL: libraryURL,
        configDirectory: root.appendingPathComponent("state"),
        cacheDirectory: root.appendingPathComponent("cache")
    )
    let probe = ThunderRuntimeFactoryProbe(
        runtime: FakeThunderDownloadRuntime(data: Data("media".utf8))
    )
    let cache = ThunderNextEpisodeCache(
        runtimeFactory: { _ in probe.make() },
        configurationProvider: { configuration }
    )
    let spec = PlaySpec(
        url: "https://dl-pc-zb.drive.uc.cn/video.mp4",
        contentLength: 5,
        metadata: [
            DrivePlaybackMetadataKey.provider: DriveProvider.uc.rawValue,
            DrivePlaybackMetadataKey.route: DrivePlaybackRoute.ucOriginalProxy,
        ]
    )

    let first = try #require(await cache.prepare(spec))
    let second = try #require(await cache.prepare(spec))

    #expect(probe.count == 1)
    ThunderNextEpisodeCache.releaseCachedFile(spec: first, cacheDirectory: configuration.cacheDirectory)
    ThunderNextEpisodeCache.releaseCachedFile(spec: second, cacheDirectory: configuration.cacheDirectory)
}

@Test func thunderNextEpisodeCacheCancelsWhenEpisodeIsNoLongerNeeded() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("thunder-cache-cancel-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let libraryURL = root.appendingPathComponent("libdk.dylib")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: libraryURL)
    let configuration = ThunderDownloadConfiguration(
        appID: "app-id",
        loginToken: "login-token",
        libraryURL: libraryURL,
        configDirectory: root.appendingPathComponent("state"),
        cacheDirectory: root.appendingPathComponent("cache")
    )
    let cache = ThunderNextEpisodeCache(
        runtime: FakeThunderDownloadRuntime(data: Data("media".utf8), delay: .seconds(5)),
        configurationProvider: { configuration }
    )
    let spec = PlaySpec(
        url: "https://dl-pc-zb.drive.uc.cn/video.mp4",
        contentLength: 5,
        metadata: [
            DrivePlaybackMetadataKey.provider: DriveProvider.uc.rawValue,
            DrivePlaybackMetadataKey.route: DrivePlaybackRoute.ucOriginalProxy,
        ]
    )
    let startedAt = ContinuousClock.now

    let local = await cache.prepare(spec, while: { false })

    #expect(local == nil)
    #expect(startedAt.duration(to: .now) < .seconds(1))
    let cachedFiles = (try? FileManager.default.contentsOfDirectory(
        at: configuration.cacheDirectory,
        includingPropertiesForKeys: nil
    )) ?? []
    #expect(cachedFiles.isEmpty)
}

private actor UnacceleratedThunderRuntime: ThunderDownloadRuntime {
    private(set) var calls = 0
    let originOnly: Bool

    init(originOnly: Bool) { self.originOnly = originOnly }

    func download(
        _ request: ThunderDownloadRequest,
        configuration: ThunderDownloadConfiguration
    ) async throws -> ThunderDownloadResult {
        calls += 1
        if originOnly { throw ThunderDownloadError.noAcceleration }
        throw ThunderDownloadError.sdk(9605)
    }
}

@Test(arguments: [true, false])
func thunderNextEpisodeCacheStopsRepeatedOriginOnlyProbes(originOnly: Bool) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("thunder-no-acceleration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = ThunderDownloadConfiguration(
        appID: "fixture", loginToken: "fixture",
        libraryURL: root.appendingPathComponent("unused.dylib"),
        configDirectory: root.appendingPathComponent("state"),
        cacheDirectory: root.appendingPathComponent("cache")
    )
    let runtime = UnacceleratedThunderRuntime(originOnly: originOnly)
    let cache = ThunderNextEpisodeCache(runtime: runtime, configurationProvider: { configuration })
    let spec = PlaySpec(url: "https://media.example.test/original.mp4", contentLength: 5, metadata: [
        DrivePlaybackMetadataKey.provider: DriveProvider.uc.rawValue,
        DrivePlaybackMetadataKey.route: DrivePlaybackRoute.ucOriginalProxy,
    ])

    #expect(await cache.prepare(spec) == nil)
    #expect(await cache.prepare(spec) == nil)
    // Lack of acceleration stops repeated speculative downloads for this
    // session; refreshable SDK login errors do not permanently poison it.
    #expect(await runtime.calls == (originOnly ? 1 : 2))
    #expect(cache.canAttemptAcceleration == !originOnly)
}

@Test func thunderCancelledDownloadRemovesOnlyOwnedPartialFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("thunder-partial-cleanup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("episode.mp4")
    let paths = ["episode.mp4", "episode.mp4.xltd", "episode.mp4.xltd.cfg", "another.mp4.xltd"]
    for path in paths { try Data("partial".utf8).write(to: root.appendingPathComponent(path)) }
    let request = ThunderDownloadRequest(
        url: "https://example.test/video", headers: [:], destinationURL: destination, expectedSize: nil
    )

    request.removePartialFiles()

    let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(remaining == ["another.mp4.xltd"])
}

@Test func thunderNextEpisodeCacheRequiresUCOriginalRoute() {
    let original = PlaySpec(url: "https://media.example.test/original.mp4", contentLength: 5, metadata: [
        DrivePlaybackMetadataKey.provider: DriveProvider.uc.rawValue,
        DrivePlaybackMetadataKey.route: DrivePlaybackRoute.ucOriginalProxy,
    ])
    var streaming = original
    streaming.metadata[DrivePlaybackMetadataKey.route] = DrivePlaybackRoute.ucOpenAPIStreaming

    #expect(ThunderNextEpisodeCache.supports(original))
    #expect(!ThunderNextEpisodeCache.supports(streaming))
}

@Test func thunderNextEpisodeCachePublishesAndCleansVerifiedLocalFile() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("thunder-cache-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let libraryURL = root.appendingPathComponent("libdk.dylib")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: libraryURL)
    let configuration = ThunderDownloadConfiguration(
        appID: "app-id",
        loginToken: "login-token",
        libraryURL: libraryURL,
        configDirectory: root.appendingPathComponent("state"),
        cacheDirectory: root.appendingPathComponent("cache")
    )
    let cache = ThunderNextEpisodeCache(
        runtime: FakeThunderDownloadRuntime(data: Data("media".utf8)),
        configurationProvider: { configuration }
    )
    var spec = PlaySpec(
        url: "https://video-play-zb.drive.uc.cn/video.m3u8",
        metadata: [
            DrivePlaybackMetadataKey.fileName: "episode.mp4",
            DrivePlaybackMetadataKey.size: "5",
        ]
    )
    let originalURL = "https://dl-pc-zb.drive.uc.cn/video.mp4"
    spec.drivePlaybackPlan = DrivePlaybackPlan(
        provider: .uc,
        asset: DrivePlaybackAssetIdentity(provider: .uc, sourceFileID: "episode"),
        candidates: [
            DrivePlaybackCandidate(
                id: "uc:streaming",
                providerRoute: DrivePlaybackRoute.ucOpenAPIStreaming,
                kind: .streaming,
                transport: .direct,
                url: spec.url
            ),
            DrivePlaybackCandidate(
                id: "uc:original",
                providerRoute: DrivePlaybackRoute.ucOriginalProxy,
                kind: .original,
                transport: .localRangeProxy,
                url: originalURL,
                headers: ["Cookie": "private"],
                expectedSize: 5
            ),
        ]
    )
    spec = DrivePlaybackRoutePolicy.preparedSpec(spec)
    #expect(!ThunderNextEpisodeCache.supports(spec)) // Respect the selected streaming quality.
    let original = try #require(spec.drivePlaybackPlan?.candidates.first(where: { $0.id == "uc:original" }))
    spec = DrivePlaybackRoutePolicy.spec(for: original, basedOn: spec, manualSelection: true)

    #expect(ThunderNextEpisodeCache.supports(spec))
    #expect(ThunderNextEpisodeCache.shouldStartPreload(
        for: spec,
        positionSeconds: 30,
        bufferedUntilSeconds: 45,
        isLoading: false,
        isSeeking: false,
        configurationAvailable: true
    ))
    #expect(!ThunderNextEpisodeCache.shouldStartPreload(
        for: spec,
        positionSeconds: 30,
        bufferedUntilSeconds: 44.9,
        isLoading: false,
        isSeeking: false,
        configurationAvailable: true
    ))
    let local = try #require(await cache.prepare(spec))
    let cachePath = try #require(local.metadata[ThunderNextEpisodeCache.cachePathMetadataKey])
    #expect(local.url.hasPrefix("file://"))
    #expect(local.headers.isEmpty)
    #expect(local.contentLength == 5)
    #expect(local.metadata[DrivePlaybackMetadataKey.route] == DrivePlaybackRoute.ucOriginalProxy)
    #expect(local.metadata[ThunderNextEpisodeCache.originalURLMetadataKey] == originalURL)
    #expect(FileManager.default.fileExists(atPath: cachePath))

    ThunderNextEpisodeCache.releaseCachedFile(spec: local, cacheDirectory: configuration.cacheDirectory)
    #expect(!FileManager.default.fileExists(atPath: cachePath))
}

@Test func playbackPreloadPolicyUsesTransitionPointAndBufferedCoverage() {
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_710,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_800,
        endingSkipSeconds: 60,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: false
    ) == .metadataAndMedia)
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_769,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_800,
        endingSkipSeconds: 0,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: false
    ) == .none)
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_770,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_799,
        endingSkipSeconds: 0,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: false
    ) == .metadataAndMedia)
}

@Test func playbackPreloadPolicyFallsBackToMetadataWithoutCompetingForBandwidth() {
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_731,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_735,
        endingSkipSeconds: 60,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: false
    ) == .metadataOnly)
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_720,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_725,
        endingSkipSeconds: 60,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: false
    ) == .none)
}

@Test func playbackPreloadPolicyKeepsStandardSourcesOnTheConservativeWindow() {
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_710,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_720,
        endingSkipSeconds: 60,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: false
    ) == .none)
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_731,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_735,
        endingSkipSeconds: 60,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: false
    ) == .metadataOnly)
}

@Test func playbackPreloadPolicyPreparesSlowRangeSourcesAtThirtySecondsWithBufferGuard() {
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_710,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_720,
        endingSkipSeconds: 60,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: false,
        allowsEarlyMediaPreload: true
    ) == .metadataOnly)
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_710,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_725,
        endingSkipSeconds: 60,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: false,
        allowsEarlyMediaPreload: true
    ) == .metadataAndMedia)
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_709,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_800,
        endingSkipSeconds: 60,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: false,
        allowsEarlyMediaPreload: true
    ) == .none)
}

@Test func playbackPreloadPolicyRejectsUnsafeOrIrrelevantStates() {
    let base = PlaybackPreloadPolicy.decision(
        positionSeconds: 1_795,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_800,
        endingSkipSeconds: 0,
        hasNextEpisode: false,
        isLoading: false,
        isSeeking: false
    )
    #expect(base == .none)
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_795,
        durationSeconds: .nan,
        bufferedUntilSeconds: 1_800,
        endingSkipSeconds: 0,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: false
    ) == .none)
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_795,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_800,
        endingSkipSeconds: 0,
        hasNextEpisode: true,
        isLoading: true,
        isSeeking: false
    ) == .none)
    #expect(PlaybackPreloadPolicy.decision(
        positionSeconds: 1_795,
        durationSeconds: 1_800,
        bufferedUntilSeconds: 1_800,
        endingSkipSeconds: 0,
        hasNextEpisode: true,
        isLoading: false,
        isSeeking: true
    ) == .none)
}

@MainActor
@Test func nextEpisodePreloadCoordinatorCoalescesUpgradesAndRejectsStaleKeys() async {
    let coordinator = NextEpisodePreloadCoordinator(ttl: 90)
    let site = Site(key: "site", name: "Site", type: 3, api: "csp_Test")
    let episode = Episode(name: "E2", url: "episode-2")
    let key = PlaybackPreloadKey(
        siteKey: site.key,
        vodID: "vod",
        playFlag: "line",
        currentEpisodeURL: "episode-1",
        targetEpisodeURL: episode.url,
        playbackGeneration: 7
    )
    var calls = 0
    let firstScheduled = coordinator.request(key: key, decision: .metadataOnly, onDiscard: { _ in }) { decision, reusable in
        calls += 1
        #expect(reusable == nil)
        return PreparedEpisodePlayback(
            key: key,
            site: site,
            episode: episode,
            spec: PlaySpec(url: "https://media.example.test/e2.mp4"),
            decision: decision,
            mediaBytes: 0,
            preparedAt: Date()
        )
    }
    let duplicateScheduled = coordinator.request(
        key: key,
        decision: .metadataOnly,
        onDiscard: { _ in }
    ) { _, _ in
        Issue.record("Duplicate request must not start another operation")
        return nil
    }
    let first = await coordinator.consume(key: key)
    #expect(firstScheduled)
    #expect(!duplicateScheduled)
    #expect(first?.decision == .metadataOnly)
    #expect(calls == 1)
    #expect(await coordinator.consume(key: key) == nil)
}

@MainActor
@Test func nextEpisodePreloadCoordinatorAcceptsSDKUpgradeOnlyBeforeConsumption() async throws {
    let coordinator = NextEpisodePreloadCoordinator()
    let site = Site(key: "site", name: "Site", type: 3, api: "csp_Test")
    let episode = Episode(name: "E2", url: "episode-2")
    let key = PlaybackPreloadKey(siteKey: site.key, vodID: "vod", playFlag: "line",
        currentEpisodeURL: "episode-1", targetEpisodeURL: episode.url, playbackGeneration: 7)
    let ordinary = PreparedEpisodePlayback(key: key, site: site, episode: episode,
        spec: PlaySpec(url: "https://example.test/e2.mp4"), decision: .metadataAndMedia,
        mediaBytes: 512_000, preparedAt: Date())
    var replacement = ordinary
    replacement.spec.url = "file:///private/tmp/e2.mp4"
    replacement.mediaBytes = 2_000_000
    var published = false
    coordinator.request(key: key, decision: .metadataAndMedia, onDiscard: { _ in }) { _, _ in
        published = true
        return ordinary
    }
    while !published { await Task.yield() }
    #expect(coordinator.upgradeMediaIfUnconsumed(replacement, expectedURL: "https://example.test/stale") == nil)
    let released = try #require(coordinator.upgradeMediaIfUnconsumed(replacement, expectedURL: ordinary.spec.url))
    #expect(released.spec.url == ordinary.spec.url)
    let consumed = try #require(await coordinator.consume(key: key))
    #expect(consumed.spec.url == replacement.spec.url && consumed.mediaBytes == replacement.mediaBytes)
    #expect(coordinator.upgradeMediaIfUnconsumed(ordinary, expectedURL: replacement.spec.url) == nil)
    #expect(await coordinator.consume(key: key) == nil)
}

@MainActor
@Test func nextEpisodePreloadCoordinatorInvalidationDiscardsLatePublication() async {
    let coordinator = NextEpisodePreloadCoordinator(ttl: 90)
    let site = Site(key: "site", name: "Site", type: 3, api: "csp_Test")
    let episode = Episode(name: "E2", url: "episode-2")
    let key = PlaybackPreloadKey(
        siteKey: site.key,
        vodID: "vod",
        playFlag: "line",
        currentEpisodeURL: "episode-1",
        targetEpisodeURL: episode.url,
        playbackGeneration: 7
    )
    coordinator.request(key: key, decision: .metadataOnly, onDiscard: { _ in }) { decision, _ in
        try? await Task.sleep(for: .milliseconds(50))
        return PreparedEpisodePlayback(
            key: key,
            site: site,
            episode: episode,
            spec: PlaySpec(url: "https://media.example.test/e2.mp4"),
            decision: decision,
            mediaBytes: 0,
            preparedAt: Date()
        )
    }
    _ = coordinator.invalidate()
    try? await Task.sleep(for: .milliseconds(80))
    #expect(await coordinator.consume(key: key) == nil)
}

@MainActor
@Test func nextEpisodePreloadFailureDoesNotLaunchQueuedMediaUpgrade() async {
    let coordinator = NextEpisodePreloadCoordinator()
    let key = PlaybackPreloadKey(
        siteKey: "site", vodID: "film", playFlag: "line",
        currentEpisodeURL: "33", targetEpisodeURL: "34", playbackGeneration: 1
    )
    var decisions: [PlaybackPreloadDecision] = []
    let operation: NextEpisodePreloadCoordinator.Operation = { decision, _ in
        decisions.append(decision)
        return nil
    }
    coordinator.request(key: key, decision: .metadataOnly, onDiscard: { _ in }, operation: operation)
    coordinator.request(key: key, decision: .metadataAndMedia, onDiscard: { _ in }, operation: operation)
    #expect(await coordinator.consume(key: key) == nil)
    #expect(decisions == [.metadataOnly])
    #expect(coordinator.currentKey == nil)
}

@MainActor
@Test func nextEpisodePreloadCoordinatorClearsFailedSlotSoLaterTriggerRetries() async {
    let coordinator = NextEpisodePreloadCoordinator(ttl: 90)
    let site = Site(key: "site", name: "Site", type: 3, api: "csp_Test")
    let episode = Episode(name: "E2", url: "episode-2")
    let key = PlaybackPreloadKey(
        siteKey: site.key,
        vodID: "vod",
        playFlag: "line",
        currentEpisodeURL: "episode-1",
        targetEpisodeURL: episode.url,
        playbackGeneration: 7
    )
    var calls = 0
    let operation: NextEpisodePreloadCoordinator.Operation = { decision, _ in
        calls += 1
        guard calls > 1 else { return nil }
        return PreparedEpisodePlayback(
            key: key,
            site: site,
            episode: episode,
            spec: PlaySpec(url: "https://media.example.test/e2.mp4"),
            decision: decision,
            mediaBytes: 0,
            preparedAt: Date()
        )
    }

    coordinator.request(key: key, decision: .metadataOnly, onDiscard: { _ in }, operation: operation)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(coordinator.currentKey == nil)

    let retried = coordinator.request(
        key: key,
        decision: .metadataAndMedia,
        onDiscard: { _ in },
        operation: operation
    )
    let prepared = await coordinator.consume(key: key)
    #expect(retried)
    #expect(calls == 2)
    #expect(prepared?.decision == .metadataAndMedia)
}

@MainActor
private func waitForPreloadTestCondition(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
@Test func nextEpisodePreloadCoordinatorConsumesMetadataWithoutWaitingForMediaUpgrade() async throws {
    let coordinator = NextEpisodePreloadCoordinator(ttl: 90)
    let site = Site(key: "site", name: "Site", type: 3, api: "csp_Test")
    let episode = Episode(name: "E2", url: "episode-2")
    let key = PlaybackPreloadKey(
        siteKey: site.key,
        vodID: "vod",
        playFlag: "line",
        currentEpisodeURL: "episode-1",
        targetEpisodeURL: episode.url,
        playbackGeneration: 7
    )
    var coldCalls = 0
    var upgradeCalls = 0
    var upgradeFinished = false
    var discardCalls = 0
    let (upgradeRelease, upgradeReleaseContinuation) = AsyncStream<Void>.makeStream()
    defer { upgradeReleaseContinuation.finish() }
    let operation: NextEpisodePreloadCoordinator.Operation = { decision, reusable in
        if var reusable {
            upgradeCalls += 1
            var release = upgradeRelease.makeAsyncIterator()
            _ = await release.next()
            reusable.decision = decision
            reusable.mediaBytes = 1_024
            upgradeFinished = true
            return reusable
        }
        coldCalls += 1
        return PreparedEpisodePlayback(
            key: key,
            site: site,
            episode: episode,
            spec: PlaySpec(url: "https://media.example.test/e2.mp4"),
            decision: decision,
            mediaBytes: 0,
            preparedAt: Date()
        )
    }

    let onDiscard: @MainActor @Sendable (PreparedEpisodePlayback) -> Void = { _ in
        discardCalls += 1
    }
    coordinator.request(key: key, decision: .metadataOnly, onDiscard: onDiscard, operation: operation)
    coordinator.request(key: key, decision: .metadataAndMedia, onDiscard: onDiscard, operation: operation)
    try #require(await waitForPreloadTestCondition { upgradeCalls == 1 })
    var prepared: PreparedEpisodePlayback?
    var consumptionFinished = false
    let consumption = Task { @MainActor in
        prepared = await coordinator.consume(key: key)
        consumptionFinished = true
    }
    let consumedWhileUpgradeBlocked = await waitForPreloadTestCondition { consumptionFinished }

    #expect(coldCalls == 1)
    #expect(upgradeCalls == 1)
    #expect(consumedWhileUpgradeBlocked)
    #expect(prepared?.decision == .metadataOnly)
    #expect(prepared?.mediaBytes == 0)
    #expect(!upgradeFinished)

    upgradeReleaseContinuation.finish()
    await consumption.value
    #expect(await waitForPreloadTestCondition { upgradeFinished })
    #expect(discardCalls == 0)
}

@MainActor
@Test func nextEpisodePreloadCoordinatorExpiresAndDiscardsPreparedResources() async {
    let coordinator = NextEpisodePreloadCoordinator(ttl: 0.02)
    let site = Site(key: "site", name: "Site", type: 3, api: "csp_Test")
    let episode = Episode(name: "E2", url: "episode-2")
    let key = PlaybackPreloadKey(
        siteKey: site.key,
        vodID: "vod",
        playFlag: "line",
        currentEpisodeURL: "episode-1",
        targetEpisodeURL: episode.url,
        playbackGeneration: 7
    )
    var discarded: PreparedEpisodePlayback?
    var discardedWhileFresh = false
    coordinator.request(key: key, decision: .metadataOnly, onDiscard: { prepared in
        discarded = prepared
        discardedWhileFresh = prepared.isFresh(ttl: 0.02)
    }) { decision, _ in
        PreparedEpisodePlayback(
            key: key,
            site: site,
            episode: episode,
            spec: PlaySpec(url: "https://media.example.test/e2.mp4"),
            decision: decision,
            mediaBytes: 0,
            preparedAt: Date()
        )
    }

    #expect(await waitForPreloadTestCondition { discarded != nil })
    #expect(discarded?.key == key)
    #expect(!discardedWhileFresh)
    #expect(coordinator.currentKey == nil)
    #expect(await coordinator.consume(key: key) == nil)
}

@MainActor
@Test func nextEpisodePreloadCoordinatorDiscardsPreparedEntryWhenKeyChanges() async {
    let coordinator = NextEpisodePreloadCoordinator(ttl: 90)
    let site = Site(key: "site", name: "Site", type: 3, api: "csp_Test")
    let episode = Episode(name: "E2", url: "episode-2")
    let firstKey = PlaybackPreloadKey(
        siteKey: site.key,
        vodID: "vod",
        playFlag: "line",
        currentEpisodeURL: "episode-1",
        targetEpisodeURL: episode.url,
        playbackGeneration: 7
    )
    let secondKey = PlaybackPreloadKey(
        siteKey: site.key,
        vodID: "vod",
        playFlag: "line",
        currentEpisodeURL: "episode-2",
        targetEpisodeURL: "episode-3",
        playbackGeneration: 8
    )
    var discardedKeys: [PlaybackPreloadKey] = []
    let operation: NextEpisodePreloadCoordinator.Operation = { decision, _ in
        PreparedEpisodePlayback(
            key: decision == .metadataOnly ? firstKey : secondKey,
            site: site,
            episode: episode,
            spec: PlaySpec(url: "https://media.example.test/e2.mp4"),
            decision: decision,
            mediaBytes: 0,
            preparedAt: Date()
        )
    }

    coordinator.request(key: firstKey, decision: .metadataOnly, onDiscard: {
        discardedKeys.append($0.key)
    }, operation: operation)
    try? await Task.sleep(for: .milliseconds(10))
    coordinator.request(key: secondKey, decision: .metadataAndMedia, onDiscard: {
        discardedKeys.append($0.key)
    }, operation: operation)
    let second = await coordinator.consume(key: secondKey)

    #expect(discardedKeys == [firstKey])
    #expect(second?.key == secondKey)
}
