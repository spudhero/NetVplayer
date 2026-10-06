import Foundation
import Models
import Testing
@testable import NetVplayerApp

private actor SourceLoadGate {
    private var waiter: CheckedContinuation<Int, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    private(set) var wasCancelled = false
    private(set) var discarded = 0
    func load() async -> Int {
        let value = await withCheckedContinuation {
            waiter = $0; started = true; startWaiter?.resume(); startWaiter = nil
        }
        wasCancelled = Task.isCancelled
        return value
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish() { waiter?.resume(returning: 42); waiter = nil }
    func discard(_ value: Int) { discarded += value }
}

@MainActor
@Test func dataSourceCancellationReachesActualLoaderAndDiscardsNonCooperativeResults() async throws {
    for cancelsCaller in [true, false] {
        let requests = OwnedDataSourceRequests()
        let gate = SourceLoadGate()
        let scope = requests.scope(source: "source-a", revision: 1)
        let caller = Task {
            try await requests.run(scope: scope, operation: { await gate.load() }, discard: { await gate.discard($0) })
        }
        await gate.waitForStart()
        if cancelsCaller { caller.cancel() } else { requests.cancelAll() }
        await gate.finish()
        do { _ = try await caller.value; Issue.record("A retired result must not be delivered") }
        catch { #expect(error is CancellationError) }
        #expect(await gate.wasCancelled)
        #expect(await gate.discarded == 42)
        let fresh = requests.scope(source: "source-b", revision: 2)
        #expect(try await requests.run(scope: fresh) { 7 } == 7)
    }
}

@MainActor
@Test func dataSourceRetiredScopeCannotStartDelayedCacheOrPrefetchLoader() async throws {
    let requests = OwnedDataSourceRequests()
    let old = requests.scope(source: "same-key-old-config", revision: 1)
    requests.cancelAll()
    await #expect(throws: CancellationError.self) {
        try await requests.run(scope: old) { Issue.record("Retired loader started"); return 1 }
    }
    let new = requests.scope(source: "same-key-new-config", revision: 2)
    #expect(old != new)
    #expect(try await requests.run(scope: new) { 2 } == 2)
}

@MainActor
@Test func dataSourceCoordinatorPreservesRepositoryCoalescingAndDoesNotCacheRetiredResults() async throws {
    let repository = CatalogRepository()
    let requests = OwnedDataSourceRequests()
    let gate = SourceLoadGate()
    let key = CatalogCacheBaseKey(revision: 1, siteKey: "fixture", kind: .home)
    let scope = requests.scope(source: "fixture", revision: 1)
    let loader: @Sendable () async throws -> Models.Result = {
        let value = try await requests.run(scope: scope) { await gate.load() }
        return Models.Result(list: [Vod(vodId: String(value), vodName: "Fixture")])
    }
    let first = Task { try await repository.result(for: key, page: 1, loader: loader) }
    await gate.waitForStart()
    let duplicate = Task { try await repository.result(for: key, page: 1, loader: loader) }
    // Give the duplicate its actor turn before retiring the shared request.
    for _ in 0..<10 { await Task.yield() }
    requests.cancelAll()
    await gate.finish()
    for caller in [first, duplicate] {
        do { _ = try await caller.value; Issue.record("Retired cache result delivered") }
        catch { #expect(error is CancellationError) }
    }
    #expect(await repository.lookup(key).pages.isEmpty)
}
