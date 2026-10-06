// DanmakuEngine/DanmakuEngine.swift
// Manual danmaku search and local cache. No automatic external requests.

import Foundation
import CryptoKit
import Networking
import Storage

public final class DanmakuEngine: @unchecked Sendable {
    public static let shared = DanmakuEngine()

    private let httpClient: HTTPClient
    private let storage: StorageManager
    private let cacheFilename = "danmaku_cache.json"
    private let lock = NSLock()
    private var cache: [DanmakuCacheEntry]
    private var candidateHeaders: [String: [String: String]] = [:]

    public init(httpClient: HTTPClient = .shared, storage: StorageManager = .shared) {
        self.httpClient = httpClient
        self.storage = storage
        self.cache = (try? storage.loadBounded([DanmakuCacheEntry].self, from: cacheFilename, maximumBytes: 64 * 1_024 * 1_024)) ?? []
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
                let response = try await httpClient.getBounded(url: url, headers: source.headers, maximumBytes: DanmakuPayloadParser.maximumPayloadBytes, timeout: 12)
                guard (200..<300).contains(response.statusCode),
                      let payload = String(data: response.data, encoding: .utf8),
                      !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                if let candidates = decodeCandidates(payload, source: source, request: request) {
                    matches.append(contentsOf: candidates)
                    continue
                }
                let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                let format: DanmakuTrackFormat = trimmed.hasPrefix("<") ? .xml
                    : (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) ? .json : trackFormat(for: source.parserType)
                let parsed = DanmakuPayloadParser.parseWithDiagnostic(payload: payload, format: format)
                guard parsed.diagnostic.failureCategory == nil, !parsed.cues.isEmpty else { continue }
                let track = DanmakuTrack(
                    format: format,
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

    public static func sourceIdentity(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Candidate envelopes carry their own title/year/season/episode/version; selection remains explicit.
    func decodeCandidates(_ payload: String, source: DanmakuSource, request: DanmakuSearchRequest) -> [DanmakuMatch]? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (object["matches"] ?? object["results"] ?? object["episodes"]) as? [[String: Any]] else { return nil }
        return rows.prefix(24).compactMap { row in
            guard let title = (row["title"] ?? row["episodeTitle"]) as? String, !title.isEmpty else { return nil }
            let content = row["payload"] as? String
            let rawURL = (row["contentURL"] ?? row["url"]) as? String ?? ""
            let url = URL(string: rawURL, relativeTo: URL(string: source.apiURL))?.absoluteURL
            guard content != nil || (!rawURL.isEmpty && ["http", "https"].contains(url?.scheme ?? "")) else { return nil }
            let identity = (try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) ?? Data()
            let key = source.id + ":" + Self.sourceIdentity(String(decoding: identity, as: UTF8.self))
            let format = DanmakuTrackFormat(rawValue: row["format"] as? String ?? "xml") ?? .xml
            let track = DanmakuTrack(format: format, contentURL: rawURL.isEmpty ? "" : (url?.absoluteString ?? ""), cacheKey: key, sourceName: source.name)
            if let content {
                let parsed = DanmakuPayloadParser.parseWithDiagnostic(payload: content, format: format)
                guard parsed.diagnostic.failureCategory == nil, !parsed.cues.isEmpty else { return nil }
                var cachedTrack = track
                cachedTrack.contentURL = ""
                saveCache(DanmakuCacheEntry(cacheKey: key, track: cachedTrack, payload: content))
            } else {
                let origin = URL(string: source.apiURL)
                let sameOrigin = url?.scheme == origin?.scheme && url?.host == origin?.host && url?.port == origin?.port
                registerCandidateHeaders(sameOrigin ? source.headers : [:], key: key)
            }
            return DanmakuMatch(id: key, title: String(title.prefix(200)), season: row["season"] as? Int,
                episode: row["episode"] as? Int, year: row["year"] as? Int, siteKey: request.siteKey,
                track: track, version: (row["version"] as? String).map { String($0.prefix(100)) })
        }
    }

    private func registerCandidateHeaders(_ headers: [String: String], key: String) {
        lock.lock(); defer { lock.unlock() }
        if candidateHeaders.count >= 64 { candidateHeaders = [:] }
        candidateHeaders[key] = headers
    }

    private func headers(for key: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return candidateHeaders[key] ?? [:]
    }

    public func loadCandidate(_ match: DanmakuMatch) async throws {
        if cachedPayload(cacheKey: match.track.cacheKey) != nil { return }
        guard !match.track.contentURL.isEmpty else { throw DanmakuImportError.invalidFile }
        let response = try await httpClient.getBounded(url: match.track.contentURL, headers: headers(for: match.track.cacheKey),
            maximumBytes: DanmakuPayloadParser.maximumPayloadBytes, timeout: 12)
        try Task.checkCancellation()
        guard let payload = String(data: response.data, encoding: .utf8) else { throw DanmakuImportError.invalidFile }
        let parsed = DanmakuPayloadParser.parseWithDiagnostic(payload: payload, format: match.track.format)
        guard parsed.diagnostic.failureCategory == nil, !parsed.cues.isEmpty else { throw DanmakuImportError.invalidFile }
        // Signed URLs and request headers are kept only for this request, never in the persistent track.
        var track = match.track
        track.contentURL = ""
        saveCache(DanmakuCacheEntry(cacheKey: track.cacheKey, track: track, payload: payload))
    }

    public func importFile(_ url: URL) throws -> DanmakuMatch {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: DanmakuPayloadParser.maximumPayloadBytes + 1) ?? Data()
        guard data.count <= DanmakuPayloadParser.maximumPayloadBytes,
              let payload = String(data: data, encoding: .utf8) else { throw DanmakuImportError.invalidFile }
        let format: DanmakuTrackFormat = url.pathExtension.lowercased() == "json" ? .json : .xml
        let result = DanmakuPayloadParser.parseWithDiagnostic(payload: payload, format: format)
        guard result.diagnostic.failureCategory == nil, !result.cues.isEmpty else { throw DanmakuImportError.invalidFile }
        let key = "file:" + Self.sourceIdentity(payload)
        let track = DanmakuTrack(format: format, cacheKey: key, sourceName: url.lastPathComponent)
        saveCache(DanmakuCacheEntry(cacheKey: key, track: track, payload: payload))
        return DanmakuMatch(id: key, title: url.deletingPathExtension().lastPathComponent, track: track)
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
        pruneExpiredLocked()
        try? storage.save(cache, to: cacheFilename)
        lock.unlock()
    }

    private func pruneExpiredLocked(now: Date = Date()) {
        cache.removeAll { $0.isExpired(now: now) || $0.payload.utf8.count > DanmakuPayloadParser.maximumPayloadBytes }
        cache.sort { $0.createdAt > $1.createdAt }
        var bytes = 0
        cache = Array(cache.prefix(64)).filter { entry in
            bytes += entry.payload.utf8.count
            return bytes <= 16 * 1_024 * 1_024
        }
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

public enum DanmakuImportError: Error, Sendable { case invalidFile }
