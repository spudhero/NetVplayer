import AppKit
import Foundation
import Testing
@testable import NetVplayerApp

@MainActor
@Suite(.serialized)
struct PosterDemandSchedulingTests {
    @Test func scrollPromotesNewlyVisibleAndDemotesPreviousDemand() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline(limit: 1)
        let blocker = fixture.start(pipeline, path: "/blocked/active")
        defer { blocker.task.cancel() }
        try await wait { PosterCancellationURLProtocol.state.requestCount == 1 }
        let old = PosterDemandToken(.visible)
        let new = PosterDemandToken(.prefetch)
        let first = fixture.start(pipeline, path: "/blocked/old", demand: old)
        let second = fixture.start(pipeline, path: "/blocked/new", demand: new)
        defer { first.task.cancel(); second.task.cancel() }
        try await wait { await pipeline.schedulingMetrics().downloads.queued == 2 }
        old.update(.nearby)
        new.update(.visible)
        await pipeline.updateDemand(old)
        await pipeline.updateDemand(new)
        PosterCancellationURLProtocol.state.complete(path: "/blocked/active")
        try await wait { PosterCancellationURLProtocol.state.count(for: "/blocked/new") == 1 }
        #expect(PosterCancellationURLProtocol.state.count(for: "/blocked/old") == 0)
        PosterCancellationURLProtocol.state.complete(path: "/blocked/new")
        try await wait { second.isFinished }
        #expect(try await second.task.value.cgImage.width == 64)
    }

    @Test(arguments: [64, 256])
    func cancellingVisibleWaiterRecomputesSharedDownloadDemand(secondSize: Int) async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline(limit: 1)
        let blocker = fixture.start(pipeline, path: "/blocked/active")
        defer { blocker.task.cancel() }
        try await wait { PosterCancellationURLProtocol.state.requestCount == 1 }
        let visible = fixture.start(pipeline, path: "/blocked/shared")
        let speculative = fixture.start(pipeline, path: "/blocked/shared", size: secondSize, demand: PosterDemandToken(.prefetch))
        let other = fixture.start(pipeline, path: "/blocked/other", demand: PosterDemandToken(.nearby))
        defer { visible.task.cancel(); speculative.task.cancel(); other.task.cancel() }
        try await wait { await pipeline.schedulingMetrics().downloads.queued == 2 }
        visible.task.cancel()
        try await wait { visible.isFinished }
        PosterCancellationURLProtocol.state.complete(path: "/blocked/active")
        try await wait { PosterCancellationURLProtocol.state.count(for: "/blocked/other") == 1 }
        #expect(PosterCancellationURLProtocol.state.count(for: "/blocked/shared") == 0)
        #expect(!speculative.isFinished)
        PosterCancellationURLProtocol.state.complete(path: "/blocked/other")
        try await wait { PosterCancellationURLProtocol.state.count(for: "/blocked/shared") == 1 }
        PosterCancellationURLProtocol.state.complete(path: "/blocked/shared")
        try await wait { speculative.isFinished }
        #expect(try await speculative.task.value.cgImage.width == secondSize)
        #expect(PosterCancellationURLProtocol.state.cancellationCount == 0)
    }

    @Test func updatingTokenBeforeAdmissionUsesLatestDemand() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline(limit: 1)
        let blocker = fixture.start(pipeline, path: "/blocked/active")
        defer { blocker.task.cancel() }
        try await wait { PosterCancellationURLProtocol.state.requestCount == 1 }
        let token = PosterDemandToken(.prefetch)
        token.update(.visible)
        await pipeline.updateDemand(token) // No registered consumer yet.
        let low = fixture.start(pipeline, path: "/blocked/low", demand: PosterDemandToken(.nearby))
        let high = fixture.start(pipeline, path: "/blocked/high", demand: token)
        defer { low.task.cancel(); high.task.cancel() }
        try await wait { await pipeline.schedulingMetrics().downloads.queued == 2 }
        PosterCancellationURLProtocol.state.complete(path: "/blocked/active")
        try await wait { PosterCancellationURLProtocol.state.count(for: "/blocked/high") == 1 }
        #expect(PosterCancellationURLProtocol.state.count(for: "/blocked/low") == 0)
    }

    @Test func multiplePrefetchBatchesLeaveDownloadCapacityForVisibleImages() async throws {
        ImageLoader.clearMemoryCache()
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove(); ImageLoader.clearMemoryCache() }
        let pipeline = fixture.pipeline()
        let batches = (0..<4).map { batch in Task {
            await ImageLoader.prefetch(PosterImagePrefetchRequest(urls: (0..<6).map {
                fixture.url("/blocked/prefetch-\(batch)-\($0)").absoluteString
            }, maxPixelSize: 64), pipeline: pipeline)
        } }
        defer { for batch in batches { batch.cancel() } }
        try await wait { await pipeline.schedulingMetrics().downloads.queued == 6 }
        #expect(PosterCancellationURLProtocol.state.requestCount == 2)
        let visible = fixture.start(pipeline, path: "/ready/visible")
        defer { visible.task.cancel() }
        try await wait { visible.isFinished }
        #expect(try await visible.task.value.cgImage.width == 64)
        #expect(await pipeline.schedulingMetrics().downloads.peakActive == 3)
        for batch in batches { batch.cancel(); await batch.value }
    }

    @Test func boundedAdmissionEvictsLowerDemandAndRejectsEqualOverflow() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline(limit: 1, outstanding: 3)
        let blocker = fixture.start(pipeline, path: "/blocked/active")
        defer { blocker.task.cancel() }
        try await wait { PosterCancellationURLProtocol.state.requestCount == 1 }
        let nearby = fixture.start(pipeline, path: "/blocked/nearby", demand: PosterDemandToken(.nearby))
        let far = fixture.start(pipeline, path: "/blocked/far", demand: PosterDemandToken(.prefetch))
        defer { blocker.task.cancel(); nearby.task.cancel(); far.task.cancel() }
        try await wait { await pipeline.schedulingMetrics().downloads.queued == 2 }
        let overflow = fixture.start(pipeline, path: "/blocked/overflow", demand: PosterDemandToken(.prefetch))
        try await wait { overflow.isFinished }
        await expectDeferred(overflow.task)
        let visible = fixture.start(pipeline, path: "/ready/visible")
        defer { visible.task.cancel() }
        try await wait { far.isFinished }
        await expectDeferred(far.task)
        #expect(!nearby.isFinished)
        let metrics = await pipeline.schedulingMetrics()
        #expect(metrics.peakOutstanding == 3 && metrics.deferred == 2)
        #expect(metrics.downloads.peakQueued <= 2)
        PosterCancellationURLProtocol.state.complete(path: "/blocked/active")
        try await wait { visible.isFinished }
        #expect(try await visible.task.value.cgImage.width == 64)
        #expect(PosterCancellationURLProtocol.state.count(for: "/blocked/far") == 0)
    }

    @Test func deferredLoaderCanRetryWithoutNegativeCache() async throws {
        ImageLoader.clearMemoryCache()
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove(); ImageLoader.clearMemoryCache() }
        let pipeline = fixture.pipeline(limit: 1, outstanding: 1)
        let blocker = fixture.start(pipeline, path: "/blocked/active")
        defer { blocker.task.cancel() }
        try await wait { PosterCancellationURLProtocol.state.requestCount == 1 }
        let loader = ImageLoader(pipeline: pipeline)
        let url = fixture.url("/ready/retry").absoluteString
        loader.load(from: url, maxPixelSize: 64)
        try await wait { loader.isDeferred }
        let (signals, continuation) = AsyncStream<Void>.makeStream()
        let observer = NotificationCenter.default.addObserver(
            forName: .posterWorkCapacityDidChange, object: nil, queue: nil
        ) { _ in
            continuation.yield(())
            continuation.finish()
        }
        defer { NotificationCenter.default.removeObserver(observer); continuation.finish() }
        PosterCancellationURLProtocol.state.complete(path: "/blocked/active")
        for await _ in signals { break }
        loader.load(from: url, maxPixelSize: 64)
        try await wait { loader.image != nil }
        #expect(!loader.isDeferred && !loader.isLoading)
        #expect(PosterCancellationURLProtocol.state.count(for: "/ready/retry") == 1)
    }

    @Test func defaultCapacityBoundsLargeBurstAndStillAdmitsVisibleWork() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline()
        let low = (0..<100).map { fixture.start(pipeline, path: "/blocked/low-\($0)", demand: PosterDemandToken(.prefetch)) }
        defer { low.forEach { $0.task.cancel() } }
        try await wait { low.filter(\.isFinished).count == 4 }
        #expect(await pipeline.schedulingMetrics().outstanding == 96)
        let visible = fixture.start(pipeline, path: "/ready/visible")
        defer { visible.task.cancel() }
        try await wait { visible.isFinished }
        #expect(try await visible.task.value.cgImage.width == 64)
        let metrics = await pipeline.schedulingMetrics()
        #expect(metrics.peakOutstanding == 96)
        #expect(metrics.downloads.peakQueued <= 96 && metrics.deferred == 5)
    }

    @Test func cancelledSizeWaitersDoNotAccumulateBehindSharedDownload() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline()
        let shared = fixture.start(pipeline, path: "/blocked/shared")
        defer { shared.task.cancel() }
        try await wait { await pipeline.schedulingMetrics().dataWaiters == 1 }
        for index in 0..<20 {
            let transient = fixture.start(pipeline, path: "/blocked/shared", size: 128 + index * 32)
            try await wait { await pipeline.schedulingMetrics().dataWaiters == 2 }
            transient.task.cancel()
            try await wait { await pipeline.schedulingMetrics().imageTasks == 1 }
            #expect(await pipeline.schedulingMetrics().dataWaiters == 1)
        }
        #expect(PosterCancellationURLProtocol.state.requestCount == 1)
        #expect(PosterCancellationURLProtocol.state.cancellationCount == 0)
        PosterCancellationURLProtocol.state.complete(path: "/blocked/shared")
        #expect(try await shared.task.value.cgImage.width == 64)
    }

    @Test func cancelledDecodeKeepsLeaseUntilSynchronousWorkerReturns() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let gate = PosterDecodeGate()
        defer { gate.open() }
        let pipeline = fixture.pipeline(decodeLimit: 2, decoder: gate.decode)
        let first = fixture.start(pipeline, path: "/ready/first")
        let second = fixture.start(pipeline, path: "/ready/second")
        defer { first.task.cancel(); second.task.cancel() }
        try await wait { gate.started == 2 }
        first.task.cancel()
        try await wait { first.isFinished }
        let third = fixture.start(pipeline, path: "/ready/third")
        defer { third.task.cancel() }
        try await wait { await pipeline.schedulingMetrics().decodes.queued == 1 }
        #expect(gate.started == 2)
        #expect(await pipeline.schedulingMetrics().decodes.active == 2)
        gate.open()
        try await wait { second.isFinished && third.isFinished }
        #expect(try await third.task.value.cgImage.width == 64)
        #expect(gate.peakActive == 2)
        #expect(await pipeline.schedulingMetrics().decodes.peakActive == 2)
        try await wait { await pipeline.schedulingMetrics().decodes.active == 0 }
    }

    @Test func clearDuringDecodeRejectsOldResultAndDoesNotExceedDecodeLimit() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let gate = PosterDecodeGate()
        defer { gate.open() }
        let pipeline = fixture.pipeline(decodeLimit: 1, decoder: gate.decode)
        let old = fixture.start(pipeline, path: "/ready/same")
        defer { old.task.cancel() }
        try await wait { gate.started == 1 }
        try await pipeline.clearDiskCache()
        try await wait { old.isFinished }
        let fresh = fixture.start(pipeline, path: "/ready/same")
        defer { fresh.task.cancel() }
        try await wait { await pipeline.schedulingMetrics().decodes.queued == 1 }
        #expect(await pipeline.diskUsage() == 0)
        #expect(gate.started == 1)
        gate.open()
        try await wait { fresh.isFinished }
        #expect(try await fresh.task.value.cgImage.width == 64)
        #expect(PosterCancellationURLProtocol.state.requestCount == 2)
        #expect(gate.peakActive == 1)
    }

    @Test func decodedCacheHitsAlsoObeyDecodeLimitAndDemandOrder() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let warm = fixture.pipeline()
        for name in ["a", "b", "c"] {
            let work = fixture.start(warm, path: "/ready/\(name)")
            _ = try await work.task.value
        }
        let gate = PosterDecodeGate()
        defer { gate.open() }
        let pipeline = fixture.pipeline(decodeLimit: 1, decoder: gate.decode)
        let first = fixture.start(pipeline, path: "/ready/a")
        defer { first.task.cancel() }
        try await wait { gate.started == 1 }
        let low = fixture.start(pipeline, path: "/ready/b", size: 128, demand: PosterDemandToken(.prefetch))
        let high = fixture.start(pipeline, path: "/ready/c", size: 256)
        defer { low.task.cancel(); high.task.cancel() }
        try await wait { await pipeline.schedulingMetrics().decodes.queued == 2 }
        gate.open()
        _ = try await high.task.value
        _ = try await low.task.value
        #expect(gate.sizes == [64, 256, 128])
        #expect(PosterCancellationURLProtocol.state.requestCount == 3)
        #expect(await pipeline.schedulingMetrics().downloads.started == 0)
    }

    @Test func visibleFirstScreenUnderSpeculativeBacklog() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline()
        let prefetch = (0..<64).map { fixture.start(pipeline, path: "/blocked/prefetch-\($0)", demand: PosterDemandToken(.prefetch)) }
        defer { prefetch.forEach { $0.task.cancel() } }
        try await wait { await pipeline.schedulingMetrics().downloads.queued == 62 }
        let clock = ContinuousClock()
        let start = clock.now
        let visible = (0..<12).map { fixture.start(pipeline, path: "/ready/visible-\($0)") }
        defer { visible.forEach { $0.task.cancel() } }
        try await wait { visible.contains(where: \.isFinished) }
        let firstSeconds = seconds(start.duration(to: clock.now))
        for work in visible { _ = try await work.task.value }
        let allSeconds = seconds(start.duration(to: clock.now))
        let metrics = await pipeline.schedulingMetrics()
        #expect(metrics.downloads.peakActive <= 8 && metrics.decodes.peakActive <= 2)
        #expect(metrics.peakOutstanding <= 96 && metrics.downloads.peakQueued <= 96)
        #expect(PosterCancellationURLProtocol.state.requestCount == 14)
        if let path = ProcessInfo.processInfo.environment["NETVPLAYER_POSTER_EVIDENCE_PATH"] {
            let report: [String: Any] = ["fixture": "64 blocked speculative + 12 immediate HTTP fixture posters; real ImageIO",
                "first_visible_seconds": firstSeconds, "first_screen_12_seconds": allSeconds,
                "peak_downloads": metrics.downloads.peakActive, "peak_decodes": metrics.decodes.peakActive,
                "peak_download_queue": metrics.downloads.peakQueued, "peak_decode_queue": metrics.decodes.peakQueued,
                "peak_outstanding_variants": metrics.peakOutstanding,
                "maximum_download_wait_seconds": metrics.downloads.maximumWaitSeconds,
                "maximum_decode_wait_seconds": metrics.decodes.maximumWaitSeconds,
                "started_http_requests": PosterCancellationURLProtocol.state.requestCount,
                "real_service_or_screen_latency": false]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func geometryRanksDistanceAndReadingOrderAndRejectsFarOrInvalidRects() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 300)
        let top = PosterDemandVisibilityView.demand(frame: CGRect(x: 0, y: 200, width: 100, height: 100), viewport: viewport)
        let right = PosterDemandVisibilityView.demand(frame: CGRect(x: 120, y: 200, width: 100, height: 100), viewport: viewport)
        let bottom = PosterDemandVisibilityView.demand(frame: CGRect(x: 0, y: 0, width: 100, height: 100), viewport: viewport)
        let near = PosterDemandVisibilityView.demand(frame: CGRect(x: 0, y: 350, width: 100, height: 100), viewport: viewport)
        #expect(top < right && right < bottom && bottom < near)
        #expect(near.tier == .nearby)
        #expect(PosterDemandVisibilityView.demand(frame: CGRect(x: 0, y: 2_000, width: 100, height: 100), viewport: viewport) == .inactive)
        #expect(PosterDemandVisibilityView.demand(frame: .infinite, viewport: viewport) == .inactive)
        #expect(PosterDemandVisibilityView.demand(frame: .zero, viewport: viewport) == .inactive)
    }

    @Test func nativeClipScrollingUpdatesDemandAndReappearancePublishesAgain() async throws {
        let output = try await NativeBackgroundWindowFixture.output.value
        #expect(output.contains("PASS poster-nearby") && output.contains("PASS poster-far"))
        #expect(output.contains("PASS poster-enable"))
        #expect(output.contains("PASS poster-window-hidden") && output.contains("PASS poster-window-restored"))
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func expectDeferred(_ task: Task<DecodedPosterImage, Error>) async {
        do { _ = try await task.value; Issue.record("Expected capacity deferral") }
        catch is PosterWorkDeferred {} catch { Issue.record("Unexpected error: \(error)") }
    }

    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for poster scheduling", sourceLocation: sourceLocation)
        throw URLError(.timedOut)
    }
}

private final class PosterDecodeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = true
    private var active = 0
    private var peak = 0
    private var decodedSizes: [Int] = []
    var started: Int { condition.withLock { decodedSizes.count } }
    var sizes: [Int] { condition.withLock { decodedSizes } }
    var peakActive: Int { condition.withLock { peak } }
    func open() { condition.withLock { blocked = false; condition.broadcast() } }
    func decode(_ data: Data, _ size: CGFloat) throws -> DecodedPosterImage {
        condition.lock()
        active += 1
        peak = max(peak, active)
        decodedSizes.append(Int(size))
        while blocked { condition.wait() }
        condition.unlock()
        defer { condition.withLock { active -= 1 } }
        return try PosterImagePipeline.decode(data: data, maxPixelSize: size)
    }
}
