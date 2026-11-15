import Foundation
import Models
import ProxyServer
import BlurayShim

public enum DiscReadError: Error, LocalizedError {
    case runtime, invalidDisc, protectedDisc, invalidTitle, readFailed
    public var errorDescription: String? {
        switch self {
        case .runtime: L10n.text("蓝光读取组件不可用")
        case .invalidDisc: L10n.text("未找到可读取的蓝光标题")
        case .protectedDisc: L10n.text("此光盘受保护，当前无法读取")
        case .invalidTitle: L10n.text("所选蓝光标题或角度不可用")
        case .readFailed: L10n.text("蓝光读取失败，请检查文件来源后重试")
        }
    }
}

/// libbluray is synchronous. One serial worker owns its state; only that worker
/// blocks while the existing async file-service/cache layer performs physical I/O.
/// No global VFS registration, mount, whole-ISO copy, or second UDF parser.
public final class BlurayDiscReader: @unchecked Sendable {
    public let reference: FileResourceReference
    private let client: any FileServiceClient
    private let clientLifetime: DiscClientLifetime?
    private let proxy: ProxyServer
    private let queue = DispatchQueue(label: "com.netvplayer.bluray", qos: .userInitiated)
    private let iso: Bool
    private let root: String
    private let session = PlaybackReadSession()
    private var handle: OpaquePointer?
    private var resources: [String: String] = [:]
    private var entries: [String: FileEntry] = [:]
    private var directories: [String: [String]] = [:]
    private var request: DiscWorkerRequest?
    private var catalog: DiscCatalog?
    private var selected: DiscSelection?
    private var needsReopen = false

    public init(reference: FileResourceReference, client: any FileServiceClient, proxy: ProxyServer = .shared, ownsClient: Bool = false) {
        self.reference = reference; self.client = client; self.proxy = proxy
        clientLifetime = ownsClient ? DiscClientLifetime(client) : nil
        iso = DiscMediaPolicy.isISO(reference.path)
        root = (reference.path as NSString).lastPathComponent.caseInsensitiveCompare("BDMV") == .orderedSame
            ? FileServicePath.parent(reference.path) : reference.path
    }
    deinit {
        nv_bd_close(handle)
        session.stop()
        for url in resources.values { proxy.unregisterSeekableResource(url: url) }
    }

