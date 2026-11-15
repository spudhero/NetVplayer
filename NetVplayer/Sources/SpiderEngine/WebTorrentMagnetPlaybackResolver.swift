import Foundation
import Models
import NodeBundleRuntime

protocol SixVMagnetPlaybackResolving: Sendable {
    func playbackURL(for magnetURI: String) async throws -> URL
}

struct SixVMagnetPlaybackFile: Decodable, Sendable {
    let index: Int
    let name: String
    let length: Int64
    let url: URL
}

public enum WebTorrentMagnetPlaybackError: LocalizedError, Equatable {
    case invalidMagnet
    case bridgeResourcesMissing
    case nodeRuntimeMissing
    case launchFailed(String)
    case bridgeFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidMagnet:
            return "磁力链接缺少有效 info hash"
        case .bridgeResourcesMissing:
            return "应用未包含 WebTorrent 桥接资源"
        case .nodeRuntimeMissing:
            return "未找到 Node.js 22 或更高版本"
        case .launchFailed(let detail):
            return "WebTorrent 进程启动失败：\(detail)"
        case .bridgeFailed(let detail):
            return detail
        case .timedOut:
            return "等待磁力元数据超时"
        }
    }
}


struct MagnetPlaybackLease: Sendable {
    let id: UUID
    let files: [SixVMagnetPlaybackFile]
}

