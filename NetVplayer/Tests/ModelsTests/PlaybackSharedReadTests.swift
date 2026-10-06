import Foundation
import Models
import Testing

private actor ReadBarrier {
    var started = false
    private var continuation: CheckedContinuation<Int, Never>?
    func wait() async -> Int {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: 42); continuation = nil }
}

@Test func playbackSharedReadCancelsOnlyTheDepartingBackgroundReader() async throws {
    let barrier = ReadBarrier()
    let underlying = Task<Int, Error> { await barrier.wait() }
    let shared = PlaybackSharedRead(task: underlying)
    let background = Task { try await shared.value(phase: .preload) }
    let foreground = Task { try await shared.value(phase: .playback) }
    while !shared.hasForegroundReaders { await Task.yield() }
    background.cancel()
    do { _ = try await background.value; Issue.record("Cancelled preload returned a value") }
    catch { #expect(error is CancellationError) }
    #expect(!underlying.isCancelled)
    while !(await barrier.started) { await Task.yield() }
    await barrier.finish()
    #expect(try await foreground.value == 42)
}

@Test func playbackSharedReadStopsTheLastReaderAndDiscardsLateCompletion() async throws {
    let barrier = ReadBarrier()
    let underlying = Task<Int, Error> { await barrier.wait() }
    let shared = PlaybackSharedRead(task: underlying)
    let foreground = Task { try await shared.value() }
    while !shared.hasForegroundReaders { await Task.yield() }
    while !(await barrier.started) { await Task.yield() }
    foreground.cancel()
    do { _ = try await foreground.value; Issue.record("Last cancelled reader returned data") }
    catch { #expect(error is CancellationError) }
    #expect(underlying.isCancelled)
    await barrier.finish() // A non-cooperative upstream cannot revive this read.
    _ = await underlying.result
    do { _ = try await shared.value(); Issue.record("Late completion revived cancelled read") }
    catch { #expect(error is CancellationError) }
}

@Test func playbackSharedReadCancelsSpeculationWithoutKillingSeekReader() async throws {
    let barrier = ReadBarrier()
    let underlying = Task<Int, Error> { await barrier.wait() }
    let shared = PlaybackSharedRead(task: underlying)
    let foreground = Task { try await shared.value(phase: .seek) }
    while !shared.hasForegroundReaders { await Task.yield() }
    #expect(!shared.cancelBackgroundReaders())
    #expect(!underlying.isCancelled)
    while !(await barrier.started) { await Task.yield() }
    await barrier.finish()
    #expect(try await foreground.value == 42)
}

@Test func playbackBackgroundBudgetUsesHysteresisAndIndependentSessions() {
    let budget = PlaybackBackgroundBudget()
    budget.update(session: "vod", bufferedAhead: 14, isLoading: false, isSeeking: false, isBuffering: false)
    #expect(!budget.permitsBackgroundWork)
    budget.update(session: "vod", bufferedAhead: 15, isLoading: false, isSeeking: false, isBuffering: false)
    #expect(budget.permitsBackgroundWork)
    budget.update(session: "vod", bufferedAhead: 11, isLoading: false, isSeeking: false, isBuffering: false)
    #expect(budget.permitsBackgroundWork)
    budget.update(session: "live", bufferedAhead: 20, isLoading: false, isSeeking: false, isBuffering: true)
    #expect(!budget.permitsBackgroundWork)
    budget.remove(session: "live")
    #expect(budget.permitsBackgroundWork)
    budget.update(session: "vod", bufferedAhead: .nan, isLoading: false, isSeeking: false, isBuffering: false)
    #expect(!budget.permitsBackgroundWork)
    budget.remove(session: "vod")
    #expect(budget.permitsBackgroundWork)
}
