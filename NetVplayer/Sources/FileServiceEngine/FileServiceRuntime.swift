import Foundation
import Models
import Storage
import ProxyServer
import DriveEngine
import Networking

public actor FileServiceRuntime {
    public static let shared = FileServiceRuntime()
    private let store: FileServiceStore
    private let cloudPreferences: UserPreferences
    private let cloudHTTPClient: HTTPClient
    private var clients: [UUID: (FileServiceConfiguration, any FileServiceClient)] = [:]
    private var playbackClients: [(UUID, UUID, any FileServiceClient, String?)] = []
    private var discResources: [UUID: (serviceID: UUID, urls: [String])] = [:]
    public init(store: FileServiceStore = .shared, cloudPreferences: UserPreferences = .shared,
                cloudHTTPClient: HTTPClient = .shared) {
        self.store = store; self.cloudPreferences = cloudPreferences; self.cloudHTTPClient = cloudHTTPClient
    }
    public func makeClient(configuration: FileServiceConfiguration, credentials: FileServiceCredentials,
                           bookmark: Data? = nil) throws -> any FileServiceClient {
        switch configuration.kind {
        case .webDAV: return try WebDAVClient(configuration: configuration, credentials: credentials)
        case .alist, .openList: return try AListClient(configuration: configuration, credentials: credentials)
        case .smb: return try SMBClient(configuration: configuration, credentials: credentials)
        case .ftp, .sftp: return try RemoteTransferClient(configuration: configuration, credentials: credentials)
        case .cloudDrive: return try CloudDirectoryClient(configuration: configuration, preferences: cloudPreferences, httpClient: cloudHTTPClient)
        case .local:
            guard let bookmark = bookmark ?? store.bookmark(for: configuration.id) else { throw FileServiceError.authorizationExpired }
            return try LocalDirectoryClient(bookmark: bookmark, rootPath: configuration.rootPath)
        }
    }
    public func test(configuration: FileServiceConfiguration, credentials: FileServiceCredentials, bookmark: Data? = nil) async throws {
        // A draft's test must never certify a different saved endpoint/account.
        let matchesSaved = store.load().services.contains(configuration)
            && (try? store.credentials(for: configuration)) == credentials
            && (bookmark == nil || bookmark == store.bookmark(for: configuration.id))
        let observation = matchesSaved ? ServiceConnectionObservations.shared.begin(store.connectionObservationScope(configuration)) : nil
        let client = try makeClient(configuration: configuration.validated(), credentials: credentials, bookmark: bookmark)
        do {
            try await client.connect(); await client.disconnect()
            if let observation, !Task.isCancelled, store.load().services.contains(configuration) {
                ServiceConnectionObservations.shared.finish(observation, state: .available)
            }
        } catch {
            await client.disconnect()
            if let observation, !TaskDiagnosticIssue.isCancellation(error), store.load().services.contains(configuration) {
                ServiceConnectionObservations.shared.finish(observation, state: ServiceConnectionObservations.failure(error))
            }
            throw error
        }
    }
    public func client(for id: UUID) async throws -> any FileServiceClient {
        guard let configuration = store.load().services.first(where: { $0.id == id }) else { throw FileServiceError.unavailable }
        if let (cachedConfiguration, cachedClient) = clients[id] {
            if cachedConfiguration == configuration { return cachedClient }
            clients[id] = nil; await cachedClient.disconnect()
        }
        let observation = ServiceConnectionObservations.shared.begin(store.connectionObservationScope(configuration))
        let client = try makeClient(configuration: configuration, credentials: store.credentials(for: configuration))
        do {
            try await client.connect()
            try Task.checkCancellation()
            if store.load().services.contains(configuration) {
                ServiceConnectionObservations.shared.finish(observation, state: .available)
            }
        } catch {
            await client.disconnect()
            if !TaskDiagnosticIssue.isCancellation(error), store.load().services.contains(configuration) {
                ServiceConnectionObservations.shared.finish(observation, state: ServiceConnectionObservations.failure(error))
            }
            throw error
        }
        // Another task can have installed a connection while this one authenticated.
        if let (existingConfiguration, existing) = clients[id], existingConfiguration == configuration { await client.disconnect(); return existing }
        guard store.load().services.contains(configuration) else { await client.disconnect(); throw FileServiceError.unavailable }
        clients[id] = (configuration, client); return client
    }
    public func invalidate(serviceID: UUID) async {
        for leaseID in discResources.filter({ $0.value.serviceID == serviceID }).map(\.key) {
            releaseDiscPlayback(leaseID: leaseID)
        }
        let client = clients.removeValue(forKey: serviceID)?.1
        let retired = playbackClients.filter { $0.0 == serviceID }
        playbackClients.removeAll { $0.0 == serviceID }
        for (_, _, client, proxy) in retired {
            if let proxy { ProxyServer.shared.unregisterSeekableResource(url: proxy) }
            else { await client.disconnect() }
        }
        await client?.disconnect()
    }
    public func releasePlayback(leaseID: UUID? = nil) async {
        for id in discResources.keys.filter({ leaseID == nil || $0 == leaseID }) { releaseDiscPlayback(leaseID: id) }
        let retired = playbackClients.filter { leaseID == nil || $0.1 == leaseID }
        playbackClients.removeAll { leaseID == nil || $0.1 == leaseID }
        for (_, _, client, proxy) in retired {
            if let proxy { ProxyServer.shared.unregisterSeekableResource(url: proxy) }
            else { await client.disconnect() }
        }
    }
    private func releaseDiscPlayback(leaseID: UUID) {
        guard let resources = discResources.removeValue(forKey: leaseID) else { return }
        resources.urls.forEach { ProxyServer.shared.unregisterSeekableResource(url: $0) }
    }
    private func discReader(_ reference: FileResourceReference) async throws -> BlurayDiscReader {
        guard let configuration = store.load().services.first(where: { $0.id == reference.serviceID }) else { throw FileServiceError.unavailable }
        let client = try makeClient(configuration: configuration, credentials: store.credentials(for: configuration))
        do { try await client.connect() }
        catch { await client.disconnect(); throw error }
        return BlurayDiscReader(reference: reference, client: client, ownsClient: true)
    }
    public func scanDisc(_ reference: FileResourceReference) async throws -> DiscCatalog {
        let reader = try await discReader(reference)
        return try await reader.scan()
    }
    public func resolveDisc(_ selection: DiscSelection, leaseID: UUID) async throws -> DiscPlayback {
        let reader = try await discReader(selection.reference)
        let playback = try await reader.playback(selection: selection)
        guard !Task.isCancelled else {
            playback.segmentURLs.forEach { ProxyServer.shared.unregisterSeekableResource(url: $0) }
            throw CancellationError()
        }
        releaseDiscPlayback(leaseID: leaseID)
        discResources[leaseID] = (selection.reference.serviceID, playback.segmentURLs)
        return playback
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
            case .ftp, .sftp, .cloudDrive: .seekableResource
            case .local: .local
            }
            let audio = DriveMediaClassifier.isPlayableAudio(name: reference.path, formatType: "", isDirectory: false, isFile: true)
            let wideAudio = ["wav", "wave", "flac", "ape", "alac", "aiff", "aif", "aifc", "caf", "dsf", "dff"]
                .contains((reference.path as NSString).pathExtension.lowercased())
            let profile = PlaybackTransferProfile.seekable(context: .init(connection: connection,
                media: audio ? (wideAudio ? .wideAudio : .compressedAudio) : .video, contentLength: entry.size, isOriginal: true))
            // Preserve SMB's sequential 4 MiB reads and one-read pipeline.
            let proxy = try ProxyServer.shared.registerSeekableResource(.init(size: entry.size, contentType: contentType,
                  readChunkSize: profile.steadyReadBytes, transferProfile: profile,
                  mediaIdentity: .init(source: "file-service", account: reference.serviceID.uuidString, item: path),
                  close: { await client.disconnect() }) { range in
                try await client.read(path: path, range: range)
            })
            playbackClients.append((configuration.id, leaseID, client, proxy))
            return .init(url: URL(string: proxy)!)
        } catch { await client.disconnect(); throw error }
    }
    public static func isVideo(_ entry: FileEntry) -> Bool {
        (!entry.isDirectory && DriveMediaClassifier.isDiscImage(name: entry.name)) ||
        DriveMediaClassifier.isPlayableVideo(name: entry.name, isDirectory: entry.isDirectory, isFile: !entry.isDirectory)
    }
    public static func isSubtitle(_ entry: FileEntry) -> Bool {
        !entry.isDirectory && ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup"].contains((entry.name as NSString).pathExtension.lowercased())
    }
}
