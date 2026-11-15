import Foundation
import CryptoKit
import Models
import Storage

extension Notification.Name {
    public static let metadataVerificationRequired = Notification.Name("netvplayer.metadataVerificationRequired")
    public static let metadataMatchingDidChange = Notification.Name("netvplayer.metadataMatchingDidChange")
}

public actor MetadataMatcher {
    public static let shared = MetadataMatcher()
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var jobIDs: [UUID: UUID] = [:]
    private var paused: [UUID: (MediaLibraryConfiguration, [FileResourceReference], Bool)] = [:]
    private var scanQueues: [UUID: ScanMatchQueue] = [:]
    private var pausedScanQueues: [UUID: ScanMatchQueue] = [:]
    private let store: FileServiceStore
    private var verification: URL?
    private var progress: [UUID: MetadataMatchProgress] = [:]
    private let searches: MetadataRequestPool<MetadataSearchResult>
    private let details: MetadataRequestPool<MediaMetadata>
    private var rematchRuns: [UUID: UUID] = [:]
    private let index: MediaIndex
    private let suppliedProviders: [any MetadataProvider]?
    private let diagnostics: TaskDiagnosticStore?
    private var measurements: [UUID: MediaLibraryMeasurement] = [:]
    public init(index: MediaIndex = .shared, providers: [any MetadataProvider]? = nil, diagnostics: TaskDiagnosticStore? = nil,
                store: FileServiceStore = .shared, cachePolicy: MetadataCachePolicy = .init()) {
        self.store = store; self.index = index; self.suppliedProviders = providers
        self.diagnostics = diagnostics ?? (index === MediaIndex.shared ? .shared : nil)
        searches = MetadataRequestPool(policy: cachePolicy, disposition: {
            $0.issue != nil ? .uncached : $0.candidates.isEmpty ? .negative : .positive
        }, cost: { (try? JSONEncoder().encode($0.candidates).count) ?? Int.max / 2 })
        details = MetadataRequestPool(policy: cachePolicy, disposition: { _ in .positive },
            cost: { (try? JSONEncoder().encode($0).count) ?? Int.max / 2 })
    }
    public func enqueue(library: MediaLibraryConfiguration, references: [FileResourceReference], rematch: Bool = false) async {
        await enqueue(library: library, references: references, rematch: rematch, measurement: nil)
    }
    func enqueue(library: MediaLibraryConfiguration, references: [FileResourceReference], rematch: Bool,
                 measurement: MediaLibraryMeasurement?) async {
        await cancel(libraryID: library.id)
        guard !references.isEmpty else { return }
        let jobID = UUID(); jobIDs[library.id] = jobID
        let measurement = measurement ?? MediaLibraryMeasurement(runID: jobID)
        measurements[jobID] = measurement
        jobs[library.id] = Task(priority: .utility) {
            await self.process(library: library, references: references, rematch: rematch, jobID: jobID, measurement: measurement)
            self.measurements[jobID] = nil
            if self.jobIDs[library.id] == jobID { self.jobs[library.id] = nil }
        }
    }
    public func rematch(_ library: MediaLibraryConfiguration) async throws {
        await cancel(libraryID: library.id)
        try Task.checkCancellation()
        let jobID = UUID(); jobIDs[library.id] = jobID; rematchRuns[library.id] = jobID
        let total = try await index.beginRematch(libraryID: library.id, runID: jobID)
        guard jobIDs[library.id] == jobID, rematchRuns[library.id] == jobID, !Task.isCancelled else {
            try? await index.endRematch(runID: jobID); throw CancellationError()
        }
        let measurement = MediaLibraryMeasurement(runID: jobID); measurements[jobID] = measurement
        jobs[library.id] = Task(priority: .utility) {
            await self.process(library: library, references: [], rematch: true, jobID: jobID, measurement: measurement, rematchTotal: total)
            try? await self.index.endRematch(runID: jobID)
            self.measurements[jobID] = nil
            if self.jobIDs[library.id] == jobID { self.jobs[library.id] = nil; self.rematchRuns[library.id] = nil }
        }
    }
    public func cancel(libraryID: UUID) async {
        jobs[libraryID]?.cancel(); paused[libraryID] = nil; pausedScanQueues[libraryID] = nil
        if let runID = rematchRuns.removeValue(forKey: libraryID) { try? await index.endRematch(runID: runID) }
        if let queue = scanQueues.removeValue(forKey: libraryID) { await queue.stop() }
    }
    func beginScanMatching(library: MediaLibraryConfiguration, revision: String, runID: UUID,
                           measurement: MediaLibraryMeasurement, capacity: Int,
                           validate: @escaping @Sendable () throws -> Void) async throws -> ScanMatchQueue {
        await cancel(libraryID: library.id)
        try Task.checkCancellation()
        try validate()
        try await index.beginMatching(libraryID: library.id, revision: revision, runID: runID)
        try Task.checkCancellation()
        let queue = ScanMatchQueue(library: library, revision: revision, runID: runID, index: index,
                                  capacity: capacity, measurement: measurement, validate: validate)
        let jobID = UUID(); jobIDs[library.id] = jobID
        measurements[jobID] = measurement; scanQueues[library.id] = queue
        jobs[library.id] = Task(priority: .utility) {
            await self.process(library: library, references: [], rematch: false, jobID: jobID, measurement: measurement, queue: queue)
            await queue.stop()
            self.measurements[jobID] = nil
            if self.jobIDs[library.id] == jobID { self.jobs[library.id] = nil; self.scanQueues[library.id] = nil }
        }
        return queue
    }
    public func waitForMatching(libraryID: UUID) async { await jobs[libraryID]?.value }
    public func cancelAllAndWait() async {
        let running = jobs
        for id in running.keys { await cancel(libraryID: id) }
        paused.removeAll(); pausedScanQueues.removeAll(); verification = nil
        for task in running.values { await task.value }
        paused.removeAll(); pausedScanQueues.removeAll()
        NotificationCenter.default.post(name: .metadataVerificationRequired, object: nil)
    }
    public func cancel(serviceID: UUID) async {
        for library in store.load().libraries where library.serviceID == serviceID { await cancel(libraryID: library.id) }
    }
    public func activeDiagnosticIDs() -> Set<UUID> { Set(measurements.keys) }
    public func currentProgress(libraryID: UUID) -> MetadataMatchProgress? { progress[libraryID] }
    public func verificationURL() -> URL? { verification }
    /// Explicit library action: fetch known identities sequentially, sharing the detail cache.
    public func enrichLibraryDetails(_ library: MediaLibraryConfiguration) async {
        await cancel(libraryID: library.id)
        let jobID = UUID(); jobIDs[library.id] = jobID
        rematchRuns[library.id] = jobID
        jobs[library.id] = Task(priority: .utility) {
            await self.processLibraryDetails(library, jobID: jobID)
            try? await self.index.endRematch(runID: jobID)
            if self.jobIDs[library.id] == jobID { self.jobs[library.id] = nil; self.rematchRuns[library.id] = nil }
        }
    }
    private func processLibraryDetails(_ library: MediaLibraryConfiguration, jobID: UUID) async {
        var status = MetadataMatchProgress(libraryID: library.id, total: 0, message: "正在补全系列与演员资料")
        var lastError: String?
        defer {
            status.isRunning = false
            status.message = Task.isCancelled ? "资料补全已取消，已保存的资料可继续使用" : "系列与演员资料已更新"
            if let lastError { status.message = "部分资料暂未更新：" + lastError }
            publish(status, jobID: jobID)
            NotificationCenter.default.post(name: .mediaLibraryIndexDidChange, object: library.id)
        }
        do {
            status.total = try await index.beginRematch(libraryID: library.id, runID: jobID, representativesOnly: true)
            publish(status, jobID: jobID)
            var cursor = ""
            while true {
                let page = try await index.rematchPage(libraryID: library.id, runID: jobID, after: cursor)
                try Task.checkCancellation()
                guard !page.isEmpty else { break }
                for id in page {
                    try Task.checkCancellation(); cursor = id
                    if let record = try await index.rematchRecord(id: id, libraryID: library.id),
                       record.candidates.isEmpty, record.metadata.tmdbID != nil || record.metadata.doubanID != nil {
                        do {
                            _ = try await enrichDetails(reference: record.reference, source: library.metadataSource)
                            status.matched += 1
                        } catch is CancellationError { return }
                        catch {
                            lastError = error.localizedDescription; status.failed += 1
                            if MetadataProviderError.category(of: error).pausesSource { return }
                        }
                    }
                    status.completed += 1; publish(status, jobID: jobID)
                }
            }
        } catch is CancellationError { return }
        catch { lastError = error.localizedDescription }
    }
    /// Enrich an existing, unambiguous match on demand; never search/rematch on opening a detail page.
    public func enrichDetails(reference: FileResourceReference, source: MetadataSource) async throws -> MediaRecord? {
        guard let record = try await index.record(reference: reference) else { return nil }
        guard source != .local, record.metadataSource == nil || record.metadataSource == source,
              record.candidates.isEmpty else { return record }
        let metadata = record.metadata
        let kind = metadata.kind ?? .movies
        let credential = suppliedProviders == nil ? try? MetadataCredentials.resolve() : nil
        let checksCredential = suppliedProviders == nil
        let configurationStore = store
        let library = store.load().libraries.first { $0.id == reference.libraryID }
        let revision = try library.map { try MediaLibraryScanner.configurationRevision($0, store: store) }
        let validate: @Sendable () throws -> Void = {
            if let library, let revision,
               try MediaLibraryScanner.configurationRevision(library, store: configurationStore) != revision {
                throw MediaScanRecoveryError.configurationChanged
            }
            if checksCredential, (try? MetadataCredentials.resolve()) != credential { throw MediaScanRecoveryError.configurationChanged }
        }
        for provider in providers(for: source, credential: credential) {
            guard let id = provider.source == .tmdb ? metadata.tmdbID : metadata.doubanID, !id.isEmpty else { continue }
            let requiredVersion = provider.source == .tmdb ? 2 : 1
            if (record.onlineMetadata.detailVersion ?? 0) >= requiredVersion { return record }
            let scope = requestScope(provider.source, credential: credential)
            let response = try await details.value(for: requestKey([scope, "detail", kind.rawValue, id])) {
                try await provider.details(id: id, kind: kind)
            }
            try Task.checkCancellation()
            return try await index.enrichDetails(response.value, snapshot: record, validate: validate)
        }
        return record
    }

    /// Display-only online lookup: shares the NAS pools without creating a library record.
    /// Unknown source categories search both namespaces; incomplete evidence cannot auto-bind.
    public func searchOnline(title: String, year: Int?, kind: MediaLibraryKind?, refresh: Bool = false) async throws -> MetadataSearchResult {
        let credential = suppliedProviders == nil ? try MetadataCredentials.resolve() : nil
        guard let provider = providers(for: .tmdb, credential: credential).first else {
            throw MetadataProviderError.unavailable(L10n.text("此构建未配置 TMDB 凭据"))
        }
        let scope = requestScope(.tmdb, credential: credential)
        let freshAfter: ContinuousClock.Instant? = refresh ? .now : nil
        var candidates: [MetadataCandidate] = []
        var issue: (any Error)?
        for type in kind.map({ [$0] }) ?? [.movies, .television] {
            try Task.checkCancellation()
            do {
                let response = try await searches.value(for: requestKey([scope, "search", type.rawValue, title, year.map(String.init) ?? ""]), cachedAfter: freshAfter) {
                    try await provider.searchResult(title: title, year: year, kind: type)
                }
                candidates += response.value.candidates.filter { $0.source == .tmdb && $0.metadata.kind == type }
                if let failure = response.value.issue { issue = failure }
            } catch {
                try Task.checkCancellation()
                issue = error
            }
        }
        try validateOnlineCredential(credential)
        // TMDB movie and TV IDs overlap; the generic NAS candidate id omits kind.
        var seen = Set<String>()
        candidates = candidates.filter { candidate in
            guard let key = Self.onlineCandidateKey(candidate) else { return false }
            return seen.insert(key).inserted
        }
        return .init(candidates: candidates, issue: issue)
    }

    public func onlineDetails(candidate: MetadataCandidate, refresh: Bool = false) async throws -> MediaMetadata {
        guard Self.onlineCandidateKey(candidate) != nil,
              let id = candidate.metadata.tmdbID, let kind = candidate.metadata.kind else {
            throw MetadataProviderError.invalidResponse
        }
        let credential = suppliedProviders == nil ? try MetadataCredentials.resolve() : nil
        guard let provider = providers(for: .tmdb, credential: credential).first else {
            throw MetadataProviderError.unavailable(L10n.text("此构建未配置 TMDB 凭据"))
        }
        let scope = requestScope(.tmdb, credential: credential)
        let response = try await details.value(for: requestKey([scope, "detail", kind.rawValue, id]), cachedAfter: refresh ? .now : nil) {
            let value = try await provider.details(id: id, kind: kind)
            guard value.tmdbID == id, value.kind == kind else { throw MetadataProviderError.invalidResponse }
            return value
        }
        try validateOnlineCredential(credential)
        guard response.value.tmdbID == id, response.value.kind == kind else { throw MetadataProviderError.invalidResponse }
        return response.value.fillingMissing(from: candidate.metadata)
    }

    public static func onlineCandidateKey(_ candidate: MetadataCandidate) -> String? {
        guard candidate.source == .tmdb, let id = candidate.metadata.tmdbID,
              !id.isEmpty, id.utf8.count <= 12, id.utf8.allSatisfy({ (48...57).contains($0) }),
              let kind = candidate.metadata.kind, kind == .movies || kind == .television else { return nil }
        return kind.rawValue + ":" + id
    }

    private func validateOnlineCredential(_ credential: TMDBCredential?) throws {
        try Task.checkCancellation()
        if suppliedProviders == nil, try MetadataCredentials.resolve() != credential {
            throw MediaScanRecoveryError.configurationChanged
        }
    }
    public func resumeAfterVerification() async {
        verification = nil
        let pending = paused; paused.removeAll()
        for (_, (library, references, rematch)) in pending {
            if rematch && references.isEmpty { try? await self.rematch(library) }
            else { await enqueue(library: library, references: references, rematch: rematch) }
        }
        let streams = pausedScanQueues; pausedScanQueues.removeAll()
        for queue in streams.values {
            do {
                let runID = UUID()
                let resumed = try await beginScanMatching(library: queue.library, revision: queue.revision, runID: runID,
                    measurement: .init(runID: runID), capacity: MediaIndex.maximumPendingMatches, validate: queue.validate)
                await resumed.finish()
            } catch { /* Configuration changed: keep old work unclaimed until an explicit scan. */ }
        }
    }
    private func publish(_ value: MetadataMatchProgress, jobID: UUID) {
        guard jobIDs[value.libraryID] == jobID else { return }
        var value = value; value.metrics = measurements[jobID]?.snapshot()
        progress[value.libraryID] = value
        NotificationCenter.default.post(name: .metadataMatchingDidChange, object: value)
    }
    private func providers(for source: MetadataSource, credential: TMDBCredential?) -> [any MetadataProvider] {
        if source == .local { return [] }
        if let suppliedProviders { return suppliedProviders.filter { source == .automatic || $0.source == source } }
        var available: [any MetadataProvider] = []
        if let credential, source == .automatic || source == .tmdb { available.append(TMDBMetadataProvider(credential: credential)) }
        if source == .automatic || source == .douban { available.append(DoubanMetadataProvider.shared) }
        return available
    }
    private func requestScope(_ source: MetadataSource, credential: TMDBCredential?) -> String {
        let credential = suppliedProviders == nil && source == .tmdb ? credential : nil
        return requestKey([source.rawValue, suppliedProviders == nil ? "production" : "supplied",
                           credential?.kind.rawValue ?? "", credential?.value ?? ""])
    }
    private func requestKey(_ parts: [String]) -> String {
        SHA256.hash(data: (try? JSONEncoder().encode(parts)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    func cacheStatistics() async -> (search: MetadataRequestPool<MetadataSearchResult>.Statistics, detail: MetadataRequestPool<MediaMetadata>.Statistics) {
        (await searches.statistics(), await details.statistics())
    }
    private func process(library: MediaLibraryConfiguration, references: [FileResourceReference], rematch: Bool,
                         jobID: UUID, measurement: MediaLibraryMeasurement, queue: ScanMatchQueue? = nil, rematchTotal: Int? = nil) async {
        let credential = suppliedProviders == nil ? try? MetadataCredentials.resolve() : nil
        let providers = providers(for: library.metadataSource, credential: credential)
        let enforcesConfiguration = store.load().services.contains { $0.id == library.serviceID }
        let revision = enforcesConfiguration ? try? MediaLibraryScanner.configurationRevision(library, store: store) : nil
        let checksCredential = suppliedProviders == nil
        let configurationStore = store
        let validateConfiguration: @Sendable () throws -> Void = {
            if let queue { try queue.validate() }
            else if enforcesConfiguration {
                guard let revision, try MediaLibraryScanner.configurationRevision(library, store: configurationStore) == revision else {
                    throw MediaScanRecoveryError.configurationChanged
                }
            }
            if checksCredential, (try? MetadataCredentials.resolve()) != credential {
                throw MediaScanRecoveryError.configurationChanged
            }
        }
        func ensureCurrent() throws {
            try Task.checkCancellation()
            guard jobIDs[library.id] == jobID else { throw CancellationError() }
            try validateConfiguration()
        }
        var disabledSources = Set<MetadataSource>()
        var sourceErrors: [MetadataSource: String] = [:]
        let freshAfter: ContinuousClock.Instant? = rematch || rematchTotal != nil ? .now : nil
        var status = MetadataMatchProgress(libraryID: library.id, total: rematchTotal ?? references.count)
        var page: [String] = [], pageOffset = 0, cursor = ""
        var interrupted = false
        var offset = 0
        publish(status, jobID: jobID)
        try? diagnostics?.record(.init(id: jobID, kind: .metadataMatch, localSubjectID: library.id,
            event: .init(stage: .confirming, state: .processing, mediaMetrics: measurement.snapshot())))
        defer {
            // A producer may still have undiscovered files when matching pauses.
            measurement.finish(status, cancelled: Task.isCancelled, paused: interrupted || status.failed > 0)
            try? diagnostics?.record(.init(id: jobID, kind: .metadataMatch, localSubjectID: library.id,
                event: .init(stage: .finished, state: Task.isCancelled ? .cancelled : !interrupted && status.failed == 0 && status.completed == status.total ? .completed : .needsAttention,
                             mediaMetrics: measurement.snapshot())))
            status.isRunning = false
            if Task.isCancelled { status.message = "匹配已取消，现有资料已保留" }
            else if !interrupted && status.completed == status.total {
                if library.metadataSource == .local { status.message = "本地影视资料检查完成" }
                else {
                    status.message = "影视信息处理完成：已匹配 \(status.matched)，待确认 \(status.needsConfirmation)，未找到 \(status.unmatched)"
                    if status.failed > 0 { status.message += L10n.text("；部分条目暂未更新，可稍后重试") }
                    if !disabledSources.isEmpty { status.message += "；部分信息来源不可达，现有资料已保留" }
                }
            }
            publish(status, jobID: jobID)
            NotificationCenter.default.post(name: .mediaLibraryIndexDidChange, object: library.id)
        }
        func pauseForVerification() {
            if let queue { pausedScanQueues[library.id] = queue }
            else if rematchTotal != nil { paused[library.id] = (library, [], true) }
            else { paused[library.id] = (library, Array(references[offset...]), rematch) }
            interrupted = true; status.message = "豆瓣需要网页验证，队列已暂停"
        }
        do {
            while true {
                try ensureCurrent()
                let work: MediaIndex.MatchWork?
                let snapshot: MediaRecord
                if let queue {
                    guard let next = try await queue.next() else { status.total = status.completed; break }
                    work = next; snapshot = next.record
                    status.total = status.completed + (try await queue.pendingCount())
                    measurement.mark(\.firstFileSeconds)
                } else if rematchTotal != nil {
                    if pageOffset == page.count {
                        page = try await index.rematchPage(libraryID: library.id, runID: jobID, after: cursor)
                        pageOffset = 0
                        guard !page.isEmpty else { break }
                    }
                    let id = page[pageOffset]; pageOffset += 1; cursor = id
                    work = nil
                    guard let record = try await index.rematchRecord(id: id, libraryID: library.id) else {
                        status.completed += 1; continue
                    }
                    snapshot = record
                } else {
                    guard offset < references.count else { break }
                    work = nil
                    guard let record = try await index.record(reference: references[offset]) else {
                        offset += 1; status.completed += 1; status.unmatched += 1; continue
                    }
                    snapshot = record
                }
                try ensureCurrent()
                measurement.mark(\.matchStartedSeconds)
                var record = snapshot
                let forceRematch = work?.rematch ?? rematch
                if forceRematch { record.filenameMetadata = MediaFilenameParser.parse(path: record.reference.path, libraryKind: library.kind) }
                let alreadyMatched = !forceRematch && record.metadataSource == library.metadataSource && record.onlineMetadata.title != nil
                if alreadyMatched { measurement.increment(\.cacheHits) }
                else if library.metadataSource == .local {
                    record.metadataSource = .local; record.candidates = []; record.metadataError = nil
                } else {
                    record.metadataError = providers.isEmpty ? "此构建未配置 TMDB 应用凭据，可选择自动、豆瓣或仅本地" : providers.compactMap { sourceErrors[$0.source] }.first
                    let query = (record.correction?.fields ?? .init()).fillingMissing(from: record.localMetadata).fillingMissing(from: record.filenameMetadata)
                    var candidates: [MetadataCandidate] = []
                    for provider in providers where !disabledSources.contains(provider.source) {
                        try ensureCurrent()
                        if provider.source == .douban, verification != nil { pauseForVerification(); return }
                        let explicitID = provider.source == .tmdb ? query.tmdbID : query.doubanID
                        let kind = query.kind ?? .movies
                        let hasTitleOverride = record.correction?.fields.title != nil || record.localMetadata.title != nil
                        let title = kind == .television ? query.showTitle ?? query.title ?? record.entry.name
                            : (!hasTitleOverride ? query.originalTitle : nil) ?? query.title ?? record.entry.name
                        let scope = requestScope(provider.source, credential: credential)
                        do {
                            let metadata: MediaMetadata
                            if let explicitID {
                                let response = try await details.value(for: requestKey([scope, "detail", kind.rawValue, explicitID]), cachedAfter: forceRematch ? freshAfter : nil) {
                                    measurement.increment(\.providerDetailCalls)
                                    return try await provider.details(id: explicitID, kind: kind)
                                }
                                if response.reused { measurement.increment(\.cacheHits) }; metadata = response.value
                            }
                            else {
                                let response = try await searches.value(for: requestKey([scope, "search", kind.rawValue, title, query.year.map(String.init) ?? ""]),
                                                                       cachedAfter: forceRematch ? freshAfter : nil) {
                                    measurement.increment(\.providerSearchCalls)
                                    return try await provider.searchResult(title: title, year: query.year, kind: kind)
                                }
                                try ensureCurrent()
                                if response.reused { measurement.increment(\.cacheHits) }
                                let found = response.value.candidates
                                measurement.increment(\.candidates, by: found.count)
                                candidates += found
                                record.candidates = candidates
                                if let issue = response.value.issue { throw issue }
                                guard let selected = Self.uniqueMatch(candidates: found, title: title, year: query.year, kind: kind),
                                      let id = selected.source == .tmdb ? selected.metadata.tmdbID : selected.metadata.doubanID else {
                                    record.candidates = candidates; continue
                                }
                                let detail = try await details.value(for: requestKey([scope, "detail", kind.rawValue, id]), cachedAfter: forceRematch ? freshAfter : nil) {
                                    measurement.increment(\.providerDetailCalls)
                                    return try await provider.details(id: id, kind: kind)
                                }
                                if detail.reused { measurement.increment(\.cacheHits) }
                                metadata = detail.value.fillingMissing(from: selected.metadata)
                            }
                            try ensureCurrent()
                            record.onlineMetadata = metadata.fillingMissing(from: record.onlineMetadata)
                            record.metadataSource = library.metadataSource; record.candidates = []; record.metadataError = nil
                            break
                        } catch MetadataProviderError.verification(let url) {
                            try ensureCurrent()
                            verification = url; pauseForVerification()
                            record.metadataError = "豆瓣需要验证，资料与播放已保留"; record.candidates = candidates
                            _ = try await index.commitMatch(record, snapshot: snapshot, work: work, runID: queue?.runID, acknowledge: false, validate: validateConfiguration)
                            NotificationCenter.default.post(name: .metadataVerificationRequired, object: url)
                            return
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            try ensureCurrent()
                            record.metadataError = error.localizedDescription
                            if MetadataProviderError.category(of: error).pausesSource {
                                disabledSources.insert(provider.source); sourceErrors[provider.source] = error.localizedDescription
                            }
                        }
                    }
                }
                try ensureCurrent()
                let unavailable = !providers.isEmpty && disabledSources.count == providers.count
                let committed = try await index.commitMatch(record, snapshot: snapshot, work: work, runID: queue?.runID,
                                                            acknowledge: queue == nil || !unavailable, validate: validateConfiguration)
                try ensureCurrent()
                if let queue { await queue.consumed() }
                if committed {
                    measurement.onlineMetadataAvailable(record)
                    // Failed stream items stay durable for the next explicit recovery.
                    if queue == nil || !unavailable {
                        status.completed += 1
                        if record.metadataError != nil { status.failed += 1 }
                        else if record.metadataSource == library.metadataSource && record.onlineMetadata.title != nil { status.matched += 1 }
                        else if !record.candidates.isEmpty { status.needsConfirmation += 1 }
                        else { status.unmatched += 1 }
                    }
                }
                if queue == nil { offset += 1 }
                if status.completed % 10 == 0 || status.completed == 1 {
                    publish(status, jobID: jobID); NotificationCenter.default.post(name: .mediaLibraryIndexDidChange, object: library.id)
                }
                if unavailable {
                    interrupted = true
                    status.message = "信息来源暂时不可用，匹配已暂停；现有资料已保留，可稍后重新匹配"; return
                }
            }
        } catch {
            interrupted = true
            if !Task.isCancelled { status.message = error.localizedDescription }
        }
    }
    /// Match a unique exact display/original/official alternative title; use the year when known to distinguish remakes.
    public static func uniqueMatch(candidates: [MetadataCandidate], title: String, year: Int?, kind: MediaLibraryKind) -> MetadataCandidate? {
        let normalized = MediaFilenameParser.normalizedTitle(title)
        guard !normalized.isEmpty else { return nil }
        let matches = candidates.filter { candidate in
            let metadata = candidate.metadata
            guard metadata.kind == kind, year == nil || metadata.year == year else { return false }
            let titles = [metadata.title, metadata.originalTitle, kind == .television ? metadata.showTitle : nil].compactMap { $0 }
                + (metadata.alternativeTitles ?? [])
            return titles.contains { MediaFilenameParser.normalizedTitle($0) == normalized }
        }
        // With no year, multiple same-title releases still require manual confirmation.
        return matches.count == 1 ? matches[0] : nil
    }
}
