import Foundation
import Models

public protocol HostMagnetPlaybackResolving: Sendable {
    func prepare(_ result: Result, resumeFile: MagnetFileIdentity?) async throws -> Result
    func release(_ leaseID: UUID) async
}

/// Resolves a Provider's output, without changing or repeating its business call.
public struct HostMagnetPlaybackResolver: HostMagnetPlaybackResolving {
    private let bridge: WebTorrentMagnetPlaybackResolver
    public init() { bridge = .shared }
    init(bridge: WebTorrentMagnetPlaybackResolver) { self.bridge = bridge }

    public static func needsResolution(_ result: Result) -> Bool {
        URLComponents(string: result.url)?.scheme?.lowercased() == "magnet"
            && result.playUrl.isEmpty && !result.needParse
            && result.interaction == nil && result.playbackCandidates.isEmpty
    }

    public func prepare(_ result: Result, resumeFile: MagnetFileIdentity?) async throws -> Result {
        guard Self.needsResolution(result) else { return result }
        guard let hash = MagnetURI.infoHash(in: result.url) else {
            throw WebTorrentMagnetPlaybackError.invalidMagnet
        }
        let lease = try await bridge.acquireFiles(for: result.url)
        do {
            try Task.checkCancellation()
            return try Self.prepared(result, leaseID: lease.id,
                files: Self.files(lease.files, infoHash: hash), resumeFile: resumeFile)
        } catch {
            await bridge.release(lease.id)
            throw error
        }
    }

    public func release(_ leaseID: UUID) async { await bridge.release(leaseID) }

    static func files(_ files: [SixVMagnetPlaybackFile], infoHash: String) throws -> [HostMagnetFile] {
        guard !files.isEmpty, Set(files.map(\.index)).count == files.count,
              Set(files.map(\.url)).count == files.count,
              Set(files.compactMap(\.url.port)).count == 1 else {
            throw WebTorrentMagnetPlaybackError.bridgeFailed("磁力文件列表为空或身份重复")
        }
        return try files.map { file in
            guard let identity = MagnetFileIdentity(infoHash: infoHash, fileIndex: file.index, length: file.length),
                  file.url.scheme == "http", file.url.host == "127.0.0.1", let port = file.url.port,
                  (1...65535).contains(port),
                  file.url.user == nil, file.url.password == nil, file.url.query == nil, file.url.fragment == nil,
                  file.url.path == "/stream/\(file.index)/\(file.name)",
                  !file.name.isEmpty, !file.name.contains("/"), !file.name.contains("\\"),
                  file.name.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw WebTorrentMagnetPlaybackError.bridgeFailed("磁力文件身份或本机播放地址无效")
            }
            return HostMagnetFile(identity: identity, name: file.name, url: file.url)
        }
    }

    static func prepared(_ result: Result, leaseID: UUID, files: [HostMagnetFile], resumeFile: MagnetFileIdentity?) throws -> Result {
        guard !files.isEmpty else { throw WebTorrentMagnetPlaybackError.bridgeFailed("磁力未返回可播放文件") }
        let choices: [HostMagnetFile]
        if let resumeFile {
            guard let exact = files.first(where: { $0.identity == resumeFile }) else {
                throw WebTorrentMagnetPlaybackError.bridgeFailed("无法确认上次播放的磁力文件，请重新选择后播放")
            }
            choices = [exact]
        } else { choices = files }
        var prepared = result
        prepared.hostMagnet = HostMagnetPlayback(leaseID: leaseID, files: files, resumeFile: resumeFile)
        prepared.externalAudioURL = ""
        prepared.playbackCandidates = choices.map { file in
            PlaybackCandidate(id: file.identity.candidateID, providerKey: "host.torrent", providerName: "磁力文件",
                name: file.name, description: ByteCountFormatter.string(fromByteCount: file.identity.length, countStyle: .file),
                kind: .directURL, status: .playable, url: file.url.absoluteString,
                format: file.url.pathExtension.lowercased(), subtitles: result.subs)
        }
        return prepared
    }
}
