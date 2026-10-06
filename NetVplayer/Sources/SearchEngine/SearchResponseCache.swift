import Foundation
import CryptoKit
import Models

struct SearchResponseCacheKey: Hashable, Sendable {
    let scope: String
    let source: String
    let keyword: String
    let page: String
    let quick: Bool

    init(scope: String, site: Site, keyword: String, page: String, quick: Bool) {
        self.scope = scope
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        source = SHA256.hash(data: (try? encoder.encode(site)) ?? Data())
            .map { String(format: "%02x", $0) }.joined()
        self.keyword = SearchQueryPlan(keyword).original
        self.page = page
        self.quick = quick
    }
}

/// Reuse complete successful pages only. Limits apply to entries, items and encoded payload bytes.
actor SearchResponseCache {
    struct Entry {
        var result: SearchResult
        let expires: ContinuousClock.Instant
        var lastUse: UInt64
        let bytes: Int
    }
    private var entries: [SearchResponseCacheKey: Entry] = [:]
    private(set) var revision: UInt64 = 0
    private var use: UInt64 = 0
    private var writers: [SearchResponseCacheKey: UUID] = [:]
    private var writerOrder: [(SearchResponseCacheKey, UUID)] = []
    private let ttl: Duration
    private let maxEntries: Int
    private let maxItems: Int
    private let maxBytes: Int

    init(ttl: Duration = .seconds(30), maxEntries: Int = 64,
         maxItems: Int = 5_000, maxBytes: Int = 4 * 1_024 * 1_024) {
        self.ttl = ttl
        self.maxEntries = max(0, maxEntries)
        self.maxItems = max(0, maxItems)
        self.maxBytes = max(0, maxBytes)
    }

    func lookup(_ key: SearchResponseCacheKey, bypass: Bool) -> (result: SearchResult?, revision: UInt64, writer: UUID) {
        entries = entries.filter { $0.value.expires > .now }
        if !bypass, var entry = entries[key] {
            use &+= 1
            entry.lastUse = use
            entries[key] = entry
            entry.result.isCached = true
            return (entry.result, revision, UUID())
        }
        // Explicit refresh must not leave an older successful page behind after a failure.
        if bypass { entries[key] = nil }
        let writer = UUID()
        writers[key] = writer
        writerOrder.append((key, writer))
        while writerOrder.count > 64 {
            let old = writerOrder.removeFirst()
            if writers[old.0] == old.1 { writers[old.0] = nil }
        }
        return (nil, revision, writer)
    }

    func insert(_ result: SearchResult, for key: SearchResponseCacheKey, revision expected: UInt64, writer: UUID) {
        guard expected == revision, writers[key] == writer else { return }
        writers[key] = nil
        writerOrder.removeAll { $0.0 == key && $0.1 == writer }
        guard !Task.isCancelled, result.error == nil, result.page == (Int(key.page) ?? 1),
              !result.vods.isEmpty, result.vods.count <= 200,
              let payload = try? JSONEncoder().encode(result.vods), payload.count <= 512 * 1_024 else { return }
        entries = entries.filter { $0.value.expires > .now }
        use &+= 1
        entries[key] = Entry(result: result, expires: .now.advanced(by: ttl), lastUse: use, bytes: payload.count)
        while entries.count > maxEntries || itemCount > maxItems || byteCount > maxBytes {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            entries[oldest] = nil
        }
    }

    func clear() {
        revision &+= 1
        entries.removeAll()
        writers.removeAll()
        writerOrder.removeAll()
    }

    var entryCount: Int { entries.count }
    var itemCount: Int { entries.values.reduce(0) { $0 + $1.result.vods.count } }
    var byteCount: Int { entries.values.reduce(0) { $0 + $1.bytes } }
}
