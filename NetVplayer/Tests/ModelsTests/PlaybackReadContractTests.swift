import Foundation
import Testing
import Models

private let readIdentity = PlaybackMediaIdentity(source: "webdav", account: "account-a", item: "/movie.mkv")

private actor ReadContractGate {
    var starts = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { starts += 1; await withCheckedContinuation { continuations.append($0) } }
    func open() { let pending = continuations; continuations = []; for c in pending { c.resume() } }
}

private func contractWait(_ predicate: () async -> Bool) async throws {
    for _ in 0..<400 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CancellationError()
}

@Test func readIdentitySurvivesRenewedURLsAndSeparatesAccounts() throws {
    var spec = PlaySpec(url: "https://one.example/file?token=old", mediaIdentity: readIdentity)
    let first = PlaybackMediaIdentity.resolved(for: spec)
    spec = spec.merging(PlaySpec(url: "https://two.example/file?token=new"))
    #expect(PlaybackMediaIdentity.resolved(for: spec) == first)
    #expect(first?.cacheKey != PlaybackMediaIdentity(source: "webdav", account: "account-b", item: "/movie.mkv").cacheKey)
    #expect(PlaybackMediaIdentity.resolved(for: PlaySpec(url: "https://unknown.example/file?token=x")) == nil)
    let reference = try FileResourceReference(serviceID: UUID(), path: "/movies/one.mkv")
    let fileSpec = PlaySpec(metadata: ["vod.episodeURL": reference.locator])
    #expect(PlaybackMediaIdentity.resolved(for: fileSpec)?.account == reference.serviceID.uuidString)
}

@Test func readHintCarriesAnOwnerGenerationRangeAndCancellation() {
    let session = PlaybackReadSession()
    let owner = session.makeOwner(mediaIdentity: readIdentity, purpose: .seek, expiry: 123)
    let hint = owner.hint(ranges: [10..<20, 40..<80])
    #expect(hint.mediaIdentity == readIdentity && hint.sessionID == session.id)
    #expect(hint.owner == owner.id && hint.generation == session.generation)
    #expect(hint.ranges == [10..<20, 40..<80] && hint.priority > PlaybackReadPurpose.nextEpisode.priority)
    #expect(hint.expiry == 123)
    owner.cancel(); #expect(hint.cancellation.isCancelled)
}