    public func scan(purpose: PlaybackReadPurpose = .probe) async throws -> DiscCatalog {
        try await run(purpose: purpose) {
            if let catalog = self.catalog { return catalog }
            try self.open()
            var titles: [DiscTitle] = []
            for index in 0..<nv_bd_title_count(self.handle) {
                try self.request?.check()
                var info = NVBDTitle()
                guard nv_bd_title(self.handle, index, &info) != 0,
                      info.clip_count > 0, info.clip_count <= 4096,
                      info.chapter_count <= 4096, info.ticks > 0, info.angles > 0 else { continue }
                var clips: [DiscClip] = []
                for n in 0..<info.clip_count {
                    var c = NVBDClip()
                    guard nv_bd_clip(self.handle, index, n, &c) != 0, c.out_time > c.in_time else { throw DiscReadError.invalidDisc }
                    let id = withUnsafePointer(to: &c.id) { $0.withMemoryRebound(to: CChar.self, capacity: 6) { String(cString: $0) } }
                    clips.append(.init(id: id, start: Double(c.start) / 90000,
                                       inTime: Double(c.in_time) / 90000, outTime: Double(c.out_time) / 90000))
                }
                var chapters: [DiscChapter] = []
                for n in 0..<info.chapter_count {
                    var c = NVBDChapter()
                    guard nv_bd_chapter(self.handle, index, n, &c) != 0, c.ticks < info.ticks else { continue }
                    let name = withUnsafePointer(to: &c.name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
                    chapters.append(.init(seconds: Double(c.ticks) / 90000, title: name, clip: c.clip))
                }
                titles.append(.init(playlist: info.playlist, duration: Double(info.ticks) / 90000,
                                    angles: UInt32(info.angles), clips: clips, chapters: chapters))
            }
            guard !titles.isEmpty else { throw DiscReadError.invalidDisc }
            let catalog = DiscCatalog(titles: titles.sorted { $0.playlist < $1.playlist })
            self.catalog = catalog; return catalog
        }
    }

    /// Resources retain this reader until the final playback/preview lease and
    /// in-flight read release. The runtime may retire the registering owner sooner.
    public func playback(selection: DiscSelection) async throws -> DiscPlayback {
        let catalog = try await scan()
        guard selection.reference == reference, let title = catalog.titles.first(where: { $0.playlist == selection.playlist }),
              selection.angle < title.angles else { throw DiscReadError.invalidTitle }
        let ranges = try await run(purpose: .probe) {
            guard self.selected == nil, nv_bd_select(self.handle, selection.playlist, selection.angle) != 0 else { throw DiscReadError.invalidTitle }
            let size = nv_bd_size(self.handle)
            guard size > 0 else { throw DiscReadError.invalidTitle }
            let starts = title.clips.indices.map { nv_bd_playitem_offset(self.handle, UInt32($0)) }
            var ranges: [Range<Int64>] = []
            for i in starts.indices {
                let end = i + 1 < starts.count ? starts[i + 1] : size
                guard starts[i] >= 0, end > starts[i], end <= size else { throw DiscReadError.invalidTitle }
                ranges.append(starts[i]..<end)
            }
            self.selected = selection
            return ranges
        }
        var urls: [String] = []
        do {
            for range in ranges {
                try Task.checkCancellation()
                let url = try proxy.registerSeekableResource(.init(size: range.count64, contentType: "video/mp2t",
                    readChunkSize: 512 * 1024, mediaIdentity: selection.mediaIdentity, managesReadBudget: true) { part in
                    guard part.lowerBound >= 0, part.upperBound <= range.count64 else { throw DiscReadError.readFailed }
                    return try await self.read(offset: range.lowerBound + part.lowerBound, count: part.count64)
                })
                urls.append(url)
            }
            return DiscPlayback(selection: selection, title: title, segmentURLs: urls)
        } catch {
            urls.forEach { proxy.unregisterSeekableResource(url: $0) }; throw error
        }
    }

    private func read(offset: Int64, count: Int64) async throws -> Data {
        try await run {
            if self.needsReopen {
                // libbluray skips a broken unit after a VFS error. A cancelled
                // HTTP probe must not leave that navigation state for the next
                // reader. Reopen on the serial worker; physical cache is shared.
                nv_bd_close(self.handle); self.handle = nil
                try self.open()
                guard let selection = self.selected,
                      nv_bd_select(self.handle, selection.playlist, selection.angle) != 0 else { throw DiscReadError.invalidTitle }
                self.needsReopen = false
            }
            var data = Data(count: Int(count))
            let read = data.withUnsafeMutableBytes { nv_bd_read(self.handle, offset, $0.bindMemory(to: UInt8.self).baseAddress, count) }
            guard read == count else { throw DiscReadError.readFailed }
            return data
        }
    }
    private func open() throws {
        if handle != nil { return }
        let bundled = Bundle.main.privateFrameworksURL?.appendingPathComponent("libbluray.4.dylib").path
        let library = ProcessInfo.processInfo.environment["NETVPLAYER_LIBBLURAY_PATH"]
            ?? bundled.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? "/opt/homebrew/opt/libbluray/lib/libbluray.4.dylib"
        var status: Int32 = 0
        handle = nv_bd_open(library, iso ? 1 : 0, Unmanaged.passUnretained(self).toOpaque(), { context, path in
            guard let context, let path else { return -1 }
            let reader = Unmanaged<BlurayDiscReader>.fromOpaque(context).takeUnretainedValue()
            return (try? reader.stat(String(cString: path)).size) ?? -1
        }, { context, path, offset, buffer, count in
            guard let context, let path, let buffer else { return -1 }
            let reader = Unmanaged<BlurayDiscReader>.fromOpaque(context).takeUnretainedValue()
            do {
                let data = try reader.physicalRead(path: String(cString: path), offset: offset, count: count)
                data.copyBytes(to: buffer, count: data.count); return Int64(data.count)
            } catch { reader.request?.record(error); return -1 }
        }, { context, path, index, name, capacity in
            guard let context, let path, let name else { return -1 }
            let reader = Unmanaged<BlurayDiscReader>.fromOpaque(context).takeUnretainedValue()
            do {
                let names = try reader.list(String(cString: path))
                guard index < names.count else { return 1 }
                let bytes = Array(names[Int(index)].utf8)
                guard bytes.count < capacity else { return -1 }
                for i in bytes.indices { name[i] = CChar(bitPattern: bytes[i]) }; name[bytes.count] = 0
                return 0
            } catch { return -1 }
        }, &status)
        guard handle != nil else {
            try request?.check()
            throw status == 1 ? DiscReadError.runtime : status == 3 ? DiscReadError.protectedDisc : DiscReadError.invalidDisc
        }
    }
    private func path(_ relative: String) throws -> String {
        guard !relative.hasPrefix("/"), !relative.contains("\\"), !relative.contains("\0"),
              !relative.split(separator: "/").contains("..") else { throw DiscReadError.invalidDisc }
        if iso { guard relative.isEmpty else { throw DiscReadError.invalidDisc }; return reference.path }
        return try FileServicePath.join(root, relative)
    }
    private func stat(_ relative: String) throws -> FileEntry {
        let path = try path(relative)
        if let entry = entries[path] { return entry }
        let client = client
        let entry = try blocking { try await client.stat(path: path) }
        guard !entry.isDirectory, !entry.isSymbolicLink, entry.size >= 0 else { throw DiscReadError.invalidDisc }
        entries[path] = entry; return entry
    }
    private func list(_ relative: String) throws -> [String] {
        let path = try path(relative)
        if let names = directories[path] { return names }
        let client = client
        let values = try blocking { try await client.allEntries(path: path) }
        guard values.count <= 10000 else { throw DiscReadError.invalidDisc }
        let names = values.filter { !$0.isSymbolicLink && !$0.name.contains("/") && $0.name != ".." }.map(\.name)
        for entry in values where !entry.isDirectory && !entry.isSymbolicLink { entries[entry.path] = entry }
        directories[path] = names; return names
    }
    private func physicalRead(path relative: String, offset: Int64, count: Int64) throws -> Data {
        try request?.check()
        let entry = try stat(relative)
        guard count >= 0, count <= 4 * 1024 * 1024, offset >= 0, offset <= entry.size, count <= entry.size - offset else { throw DiscReadError.readFailed }
        let url: String
        if let existing = resources[entry.path] { url = existing }
        else {
            let client = client, path = entry.path, lifetime = clientLifetime
            url = try proxy.registerSeekableResource(.init(size: entry.size, readChunkSize: 512 * 1024,
                mediaIdentity: .init(source: "file-service", account: reference.serviceID.uuidString, item: path)) { range in
                _ = lifetime // the final physical read also owns the connection/scope
                // Retry only unread suffixes; bounded attempts preserve genuine I/O failures.
                var data = Data(), offset = range.lowerBound
                var attempts = 0
                while offset < range.upperBound {
                    try Task.checkCancellation()
                    attempts += 1
                    guard attempts <= 32 else { throw DiscReadError.readFailed }
                    let chunk = try await client.read(path: path, range: offset..<range.upperBound)
                    guard !chunk.isEmpty, chunk.count <= range.upperBound - offset else { throw DiscReadError.readFailed }
                    data.append(chunk); offset += Int64(chunk.count)
                }
                return data
            })
            resources[entry.path] = url
        }
        let proxy = proxy
        // UDF frequently asks for a single 2 KiB block. Share aligned windows in
        // the existing cache, rather than issue a network round trip per block.
        return try blocking {
            let window: Int64 = 256 * 1024
            var data = Data(), cursor = offset
            while cursor < offset + count {
                try Task.checkCancellation()
                let start = cursor / window * window
                let end = min(entry.size, start + window)
                let bytes = try await proxy.readRegisteredResource(url: url, range: start..<end)
                let limit = min(end, offset + count)
                data.append(bytes.subdata(in: Int(cursor - start)..<Int(limit - start)))
                cursor = limit
            }
            return data
        }
    }
    private func run<T: Sendable>(purpose: PlaybackReadPurpose? = nil, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let owner = PlaybackReadScope.owner
        let priority = PlaybackReadScope.priority
        let request = DiscWorkerRequest(owner: owner, priority: priority, fallbackPurpose: purpose ?? .foreground, session: session,
                                        identity: .init(source: "bluray", account: reference.serviceID.uuidString, item: reference.path))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.request = request
                    defer { self.request = nil }
                    do { try request.check(); let value = try work(); try request.check(); continuation.resume(returning: value) }
                    catch { self.needsReopen = true; continuation.resume(throwing: error) }
                }
            }
        } onCancel: { request.cancel() }
    }
    private func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        guard let request else { throw CancellationError() }
        return try request.wait(work)
    }
}

