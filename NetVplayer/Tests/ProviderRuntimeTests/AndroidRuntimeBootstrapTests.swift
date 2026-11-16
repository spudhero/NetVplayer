import Foundation
import Testing
@testable import SpiderEngine

@Test func androidBootstrapSharesConcurrentPreparation() async throws {
    let probe = BootstrapProbe()
    let bootstrap = AndroidRuntimeBootstrap { _, _ in
        await probe.started()
        try await Task.sleep(for: .milliseconds(100))
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<12 { group.addTask { try await bootstrap.prepare() } }
        try await group.waitForAll()
    }
    #expect(await probe.attempts == 1)
}

@Test func androidBootstrapRetriesAfterTransientFailure() async throws {
    let probe = BootstrapProbe()
    let bootstrap = AndroidRuntimeBootstrap { _, _ in
        if await probe.started() == 1 { throw URLError(.notConnectedToInternet) }
    }
    await #expect(throws: URLError.self) { try await bootstrap.prepare() }
    try await bootstrap.prepare()
    #expect(await probe.attempts == 2)
}

@Test func androidBootstrapCancellationDrainsAndAllowsRetry() async throws {
    let probe = BootstrapProbe()
    let bootstrap = AndroidRuntimeBootstrap { _, _ in
        if await probe.started() == 1 { try await Task.sleep(for: .seconds(30)) }
    }
    let preparation = Task { try await bootstrap.prepare() }
    while await probe.attempts == 0 { await Task.yield() }
    await bootstrap.cancel()
    await #expect(throws: CancellationError.self) { try await preparation.value }
    try await bootstrap.prepare()
    #expect(await probe.attempts == 2)
}

private actor BootstrapProbe {
    private(set) var attempts = 0
    @discardableResult func started() -> Int { attempts += 1; return attempts }
}
