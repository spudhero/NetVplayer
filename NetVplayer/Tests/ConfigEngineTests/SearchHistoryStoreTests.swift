import Foundation
import Testing
import Storage

@Suite("Search history store")
struct SearchHistoryStoreTests {
    @Test("records newest first, deduplicates, and respects the limit")
    func recordAndLimit() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = store.record("沙丘", searchedAt: start, limit: 3)
        _ = store.record("三体", searchedAt: start.addingTimeInterval(1), limit: 3)
        _ = store.record("流浪地球", searchedAt: start.addingTimeInterval(2), limit: 3)
        let entries = store.record("沙丘", searchedAt: start.addingTimeInterval(3), limit: 3)

        #expect(entries.map(\.query) == ["沙丘", "流浪地球", "三体"])
        #expect(entries.count == 3)
    }

    @Test("removes one entry and clears all history")
    func removeAndClear() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = store.record("繁花").first!
        _ = store.record("庆余年")
        let remaining = store.remove(id: first.id)

        #expect(remaining.map(\.query) == ["庆余年"])

        store.clear()
        #expect(store.load().isEmpty)
    }

    private func makeStore() -> (SearchHistoryStore, UserDefaults, String) {
        let suiteName = "SearchHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (SearchHistoryStore(defaults: defaults), defaults, suiteName)
    }
}