private extension Range where Bound == Int64 { var count64: Int64 { upperBound - lowerBound } }

private final class DiscClientLifetime: @unchecked Sendable {
    let client: any FileServiceClient
    init(_ client: any FileServiceClient) { self.client = client }
    deinit { let client = client; Task { await client.disconnect() } }
}

private final class DiscWorkerRequest: @unchecked Sendable {
    let owner: PlaybackReadOwner?
    let priority: PlaybackReadPriority?
    private let fallback: PlaybackReadOwner
    private let lock = NSLock()
    private var cancelled = false
    private var io: Task<Void, Never>?
    private var ioError: Error?
    init(owner: PlaybackReadOwner?, priority: PlaybackReadPriority?, fallbackPurpose: PlaybackReadPurpose,
         session: PlaybackReadSession, identity: PlaybackMediaIdentity) {
        self.owner = owner; self.priority = priority
        fallback = session.makeOwner(mediaIdentity: identity, purpose: fallbackPurpose)
    }
    deinit { fallback.cancel() }
    func check() throws {
        let state = lock.withLock { (cancelled, ioError) }
        if state.0 { throw CancellationError() }
        try owner?.check()
        if let error = state.1 { throw error }
    }
    func record(_ error: Error) { lock.withLock { if ioError == nil { ioError = error } } }
    func cancel() { let task = lock.withLock { cancelled = true; return io }; task?.cancel() }
    func wait<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        try check()
        let box = DiscBlockingResult<T>()
        let owner = owner, priority = priority, fallback = fallback
        let task = Task {
            do {
                let value = try await PlaybackReadScope.$priority.withValue(priority) {
                    if let owner { return try await owner.perform(work) }
                    if priority != nil { return try await work() } // shared transfer owns cancellation
                    return try await fallback.perform(work)
                }
                box.complete(.success(value))
            } catch { box.complete(.failure(error)) }
        }
        let stop = lock.withLock { io = task; return cancelled }
        if stop { task.cancel() }
        // The serial worker retains all callbacks/readers until non-cooperative I/O returns.
        box.semaphore.wait()
        lock.withLock { io = nil }
        try check()
        return try box.result!.get()
    }
}
private final class DiscBlockingResult<T: Sendable>: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Swift.Result<T, Error>?
    func complete(_ result: Swift.Result<T, Error>) { self.result = result; semaphore.signal() }
}