@Test func readGenerationCancelsQueuedWorkAndNeverRevivesAfterStop() async throws {
    let session = PlaybackReadSession()
    let budget = PlaybackBackgroundBudget()
    budget.update(session: "foreground", bufferedAhead: 0, isLoading: true, isSeeking: false, isBuffering: false)
    let owner = session.makeOwner(mediaIdentity: readIdentity, purpose: .subtitleExtraction)
    let gate = ReadContractGate()
    let task = Task {
        try await owner.perform { try await budget.withRead(owner: owner, bytes: 10) { await gate.wait() } }
    }
    try await contractWait { budget.waitingReadCount == 1 }
    session.advance()
    do { try await task.value; Issue.record("Old generation ran") } catch { #expect(error is CancellationError) }
    #expect(await gate.starts == 0 && budget.waitingReadCount == 0)
    let next = session.makeOwner(mediaIdentity: readIdentity, purpose: .foreground)
    #expect(!next.isCancelled && next.generation != owner.generation)
    session.stop(); session.advance()
    #expect(session.makeOwner(mediaIdentity: readIdentity, purpose: .foreground).isCancelled)
}

@Test func readOwnersCancelIndependentlyAndWaitForNonCooperativeUpstream() async throws {
    let session = PlaybackReadSession()
    let first = session.makeOwner(mediaIdentity: readIdentity, purpose: .chapterPreview)
    let second = session.makeOwner(mediaIdentity: readIdentity, purpose: .foreground)
    let gate = ReadContractGate()
    let task = Task { try await first.perform { await gate.wait(); return 7 } }
    try await contractWait { await gate.starts == 1 }
    first.cancel()
    #expect(!second.isCancelled)
    await gate.open()
    do { _ = try await task.value; Issue.record("Cancelled owner accepted late bytes") }
    catch { #expect(error is CancellationError) }
    #expect(try await second.perform { 9 } == 9)
}

@Test func readExpiryCancelsAnInFlightOperation() async throws {
    let session = PlaybackReadSession()
    let owner = session.makeOwner(mediaIdentity: readIdentity, purpose: .chapterPreview,
        expiry: ProcessInfo.processInfo.systemUptime + 0.03)
    do {
        _ = try await owner.perform { try await Task.sleep(for: .seconds(10)); return 1 }
        Issue.record("Expired operation completed")
    } catch { #expect(error is CancellationError) }
}

@Test func readScopeCancellationRetiresChildrenButPreservesOtherOwners() async throws {
    let session = PlaybackReadSession()
    let scope = PlaybackReadCancellation()
    let parent = session.makeOwner(mediaIdentity: readIdentity, purpose: .foreground, cancellation: scope)
    let child = try parent.sibling(purpose: .readAhead)
    parent.cancel() // A completed HTTP request may have seeded its read-ahead.
    #expect(!child.isCancelled)
    let other = session.makeOwner(mediaIdentity: readIdentity, purpose: .foreground)
    scope.cancel()
    #expect(child.isCancelled && !other.isCancelled)
    session.advance()
    #expect(throws: CancellationError.self) { try child.sibling(purpose: .readAhead) }
}

@Test func sharedBackgroundSlotsAndBytesBoundPreviewSubtitleAndPreload() async throws {
    let session = PlaybackReadSession()
    let budget = PlaybackBackgroundBudget(maximumConcurrentReads: 2, maximumBytes: 12)
    let gate = ReadContractGate()
    let tasks = [PlaybackReadPurpose.chapterPreview, .subtitleExtraction, .nextEpisode].map { purpose in
        Task {
            let owner = session.makeOwner(mediaIdentity: readIdentity, purpose: purpose)
            return try await owner.perform { try await budget.withRead(owner: owner, bytes: 6) { await gate.wait() } }
        }
    }
    try await contractWait { await gate.starts == 2 && budget.waitingReadCount == 1 }
    #expect(budget.reservedBytes == 12 && budget.activeBackgroundReads == 2)
    session.stop()
    await gate.open()
    for task in tasks { _ = await task.result }
    #expect(budget.reservedBytes == 0 && budget.waitingReadCount == 0)
    do {
        try await budget.withRead(bytes: 13) { Issue.record("Over-budget speculation ran") }
        Issue.record("Oversized speculative range was admitted")
    } catch { #expect((error as? URLError)?.code == .dataLengthExceedsMaximum) }
}

@Test func foregroundJoinPromotesAnAlreadyQueuedSharedTransfer() async throws {
    let budget = PlaybackBackgroundBudget()
    budget.update(session: "seeking", bufferedAhead: 0, isLoading: false, isSeeking: true, isBuffering: false)
    let priority = PlaybackReadPriority()
    let upstream = Task<Int, Error> {
        try await PlaybackReadScope.$priority.withValue(priority) {
            try await budget.withRead(owner: nil, purpose: .nextEpisode, bytes: 10) { 42 }
        }
    }
    let shared = PlaybackSharedRead(task: upstream, priority: priority)
    let background = Task { try await shared.value(phase: .preload) }
    try await contractWait { budget.waitingReadCount == 1 }
    let foreground = Task { try await shared.value(phase: .seek) }
    #expect(try await foreground.value == 42)
    #expect(try await background.value == 42)
    #expect(budget.waitingReadCount == 0 && budget.reservedBytes == 0)
}

@Test func sharedTransferKeepsItsBackgroundPurposeAfterDetachingTheCreator() async throws {
    let budget = PlaybackBackgroundBudget()
    budget.update(session: "loading", bufferedAhead: 0, isLoading: true, isSeeking: false, isBuffering: false)
    let priority = PlaybackReadPriority(purpose: .chapterPreview)
    let task = Task {
        try await PlaybackReadScope.$priority.withValue(priority) {
            try await budget.withRead(owner: nil, purpose: .foreground, bytes: 10) { 42 }
        }
    }
    try await contractWait { budget.waitingReadCount == 1 }
    priority.promote()
    #expect(try await task.value == 42)
    #expect(budget.waitingReadCount == 0)
}

@Test func firstFramePercentilesAndStallsExcludeStartupSeekAndIntentionalPause() {
    let metrics = PlaybackQualityMetrics(capacity: 3)
    metrics.beginLoad(now: 0)
    metrics.cachePause(true, eligible: false, now: 1)
    metrics.presentedFreshFrame(now: 1) // Not native-ready yet.
    #expect(metrics.snapshot(now: 1).startupFirstFrame.count == 0)
    metrics.mediaReady(); metrics.presentedFreshFrame(now: 2)
    metrics.beginSeek(now: 3); metrics.beginSeek(now: 4)
    metrics.mediaReady(); metrics.presentedFreshFrame(now: 4.5)
    metrics.cachePause(true, eligible: true, now: 5)
    metrics.cachePause(true, eligible: true, now: 6)
    #expect(metrics.snapshot(now: 7).totalStallSeconds == 2)
    metrics.cachePause(false, eligible: true, now: 8)
    metrics.cachePause(true, eligible: true, now: 12)
    metrics.cachePause(false, eligible: false, now: 13)
    let result = metrics.snapshot(now: 100)
    #expect(result.startupFirstFrame.p50 == 2 && result.startupFirstFrame.p95 == 2)
    #expect(result.seekFirstFrame.p50 == 0.5 && result.cancelledSeeks == 1)
    #expect(result.stallCount == 2 && result.totalStallSeconds == 4)
    #expect(result.restallIntervals.samples == [4])
    metrics.stop(now: 101); metrics.beginLoad(now: 102)
    metrics.mediaReady(); metrics.presentedFreshFrame(now: 103)
    #expect(metrics.snapshot().startupFirstFrame.p50 == 1)
}

@Test func vodExperimentIsOptInBoundedAndFallsBackAfterStability() {
    var disabled = VODRebufferExperiment()
    for t in 1...100 { disabled.recovered(wait: 100, now: Double(t)) }
    #expect(disabled.target == disabled.baseline)
    var experiment = VODRebufferExperiment(enabled: true, baseline: 1)
    experiment.recovered(wait: 10, now: 0)
    experiment.recovered(wait: 10, now: 2)
    #expect(experiment.target > experiment.baseline && experiment.target <= experiment.maximum)
    experiment.tick(now: 2 + experiment.stablePeriod - 1)
    #expect(experiment.target > experiment.baseline)
    experiment.tick(now: 2 + experiment.stablePeriod)
    #expect(experiment.target == experiment.baseline)
    #expect(VODRebufferExperiment(enabled: true, baseline: 20).target == 20)
}
