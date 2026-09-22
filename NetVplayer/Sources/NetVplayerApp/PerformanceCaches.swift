import Foundation
import Models
import SpiderEngine
import Storage
import WebKit

struct CatalogCacheBaseKey: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case home
        case category(String)
    }

    struct Selection: Hashable, Sendable {
        let key: String
        let value: String
    }

    let revision: UInt64
    let siteKey: String
    let kind: Kind
    let selection: [Selection]

    init(
        revision: UInt64,
        siteKey: String,
        kind: Kind,
        selection: [String: String] = [:]
    ) {
        self.revision = revision
        self.siteKey = siteKey
        self.kind = kind
        self.selection = selection
            .map { Selection(key: $0.key, value: $0.value) }
            .sorted {
                if $0.key != $1.key { return $0.key < $1.key }
                return $0.value < $1.value
            }
    }
}

struct CatalogCacheLookup: Sendable {
    enum Freshness: Sendable, Equatable {
        case fresh
        case stale
        case expired
        case miss
    }

    var pages: [Models.Result]
    var freshness: Freshness
}

struct CatalogCacheStats: Sendable, Equatable {
    var pageCount: Int
    var vodCount: Int
}

actor CatalogRepository {
    static let shared = CatalogRepository()

    private struct PageKey: Hashable, Sendable {
        let base: CatalogCacheBaseKey
        let page: Int
    }

    private struct Entry: Sendable {
        var result: Models.Result
        var storedAt: Date
        var lastAccess: UInt64
    }

    private struct InFlight: Sendable {
        let id: UUID
        let task: Task<Models.Result, Error>
    }

    private let maximumPages: Int
    private let freshTTL: TimeInterval
    private let staleTTL: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [PageKey: Entry] = [:]
    private var inFlight: [PageKey: InFlight] = [:]
    private var accessSerial: UInt64 = 0

    init(
        maximumPages: Int = 64,
        freshTTL: TimeInterval = 5 * 60,
        staleTTL: TimeInterval = 30 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.maximumPages = max(1, maximumPages)
        self.freshTTL = max(0, freshTTL)
        self.staleTTL = max(freshTTL, staleTTL)
        self.now = now
    }

    func lookup(_ base: CatalogCacheBaseKey) -> CatalogCacheLookup {
        var pages: [Models.Result] = []
        var page = 1
        var firstStoredAt: Date?
        while let entry = entries[PageKey(base: base, page: page)] {
            accessSerial &+= 1
            var updated = entry
            updated.lastAccess = accessSerial
            entries[PageKey(base: base, page: page)] = updated
            pages.append(entry.result)
            firstStoredAt = firstStoredAt ?? entry.storedAt
            page += 1
        }
        guard let firstStoredAt else {
            return CatalogCacheLookup(pages: [], freshness: .miss)
        }
        let age = max(0, now().timeIntervalSince(firstStoredAt))
        let freshness: CatalogCacheLookup.Freshness
        if age <= freshTTL {
            freshness = .fresh
        } else if age <= staleTTL {
            freshness = .stale
        } else {
            freshness = .expired
        }
        return CatalogCacheLookup(pages: pages, freshness: freshness)
    }

    func result(
        for base: CatalogCacheBaseKey,
        page: Int,
        forceRefresh: Bool = false,
        loader: @escaping @Sendable () async throws -> Models.Result
    ) async throws -> Models.Result {
        let key = PageKey(base: base, page: max(1, page))
        if !forceRefresh,
           let cached = entries[key],
           now().timeIntervalSince(cached.storedAt) <= freshTTL {
            accessSerial &+= 1
            var updated = cached
            updated.lastAccess = accessSerial
            entries[key] = updated
            return cached.result
        }
        if let existing = inFlight[key] {
            return try await existing.task.value
        }

        let requestID = UUID()
        let task = Task { try await loader() }
        inFlight[key] = InFlight(id: requestID, task: task)
        do {
            let result = try await task.value
            if inFlight[key]?.id == requestID {
                inFlight[key] = nil
                store(result, for: key)
            }
            return result
        } catch {
            if inFlight[key]?.id == requestID { inFlight[key] = nil }
            throw error
        }
    }

    func invalidate(_ base: CatalogCacheBaseKey) {
        for key in entries.keys.filter({ $0.base == base }) {
            entries[key] = nil
        }
        for key in inFlight.keys.filter({ $0.base == base }) {
            inFlight[key]?.task.cancel()
            inFlight[key] = nil
        }
    }

    func clear() {
        entries.removeAll()
        for request in inFlight.values { request.task.cancel() }
        inFlight.removeAll()
    }

    func stats() -> CatalogCacheStats {
        CatalogCacheStats(
            pageCount: entries.count,
            vodCount: entries.values.reduce(0) { $0 + $1.result.list.count }
        )
    }

    private func store(_ result: Models.Result, for key: PageKey) {
        accessSerial &+= 1
        entries[key] = Entry(result: result, storedAt: now(), lastAccess: accessSerial)
        if entries.count > maximumPages,
           let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries[oldest] = nil
        }
    }
}

struct VodDetailCacheKey: Hashable, Sendable {
    let revision: UInt64
    let siteKey: String
    let vodID: String
}

func isProvisionalDetailResult(_ result: Models.Result) -> Bool {
    result.list.contains { $0.vodPlayUrl.contains("netvplayer-pending:") }
}

