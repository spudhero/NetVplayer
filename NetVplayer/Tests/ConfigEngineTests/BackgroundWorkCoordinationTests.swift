import AppKit
import Foundation
import Models
import Networking
import Testing
@testable import LiveEngine
@testable import NetVplayerApp

@MainActor
@Suite(.serialized)
struct BackgroundWorkCoordinationTests {
    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<600 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for coordination", sourceLocation: sourceLocation)
        throw URLError(.timedOut)
    }
    private func pressure(_ budget: PlaybackBackgroundBudget, _ kind: String) {
        budget.update(session: "movie", bufferedAhead: 40, isLoading: kind == "load",
                      isSeeking: kind == "seek", isBuffering: kind == "buffer")
    }

    @Test(arguments: ["load", "seek", "buffer"])
    func prefetchWaitsAtEntryButVisibleDemandCompletes(kind: String) async throws {
        let budget = PlaybackBackgroundBudget(), fixture = try PosterCancellationFixture()
        defer { fixture.remove(); ImageLoader.clearMemoryCache() }
        pressure(budget, kind)
        let pipeline = fixture.pipeline(budget: budget)
        let prefetch = Task { await ImageLoader.prefetch(PosterImagePrefetchRequest(
            urls: [fixture.url("/ready/prefetch").absoluteString], maxPixelSize: 64), pipeline: pipeline) }
        defer { prefetch.cancel() }
        let visible = fixture.start(pipeline, path: "/ready/visible")
        try await wait { visible.isFinished }
        _ = try await visible.task.value
        #expect(PosterCancellationURLProtocol.state.count(for: "/ready/prefetch") == 0)
        budget.remove(session: "movie") // pause / stop releases pressure as well as recovery
        await prefetch.value
        #expect(PosterCancellationURLProtocol.state.count(for: "/ready/prefetch") == 1)
    }

    @Test func queuedSpeculationCannotSlipThroughAReleasedSlotDuringSeek() async throws {
        let budget = PlaybackBackgroundBudget(), fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline(limit: 1, budget: budget)
        let active = fixture.start(pipeline, path: "/blocked/active")
        try await wait { PosterCancellationURLProtocol.state.requestCount == 1 }
        let prefetch = fixture.start(pipeline, path: "/ready/prefetch", demand: PosterDemandToken(.prefetch))
        defer { prefetch.task.cancel(); active.task.cancel() }
        try await wait { await pipeline.schedulingMetrics().downloads.queued == 1 }
        pressure(budget, "seek")
        PosterCancellationURLProtocol.state.complete(path: "/blocked/active")
        try await wait { active.isFinished }
        #expect(PosterCancellationURLProtocol.state.count(for: "/ready/prefetch") == 0)
        let visible = fixture.start(pipeline, path: "/ready/new")
        try await wait { visible.isFinished }
        #expect(try await visible.task.value.cgImage.width == 64)
        budget.update(session: "movie", bufferedAhead: 40, isLoading: false, isSeeking: false, isBuffering: false)
        try await wait { prefetch.isFinished }
        #expect(try await prefetch.task.value.cgImage.width == 64)
    }

    @Test func completedDownloadWaitsBeforeDecodeAndVisibleJoinPromotesIt() async throws {
        let budget = PlaybackBackgroundBudget(), fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline(budget: budget)
        let token = PosterDemandToken(.prefetch)
        let low = fixture.start(pipeline, path: "/blocked/shared", demand: token)
        defer { low.task.cancel() }
        try await wait { PosterCancellationURLProtocol.state.requestCount == 1 }
        pressure(budget, "buffer")
        PosterCancellationURLProtocol.state.complete(path: "/blocked/shared")
        try await wait { await pipeline.schedulingMetrics().decodes.queued == 1 }
        #expect(await pipeline.schedulingMetrics().decodes.started == 0)
        let high = fixture.start(pipeline, path: "/blocked/shared")
        try await wait { high.isFinished && low.isFinished }
        #expect(try await high.task.value.cgImage.width == 64)
        #expect(try await low.task.value.cgImage.width == 64)
        #expect(PosterCancellationURLProtocol.state.requestCount == 1)
    }

    @Test func hiddenWindowsParkAllNewImageWorkAndCancellationNeverReplays() async throws {
        let budget = PlaybackBackgroundBudget(), fixture = try PosterCancellationFixture(), window = UUID()
        defer { fixture.remove() }
        budget.updateWindow(window, visible: false)
        let pipeline = fixture.pipeline(budget: budget)
        let image = fixture.start(pipeline, path: "/ready/visible")
        let cancelled = fixture.start(pipeline, path: "/ready/cancelled", demand: PosterDemandToken(.prefetch))
        try await wait { await pipeline.schedulingMetrics().downloads.queued == 2 }
        #expect(PosterCancellationURLProtocol.state.requestCount == 0)
        cancelled.task.cancel()
        try await wait { cancelled.isFinished }
        budget.updateWindow(window, visible: true)
        try await wait { image.isFinished }
        #expect(try await image.task.value.cgImage.width == 64)
        #expect(PosterCancellationURLProtocol.state.count(for: "/ready/cancelled") == 0)
    }

    @Test func nativeWindowOrderOutAndMiniaturizationPublishWithoutViewRemoval() async throws {
        let output = try await NativeBackgroundWindowFixture.output.value
        #expect(output.contains("PASS occluded") && output.contains("PASS unoccluded"))
        #expect(output.contains("PASS minimize") && output.contains("PASS restore"))
        #expect(output.contains("PASS close"))
    }

    @Test(arguments: ["load", "seek", "buffer", "hidden"])
    func automaticFeedWaitsAndRecoversWithoutFailureCooldown(kind: String) async throws {
        let fixture = try BudgetEPGFixture()
        defer { fixture.remove() }
        let window = UUID()
        if kind == "hidden" { fixture.budget.updateWindow(window, visible: false) }
        else { pressure(fixture.budget, kind) }
        let auto = Task { await fixture.query() }
        defer { auto.cancel() }
        try await wait { await fixture.repo.importActivity().waiters == 1 }
        #expect(EPGFixtureProtocol.count(fixture.url) == 0)
        fixture.budget.remove(session: "movie")
        fixture.budget.updateWindow(window, visible: true)
        #expect(await auto.value.availability == .available)
        #expect(EPGFixtureProtocol.count(fixture.url) == 1)
        #expect(await fixture.repo.importActivity().jobs == 0)
    }

    @Test func automaticDownloadIsInterruptedAndManualJoinPromotesPendingFeed() async throws {
        let fixture = try BudgetEPGFixture(hold: true)
        defer { fixture.remove() }
        let auto = Task { await fixture.query() }
        defer { auto.cancel() }
        try await wait { EPGFixtureProtocol.count(fixture.url) == 1 }
        pressure(fixture.budget, "seek")
        try await wait { await fixture.repo.importActivity().running == 0 }
        #expect(await fixture.repo.importActivity().waiters == 1)
        // A cancelled generation leaves no download/parser staging behind.
        let source = fixture.root.appendingPathComponent(XMLTVRepository.cacheKey(url: fixture.url, scope: "fixture", dateRequest: nil))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []).isEmpty)
        EPGFixtureProtocol.set(fixture.url, data: fixture.xml)
        let manual = Task { await fixture.query(manual: true) }
        #expect(await manual.value.availability == .available)
        #expect(await auto.value.data.items.first?.title == "Budget fixture")
        #expect(EPGFixtureProtocol.count(fixture.url) == 1)
    }

    @Test func cancellingManualConsumerDemotesSharedImportAndOtherWaiterSurvives() async throws {
        let fixture = try BudgetEPGFixture(hold: true)
        defer { fixture.remove() }
        pressure(fixture.budget, "buffer")
        let auto = Task { await fixture.query() }
        let manual = Task { await fixture.query(manual: true) }
        defer { auto.cancel(); manual.cancel() }
        try await wait { await fixture.repo.importActivity().waiters == 2 && EPGFixtureProtocol.count(fixture.url) == 1 }
        manual.cancel()
        #expect(await manual.value.availability == .unavailable)
        try await wait { await fixture.repo.importActivity().running == 0 }
        #expect(await fixture.repo.importActivity().waiters == 1)
        EPGFixtureProtocol.set(fixture.url, data: fixture.xml)
        fixture.budget.remove(session: "movie")
        #expect(await auto.value.availability == .available)
    }

    @Test func cancelledQueuedConsumersDoNotStartOnRecoveryAndSlotsAreBounded() async throws {
        let fixture = try BudgetEPGFixture()
        defer { fixture.remove() }
        pressure(fixture.budget, "load")
        let tasks = (0..<4).map { index in Task {
            await fixture.repo.programmes(url: fixture.url + "?source=\(index)", channelID: "one", channelName: "One",
                window: fixture.window, now: fixture.now)
        } }
        defer { tasks.forEach { $0.cancel() } }
        try await wait { await fixture.repo.importActivity().jobs == 4 }
        #expect(await fixture.query().availability == .unavailable)
        for task in tasks { task.cancel(); _ = await task.value }
        try await wait { await fixture.repo.importActivity().jobs == 0 }
        fixture.budget.remove(session: "movie")
        #expect(EPGFixtureProtocol.count(fixture.url) == 0)
        #expect(await fixture.query().availability == .available)
    }

    @Test func freshCachedFeedAndDatedQueriesRemainAvailableUnderPressure() async throws {
        let fixture = try BudgetEPGFixture()
        defer { fixture.remove() }
        #expect(await fixture.query().availability == .available)
        pressure(fixture.budget, "load")
        #expect(await fixture.query().availability == .available)
        #expect(EPGFixtureProtocol.count(fixture.url) == 1)
        let date = TVBoxEPGRequest(date: "2026-10-01", timeZone: TimeZone(secondsFromGMT: 0)!, channelID: "one", channelName: "One")
        let result = await fixture.repo.programmes(url: fixture.url, channelID: "one", channelName: "One",
            window: fixture.window, now: fixture.now, scope: "dated", dateRequest: date)
        #expect(result.availability == .available)
        #expect(EPGFixtureProtocol.count(fixture.url) == 2)
    }

    @Test func manualGuideRetryShowsActivityAndCancelStaysStopped() async throws {
        let fixture = try BudgetEPGFixture(hold: true), model = EPGGuideModel()
        defer { model.stop(); fixture.remove() }
        model.reset(window: fixture.window) { _, _, force in await fixture.query(manual: force) }
        model.appear(id: "one", channel: Channel(name: "One"), generation: model.generation)
        try await wait { EPGFixtureProtocol.count(fixture.url) == 1 }
        model.cancel(id: "one")
        try await wait { model.loading.isEmpty }
        #expect(model.rows["one"]?.message == L10n.text("已取消节目单加载。"))
        pressure(fixture.budget, "load")
        model.retry(id: "one")
        try await wait { EPGFixtureProtocol.count(fixture.url) == 2 }
        #expect(model.loading.contains("one"))
        model.cancel(id: "one")
        try await wait { (await fixture.repo.importActivity().jobs == 0) && model.loading.isEmpty }
        fixture.budget.remove(session: "movie")
        #expect(EPGFixtureProtocol.count(fixture.url) == 2)
    }
}

private struct BudgetEPGFixture: Sendable {
    let root: URL
    let url = "https://epg.invalid/\(UUID()).xml"
    let budget = PlaybackBackgroundBudget()
    let repo: XMLTVRepository
    let session: URLSession
    let now = Date(timeIntervalSince1970: 1_790_812_800)
    var window: DateInterval { DateInterval(start: now, duration: 3_600) }
    let xml = Data("<tv><channel id='one'><display-name>One</display-name></channel><programme channel='one' start='20261001000000 +0000' stop='20261001010000 +0000'><title>Budget fixture</title></programme></tv>".utf8)
    init(hold: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("epg-background-\(UUID())")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EPGFixtureProtocol.self]
        session = URLSession(configuration: config)
        repo = XMLTVRepository(directory: root, client: HTTPClient(session: session), budget: budget)
        EPGFixtureProtocol.set(url, data: xml, hold: hold)
    }
    func query(manual: Bool = false) async -> EpgLoadResult {
        await repo.programmes(url: url, channelID: "one", channelName: "One", window: window,
            forceRefresh: manual, now: now, scope: "fixture")
    }
    func remove() { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
}
