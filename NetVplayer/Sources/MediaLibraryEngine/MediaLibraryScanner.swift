import Foundation
import CryptoKit
import Models
import Storage
import FileServiceEngine

extension Notification.Name {
    public static let mediaLibraryIndexDidChange = Notification.Name("netvplayer.mediaLibraryIndexDidChange")
    public static let mediaLibraryScanDidChange = Notification.Name("netvplayer.mediaLibraryScanDidChange")
}

public actor MediaLibraryScanner {
    public static let shared = MediaLibraryScanner()
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var jobServices: [UUID: UUID] = [:]
    private var progress: [UUID: MediaScanProgress] = [:]
    private let index: MediaIndex
    private let store: FileServiceStore
    private let runtime: FileServiceRuntime
    private let limiter = ScanLimiter()
    private let diagnostics: TaskDiagnosticStore?
    private let matcher: MetadataMatcher
    private let matchesSuppliedClients: Bool
    private let matchQueueCapacity: Int
    private var diagnosticIDs: [UUID: UUID] = [:]
    private var measurements: [UUID: MediaLibraryMeasurement] = [:]
    public init(index: MediaIndex = .shared, store: FileServiceStore = .shared, runtime: FileServiceRuntime? = nil,
                diagnostics: TaskDiagnosticStore? = nil, matcher: MetadataMatcher? = nil,
                matchQueueCapacity: Int = MediaIndex.maximumPendingMatches) {
        self.matchQueueCapacity = matchQueueCapacity
        self.matcher = matcher ?? .shared; self.matchesSuppliedClients = matcher != nil
        self.index = index; self.store = store; self.runtime = runtime ?? (store === FileServiceStore.shared ? .shared : FileServiceRuntime(store: store))
        self.diagnostics = diagnostics ?? (index === MediaIndex.shared && store === FileServiceStore.shared ? .shared : nil)
    }
    /// Only explicit user operations call start. Reading a checkpoint never creates a job or client.
    public func start(_ library: MediaLibraryConfiguration, rematch: Bool = false, request: MediaScanRequest = .rescan) {
        enqueue(library, rematch: rematch, request: request)
    }
    private func enqueue(_ library: MediaLibraryConfiguration, rematch: Bool = false, request: MediaScanRequest,
                         client: (any FileServiceClient)? = nil) {
        guard jobs[library.id] == nil else { return }
        let diagnosticID = UUID()
        diagnosticIDs[library.id] = diagnosticID
        measurements[library.id] = MediaLibraryMeasurement(runID: diagnosticID)
        let previousRetries = (try? diagnostics?.records().first { $0.kind == .mediaScan && $0.localSubjectID == library.id }?.latest.retryCount) ?? 0
        let retries = request == .rescan ? 0 : min(99, previousRetries + 1)
        recordDiagnostic(diagnosticID, libraryID: library.id, stage: .queued, state: .processing, retries: retries)
        jobServices[library.id] = library.serviceID
        publish(MediaScanProgress(libraryID: library.id, currentPath: library.path))
        jobs[library.id] = Task(priority: .utility) {
            let acquired = await limiter.acquire()
            if acquired && !Task.isCancelled {
                await self.perform(library, rematch: rematch, request: request, suppliedClient: client, runID: diagnosticID, retries: retries)
            } else {
                var status = MediaScanProgress(libraryID: library.id, currentPath: library.path, isRunning: false)
                status.isCancelled = true
                status.message = L10n.text("扫描已取消，旧索引已保留"); self.publish(status)
                self.recordDiagnostic(diagnosticID, libraryID: library.id, stage: .queued, state: .cancelled, retries: retries)
            }
            if acquired { await limiter.release() }
            self.jobs[library.id] = nil; self.jobServices[library.id] = nil; self.diagnosticIDs[library.id] = nil; self.measurements[library.id] = nil
        }
    }
    public func cancel(libraryID: UUID) async {
        guard let task = jobs[libraryID] else { return }
        task.cancel()
        await matcher.cancel(libraryID: libraryID)
        try? await index.interruptScanCheckpoint(libraryID: libraryID, phase: .cancelled)
    }
    public func cancel(serviceID: UUID) async {
        for id in jobServices.filter({ $0.value == serviceID }).map(\.key) { await cancel(libraryID: id) }
    }
    public func currentProgress(libraryID: UUID) -> MediaScanProgress? { progress[libraryID] }
    public func activeDiagnosticIDs() -> Set<UUID> { Set(diagnosticIDs.values) }
    public func diagnosticIssue(libraryID: UUID) -> TaskDiagnosticIssue? {
        (try? diagnostics?.records().first { $0.kind == .mediaScan && $0.localSubjectID == libraryID })?.latest.issue
    }
    public func waitForScan(libraryID: UUID) async { await jobs[libraryID]?.value }
    public func cancelAllAndWait() async {
        let running = jobs
        for id in running.keys { await cancel(libraryID: id) }
        for task in running.values { await task.value }
    }
    /// Protocol fixtures use the identical job, checkpoint, cancellation and completion path.
    public func scan(_ library: MediaLibraryConfiguration, client: any FileServiceClient, request: MediaScanRequest = .rescan) async {
        enqueue(library, request: request, client: client)
        await jobs[library.id]?.value
    }
    public func checkpoint(libraryID: UUID) async throws -> MediaScanCheckpoint? {
        var checkpoint = try await index.scanCheckpoint(libraryID: libraryID)
        if checkpoint?.phase == .running && jobs[libraryID] == nil { checkpoint?.phase = .interrupted }
        return checkpoint
    }
    /// Stable across restarts, local-only, and sensitive to endpoint/root, library and authorization edits.
    public nonisolated static func configurationRevision(_ library: MediaLibraryConfiguration, store: FileServiceStore) throws -> String {
        try store.scanConfigurationRevision(for: library)
    }
    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func publish(_ value: MediaScanProgress) {
        var value = value; value.metrics = measurements[value.libraryID]?.snapshot()
        progress[value.libraryID] = value
        NotificationCenter.default.post(name: .mediaLibraryScanDidChange, object: value)
    }
    private func recordDiagnostic(_ id: UUID, libraryID: UUID, stage: TaskResultStage, state: TaskResultState,
                                  issue: TaskDiagnosticIssue? = nil, retries: Int) {
        try? diagnostics?.record(.init(id: id, kind: .mediaScan, localSubjectID: libraryID,
            event: .init(stage: stage, state: state, issue: issue, retryCount: retries, mediaMetrics: measurements[libraryID]?.snapshot())))
    }
    private func perform(_ input: MediaLibraryConfiguration, rematch: Bool, request: MediaScanRequest,
                         suppliedClient: (any FileServiceClient)?, runID: UUID, retries: Int) async {
        var library = input
        let measurement = measurements[input.id]
        var claimed = false
        var matchQueue: ScanMatchQueue?
        var status = MediaScanProgress(libraryID: library.id, currentPath: library.path)
        recordDiagnostic(runID, libraryID: library.id, stage: .scanning, state: .processing, retries: retries)
        publish(status)
        do {
            library.path = try FileServicePath.normalize(library.path)
            // Fixture clients may omit a catalog; configured fixtures still exercise revision rejection.
            let enforcesConfiguration = suppliedClient == nil || store.load().services.contains { $0.id == library.serviceID }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let revision = try enforcesConfiguration ? Self.configurationRevision(library, store: store)
                : Self.digest(encoder.encode(library))
            let deadline = Date().addingTimeInterval(3600)
            func ensureCurrent() throws {
                try Task.checkCancellation()
                guard Date() < deadline else { throw MediaScanRecoveryError.readBudget }
                if enforcesConfiguration, try Self.configurationRevision(library, store: store) != revision {
                    throw MediaScanRecoveryError.configurationChanged
                }
            }
            try ensureCurrent()
            let checkpoint = try await index.beginScanCheckpoint(library: library, revision: revision, request: request, runID: runID)
            claimed = true
            try ensureCurrent()
            let client: any FileServiceClient
            if let suppliedClient { client = suppliedClient }
            else { client = try await runtime.client(for: library.serviceID) }
            try ensureCurrent()
            if suppliedClient == nil || matchesSuppliedClients, let measurement {
                let configuration = library, expectedRevision = revision, configurationStore = store
                matchQueue = try await matcher.beginScanMatching(library: library, revision: revision, runID: runID,
                    measurement: measurement, capacity: matchQueueCapacity) {
                    if enforcesConfiguration, try Self.configurationRevision(configuration, store: configurationStore) != expectedRevision {
                        throw MediaScanRecoveryError.configurationChanged
                    }
                }
            }
            let previous = Dictionary(checkpoint.directories.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
            var roots = [library.path]
            if case .retryFailed(let paths) = request {
                // A selected ancestor already includes its failed descendants.
                roots = Set(paths).sorted().filter { path in !paths.contains { $0 != path && path.hasPrefix($0 == "/" ? "/" : $0 + "/") } }
            }
            var successfulRetryRoots: [String] = []
            var listedEntries = 0
            let corrections = Dictionary(store.loadCorrections().map { ($0.reference, $0) }, uniquingKeysWith: { _, last in last })
            for root in roots {
                try ensureCurrent()
                // Only metadata ancestors are read for a retry; their media rows are never updated.
                var inherited = MediaMetadata(), parentFingerprint = ""
                if root != library.path {
                    var ancestors: [String] = [], cursor = FileServicePath.parent(root)
                    while true {
                        guard cursor == library.path || cursor.hasPrefix(library.path == "/" ? "/" : library.path + "/"), ancestors.count < 128 else {
                            throw MediaScanRecoveryError.unavailable
                        }
                        ancestors.insert(cursor, at: 0)
                        if cursor == library.path { break }
                        cursor = FileServicePath.parent(cursor)
                    }
                    for path in ancestors {
                        let entries = try await boundedEntries(client: client, path: path, listedEntries: &listedEntries)
                        try ensureCurrent()
                        let context = try await directoryContext(entries: entries, path: path, library: library,
                            inherited: inherited, parentFingerprint: parentFingerprint, client: client)
                        inherited = context.show; parentFingerprint = context.fingerprint
                    }
                }
                var stack: [(String, MediaMetadata, String)] = [(root, inherited, parentFingerprint)]
                var visited = Set<String>()
                let failuresBeforeRoot = status.failedDirectories.count
                while let (path, inherited, parentFingerprint) = stack.popLast() {
                    try ensureCurrent()
                    guard visited.insert(path).inserted else { continue }
                    guard visited.count <= MediaScanCheckpoint.maximumDirectories, path.split(separator: "/").count <= 128 else {
                        throw MediaScanRecoveryError.capacity
                    }
                    status.currentPath = path; status.directories += 1; publish(status)
                    try await index.visitScanDirectory(.init(path: path), libraryID: library.id, runID: runID)
                    let originalEntries: [FileEntry]
                    do { originalEntries = try await boundedEntries(client: client, path: path, listedEntries: &listedEntries) }
                    catch {
                        try ensureCurrent()
                        if error is MediaScanRecoveryError { throw error }
                        let issue = TaskDiagnosticIssue.local(error)
                        if status.taskIssue == nil || issue.reason == .credentialExpired { status.taskIssue = issue }
                        status.failedDirectories.append(path)
                        try await index.visitScanDirectory(.init(path: path, state: .failed), libraryID: library.id, runID: runID)
                        publish(status); continue
                    }
                    try ensureCurrent()
                    let context = try await directoryContext(entries: originalEntries, path: path, library: library,
                        inherited: inherited, parentFingerprint: parentFingerprint, client: client)
                    try ensureCurrent()
                    let entries = context.entries, show = context.show, fingerprint = context.fingerprint
                    let discRoot = context.discRoot, entryByName = context.byName
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    var material = try encoder.encode(originalEntries.sorted { $0.path < $1.path })
                    material.append(Data(fingerprint.utf8))
                    let directoryFingerprint = Self.digest(material)
                    let children = entries.filter { $0.isDirectory && !discRoot }.map(\.path)
                    let reused = previous[path].map { $0.state == .completed && $0.fingerprint == directoryFingerprint && $0.scanID != nil } == true && !rematch
                    if reused, let oldRun = previous[path]?.scanID {
                        try await index.reuseScanDirectory(path: path, previousScanID: oldRun, libraryID: library.id, runID: runID)
                        status.files += entries.filter { (discRoot && $0.path == path) || FileServiceRuntime.isVideo($0) }.count
                        if status.files > 0 { measurement?.mark(\.firstFileSeconds) }
                    } else {
                        // Only the shared fallback is retained, for this directory listing only.
                        // Per-file NFOs and failed reads keep their original behavior and priority.
                        var sharedMovieMetadata: MediaMetadata?
                        for entry in entries {
                            try ensureCurrent()
                            if entry.isDirectory && !discRoot { continue }
                            guard (discRoot && entry.path == path) || FileServiceRuntime.isVideo(entry) else { continue }
                            let reference = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: entry.path)
                            try ensureCurrent()
                            let existing = try await index.record(reference: reference)
                            if let existing, existing.entry == entry, existing.sidecarVersion == fingerprint, !rematch {
                                if let correction = corrections[reference], correction != existing.correction {
                                    var updated = existing; updated.correction = correction; try await index.upsertScanned(updated, runID: runID)
                                }
                                try await index.markScanned(reference: reference, runID: runID)
                            } else {
                                let filename = MediaFilenameParser.parse(path: entry.path, libraryKind: library.kind)
                                var local = MediaMetadata()
                                let stem = (entry.name as NSString).deletingPathExtension
                                if let nfo = entryByName[(stem + ".nfo").lowercased()] ?? entryByName["movie.nfo"] {
                                    do {
                                        let shared = nfo.path == entryByName["movie.nfo"]?.path
                                        if shared, let cached = sharedMovieMetadata { local = cached }
                                        else {
                                            local = try await readNFO(nfo, client: client)
                                            if shared { sharedMovieMetadata = local }
                                        }
                                    }
                                    catch { status.message = L10n.text("部分资料读取失败，已继续扫描。") }
                                }
                                local = local.fillingMissing(from: show)
                                if let poster = image(in: entryByName, stem: stem, role: "poster") {
                                    local.poster = try? await MediaArtworkCache.shared.cache(entry: poster,
                                        reference: FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: poster.path), client: client)
                                }
                                if let fanart = image(in: entryByName, stem: stem, role: "fanart") {
                                    local.fanart = try? await MediaArtworkCache.shared.cache(entry: fanart,
                                        reference: FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: fanart.path), client: client)
                                }
                                let grouping = local.fillingMissing(from: filename)
                                let title = grouping.kind == .television ? grouping.showTitle ?? filename.showTitle ?? grouping.title ?? entry.name : grouping.title ?? entry.name
                                let groupKey = (grouping.kind ?? .movies).rawValue + ":" + MediaFilenameParser.normalizedTitle(title) + ":\(grouping.year ?? 0)"
                                var record = MediaRecord(reference: reference, entry: entry, groupKey: groupKey,
                                    filenameMetadata: filename, localMetadata: local, onlineMetadata: existing?.onlineMetadata ?? .init(),
                                    correction: existing?.correction, metadataSource: library.metadataSource, sidecarVersion: fingerprint)
                                if let correction = corrections[reference] { record.correction = correction }
                                try Task.checkCancellation()
                                try ensureCurrent()
                                measurement?.mark(\.firstFileSeconds)
                                if let matchQueue { try await matchQueue.append(record, rematch: rematch) }
                                else { try await index.upsertScanned(record, runID: runID) }
                            }

                            status.files += 1
                            measurement?.mark(\.firstFileSeconds)
                            if status.files % 25 == 0 { publish(status); NotificationCenter.default.post(name: .mediaLibraryIndexDidChange, object: library.id) }
                            await Task.yield()
                        }
                    }
                    try ensureCurrent()
                    try await index.visitScanDirectory(.init(path: path, state: .completed, fingerprint: directoryFingerprint, scanID: runID),
                        libraryID: library.id, runID: runID, children: children)
                    stack += children.map { ($0, show, fingerprint) }
                }
                if case .retryFailed = request, status.failedDirectories.count == failuresBeforeRoot { successfulRetryRoots.append(root) }
            }
            try ensureCurrent()
            let fullTraversal: Bool = { if case .retryFailed = request { return false }; return true }()
            let success = status.failedDirectories.isEmpty
            try await index.completeScanCheckpoint(libraryID: library.id, runID: runID,
                fullSuccess: fullTraversal && success, successfulRetryRoots: successfulRetryRoots)
            if !success { status.message = L10n.text("部分目录读取失败，旧索引已保留") }
            else if !fullTraversal { status.message = L10n.text("所选目录扫描完成，其他目录索引未变") }
            else { status.message = L10n.text("扫描完成，共 {0} 个视频", [String(status.files)]) }
            measurement?.mark(\.scanFinishedSeconds)
            status.isRunning = false; publish(status)
            recordDiagnostic(runID, libraryID: library.id, stage: .finished,
                state: success ? .completed : status.taskIssue?.reason == .credentialExpired ? .needsLogin : .needsAttention,
                issue: success ? nil : status.taskIssue ?? .init(.partial), retries: retries)
            NotificationCenter.default.post(name: .mediaLibraryIndexDidChange, object: library.id)
            if let matchQueue { try ensureCurrent(); await matchQueue.finish() }
        } catch {
            if let matchQueue { await matchQueue.stop() }
            let recovery = error as? MediaScanRecoveryError
            if claimed {
                let phase: MediaScanCheckpoint.Phase = recovery == .configurationChanged ? .invalidated : .interrupted
                // Explicit cancellation already revoked the token and stored .cancelled.
                try? await index.interruptScanCheckpoint(libraryID: library.id, runID: runID, phase: phase)
            }
            status.isRunning = false; status.recoveryError = recovery
            status.isCancelled = Task.isCancelled || TaskDiagnosticIssue.isCancellation(error)
            status.taskIssue = status.isCancelled ? nil : .local(error)
            status.message = status.isCancelled ? L10n.text("扫描已取消，旧索引已保留") : L10n.text("扫描未完成，旧索引已保留")
            recordDiagnostic(runID, libraryID: library.id, stage: .scanning,
                state: status.isCancelled ? .cancelled : status.taskIssue?.reason == .credentialExpired ? .needsLogin : .needsAttention,
                issue: status.taskIssue, retries: retries)
            publish(status); NotificationCenter.default.post(name: .mediaLibraryIndexDidChange, object: library.id)
        }
    }
    private func boundedEntries(client: any FileServiceClient, path: String, listedEntries: inout Int) async throws -> [FileEntry] {
        var entries: [FileEntry] = [], cursor: String?, cursors = Set<String>(), paths = Set<String>(), pages = 0
        repeat {
            try Task.checkCancellation()
            let page = try await client.list(path: path, cursor: cursor)
            try Task.checkCancellation()
            listedEntries += page.entries.count; pages += 1
            guard listedEntries <= 1_000_000, entries.count + page.entries.count <= 100_000, pages <= 1024 else {
                throw MediaScanRecoveryError.readBudget
            }
            var fresh = 0
            for entry in page.entries {
                guard !entry.name.hasPrefix("."), !entry.isSymbolicLink else { continue }
                guard entry.path.utf8.count <= 4096, try FileServicePath.normalize(entry.path) == entry.path,
                      FileServicePath.parent(entry.path) == path, entry.path != path,
                      (entry.path as NSString).lastPathComponent == entry.name else { throw FileServiceError.path(path) }
                if paths.insert(entry.path).inserted { entries.append(entry); fresh += 1 }
            }
            cursor = page.nextCursor
            if let cursor, !cursors.insert(cursor).inserted || (page.entries.isEmpty || (fresh == 0 && !page.entries.allSatisfy({ $0.name.hasPrefix(".") || $0.isSymbolicLink }))) {
                throw FileServiceError.protocolFailure("服务分页未向前推进，未完成目录读取")
            }
        } while cursor != nil
        return entries
    }
    private func directoryContext(entries input: [FileEntry], path: String, library: MediaLibraryConfiguration,
                                  inherited: MediaMetadata, parentFingerprint: String, client: any FileServiceClient) async throws
        -> (entries: [FileEntry], show: MediaMetadata, fingerprint: String, discRoot: Bool, byName: [String: FileEntry]) {
        var entries = input
        let bdmv = entries.first(where: DiscMediaPolicy.isBDMV)
        let discRoot = bdmv != nil || ((path as NSString).lastPathComponent.caseInsensitiveCompare("BDMV") == .orderedSame
            && entries.contains { $0.isDirectory && $0.name.caseInsensitiveCompare("PLAYLIST") == .orderedSame })
        if discRoot {
            entries = entries.filter { !$0.isDirectory && !FileServiceRuntime.isVideo($0) }
            entries.append(.init(path: path, name: (path as NSString).lastPathComponent.isEmpty ? library.name : (path as NSString).lastPathComponent,
                                 isDirectory: true, modifiedAt: bdmv?.modifiedAt, version: bdmv?.version))
        }
        let sidecars = entries.filter { !FileServiceRuntime.isVideo($0) && !$0.isDirectory }
        let material = "nfo-details-v4-disc|" + library.kind.rawValue + "|" + parentFingerprint + "|" + sidecars.map {
            $0.name + ":\($0.size):\($0.modifiedAt?.timeIntervalSince1970 ?? 0):" + ($0.version ?? "")
        }.sorted().joined(separator: "|")
        let fingerprint = Self.digest(Data(material.utf8))
        let byName = Dictionary(entries.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var show = inherited
        if let tvshow = byName["tvshow.nfo"], var metadata = try? await readNFO(tvshow, client: client) {
            metadata.showTitle = metadata.title ?? metadata.showTitle; metadata.title = nil
            show = metadata.fillingMissing(from: show)
        }
        if let poster = image(in: byName, stem: "", role: "poster"),
           let cached = try? await MediaArtworkCache.shared.cache(entry: poster,
                reference: FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: poster.path), client: client) {
            show.poster = cached
        }
        return (entries, show, fingerprint, discRoot, byName)
    }
    private func readNFO(_ entry: FileEntry, client: any FileServiceClient) async throws -> MediaMetadata {
        guard entry.size > 0, entry.size <= NFOMetadataParser.maximumBytes else { throw FileServiceError.protocolFailure("NFO 超过读取上限或为空") }
        return try NFOMetadataParser.parse(await client.read(path: entry.path, range: 0..<entry.size))
    }
    private func image(in entries: [String: FileEntry], stem: String, role: String) -> FileEntry? {
        let names = role == "poster" ? [stem + "-poster", stem, "poster", "folder"] : [stem + "-fanart", "fanart"]
        for name in names where !name.isEmpty {
            for ext in ["jpg", "jpeg", "png", "webp"] {
                if let entry = entries[name.lowercased() + "." + ext] { return entry }
            }
        }
        return nil
    }
}

private actor ScanLimiter {
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < 2 { active += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }
    func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().1.resume(returning: true) }
    }
}