actor WebTorrentMagnetPlaybackResolver: SixVMagnetPlaybackResolving {
    static let shared = WebTorrentMagnetPlaybackResolver()

    private struct BridgeReady: Decodable, Sendable {
        var url: URL?
        var error: String?
        var files: [SixVMagnetPlaybackFile]?
        var infoHash: String?
    }
    private struct Session {
        let id: UUID
        let process: Process
        let startedAt: Date
        var worker: Task<Void, Never>?
        var files: [SixVMagnetPlaybackFile]?
        var waiters: [UUID: CheckedContinuation<MagnetPlaybackLease, any Error>] = [:]
        var leases: Set<UUID> = []
        // The pre-existing native API returns a URL without an explicit owner.
        var nativePinned = false
    }
    private var sessions: [String: Session] = [:]
    private let fileManager: FileManager
    private let environment: [String: String]
    private let cacheRoot: URL?

    init(fileManager: FileManager = .default,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         cacheRoot: URL? = nil) {
        self.fileManager = fileManager
        self.environment = environment
        self.cacheRoot = cacheRoot
    }

    func acquireFiles(for magnetURI: String) async throws -> MagnetPlaybackLease {
        guard let hash = MagnetURI.infoHash(in: magnetURI) else { throw WebTorrentMagnetPlaybackError.invalidMagnet }
        let id = UUID()
        do {
            let lease: MagnetPlaybackLease = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    enqueue(hash: hash, magnetURI: magnetURI, id: id, continuation: continuation)
                }
            } onCancel: {
                Task { await self.cancel(hash: hash, id: id) }
            }
            try Task.checkCancellation()
            return lease
        } catch {
            cancel(hash: hash, id: id)
            throw error
        }
    }

    func release(_ leaseID: UUID) {
        guard let hash = sessions.first(where: { $0.value.leases.contains(leaseID) })?.key else { return }
        sessions[hash]?.leases.remove(leaseID)
        discardIfUnowned(hash)
    }

    func playbackURL(for magnetURI: String) async throws -> URL {
        let lease = try await acquireFiles(for: magnetURI)
        defer { release(lease.id) }
        guard let hash = MagnetURI.infoHash(in: magnetURI), !lease.files.isEmpty else { throw WebTorrentMagnetPlaybackError.invalidMagnet }
        let url: URL
        if let selection = URLComponents(string: magnetURI)?.queryItems?.first(where: { $0.name == "netvplayer_file" }) {
            guard let raw = selection.value, let index = Int(raw), index >= 0,
                  let file = lease.files.first(where: { $0.index == index }) else {
                throw WebTorrentMagnetPlaybackError.bridgeFailed("种子中的所选视频文件已不存在")
            }
            url = file.url
        } else { url = lease.files[0].url }
        sessions[hash]?.nativePinned = true
        return url
    }

    func playbackFiles(for magnetURI: String) async throws -> [SixVMagnetPlaybackFile] {
        _ = try await playbackURL(for: magnetURI)
        return MagnetURI.infoHash(in: magnetURI).flatMap { sessions[$0]?.files } ?? []
    }

    private func enqueue(hash: String, magnetURI: String, id: UUID,
                         continuation: CheckedContinuation<MagnetPlaybackLease, any Error>) {
        if let existing = sessions[hash], !existing.process.isRunning {
            finish(hash: hash, sessionID: existing.id, result: .failure(WebTorrentMagnetPlaybackError.bridgeFailed("WebTorrent 已退出")))
            sessions.removeValue(forKey: hash)
        }
        do {
            if sessions[hash] == nil {
                trimNativeSessionsIfNeeded()
                sessions[hash] = try launch(hash: hash, magnetURI: magnetURI)
            }
            if let files = sessions[hash]?.files {
                sessions[hash]?.leases.insert(id)
                continuation.resume(returning: MagnetPlaybackLease(id: id, files: files))
            } else { sessions[hash]?.waiters[id] = continuation }
        } catch { continuation.resume(throwing: error) }
    }

    private func launch(hash: String, magnetURI: String) throws -> Session {
        let bridgeRoot = try bridgeRootURL()
        let root = try sessionRootURL(infoHash: hash)
        let id = UUID()
        // A new launch never reads a prior process's ready file.
        let control = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: control, withIntermediateDirectories: true)
        let ready = control.appendingPathComponent("ready.json")
        let log = control.appendingPathComponent("bridge.log")
        fileManager.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = try nodeExecutableURL()
        process.currentDirectoryURL = bridgeRoot
        process.arguments = [bridgeRoot.appendingPathComponent("torrent-bridge.mjs").path,
                             magnetURI, ready.path, control.appendingPathComponent("data", isDirectory: true).path, String(ProcessInfo.processInfo.processIdentifier)]
        var childEnvironment = environment
        childEnvironment["NODE_ENV"] = "production"
        process.environment = childEnvironment
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        do { try process.run() }
        catch { throw WebTorrentMagnetPlaybackError.launchFailed(error.localizedDescription) }
        var session = Session(id: id, process: process, startedAt: Date())
        session.worker = Task {
            do {
                let files = try await Self.waitForReadyFile(ready, process: process, hash: hash)
                self.finish(hash: hash, sessionID: id, result: .success(files))
            } catch { self.finish(hash: hash, sessionID: id, result: .failure(error)) }
        }
        return session
    }

    private func finish(hash: String, sessionID: UUID,
                        result: Swift.Result<[SixVMagnetPlaybackFile], any Error>) {
        guard var session = sessions[hash], session.id == sessionID else { return }
        let waiters = session.waiters
        session.waiters = [:]
        switch result {
        case .success(let files):
            session.files = files
            session.leases.formUnion(waiters.keys)
            sessions[hash] = session
            for (id, continuation) in waiters {
                continuation.resume(returning: MagnetPlaybackLease(id: id, files: files))
            }
            discardIfUnowned(hash)
        case .failure(let error):
            sessions.removeValue(forKey: hash)
            if session.process.isRunning { session.process.terminate() }
            for continuation in waiters.values { continuation.resume(throwing: error) }
        }
    }

    private func cancel(hash: String, id: UUID) {
        sessions[hash]?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        sessions[hash]?.leases.remove(id)
        discardIfUnowned(hash)
    }

    private func discardIfUnowned(_ hash: String) {
        guard let session = sessions[hash], session.waiters.isEmpty,
              session.leases.isEmpty, !session.nativePinned else { return }
        sessions.removeValue(forKey: hash)
        session.worker?.cancel()
        if session.process.isRunning { session.process.terminate() }
    }

    private func trimNativeSessionsIfNeeded() {
        let unowned = sessions.filter { $0.value.leases.isEmpty && $0.value.waiters.isEmpty }
        guard unowned.count >= 2,
              let oldest = unowned.min(by: { $0.value.startedAt < $1.value.startedAt }) else { return }
        sessions.removeValue(forKey: oldest.key)
        oldest.value.worker?.cancel()
        if oldest.value.process.isRunning { oldest.value.process.terminate() }
    }

    private static func waitForReadyFile(_ readyURL: URL, process: Process, hash: String) async throws -> [SixVMagnetPlaybackFile] {
        for _ in 0..<360 {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: readyURL) {
                guard data.count <= 4 * 1024 * 1024,
                      let ready = try? JSONDecoder().decode(BridgeReady.self, from: data) else {
                    throw WebTorrentMagnetPlaybackError.bridgeFailed("WebTorrent 返回了无效元数据")
                }
                if let error = ready.error, !error.isEmpty { throw WebTorrentMagnetPlaybackError.bridgeFailed(error) }
                guard ready.infoHash?.lowercased() == hash, let files = ready.files,
                      ready.url == files.first?.url else {
                    throw WebTorrentMagnetPlaybackError.bridgeFailed("磁力元数据或文件身份不匹配")
                }
                _ = try HostMagnetPlaybackResolver.files(files, infoHash: hash)
                return files
            }
            guard process.isRunning else { throw WebTorrentMagnetPlaybackError.bridgeFailed("WebTorrent 在取得元数据前退出") }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw WebTorrentMagnetPlaybackError.timedOut
    }
    private func bridgeRootURL() throws -> URL {
        var candidates: [URL] = []
        if let configured = environment["NETVPLAYER_TORRENT_BRIDGE_PATH"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("TorrentBridge", isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/TorrentBridge", isDirectory: true)
        )
        guard let root = candidates.first(where: {
            fileManager.fileExists(atPath: $0.appendingPathComponent("torrent-bridge.mjs").path)
                && fileManager.fileExists(atPath: $0.appendingPathComponent("node_modules/webtorrent").path)
        }) else {
            throw WebTorrentMagnetPlaybackError.bridgeResourcesMissing
        }
        return root
    }

    private func nodeExecutableURL() throws -> URL {
        guard let node = NodeRuntimeLocator.locate(
            fileManager: fileManager,
            environment: environment,
            bundleResourceURL: Bundle.main.resourceURL
        ) else {
            throw WebTorrentMagnetPlaybackError.nodeRuntimeMissing
        }
        return node.executableURL
    }

    private func sessionRootURL(infoHash: String) throws -> URL {
        if let cacheRoot {
            let root = cacheRoot.appendingPathComponent(infoHash, isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport
            .appendingPathComponent("NetVplayer", isDirectory: true)
            .appendingPathComponent("TorrentCache", isDirectory: true)
            .appendingPathComponent(infoHash, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}

public enum MagnetPlaybackEpisodes {
    public static func resolve(for magnetURI: String) async throws -> [Episode] {
        let files = try await WebTorrentMagnetPlaybackResolver.shared.playbackFiles(for: magnetURI)
        return episodes(for: magnetURI, files: files)
    }

    static func episodes(for magnetURI: String, files: [SixVMagnetPlaybackFile]) -> [Episode] {
        files.compactMap { file in
            guard var components = URLComponents(string: magnetURI) else { return nil }
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "netvplayer_file" }
            items.append(URLQueryItem(name: "netvplayer_file", value: String(file.index)))
            components.queryItems = items
            guard let url = components.string else { return nil }
            let name = file.name.replacingOccurrences(of: "$", with: " ")
                .replacingOccurrences(of: "#", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Episode(name: name, url: url)
        }
    }
}
