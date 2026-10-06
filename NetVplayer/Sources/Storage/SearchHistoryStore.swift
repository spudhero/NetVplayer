import Foundation

public struct SearchHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let query: String
    public let searchedAt: Date

    public init(id: UUID = UUID(), query: String, searchedAt: Date = Date()) {
        self.id = id
        self.query = query
        self.searchedAt = searchedAt
    }
}

public final class SearchHistoryStore: @unchecked Sendable {
    public static let shared = SearchHistoryStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "netvplayer.searchHistory.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func load(limit: Int = 20) -> [SearchHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(loadUnlocked().prefix(max(0, limit)))
    }

    @discardableResult
    public func record(
        _ query: String,
        searchedAt: Date = Date(),
        limit: Int = 20
    ) -> [SearchHistoryEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return load(limit: limit) }

        lock.lock()
        defer { lock.unlock() }

        var entries = loadUnlocked()
        entries.removeAll {
            $0.query.localizedCaseInsensitiveCompare(normalizedQuery) == .orderedSame
        }
        entries.insert(SearchHistoryEntry(query: normalizedQuery, searchedAt: searchedAt), at: 0)
        entries = Array(entries.prefix(max(0, limit)))
        saveUnlocked(entries)
        return entries
    }

    @discardableResult
    public func remove(id: UUID, limit: Int = 20) -> [SearchHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }

        var entries = loadUnlocked()
        entries.removeAll { $0.id == id }
        entries = Array(entries.prefix(max(0, limit)))
        saveUnlocked(entries)
        return entries
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }

    private func loadUnlocked() -> [SearchHistoryEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([SearchHistoryEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.searchedAt > $1.searchedAt }
    }

    private func saveUnlocked(_ entries: [SearchHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