actor VodDetailRepository {
    static let shared = VodDetailRepository()

    private struct Entry: Sendable {
        var result: Models.Result
        var storedAt: Date
        var lastAccess: UInt64
    }

    private struct InFlight: Sendable {
        let id: UUID
        let task: Task<Models.Result, Error>
    }

    private let maximumEntries: Int
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [VodDetailCacheKey: Entry] = [:]
    private var inFlight: [VodDetailCacheKey: InFlight] = [:]
    private var prefetchKeys = Set<VodDetailCacheKey>()
    private var accessSerial: UInt64 = 0

    init(
        maximumEntries: Int = 32,
        ttl: TimeInterval = 10 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.ttl = max(0, ttl)
        self.now = now
    }

    func result(
        for key: VodDetailCacheKey,
        loader: @escaping @Sendable () async throws -> Models.Result
    ) async throws -> Models.Result {
        if let cached = entries[key], now().timeIntervalSince(cached.storedAt) <= ttl {
            accessSerial &+= 1
            var updated = cached
            updated.lastAccess = accessSerial
            entries[key] = updated
            return cached.result
        }
        entries[key] = nil
        if let existing = inFlight[key] {
            return try await existing.task.value
        }

        let requestID = UUID()
        let task = Task { try await loader() }
        inFlight[key] = InFlight(id: requestID, task: task)
        do {
            let result = try await task.value
            if inFlight[key]?.id == requestID {
                inFlight[key] = nil
                prefetchKeys.remove(key)
                if !result.list.isEmpty, !isProvisionalDetailResult(result) { store(result, for: key) }
            }
            return result
        } catch {
            if inFlight[key]?.id == requestID { inFlight[key] = nil }
            prefetchKeys.remove(key)
            throw error
        }
    }

    func prefetch(
        key: VodDetailCacheKey,
        loader: @escaping @Sendable () async throws -> Models.Result
    ) {
        if let cached = entries[key], now().timeIntervalSince(cached.storedAt) <= ttl { return }
        entries[key] = nil
        guard inFlight[key] == nil, prefetchKeys.count < 2 else { return }
        prefetchKeys.insert(key)
        let requestID = UUID()
        let task = Task { try await loader() }
        inFlight[key] = InFlight(id: requestID, task: task)
        Task {
            do {
                let result = try await task.value
                if inFlight[key]?.id == requestID {
                    if !result.list.isEmpty, !isProvisionalDetailResult(result) { store(result, for: key) }
                    inFlight[key] = nil
                    prefetchKeys.remove(key)
                }
            } catch {
                // Prefetch failures are intentionally silent.
                if inFlight[key]?.id == requestID {
                    inFlight[key] = nil
                    prefetchKeys.remove(key)
                }
            }
        }
    }

    func clear() {
        entries.removeAll()
        for request in inFlight.values { request.task.cancel() }
        inFlight.removeAll()
        prefetchKeys.removeAll()
    }

    func entryCount() -> Int {
        let current = now()
        entries = entries.filter { current.timeIntervalSince($0.value.storedAt) <= ttl }
        return entries.count
    }

    private func store(_ result: Models.Result, for key: VodDetailCacheKey) {
        accessSerial &+= 1
        entries[key] = Entry(result: result, storedAt: now(), lastAccess: accessSerial)
        if entries.count > maximumEntries,
           let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries[oldest] = nil
        }
    }
}

struct CacheSnapshot: Sendable, Equatable {
    var posterBytes: Int64
    var networkBytes: Int64
    var catalogPages: Int
    var catalogVods: Int
    var detailEntries: Int

    var totalDiskBytes: Int64 { posterBytes + networkBytes }
}

struct CacheClearReport: Sendable, Equatable {
    var failures: [String]
    var succeeded: Bool { failures.isEmpty }
}

@MainActor
final class CacheCoordinator {
    static let shared = CacheCoordinator()

    func snapshot() async -> CacheSnapshot {
        async let posterBytes = PosterImagePipeline.shared.diskUsage()
        async let catalogStats = CatalogRepository.shared.stats()
        async let detailEntries = VodDetailRepository.shared.entryCount()
        let networkBytes = Int64(URLCache.shared.currentDiskUsage)
        return await CacheSnapshot(
            posterBytes: posterBytes,
            networkBytes: networkBytes,
            catalogPages: catalogStats.pageCount,
            catalogVods: catalogStats.vodCount,
            detailEntries: detailEntries
        )
    }

    func clearPerformanceCaches() async -> CacheClearReport {
        var failures: [String] = []
        ImageLoader.clearMemoryCache()
        do {
            try await PosterImagePipeline.shared.clearDiskCache()
        } catch {
            failures.append("海报缓存：\(error.localizedDescription)")
        }
        await CatalogRepository.shared.clear()
        await VodDetailRepository.shared.clear()
        await SpiderReplacementRegistry.shared.clearContentCaches()
        URLCache.shared.removeAllCachedResponses()
        await removeWebsiteData(types: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])
        NotificationCenter.default.post(name: .netVplayerCacheDidChange, object: nil)
        return CacheClearReport(failures: failures)
    }

    func clearWebSessions() async -> CacheClearReport {
        await removeWebsiteData(types: WKWebsiteDataStore.allWebsiteDataTypes())
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
        return CacheClearReport(failures: [])
    }

    private func removeWebsiteData(types: Set<String>) async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: types,
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }
}
