import Foundation
import DriveEngine
import Models
import Testing
@testable import SpiderEngine

private actor DetailShareGate: DriveShareExpanding {
    private var waiters: [String: CheckedContinuation<[Episode], Never>] = [:]
    private var calls: [String] = []

    nonisolated func canExpand(url: String) -> Bool { true }
    func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        calls.append(url)
        return await withCheckedContinuation { waiters[url] = $0 }
    }
    func count() -> Int { calls.count }
    func complete(_ url: String) {
        waiters.removeValue(forKey: url)?.resume(returning: [Episode(name: "Expanded", url: "https://media.example.test/video.mp4")])
    }
}

@Suite("Progressive detail expansion")
struct ProgressiveDetailTests {
    @Test func fasterShareBecomesPlayableBeforeSlowShareCompletes() async throws {
        let fast = "https://pan.quark.cn/s/fast"
        let slow = "https://drive.uc.cn/s/slow"
        let gate = DetailShareGate()
        let store = ProgressiveDetailStore()
        let key = ProgressiveDetailKey(site: Site(key: "fixture", api: "fixture"), id: "detail")
        let resolver = RemoteProviderDriveShareResolver(expander: DriveShareExpander(expanders: [gate]))
        let input = Result(list: [Vod(vodId: "detail", vodName: "Metadata", vodPlayFrom: "Fast$$$Slow", vodPlayUrl: "Fast$\(fast)$$$Slow$\(slow)")])
        let initial = try await store.result(for: key, resolver: resolver) { input }
        #expect(initial.list.first?.vodName == "Metadata")
        #expect(initial.list.first?.vodPlayUrl.contains("netvplayer-pending:") == true)
        for _ in 0..<100 where await gate.count() < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.count() == 2)
        await gate.complete(fast)
        var partial = initial
        for _ in 0..<100 {
            partial = try await store.result(for: key, resolver: resolver) { input }
            if partial.list[0].vodPlayUrl.contains("video.mp4") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(partial.list[0].parseFlags()[0].episodes[0].url.hasSuffix("video.mp4"))
        #expect(partial.list[0].parseFlags()[1].episodes[0].url.hasPrefix("netvplayer-pending:"))
        await gate.complete(slow)
        for _ in 0..<100 {
            let final = try await store.result(for: key, resolver: resolver) { input }
            if !final.list[0].vodPlayUrl.contains("netvplayer-pending:") {
                #expect(final.list[0].parseFlags().map(\.name) == ["Fast", "Slow"])
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Expansion did not complete")
    }

    @Test func clearDoesNotAcceptExpansionThatIgnoresCancellation() async throws {
        let share = "https://pan.quark.cn/s/held"
        let gate = DetailShareGate()
        let store = ProgressiveDetailStore()
        let key = ProgressiveDetailKey(site: Site(key: "clear", api: "fixture"), id: "detail")
        let resolver = RemoteProviderDriveShareResolver(expander: DriveShareExpander(expanders: [gate]))
        _ = try await store.result(for: key, resolver: resolver) {
            Result(list: [Vod(vodId: "old", vodPlayFrom: "Share", vodPlayUrl: "Held$\(share)")])
        }
        for _ in 0..<100 where await gate.count() == 0 { try await Task.sleep(for: .milliseconds(10)) }
        await store.clear()
        await gate.complete(share)
        let new = try await store.result(for: key, resolver: resolver) {
            Result(list: [Vod(vodId: "new", vodName: "New")])
        }
        #expect(new.list.first?.vodId == "new")
    }
}
