import Foundation
import Models
import Testing
@testable import NetVplayerApp

private final class DetailTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; date += seconds }
}

private actor DetailPrefetchProbe {
    var calls: [String: Int] = [:]
    var ready = false
    func load(_ id: String) -> Models.Result {
        calls[id, default: 0] += 1
        return Models.Result(list: [Vod(vodId: id, vodPlayFrom: "Route", vodPlayUrl: ready
            ? "Episode$https://media.example.test/episode.mp4"
            : "Loading$netvplayer-pending://episode")])
    }
    func count(_ id: String) -> Int { calls[id, default: 0] }
    func finish() { ready = true }
}

@Suite("Detail cache lifecycle")
struct DetailCacheLifecycleTests {
    @Test func expiredDetailsAndLeastRecentlyUsedEntriesAreReloaded() async throws {
        let clock = DetailTestClock()
        let cache = VodDetailRepository(maximumEntries: 2, ttl: 600, now: clock.now)
        let a = VodDetailCacheKey(revision: 1, siteKey: "site", vodID: "a")
        let b = VodDetailCacheKey(revision: 1, siteKey: "site", vodID: "b")
        let c = VodDetailCacheKey(revision: 1, siteKey: "site", vodID: "c")
        for key in [a,b] { _ = try await cache.result(for: key) { Result(list: [Vod(vodId: key.vodID)]) } }
        _ = try await cache.result(for: a) { Issue.record("Fresh cache missed"); return .empty }
        _ = try await cache.result(for: c) { Result(list: [Vod(vodId: "c")]) }
        let reloaded = try await cache.result(for: b) { Result(list: [Vod(vodId: "b-new")]) }
        #expect(reloaded.list.first?.vodId == "b-new")
        clock.advance(601)
        #expect(await cache.entryCount() == 0)
        let expired = try await cache.result(for: b) { Result(list: [Vod(vodId: "expired-new")]) }
        #expect(expired.list.first?.vodId == "expired-new")
    }

    @Test func pendingExpansionHoldsBothPrefetchSlotsUntilFinished() async throws {
        let cache = VodDetailRepository()
        let probe = DetailPrefetchProbe()
        let keys = ["a", "b", "c"].map { VodDetailCacheKey(revision: 1, siteKey: "fixture", vodID: $0) }
        for key in keys { await cache.prefetch(key: key) { await probe.load(key.vodID) } }
        try await Task.sleep(for: .milliseconds(300))
        await cache.prefetch(key: keys[2]) { await probe.load("c") }
        #expect(await probe.count("a") > 0)
        #expect(await probe.count("b") > 0)
        #expect(await probe.count("c") == 0)
        #expect(await cache.entryCount() == 0)
        await probe.finish()
        for _ in 0..<100 where await cache.entryCount() != 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await cache.entryCount() == 2)
        await cache.clear()
    }
}
