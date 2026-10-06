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
    private var progress: [UUID: MediaScanProgress] = [:]
    private let index: MediaIndex
    private let limiter = ScanLimiter()
    public init(index: MediaIndex = .shared) { self.index = index }
    public func start(_ library: MediaLibraryConfiguration, rematch: Bool = false) {
        guard jobs[library.id] == nil else { return }
        jobs[library.id] = Task(priority: .utility) {
            await limiter.acquire()
            if !Task.isCancelled {
                await self.perform(library, rematch: rematch)
            }
            await limiter.release()
            self.jobs[library.id] = nil
        }
    }
    public func cancel(libraryID: UUID) { jobs[libraryID]?.cancel() }
    public func cancel(serviceID: UUID) {
        for library in FileServiceStore.shared.load().libraries where library.serviceID == serviceID { jobs[library.id]?.cancel() }
    }
    public func currentProgress(libraryID: UUID) -> MediaScanProgress? { progress[libraryID] }
    public func scanStaleLibraries() async {
        for library in FileServiceStore.shared.load().libraries {
            let last = try? await index.lastSuccessfulScan(libraryID: library.id)
            if last == nil || Date().timeIntervalSince(last!) > 24 * 60 * 60 { start(library) }
        }
    }
    public func waitForScan(libraryID: UUID) async { await jobs[libraryID]?.value }
    public func cancelAllAndWait() async {
        let running = Array(jobs.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
    }
    /// Public seam for protocol-independent scanning tests; production uses the configured runtime client.
    public func scan(_ library: MediaLibraryConfiguration, client: any FileServiceClient) async {
        await perform(library, suppliedClient: client)
    }
    private func publish(_ value: MediaScanProgress) {
        progress[value.libraryID] = value
        NotificationCenter.default.post(name: .mediaLibraryScanDidChange, object: value)
    }
    private func perform(_ library: MediaLibraryConfiguration, rematch: Bool = false, suppliedClient: (any FileServiceClient)? = nil) async {
        let scanID = UUID()
        var status = MediaScanProgress(libraryID: library.id, currentPath: library.path)
        publish(status)
        do {
            let client: any FileServiceClient
            if let suppliedClient { client = suppliedClient }
            else { client = try await FileServiceRuntime.shared.client(for: library.serviceID) }
            var stack: [(String, MediaMetadata, String)] = [(try FileServicePath.normalize(library.path), .init(), "")]
            var visited = Set<String>()
            var changedRecords: [FileResourceReference] = []
            let corrections = Dictionary(FileServiceStore.shared.loadCorrections().map { ($0.reference, $0) }, uniquingKeysWith: { _, last in last })
            while let (path, inherited, parentFingerprint) = stack.popLast() {
                try Task.checkCancellation()
                guard visited.insert(path).inserted else { continue }
                status.currentPath = path; status.directories += 1; publish(status)
                let entries: [FileEntry]
                do { entries = try await client.allEntries(path: path).filter { !$0.name.hasPrefix(".") && !$0.isSymbolicLink } }
                catch {
                    if Task.isCancelled { throw CancellationError() }
                    status.failedDirectories.append(path); status.message = error.localizedDescription; publish(status); continue
                }
                let sidecars = entries.filter { !FileServiceRuntime.isVideo($0) && !$0.isDirectory }
                let fingerprintMaterial = library.kind.rawValue + "|" + parentFingerprint + "|" + sidecars.map { $0.name + ":\($0.size):\($0.modifiedAt?.timeIntervalSince1970 ?? 0):" + ($0.version ?? "") }.sorted().joined(separator: "|")
                let fingerprint = SHA256.hash(data: Data(fingerprintMaterial.utf8)).map { String(format: "%02x", $0) }.joined()
                let entryByName = Dictionary(entries.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
                var show = inherited
                if let tvshow = entryByName["tvshow.nfo"] {
                    do {
                        var metadata = try await readNFO(tvshow, client: client)
                        metadata.showTitle = metadata.title ?? metadata.showTitle; metadata.title = nil
                        show = metadata.fillingMissing(from: show)
                    } catch { status.message = "\(tvshow.path)：\(error.localizedDescription)" }
                }
                // Keep artwork common to a show available to descendants.
                if let poster = image(in: entryByName, stem: "", role: "poster") {
                    if let cached = try? await MediaArtworkCache.shared.cache(entry: poster,
                        reference: FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: poster.path), client: client) { show.poster = cached }
                }
                for entry in entries {
                    try Task.checkCancellation()
                    if entry.isDirectory { stack.append((entry.path, show, fingerprint)); continue }
                    guard FileServiceRuntime.isVideo(entry) else { continue }
                    let reference = try FileResourceReference(serviceID: library.serviceID, libraryID: library.id, path: entry.path)
                    let existing = try await index.record(reference: reference)
                    if let existing, existing.entry == entry, existing.sidecarVersion == fingerprint, !rematch {
                        if let correction = corrections[reference], correction != existing.correction {
                            var updated = existing; updated.correction = correction; try await index.upsert(updated)
                        }
                        try await index.markSeen(reference: reference, scanID: scanID)
                    } else {
                        let filename = MediaFilenameParser.parse(path: entry.path, libraryKind: library.kind)
                        var local = MediaMetadata()
                        let stem = (entry.name as NSString).deletingPathExtension
                        if let nfo = entryByName[(stem + ".nfo").lowercased()] ?? entryByName["movie.nfo"] {
                            do { local = try await readNFO(nfo, client: client) }
                            catch { status.message = "\(nfo.path)：\(error.localizedDescription)" }
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
                            correction: existing?.correction, metadataSource: existing?.metadataSource, sidecarVersion: fingerprint)
                        if let correction = corrections[reference] { record.correction = correction }
                        try Task.checkCancellation()
                        try await index.upsert(record, scanID: scanID)
                        changedRecords.append(reference)
                    }
                    status.files += 1
                    if status.files % 25 == 0 { publish(status); NotificationCenter.default.post(name: .mediaLibraryIndexDidChange, object: library.id) }
                    await Task.yield()
                }
            }
            try Task.checkCancellation()
            let success = status.failedDirectories.isEmpty
            try await index.finishScan(libraryID: library.id, scanID: scanID, succeeded: success, error: status.message)
            status.message = success ? "扫描完成，共 \(status.files) 个视频" : "部分目录读取失败，旧索引已保留"
            status.isRunning = false; publish(status)
            NotificationCenter.default.post(name: .mediaLibraryIndexDidChange, object: library.id)
            if suppliedClient == nil {
                let current = FileServiceStore.shared.load().libraries.first { $0.id == library.id } ?? library
                await MetadataMatcher.shared.enqueue(library: current, references: changedRecords, rematch: rematch)
            }
        } catch {
            try? await index.finishScan(libraryID: library.id, scanID: scanID, succeeded: false, error: error.localizedDescription)
            status.isRunning = false; status.message = Task.isCancelled ? "扫描已取消，旧索引已保留" : error.localizedDescription
            publish(status); NotificationCenter.default.post(name: .mediaLibraryIndexDidChange, object: library.id)
        }
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
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 2 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() } }
}
