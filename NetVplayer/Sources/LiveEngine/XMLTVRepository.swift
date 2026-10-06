import Foundation
import Models
import Networking

/// Downloads and stages a complete generation before atomically replacing the active manifest.
public actor XMLTVRepository {
    public static let shared = XMLTVRepository()
    private let directory: URL
    private let client: HTTPClient
    private let limits: EPGImportLimits
    private struct ImportJob { var id = UUID(); var task: Task<XMLTVIndexManifest, Error> }
    private var imports: [String: ImportJob] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var failedSources = Set<String>()
    private let freshness: TimeInterval = 6 * 60 * 60

    public init(directory: URL? = nil, client: HTTPClient = .shared, limits: EPGImportLimits = .init()) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetVplayer/epg-v1", isDirectory: true)
        self.client = client; self.limits = limits
    }

    public func programmes(url: String, channelID: String, channelName: String, window: DateInterval,
                           forceRefresh: Bool = false, now: Date = Date()) async -> EpgLoadResult {
        let key = XMLTVIndex.digest(url)
        let source = directory.appendingPathComponent(key, isDirectory: true)
        let active = source.appendingPathComponent("active.json")
        let previous = try? XMLTVIndex.read(XMLTVIndexManifest.self, from: active)
        let recentFailure = lastAttempt[key].map { now.timeIntervalSince($0) < 30 } ?? false
        var manifest = previous
        var failed = failedSources.contains(key)
        if forceRefresh || previous == nil || now.timeIntervalSince(previous!.importedAt) >= freshness {
            if !forceRefresh, recentFailure, imports[key] == nil { failed = true }
            else {
                var awaitedID: UUID?
                var stagedGeneration: String?
                do {
                    if imports[key] == nil {
                        // The guide schedules at most four requests; imports additionally cap distinct feeds.
                        guard imports.count < 4 else { throw EPGImportError.limitExceeded }
                        lastAttempt[key] = now
                        let client = client; let limits = limits
                        imports[key] = ImportJob(task: Task {
                            try await Self.importFeed(url: url, source: source, client: client, limits: limits, now: now)
                        })
                    }
                    let job = imports[key]!
                    awaitedID = job.id
                    let staged = try await job.task.value
                    stagedGeneration = staged.generation
                    if imports[key]?.id == job.id {
                        guard !job.task.isCancelled else { throw CancellationError() }
                        try activate(staged, source: source)
                        imports[key] = nil
                    }
                    manifest = try XMLTVIndex.read(XMLTVIndexManifest.self, from: active)
                    failedSources.remove(key)
                    failed = false
                    pruneCache(preserving: key)
                } catch {
                    if let awaitedID, imports[key]?.id == awaitedID {
                        imports[key] = nil
                        if let stagedGeneration { try? FileManager.default.removeItem(at: source.appendingPathComponent(stagedGeneration)) }
                    }
                    manifest = (try? XMLTVIndex.read(XMLTVIndexManifest.self, from: active)) ?? previous
                    failedSources.insert(key)
                    failed = true
                }
            }
        }
        guard !Task.isCancelled else { return EpgLoadResult(data: EpgData(channelName: channelName), availability: .unavailable) }
        guard let manifest else {
            return EpgLoadResult(data: EpgData(channelName: channelName), availability: .unavailable, message: L10n.text("节目单加载失败，请重试。"))
        }
        do {
            let data = try XMLTVIndex.query(manifest: manifest, directory: source.appendingPathComponent(manifest.generation),
                channelID: channelID, channelName: channelName, window: window)
            return EpgLoadResult(data: data, availability: failed ? .stale : (data.items.isEmpty ? .empty : .available),
                                 message: failed ? L10n.text("刷新失败，正在显示上次的节目单。") : nil)
        } catch {
            return EpgLoadResult(data: EpgData(channelName: channelName), availability: .unavailable, message: L10n.text("节目单加载失败，请重试。"))
        }
    }

    public func cancelImport(url: String) { imports[XMLTVIndex.digest(url)]?.task.cancel() }

    private static func importFeed(url: String, source: URL, client: HTTPClient, limits: EPGImportLimits, now: Date) async throws -> XMLTVIndexManifest {
        let generation = UUID().uuidString
        let staging = source.appendingPathComponent(generation, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var staged = false
        defer { if !staged { try? FileManager.default.removeItem(at: staging) } }
        let downloaded = staging.appendingPathComponent("download.tmp")
        let expanded = staging.appendingPathComponent("expanded.tmp")
        try await client.downloadBounded(url: url, to: downloaded, maximumBytes: limits.downloadBytes, timeout: 30)
        let work = Task.detached(priority: .utility) {
            let file = try EPGFileExpansion.expandIfNeeded(input: downloaded, output: expanded, maximumBytes: limits.expandedBytes)
            let window = DateInterval(start: now.addingTimeInterval(-2 * 86_400), end: now.addingTimeInterval(8 * 86_400))
            let writer = XMLTVIndexWriter(directory: staging, limits: limits)
            let channels = try XMLTVStreamingParser.parse(file: file, limits: limits, window: window, receive: writer.append)
            try Task.checkCancellation()
            return XMLTVIndexManifest(generation: generation, importedAt: now, channels: channels, window: window, indexBytes: writer.byteCount)
        }
        let manifest = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: downloaded)
        try? FileManager.default.removeItem(at: expanded)
        let encoded = try JSONEncoder().encode(manifest)
        try encoded.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        staged = true
        return manifest
    }

    private func activate(_ manifest: XMLTVIndexManifest, source: URL) throws {
        let generation = manifest.generation
        let encoded = try JSONEncoder().encode(manifest)
        try encoded.write(to: source.appendingPathComponent("active.json"), options: .atomic)
        // Activation and index reads share the actor, so readers never observe a deleted generation.
        for child in (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] {
            if UUID(uuidString: child.lastPathComponent) != nil, child.lastPathComponent != generation { try? FileManager.default.removeItem(at: child) }
        }
    }

    private func pruneCache(preserving key: String) {
        let entries = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).compactMap { url -> (URL, XMLTVIndexManifest)? in
            guard let manifest = try? XMLTVIndex.read(XMLTVIndexManifest.self, from: url.appendingPathComponent("active.json")) else { return nil }
            return (url, manifest)
        }.sorted { $0.1.importedAt > $1.1.importedAt }
        var bytes = 0; var count = 0
        for (url, manifest) in entries {
            bytes += manifest.indexBytes; count += 1
            if (count > 32 || bytes > 256 * 1_024 * 1_024), url.lastPathComponent != key, imports[url.lastPathComponent] == nil {
                try? FileManager.default.removeItem(at: url)
                lastAttempt[url.lastPathComponent] = nil
                failedSources.remove(url.lastPathComponent)
            }
        }
        if lastAttempt.count > 128 { lastAttempt = lastAttempt.filter { Date().timeIntervalSince($0.value) < 30 } }
        if failedSources.count > 128 { failedSources = failedSources.intersection(lastAttempt.keys) }
    }
}
