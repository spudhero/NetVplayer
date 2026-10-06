import Foundation
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
    private var verification: URL?
    private var cache: [String: MediaMetadata] = [:]
    private var candidateCache: [String: [MetadataCandidate]] = [:]
    private var progress: [UUID: MetadataMatchProgress] = [:]
    private let index: MediaIndex
    private let suppliedProviders: [any MetadataProvider]?
    public init(index: MediaIndex = .shared, providers: [any MetadataProvider]? = nil) {
        self.index = index; self.suppliedProviders = providers
    }
    public func enqueue(library: MediaLibraryConfiguration, references: [FileResourceReference], rematch: Bool = false) {
        jobs[library.id]?.cancel(); paused[library.id] = nil
        guard !references.isEmpty else { return }
        let jobID = UUID(); jobIDs[library.id] = jobID
        jobs[library.id] = Task(priority: .utility) {
            await self.process(library: library, references: references, rematch: rematch, jobID: jobID)
            if self.jobIDs[library.id] == jobID { self.jobs[library.id] = nil }
        }
    }
    public func rematch(_ library: MediaLibraryConfiguration) async throws {
        let records = try await index.records(libraryID: library.id)
        enqueue(library: library, references: records.map(\.reference), rematch: true)
    }
    public func cancel(libraryID: UUID) { jobs[libraryID]?.cancel(); paused[libraryID] = nil }
    public func waitForMatching(libraryID: UUID) async { await jobs[libraryID]?.value }
    public func cancelAllAndWait() async {
        let running = Array(jobs.values)
        for task in running { task.cancel() }
        paused.removeAll(); verification = nil
        for task in running { await task.value }
        paused.removeAll()
        NotificationCenter.default.post(name: .metadataVerificationRequired, object: nil)
    }
    public func cancel(serviceID: UUID) {
        for library in FileServiceStore.shared.load().libraries where library.serviceID == serviceID { cancel(libraryID: library.id) }
    }
    public func currentProgress(libraryID: UUID) -> MetadataMatchProgress? { progress[libraryID] }
    public func verificationURL() -> URL? { verification }
    public func resumeAfterVerification() {
        verification = nil
        let pending = paused; paused.removeAll()
        for (_, (library, references, rematch)) in pending { enqueue(library: library, references: references, rematch: rematch) }
    }
    private func publish(_ value: MetadataMatchProgress, jobID: UUID) {
        guard jobIDs[value.libraryID] == jobID else { return }
        progress[value.libraryID] = value
        NotificationCenter.default.post(name: .metadataMatchingDidChange, object: value)
    }
    private func providers(for source: MetadataSource) -> [any MetadataProvider] {
        if source == .local { return [] }
        if let suppliedProviders { return suppliedProviders.filter { source == .automatic || $0.source == source } }
        let credential = try? MetadataCredentials.resolve()
        var available: [any MetadataProvider] = []
        if let credential, source == .automatic || source == .tmdb { available.append(TMDBMetadataProvider(credential: credential)) }
        if source == .automatic || source == .douban { available.append(DoubanMetadataProvider.shared) }
        return available
    }
    private func process(library: MediaLibraryConfiguration, references: [FileResourceReference], rematch: Bool, jobID: UUID) async {
        let providers = providers(for: library.metadataSource)
        var disabledSources = Set<MetadataSource>()
        var batchCache: [String: MediaMetadata] = [:]
        var batchCandidates: [String: [MetadataCandidate]] = [:]
        var status = MetadataMatchProgress(libraryID: library.id, total: references.count)
        publish(status, jobID: jobID)
        defer {
            status.isRunning = false
            if Task.isCancelled { status.message = "匹配已取消，现有资料已保留" }
            else if status.completed == status.total {
                if library.metadataSource == .local { status.message = "本地影视资料检查完成" }
                else {
                    status.message = "影视信息处理完成：已匹配 \(status.matched)，待确认 \(status.needsConfirmation)，未找到 \(status.unmatched)"
                    if !disabledSources.isEmpty { status.message += "；部分信息来源不可达，现有资料已保留" }
                }
            }
            publish(status, jobID: jobID)
            NotificationCenter.default.post(name: .mediaLibraryIndexDidChange, object: library.id)
        }
        for (offset, reference) in references.enumerated() {
            if Task.isCancelled { return }
            do {
                  guard var record = try await index.record(reference: reference) else { status.completed = offset + 1; status.unmatched += 1; continue }
                  if rematch {
                      record.filenameMetadata = MediaFilenameParser.parse(path: reference.path, libraryKind: library.kind)
                          .fillingMissing(from: record.filenameMetadata)
                  }
                if !rematch && record.metadataSource == library.metadataSource && record.onlineMetadata.title != nil {
                    status.completed = offset + 1; status.matched += 1; continue
                }
                if library.metadataSource == .local {
                    record.metadataSource = .local; record.candidates = []; record.metadataError = nil
                    try await index.upsert(record); status.completed = offset + 1; continue
                }
                record.metadataError = providers.isEmpty ? "此构建未配置 TMDB 应用凭据，可选择自动、豆瓣或仅本地" : nil
                let query = (record.correction?.fields ?? .init()).fillingMissing(from: record.localMetadata).fillingMissing(from: record.filenameMetadata)
                var candidates: [MetadataCandidate] = []
                for provider in providers where !disabledSources.contains(provider.source) {
                    if provider.source == .douban, verification != nil {
                        paused[library.id] = (library, Array(references[offset...]), rematch)
                        status.message = "豆瓣需要网页验证，队列已暂停"; return
                    }
                    let explicitID = provider.source == .tmdb ? query.tmdbID : query.doubanID
                    let kind = query.kind ?? .movies
                      let hasTitleOverride = record.correction?.fields.title != nil || record.localMetadata.title != nil
                      let title = kind == .television ? query.showTitle ?? query.title ?? record.entry.name
                          : (!hasTitleOverride ? query.originalTitle : nil) ?? query.title ?? record.entry.name
                    let key = provider.source.rawValue + ":" + (explicitID ?? MediaFilenameParser.normalizedTitle(title)) + ":\(query.year ?? 0):" + kind.rawValue
                    do {
                        let details: MediaMetadata
                        if let cached = batchCache[key] ?? (rematch ? nil : cache[key]) { details = cached }
                        else if let explicitID { details = try await provider.details(id: explicitID, kind: kind) }
                        else {
                            let found: [MetadataCandidate]
                            if let cached = batchCandidates[key] ?? (rematch ? nil : candidateCache[key]) { found = cached }
                            else {
                                found = try await provider.search(title: title, year: query.year, kind: kind)
                                candidateCache[key] = found; batchCandidates[key] = found
                            }
                            candidates += found
                            guard let selected = Self.uniqueMatch(candidates: found, title: title, year: query.year, kind: kind),
                                  let id = selected.source == .tmdb ? selected.metadata.tmdbID : selected.metadata.doubanID else {
                                record.candidates = candidates; continue
                            }
                            let fetched = try await provider.details(id: id, kind: kind)
                            details = fetched.fillingMissing(from: selected.metadata)
                        }
                        try Task.checkCancellation()
                        record.onlineMetadata = details.fillingMissing(from: record.onlineMetadata)
                        record.metadataSource = library.metadataSource; record.candidates = []; record.metadataError = nil
                        cache[key] = details; batchCache[key] = details; break
                    } catch MetadataProviderError.verification(let url) {
                        verification = url; paused[library.id] = (library, Array(references[offset...]), rematch)
                        record.metadataError = "豆瓣需要验证，资料与播放已保留"; record.candidates = candidates
                        if let current = try await index.record(reference: reference) { record.correction = current.correction }
                        try await index.upsert(record)
                        status.message = "豆瓣需要网页验证，队列已暂停"
                        NotificationCenter.default.post(name: .metadataVerificationRequired, object: url)
                        return
                    } catch is CancellationError { return }
                    catch {
                        // Stop this source for the whole batch, rather than repeating a failing request for every episode.
                        record.metadataError = error.localizedDescription; disabledSources.insert(provider.source)
                    }
                }
                try Task.checkCancellation()
                if let current = try await index.record(reference: reference) { record.correction = current.correction }
                try await index.upsert(record)
                status.completed = offset + 1
                if record.metadataSource == library.metadataSource && record.onlineMetadata.title != nil { status.matched += 1 }
                else if !record.candidates.isEmpty { status.needsConfirmation += 1 }
                else { status.unmatched += 1 }
                if offset % 10 == 0 { publish(status, jobID: jobID); NotificationCenter.default.post(name: .mediaLibraryIndexDidChange, object: library.id) }
                if !providers.isEmpty, disabledSources.count == providers.count {
                    status.message = "信息来源暂时不可用，匹配已暂停；现有资料已保留，可稍后重新匹配"; return
                }
            } catch { if Task.isCancelled { return }; status.completed = offset + 1; status.unmatched += 1; status.message = error.localizedDescription }
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
