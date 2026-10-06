import Foundation
import Models
import Storage
import ProxyServer
import DriveEngine

public actor FileServiceRuntime {
    public static let shared = FileServiceRuntime()
    private let store: FileServiceStore
    private var clients: [UUID: (FileServiceConfiguration, any FileServiceClient)] = [:]
    private var playbackClients: [(UUID, UUID, any FileServiceClient, String?)] = []
    public init(store: FileServiceStore = .shared) { self.store = store }
    public func makeClient(configuration: FileServiceConfiguration, credentials: FileServiceCredentials,
                           bookmark: Data? = nil) throws -> any FileServiceClient {
        switch configuration.kind {
        case .webDAV: return try WebDAVClient(configuration: configuration, credentials: credentials)
        case .alist, .openList: return try AListClient(configuration: configuration, credentials: credentials)
        case .smb: return try SMBClient(configuration: configuration, credentials: credentials)
        case .local:
            guard let bookmark = bookmark ?? store.bookmark(for: configuration.id) else { throw FileServiceError.authorizationExpired }
            return try LocalDirectoryClient(bookmark: bookmark, rootPath: configuration.rootPath)
        }
    }
    public func test(configuration: FileServiceConfiguration, credentials: FileServiceCredentials, bookmark: Data? = nil) async throws {
        let client = try makeClient(configuration: configuration.validated(), credentials: credentials, bookmark: bookmark)
        do { try await client.connect(); await client.disconnect() }
        catch { await client.disconnect(); throw error }
    }
    public func client(for id: UUID) async throws -> any FileServiceClient {
        guard let configuration = store.load().services.first(where: { $0.id == id }) else { throw FileServiceError.unavailable }
        if let (cachedConfiguration, cachedClient) = clients[id] {
            if cachedConfiguration == configuration { return cachedClient }
            clients[id] = nil; await cachedClient.disconnect()
        }
        let client = try makeClient(configuration: configuration, credentials: store.credentials(for: configuration))
        try await client.connect()
        // Another task can have installed a connection while this one authenticated.
        if let (existingConfiguration, existing) = clients[id], existingConfiguration == configuration { await client.disconnect(); return existing }
        guard store.load().services.contains(configuration) else { await client.disconnect(); throw FileServiceError.unavailable }
        clients[id] = (configuration, client); return client
    }
    public func invalidate(serviceID: UUID) async {
        let client = clients.removeValue(forKey: serviceID)?.1
        let retired = playbackClients.filter { $0.0 == serviceID }
        playbackClients.removeAll { $0.0 == serviceID }
        for (_, _, client, proxy) in retired {
            if let proxy { ProxyServer.shared.unregisterSeekableResource(url: proxy) }
            await client.disconnect()
        }
        await client?.disconnect()
    }
    public func releasePlayback(leaseID: UUID? = nil) async {
        let retired = playbackClients.filter { leaseID == nil || $0.1 == leaseID }
        playbackClients.removeAll { leaseID == nil || $0.1 == leaseID }
        for (_, _, client, proxy) in retired {
            if let proxy { ProxyServer.shared.unregisterSeekableResource(url: proxy) }
            await client.disconnect()
        }
    }
    /// A separate connection/scope remains alive until the player closes, independent of directory navigation.
    public func resolvePlayback(_ reference: FileResourceReference, leaseID: UUID = UUID()) async throws -> ResolvedFileResource {
        guard let configuration = store.load().services.first(where: { $0.id == reference.serviceID }) else { throw FileServiceError.unavailable }
        let client = try makeClient(configuration: configuration, credentials: store.credentials(for: configuration))
        do {
            try await client.connect()
            if configuration.kind == .local {
                let resource = try await client.resolve(path: reference.path)
                playbackClients.append((configuration.id, leaseID, client, nil)); return resource
            }
            let entry = try await client.stat(path: reference.path)
            let contentType: String = switch (reference.path as NSString).pathExtension.lowercased() {
            case "srt": "application/x-subrip"; case "vtt": "text/vtt"; case "ass", "ssa": "text/plain"
            case "jpg", "jpeg": "image/jpeg"; case "png": "image/png"; case "webp": "image/webp"
            case "mp4", "m4v": "video/mp4"; default: "application/octet-stream"
            }
            let path = reference.path
            let connection: PlaybackTransferConnection = switch configuration.kind {
            case .smb: .smb
            case .webDAV: .webdav
            case .alist, .openList: .alist
            case .local: .local
            }
            let audio = DriveMediaClassifier.isPlayableAudio(name: reference.path, formatType: "", isDirectory: false, isFile: true)
            let wideAudio = ["wav", "wave", "flac", "ape", "alac", "aiff", "aif", "aifc", "caf", "dsf", "dff"]
                .contains((reference.path as NSString).pathExtension.lowercased())
            let profile = PlaybackTransferProfile.seekable(context: .init(connection: connection,
                media: audio ? (wideAudio ? .wideAudio : .compressedAudio) : .video, contentLength: entry.size, isOriginal: true))
            // Preserve SMB's sequential 4 MiB reads and one-read pipeline.
            let proxy = try ProxyServer.shared.registerSeekableResource(.init(size: entry.size, contentType: contentType,
                readChunkSize: profile.steadyReadBytes, transferProfile: profile) { range in
                try await client.read(path: path, range: range)
            })
            playbackClients.append((configuration.id, leaseID, client, proxy))
            return .init(url: URL(string: proxy)!)
        } catch { await client.disconnect(); throw error }
    }
    public static func isVideo(_ entry: FileEntry) -> Bool {
        DriveMediaClassifier.isPlayableVideo(name: entry.name, isDirectory: entry.isDirectory, isFile: !entry.isDirectory)
    }
    public static func isSubtitle(_ entry: FileEntry) -> Bool {
        !entry.isDirectory && ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup"].contains((entry.name as NSString).pathExtension.lowercased())
    }
}
