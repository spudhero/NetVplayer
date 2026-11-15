import Foundation
import Models
import Networking

/// Downloads and stages a complete generation before atomically replacing the active manifest.
public actor XMLTVRepository {
    public static let shared = XMLTVRepository()
    private let directory: URL
    private let client: HTTPClient
    private let limits: EPGImportLimits
    private struct ImportWaiter {
        let manual: Bool
        let continuation: CheckedContinuation<XMLTVIndexManifest, Error>
    }
    private struct ImportJob {
        var id = UUID()
        let source: URL
        let operation: @Sendable () async throws -> XMLTVIndexManifest
        let automatic: Bool
        let attemptedAt: Date
        var task: Task<Void, Never>?
        var interrupted = false
        var waiters: [UUID: ImportWaiter] = [:]
        var isManual: Bool { waiters.values.contains { $0.manual } }
    }
    private let budget: PlaybackBackgroundBudget
    private var budgetObservation: Task<Void, Never>?
    private var imports: [String: ImportJob] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var failedSources = Set<String>()
    private let freshness: TimeInterval = 6 * 60 * 60

    public init(directory: URL? = nil, client: HTTPClient = .shared, limits: EPGImportLimits = .init(),
                budget: PlaybackBackgroundBudget = .shared) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetVplayer/epg-v1", isDirectory: true)
        self.client = client; self.limits = limits; self.budget = budget
    }

    deinit { budgetObservation?.cancel() }

    public func programmes(url: String, channelID: String, channelName: String, window: DateInterval,
                             forceRefresh: Bool = false, now: Date = Date(), scope: String = "",
                             dateRequest: TVBoxEPGRequest? = nil) async -> EpgLoadResult {
        guard window.duration > 0, window.duration <= 2 * 86_400,
              now.timeIntervalSince1970.isFinite, abs(now.timeIntervalSince1970) < 1e12,
              window.start.timeIntervalSince1970.isFinite, abs(window.start.timeIntervalSince1970) < 1e12 else {
            return EpgLoadResult(data: EpgData(channelName: channelName), availability: .unavailable)
        }
        let key = Self.cacheKey(url: url, scope: scope, dateRequest: dateRequest)
        let source = directory.appendingPathComponent(key, isDirectory: true)
        let active = source.appendingPathComponent("active.json")
        let previous = try? XMLTVIndex.read(XMLTVIndexManifest.self, from: active)
        let recentFailure = lastAttempt[key].map { now.timeIntervalSince($0) < 30 } ?? false
        var manifest = previous
        var failed = failedSources.contains(key)
        var cancelled = false
        if forceRefresh || previous == nil || now.timeIntervalSince(previous!.importedAt) >= freshness {
            if !forceRefresh, recentFailure, imports[key] == nil { failed = true }
            else {
                do {
                    let client = client, limits = limits
                    let staged = try await awaitImport(key: key, source: source, manual: forceRefresh,
                        automatic: dateRequest == nil, now: now) {
                        try await Self.importFeed(url: url, source: source, client: client, limits: limits, now: now,
                                                  previous: previous, dateRequest: dateRequest)
                    }
                    manifest = (try? XMLTVIndex.read(XMLTVIndexManifest.self, from: active)) ?? staged
                    failed = false
                } catch {
                    manifest = (try? XMLTVIndex.read(XMLTVIndexManifest.self, from: active)) ?? previous
                    cancelled = error is CancellationError
                    failed = !cancelled
                }
            }
        }
        guard !Task.isCancelled else { return EpgLoadResult(data: EpgData(channelName: channelName), availability: .unavailable) }
        guard let manifest else {
            return EpgLoadResult(data: EpgData(channelName: channelName), availability: .unavailable, message: L10n.text("节目单加载失败，请重试。"))
        }
        do {
            var data = try XMLTVIndex.query(manifest: manifest, directory: source.appendingPathComponent(manifest.generation),
                channelID: channelID, channelName: channelName, window: window)
            data.items = data.items.filter { $0.end > EPGHistoryMerge.window(now: now).start }
            return EpgLoadResult(data: data, availability: (failed || cancelled) ? .stale : (data.items.isEmpty ? .empty : .available),
                                 message: cancelled ? L10n.text("已取消节目单加载。") : failed ? L10n.text("刷新失败，正在显示上次的节目单。") : nil)
        } catch {
            return EpgLoadResult(data: EpgData(channelName: channelName), availability: .unavailable, message: L10n.text("节目单加载失败，请重试。"))
        }
    }

    public func cancelImport(url: String, scope: String = "", dateRequest: TVBoxEPGRequest? = nil) {
        let key = Self.cacheKey(url: url, scope: scope, dateRequest: dateRequest)
        guard let job = imports[key] else { return }
        for id in job.waiters.keys { cancelWaiter(key: key, id: id) }
    }

    private func awaitImport(key: String, source: URL, manual: Bool, automatic: Bool, now: Date,
                             operation: @escaping @Sendable () async throws -> XMLTVIndexManifest) async throws -> XMLTVIndexManifest {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if imports[key] == nil {
                    guard imports.count < 4 else { continuation.resume(throwing: EPGImportError.limitExceeded); return }
                    imports[key] = ImportJob(source: source, operation: operation, automatic: automatic, attemptedAt: now)
                }
                imports[key]?.waiters[waiterID] = ImportWaiter(manual: manual, continuation: continuation)
                observeBudgetIfNeeded()
                reconcileImports()
            }
        } onCancel: { Task { await self.cancelWaiter(key: key, id: waiterID) } }
    }

    private func observeBudgetIfNeeded() {
        guard budgetObservation == nil else { return }
        let changes = budget.permissionChanges()
        budgetObservation = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { break }
                await self?.reconcileImports()
            }
        }
    }

    private func cancelWaiter(key: String, id: UUID) {
        guard let waiter = imports[key]?.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        reconcileImports()
    }

    private func permitted(_ job: ImportJob) -> Bool {
        !job.automatic || job.isManual || budget.permitsOptionalWork
    }

    private func reconcileImports() {
        for key in Array(imports.keys) {
            guard var job = imports[key] else { continue }
            if job.waiters.isEmpty || !permitted(job) {
                if let task = job.task {
                    job.interrupted = true
                    imports[key] = job
                    task.cancel()
                } else if job.waiters.isEmpty { imports[key] = nil }
                continue
            }
            guard job.task == nil else { continue }
            let id = UUID(), operation = job.operation
            job.id = id; job.interrupted = false
            job.task = Task { [weak self] in
                let result: Swift.Result<XMLTVIndexManifest, Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                await self?.finishImport(key: key, id: id, result: result)
            }
            imports[key] = job
        }
    }

    private func finishImport(key: String, id: UUID, result: Swift.Result<XMLTVIndexManifest, Error>) {
        guard var job = imports[key], job.id == id else { return }
        job.task = nil
        // Keep the physical slot until download/parser cleanup has returned. A
        // manual join promotes the surviving job, even if an old attempt is cancelling.
        if job.interrupted || job.waiters.isEmpty || !permitted(job) {
            if case .success(let staged) = result { try? FileManager.default.removeItem(at: job.source.appendingPathComponent(staged.generation)) }
            imports[key] = job
            reconcileImports()
            return
        }
        var outcome = result
        if case .success(let manifest) = result {
            do { try activate(manifest, source: job.source) }
            catch {
                try? FileManager.default.removeItem(at: job.source.appendingPathComponent(manifest.generation))
                outcome = .failure(error)
            }
        }
        imports[key] = nil
        switch outcome {
        case .success:
            failedSources.remove(key)
            lastAttempt[key] = nil
            pruneCache(preserving: key)
        case .failure(let error):
            if !(error is CancellationError) { failedSources.insert(key); lastAttempt[key] = job.attemptedAt }
        }
        for waiter in job.waiters.values { waiter.continuation.resume(with: outcome) }
    }

    func importActivity() -> (jobs: Int, running: Int, waiters: Int) {
        (imports.count, imports.values.filter { $0.task != nil }.count,
         imports.values.reduce(0) { $0 + $1.waiters.count })
    }

    static func cacheKey(url: String, scope: String, dateRequest: TVBoxEPGRequest?) -> String {
        if scope.isEmpty, dateRequest == nil { return XMLTVIndex.digest(url) }
        // Length-safe encoding prevents credentials/channel IDs from becoming key delimiters.
        let parts = ["epg-v2", scope, url, dateRequest?.date ?? "", dateRequest?.timeZone.identifier ?? "", dateRequest?.channelID ?? ""]
        return XMLTVIndex.digest(String(decoding: (try? JSONEncoder().encode(parts)) ?? Data(), as: UTF8.self))
    }

    private static func importFeed(url: String, source: URL, client: HTTPClient, limits: EPGImportLimits, now: Date,
                                   previous: XMLTVIndexManifest?, dateRequest: TVBoxEPGRequest?) async throws -> XMLTVIndexManifest {
        let generation = UUID().uuidString
        let staging = source.appendingPathComponent(generation, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var staged = false
        defer { if !staged { try? FileManager.default.removeItem(at: staging) } }
        let downloaded = staging.appendingPathComponent("download.tmp")
        let expanded = staging.appendingPathComponent("expanded.tmp")
        try await client.downloadBounded(url: url, to: downloaded,
            maximumBytes: dateRequest == nil ? limits.downloadBytes : min(limits.downloadBytes, TVBoxEPGParser.maximumBytes), timeout: 30)
        let work = Task.detached(priority: .utility) {
            let file = try EPGFileExpansion.expandIfNeeded(input: downloaded, output: expanded,
                maximumBytes: dateRequest == nil ? limits.expandedBytes : min(limits.expandedBytes, TVBoxEPGParser.maximumBytes))
            let window = EPGHistoryMerge.window(now: now)
            let fresh = staging.appendingPathComponent("fresh", isDirectory: true)
            try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
            let writer = XMLTVIndexWriter(directory: fresh, limits: limits)
            let handle = try FileHandle(forReadingFrom: file)
            let prefix = try handle.read(upToCount: 512) ?? Data()
            try handle.close()
            let first = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))).first
            let channels: [String: String]
            let isJSON = first == "{"
            if isJSON {
                guard let dateRequest else { throw EPGImportError.invalidDate }
                let data = try XMLTVIndex.boundedData(file, maximumBytes: TVBoxEPGParser.maximumBytes)
                let epg = try TVBoxEPGParser.parse(data: data, request: dateRequest)
                channels = [dateRequest.channelID: dateRequest.channelName]
                try writer.append(epg.items.filter { $0.end > window.start && $0.start < window.end }.map {
                    XMLTVProgramme(channelID: dateRequest.channelID, item: $0)
                })
            } else if first == "<" {
                channels = try XMLTVStreamingParser.parse(file: file, limits: limits, window: window, receive: writer.append)
            } else { throw EPGImportError.invalidXML }
            let bytes = try EPGHistoryMerge.write(fresh: fresh,
                previous: isJSON ? nil : previous.map { source.appendingPathComponent($0.generation) },
                channels: channels, previousChannels: previous?.channels ?? [:], destination: staging, limits: limits, now: now, freshWriter: writer)
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: fresh)
            return XMLTVIndexManifest(generation: generation, importedAt: now, channels: channels, window: window, indexBytes: bytes)
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
