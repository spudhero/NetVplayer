import Foundation
import Models
import Testing

@Test func optionalWindowGateNeverBlocksCurrentMediaReadAhead() async throws {
    let budget = PlaybackBackgroundBudget(maximumConcurrentReads: 1, maximumBytes: 8)
    budget.updateWindow(UUID(), visible: false)
    budget.update(session: "movie", bufferedAhead: 0, isLoading: true, isSeeking: true, isBuffering: true)
    #expect(!budget.permitsOptionalWork && !budget.permitsVisibleWork)
    let result = try await budget.withRead(purpose: .readAhead, bytes: 8) { 42 }
    #expect(result == 42 && budget.reservedBytes == 0)
}

@Test func optionalBudgetUsesHysteresisAndIndependentWindowsAndSessions() async throws {
    let budget = PlaybackBackgroundBudget(), a = UUID(), b = UUID()
    budget.updateWindow(a, visible: false)
    budget.updateWindow(b, visible: true)
    budget.update(session: "one", bufferedAhead: 0, isLoading: true, isSeeking: false, isBuffering: false)
    budget.update(session: "two", bufferedAhead: 40, isLoading: false, isSeeking: false, isBuffering: false)
    #expect(!budget.permitsOptionalWork && budget.permitsVisibleWork)
    budget.update(session: "one", bufferedAhead: 5, isLoading: false, isSeeking: false, isBuffering: false)
    #expect(!budget.permitsOptionalWork)
    budget.remove(session: "one")
    #expect(budget.permitsOptionalWork)
    budget.removeWindow(b)
    #expect(!budget.permitsOptionalWork)
    budget.removeWindow(a)
    #expect(!budget.permitsOptionalWork) // Closing the last window does not reopen the gate.
}

@Test func optionalWaitersWakeOnCooldownExpiryAndCancelWhileHidden() async throws {
    let budget = PlaybackBackgroundBudget()
    budget.suspendBackgroundWork(for: 0.05)
    let before = ContinuousClock.now
    try await budget.waitForOptionalPermission()
    #expect(before.duration(to: .now) >= .milliseconds(25))
    budget.updateWindow(UUID(), visible: false)
    let waiting = Task { try await budget.waitForOptionalPermission() }
    waiting.cancel()
    do { try await waiting.value; Issue.record("Cancelled optional work was admitted") }
    catch { #expect(error is CancellationError) }
}
