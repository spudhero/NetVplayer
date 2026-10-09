import Foundation
import Testing
@testable import ProviderRuntime

private actor GateOperations {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

@Test func canceledQueuedProviderOperationDoesNotReinitializeOrDelayTheNextRequest() async throws {
    let gate = ProviderOperationGate()
    let operations = GateOperations()
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let first = Task {
        try await gate.run {
            await operations.record("first")
            started.continuation.yield(())
            for await _ in release.stream { break }
            return 1
        }
    }
    for await _ in started.stream { break }
    let stale = Task {
        try await gate.run {
            await operations.record("stale")
            return 2
        }
    }
    // Keep the first request blocked while cancellation reaches the queued caller.
    try await Task.sleep(for: .milliseconds(20))
    stale.cancel()
    release.continuation.yield(())
    #expect(try await first.value == 1)
    do {
        _ = try await stale.value
        Issue.record("Canceled source request executed after the preceding request")
    } catch is CancellationError { }
    #expect(try await gate.run { await operations.record("next"); return 3 } == 3)
    #expect(await operations.values == ["first", "next"])
}

@Test func cancelingActiveProviderOperationReachesTheRunnerWorkAndReleasesTheGate() async throws {
    let gate = ProviderOperationGate()
    let started = AsyncStream<Void>.makeStream()
    let active = Task {
        try await gate.run {
            started.continuation.yield(())
            try await Task.sleep(for: .seconds(2))
            return 1
        }
    }
    for await _ in started.stream { break }
    active.cancel()
    do {
        _ = try await active.value
        Issue.record("Caller cancellation did not reach the active Provider operation")
    } catch is CancellationError { }
    #expect(try await gate.run { 2 } == 2)
}
