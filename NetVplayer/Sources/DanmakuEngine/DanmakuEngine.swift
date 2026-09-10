// DanmakuEngine/DanmakuEngine.swift
// Manual danmaku search and local cache. No automatic external requests.

import Foundation
import Networking
import Storage

public final class DanmakuEngine: @unchecked Sendable {
    public static let shared = DanmakuEngine()

    private let httpClient: HTTPClient
    private let storage: StorageManager
    private let cacheFilename = "danmaku_cache.json"
    private let lock = NSLock()
    private var cache: [DanmakuCacheEntry]

    public init(httpClient: HTTPClient = .shared, storage: StorageManager = .shared) {
        self.httpClient = httpClient
        self.storage = storage
        self.cache = (try? storage.load([DanmakuCacheEntry].self, from: cacheFilename)) ?? []
        pruneExpiredLocked()
    }

    public func manualSearch(request: DanmakuSearchRequest, sources: [DanmakuSource]) async -> [DanmakuMatch] {
        let enabledSources = sources.filter(\.enabled)
        guard !request.effectiveKeyword.isEmpty, !enabledSources.isEmpty else { return [] }

        var matches: [DanmakuMatch] = []
        for source in enabledSources {
            let cacheKey = request.cacheKey(sourceID: source.id)
            if let cached = cachedTrack(cacheKey: cacheKey) {
                matches.append(match(from: request, cacheKey: cacheKey, track: cached))
                continue
            }
            guard let url = searchURL(for: request, source: source) else { continue }
            do {
                let response = try await httpClient.get(url: url, headers: source.headers, timeout: 12)
                guard (200..<300).contains(response.statusCode),
                      let payload = String(data: response.data, encoding: .utf8),
                      !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let track = DanmakuTrack(
                    format: trackFormat(for: source.parserType),
                    cacheKey: cacheKey,
                    sourceName: source.name
                )
                saveCache(DanmakuCacheEntry(cacheKey: cacheKey, track: track, payload: payload))
                matches.append(match(from: request, cacheKey: cacheKey, track: track))
            } catch {
                continue
            }
        }
        return matches
    }

    public func cachedTrack(cacheKey: String) -> DanmakuTrack? {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked()
        return cache.first { $0.cacheKey == cacheKey }?.track
    }

    public func cachedPayload(cacheKey: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked()
        return cache.first { $0.cacheKey == cacheKey }?.payload
    }

    public func replayFixture(_ sample: DanmakuFixtureReplaySample) -> DanmakuFixtureReplayResult {
        let cacheKey = sample.request.cacheKey(sourceID: sample.sourceID)
        let track = DanmakuTrack(
            format: sample.format,
            cacheKey: cacheKey,
            sourceName: sample.sourceName
        )
        saveCache(DanmakuCacheEntry(cacheKey: cacheKey, track: track, payload: sample.payload))
        let parseResult = DanmakuPayloadParser.parseWithDiagnostic(payload: sample.payload, format: sample.format)
        return DanmakuFixtureReplayResult(
            match: match(from: sample.request, cacheKey: cacheKey, track: track),
            diagnostic: parseResult.diagnostic
        )
    }

    public func searchURL(for request: DanmakuSearchRequest, source: DanmakuSource) -> String? {
        let keyword = request.effectiveKeyword
        guard !keyword.isEmpty else { return nil }
        if !source.queryTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let templated = source.queryTemplate
                .replacingOccurrences(of: "{keyword}", with: urlEncoded(keyword))
                .replacingOccurrences(of: "{title}", with: urlEncoded(request.title))
                .replacingOccurrences(of: "{season}", with: request.season.map(String.init) ?? "")
                .replacingOccurrences(of: "{episode}", with: request.episode.map(String.init) ?? "")
                .replacingOccurrences(of: "{year}", with: request.year.map(String.init) ?? "")
            if templated.hasPrefix("http://") || templated.hasPrefix("https://") {
                return templated
            }
            return appendPathOrQuery(templated, to: source.apiURL)
        }

        guard var components = URLComponents(string: source.apiURL) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "keyword", value: keyword))
        components.queryItems = items
        return components.string
    }

    private func saveCache(_ entry: DanmakuCacheEntry) {
        lock.lock()
        cache.removeAll { $0.cacheKey == entry.cacheKey }
        cache.append(entry)
        let snapshot = cache
        lock.unlock()
        try? storage.save(snapshot, to: cacheFilename)
    }

    private func pruneExpiredLocked(now: Date = Date()) {
        cache.removeAll { $0.isExpired(now: now) }
    }

    private func match(from request: DanmakuSearchRequest, cacheKey: String, track: DanmakuTrack) -> DanmakuMatch {
        DanmakuMatch(
            id: cacheKey,
            title: request.title,
            season: request.season,
            episode: request.episode,
            year: request.year,
            siteKey: request.siteKey,
            confidence: request.manualKeyword.isEmpty ? 0.85 : 1.0,
            track: track
        )
    }

    private func trackFormat(for parserType: DanmakuParserType) -> DanmakuTrackFormat {
        switch parserType {
        case .xml, .bilibiliXML: return .xml
        case .json: return .json
        case .text: return .text
        }
    }

    private func appendPathOrQuery(_ value: String, to base: String) -> String? {
        guard !value.hasPrefix("?") else {
            return base + value
        }
        guard var components = URLComponents(string: base) else { return nil }
        let separator = value.hasPrefix("/") ? "" : "/"
        components.path += separator + value
        return components.string
    }

    private func urlEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}
