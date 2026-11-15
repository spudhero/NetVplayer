import Foundation
import CryptoKit
import Models

public struct FileServiceCatalog: Codable, Equatable, Sendable {
    public var services: [FileServiceConfiguration]
    public var libraries: [MediaLibraryConfiguration]
    public var defaultMetadataSource: MetadataSource
    public init(services: [FileServiceConfiguration] = [], libraries: [MediaLibraryConfiguration] = [],
                defaultMetadataSource: MetadataSource = .automatic) {
        self.services = services; self.libraries = libraries; self.defaultMetadataSource = defaultMetadataSource
    }
}

public struct FileServiceCredentials: Codable, Equatable, Sendable {
    public var username: String
    public var password: String
    public var directoryPasswords: [String: String]
    public init(username: String = "", password: String = "", directoryPasswords: [String: String] = [:]) {
        self.username = username; self.password = password; self.directoryPasswords = directoryPasswords
    }
    public func directoryPassword(for path: String) -> String {
        directoryPasswords.keys.filter { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
            .max(by: { $0.count < $1.count }).flatMap { directoryPasswords[$0] } ?? ""
    }
}

public final class FileServiceStore: @unchecked Sendable {
    public static let shared = FileServiceStore()
    private let storage: StorageManager
    private let preferences: UserPreferences
    private let scanRevisionLock = NSLock()
    private struct ScanVersion: Equatable {
        var catalog: StorageManager.FileVersion?, authorization: StorageManager.FileVersion?
    }
    private var scanVersion: ScanVersion?
    private var scanRevisions: [UUID: (library: MediaLibraryConfiguration, revision: String)] = [:]
    public init(storage: StorageManager = .shared, preferences: UserPreferences = .shared) {
        self.storage = storage; self.preferences = preferences
    }
    public func load() -> FileServiceCatalog {
        (try? storage.loadBounded(FileServiceCatalog.self, from: "file-services.json", maximumBytes: 4 * 1024 * 1024)) ?? .init()
    }
    public func save(_ catalog: FileServiceCatalog) throws {
        let previous = load()
        for service in previous.services where !catalog.services.contains(service) {
            ServiceConnectionObservations.shared.invalidate(connectionObservationScope(service))
        }
        try storage.save(catalog, to: "file-services.json")
    }
    public func connectionObservationScope(_ service: FileServiceConfiguration) -> ServiceConnectionObservations.Scope {
        .init(namespace: storage.connectionObservationNamespace + ":files", id: service.id,
              revision: ServiceConnectionObservations.revision([service.endpointIdentity, service.rootPath,
                  (try? scanAuthorizationRevision(for: service.id)) ?? UUID().uuidString,
                  String(preferences.searchCredentialRevision)]))
    }
    public func loadCorrections() -> [MediaManualCorrection] {
        (try? storage.loadBounded([MediaManualCorrection].self, from: "media-corrections.json", maximumBytes: 8 * 1024 * 1024)) ?? []
    }
    public func saveCorrections(_ corrections: [MediaManualCorrection]) throws { try storage.save(corrections, to: "media-corrections.json") }
    private struct CredentialEnvelope: Codable { var endpoint: String; var credentials: FileServiceCredentials }
    public func credentials(for service: FileServiceConfiguration) throws -> FileServiceCredentials {
        let key = "file-service." + service.id.uuidString
        let value = preferences.credential(key)
        try preferences.checkCredentialPersistence(for: key)
        guard !value.isEmpty else { return .init() }
        guard let data = value.data(using: .utf8), let envelope = try? JSONDecoder().decode(CredentialEnvelope.self, from: data),
              envelope.endpoint == service.endpointIdentity else { return .init() }
        return envelope.credentials
    }
    public func saveCredentials(_ credentials: FileServiceCredentials, for service: FileServiceConfiguration) throws {
        ServiceConnectionObservations.shared.invalidate(connectionObservationScope(service))
        // Rotate before changing authorization, so even a failed save cannot reuse old scan evidence.
        try rotateScanAuthorizationRevision(for: service.id)
        let envelope = CredentialEnvelope(endpoint: service.endpointIdentity, credentials: credentials)
        let value = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        try preferences.saveCredential(value, for: "file-service." + service.id.uuidString)
    }
    public func bookmark(for id: UUID) -> Data? {
        (try? storage.load([String: Data].self, from: "file-service-bookmarks.json"))?[id.uuidString]
    }
    public func saveBookmark(_ data: Data?, for id: UUID) throws {
        try rotateScanAuthorizationRevision(for: id)
        var values = (try? storage.load([String: Data].self, from: "file-service-bookmarks.json")) ?? [:]
        values[id.uuidString] = data
        try storage.save(values, to: "file-service-bookmarks.json")
    }
    public func removeSecrets(for id: UUID) throws {
        try rotateScanAuthorizationRevision(for: id)
        try preferences.saveCredential("", for: "file-service." + id.uuidString)
        try saveBookmark(nil, for: id)
    }
    public func scanAuthorizationRevision(for id: UUID) throws -> String {
        let revisions = try loadScanAuthorizationRevisions()
        return revisions[id.uuidString] ?? "legacy"
    }
    /// Same persistent digest as the original scanner, without re-reading unchanged JSON
    /// for every record/queue/CAS check. Never rely on a time-based freshness window.
    public func scanConfigurationRevision(for library: MediaLibraryConfiguration) throws -> String {
        scanRevisionLock.lock(); defer { scanRevisionLock.unlock() }
        for _ in 0..<3 {
            let before = try currentScanVersion()
            if before == scanVersion, let cached = scanRevisions[library.id], cached.library == library {
                return cached.revision
            }
            let catalog = load()
            guard catalog.libraries.contains(library), let service = catalog.services.first(where: { $0.id == library.serviceID }) else {
                throw MediaScanRecoveryError.configurationChanged
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var material = try encoder.encode(library); material.append(try encoder.encode(service))
            material.append(Data(try scanAuthorizationRevision(for: service.id).utf8))
            let after = try currentScanVersion()
            // A writer may replace either file while it is being decoded. Don't cache a mixed snapshot.
            guard before == after else { continue }
            let revision = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
            if after != scanVersion || scanRevisions.count >= 128 { scanRevisions.removeAll(keepingCapacity: true) }
            scanVersion = after; scanRevisions[library.id] = (library, revision)
            return revision
        }
        throw MediaScanRecoveryError.configurationChanged
    }
    private func currentScanVersion() throws -> ScanVersion {
        try .init(catalog: storage.fileVersion("file-services.json"), authorization: storage.fileVersion("file-scan-revisions.json"))
    }
    private func loadScanAuthorizationRevisions() throws -> [String: String] {
        do { return try storage.loadBounded([String: String].self, from: "file-scan-revisions.json", maximumBytes: 1024 * 1024) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return [:] }
            throw error
        }
    }
    private func rotateScanAuthorizationRevision(for id: UUID) throws {
        try storage.withJournalLock("file-scan-revisions.json") {
            var revisions = try loadScanAuthorizationRevisions()
            guard revisions.count < 4096 || revisions[id.uuidString] != nil else { throw MediaScanRecoveryError.capacity }
            revisions[id.uuidString] = UUID().uuidString
            try storage.save(revisions, to: "file-scan-revisions.json")
        }
    }
}
