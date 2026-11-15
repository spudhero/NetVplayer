import Foundation
import Models
import Testing

private actor ReadAheadBudgetGate {
    private(set) var starts = 0
    private var released = false

    func read() async throws {
        starts += 1
        while !released {
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
    }

    func release() { released = true }
}

private func waitForReadAhead(_ predicate: () async -> Bool) async throws {
    for _ in 0..<400 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw URLError(.timedOut)
}

@Test(arguments: [2, 4])
func readAheadFillsLowBufferWithinSlotAndByteLimits(maximumReads: Int) async throws {
    // Exercise the slot ceiling and byte ceiling independently. Both admit two
    // six-byte reads, even while the current movie is buffering and reading.
    let budget = PlaybackBackgroundBudget(maximumConcurrentReads: maximumReads,
        maximumBytes: maximumReads == 2 ? 64 : 12)
    budget.update(session: "movie", bufferedAhead: 0,
        isLoading: false, isSeeking: false, isBuffering: true)
    let foregroundGate = ReadAheadBudgetGate()
    let readAheadGate = ReadAheadBudgetGate()
    let auxiliaryGate = ReadAheadBudgetGate()
    let foreground = Task {
        try await budget.withRead(purpose: .foreground, bytes: 6) {
            try await foregroundGate.read()
        }
    }
    defer { foreground.cancel() }
    try await waitForReadAhead { await foregroundGate.starts == 1 }

    let reads = (0..<3).map { _ in Task {
        try await budget.withRead(purpose: .readAhead, bytes: 6) {
            try await readAheadGate.read()
        }
    } }
    let auxiliary = [PlaybackReadPurpose.chapterPreview, .subtitleExtraction, .nextEpisode].map { purpose in Task {
        try await budget.withRead(purpose: purpose, bytes: 1) {
            try await auxiliaryGate.read()
        }
    } }
    defer { for task in reads + auxiliary { task.cancel() } }

    try await waitForReadAhead { await readAheadGate.starts == 2 && budget.waitingReadCount == 4 }
    #expect(budget.activeBackgroundReads == 2 && budget.reservedBytes == 12)
    #expect(await auxiliaryGate.starts == 0)
    #expect(!budget.permitsBackgroundWork)

    await readAheadGate.release()
    for task in reads { try await task.value }
    #expect(await readAheadGate.starts == 3)
    #expect(await auxiliaryGate.starts == 0)
    #expect(budget.activeBackgroundReads == 0 && budget.reservedBytes == 0)
    for task in auxiliary { task.cancel(); _ = await task.result }
    await foregroundGate.release()
    try await foreground.value
    #expect(budget.waitingReadCount == 0)
}

@Test func readAheadRetainsOwnerCancellationAndRangeBounds() async throws {
    let budget = PlaybackBackgroundBudget(maximumConcurrentReads: 1, maximumBytes: 6)
    budget.update(session: "movie", bufferedAhead: 0,
        isLoading: true, isSeeking: true, isBuffering: true)
    do {
        try await budget.withRead(purpose: .readAhead, bytes: 7) {
            Issue.record("Oversized read-ahead reached upstream")
            return ()
        }
        Issue.record("Oversized read-ahead was admitted")
    } catch { #expect((error as? URLError)?.code == .dataLengthExceedsMaximum) }

    let session = PlaybackReadSession()
    let identity = PlaybackMediaIdentity(source: "http", account: "fixture", item: "movie")
    let gate = ReadAheadBudgetGate()
    let reads = (0..<2).map { _ in
        let owner = session.makeOwner(mediaIdentity: identity, purpose: .readAhead)
        return Task {
            try await owner.perform {
                try await budget.withRead(owner: owner, bytes: 6) { try await gate.read() }
            }
        }
    }
    defer { session.stop(); for task in reads { task.cancel() } }
    try await waitForReadAhead { await gate.starts == 1 && budget.waitingReadCount == 1 }
    session.stop()
    for task in reads {
        do { try await task.value; Issue.record("Retired read-ahead completed") }
        catch { #expect(error is CancellationError) }
    }
    #expect(budget.activeBackgroundReads == 0 && budget.reservedBytes == 0 && budget.waitingReadCount == 0)
}

@Test func readAheadHonorsCongestionCooldownUntilForegroundNeedsItsBytes() async throws {
    let budget = PlaybackBackgroundBudget()
    budget.suspendBackgroundWork(for: 60)
    let priority = PlaybackReadPriority(purpose: .readAhead)
    let gate = ReadAheadBudgetGate()
    let read = Task {
        try await PlaybackReadScope.$priority.withValue(priority) {
            try await budget.withRead(purpose: .readAhead, bytes: 6) { try await gate.read() }
        }
    }
    defer { read.cancel() }
    try await waitForReadAhead { budget.waitingReadCount == 1 }
    #expect(await gate.starts == 0 && budget.reservedBytes == 0)
    priority.promote()
    try await waitForReadAhead { await gate.starts == 1 }
    await gate.release()
    try await read.value
    #expect(budget.waitingReadCount == 0 && budget.reservedBytes == 0)
}
