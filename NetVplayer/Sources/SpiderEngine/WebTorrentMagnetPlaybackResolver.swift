import Foundation
import NodeBundleRuntime

protocol SixVMagnetPlaybackResolving: Sendable {
    func playbackURL(for magnetURI: String) async throws -> URL
}

enum WebTorrentMagnetPlaybackError: LocalizedError, Equatable {
    case invalidMagnet
    case bridgeResourcesMissing
    case nodeRuntimeMissing
    case launchFailed(String)
    case bridgeFailed(String)
    case timedOut

    var errorDescription: String? {
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

actor WebTorrentMagnetPlaybackResolver: SixVMagnetPlaybackResolving {
    static let shared = WebTorrentMagnetPlaybackResolver()

    private struct BridgeReady: Decodable {
        var url: String?
        var error: String?
    }

    private struct Session {
        let process: Process
        let playbackURL: URL
        let startedAt: Date
    }

    private var sessions: [String: Session] = [:]
    private let fileManager: FileManager
    private let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    func playbackURL(for magnetURI: String) async throws -> URL {
        let infoHash = try Self.infoHash(in: magnetURI)
        discardFinishedSessions()
        if let session = sessions[infoHash], session.process.isRunning {
            return session.playbackURL
        }
        trimSessionsIfNeeded()

        let bridgeRoot = try bridgeRootURL()
        let scriptURL = bridgeRoot.appendingPathComponent("torrent-bridge.mjs")
        let nodeURL = try nodeExecutableURL()
        let sessionRoot = try sessionRootURL(infoHash: infoHash)
        let readyURL = sessionRoot.appendingPathComponent("ready.json")
        let logURL = sessionRoot.appendingPathComponent("bridge.log")
        try? fileManager.removeItem(at: readyURL)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }

        let process = Process()
        process.executableURL = nodeURL
        process.currentDirectoryURL = bridgeRoot
        process.arguments = [
            scriptURL.path,
            magnetURI,
            readyURL.path,
            sessionRoot.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        var childEnvironment = environment
        childEnvironment["NODE_ENV"] = "production"
        process.environment = childEnvironment
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            _ = try? logHandle.seekToEnd()
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        do {
            try process.run()
        } catch {
            throw WebTorrentMagnetPlaybackError.launchFailed(error.localizedDescription)
        }

        do {
            let playbackURL = try await waitForReadyFile(readyURL, process: process)
            sessions[infoHash] = Session(
                process: process,
                playbackURL: playbackURL,
                startedAt: Date()
            )
            return playbackURL
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    private func waitForReadyFile(_ readyURL: URL, process: Process) async throws -> URL {
        for _ in 0..<360 {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: readyURL),
               let ready = try? JSONDecoder().decode(BridgeReady.self, from: data) {
                if let error = ready.error, !error.isEmpty {
                    throw WebTorrentMagnetPlaybackError.bridgeFailed(error)
                }
                if let value = ready.url,
                   let url = URL(string: value),
                   url.host == "127.0.0.1" || url.host == "localhost" {
                    return url
                }
                throw WebTorrentMagnetPlaybackError.bridgeFailed("WebTorrent 返回了无效播放地址")
            }
            if !process.isRunning {
                throw WebTorrentMagnetPlaybackError.bridgeFailed("WebTorrent 在取得元数据前退出")
            }
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

    private func discardFinishedSessions() {
        sessions = sessions.filter { $0.value.process.isRunning }
    }

    private func trimSessionsIfNeeded() {
        guard sessions.count >= 2,
              let oldest = sessions.min(by: { $0.value.startedAt < $1.value.startedAt }) else { return }
        if oldest.value.process.isRunning { oldest.value.process.terminate() }
        sessions.removeValue(forKey: oldest.key)
    }

    private static func infoHash(in magnetURI: String) throws -> String {
        guard let components = URLComponents(string: magnetURI),
              components.scheme?.lowercased() == "magnet",
              let exactTopic = components.queryItems?.first(where: { $0.name.lowercased() == "xt" })?.value,
              let hash = exactTopic.components(separatedBy: ":").last?.uppercased(),
              Self.isValidInfoHash(hash) else {
            throw WebTorrentMagnetPlaybackError.invalidMagnet
        }
        return hash
    }

    private static func isValidInfoHash(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        switch value.count {
        case 40:
            return bytes.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
        case 32:
            return bytes.allSatisfy { (65...90).contains($0) || (50...55).contains($0) }
        default:
            return false
        }
    }
}
