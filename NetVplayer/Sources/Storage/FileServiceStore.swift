import Foundation
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
    public init(storage: StorageManager = .shared, preferences: UserPreferences = .shared) {
        self.storage = storage; self.preferences = preferences
    }
    public func load() -> FileServiceCatalog {
        (try? storage.loadBounded(FileServiceCatalog.self, from: "file-services.json", maximumBytes: 4 * 1024 * 1024)) ?? .init()
    }
    public func save(_ catalog: FileServiceCatalog) throws { try storage.save(catalog, to: "file-services.json") }
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
        let envelope = CredentialEnvelope(endpoint: service.endpointIdentity, credentials: credentials)
        let value = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        try preferences.saveCredential(value, for: "file-service." + service.id.uuidString)
    }
    public func bookmark(for id: UUID) -> Data? {
        (try? storage.load([String: Data].self, from: "file-service-bookmarks.json"))?[id.uuidString]
    }
    public func saveBookmark(_ data: Data?, for id: UUID) throws {
        var values = (try? storage.load([String: Data].self, from: "file-service-bookmarks.json")) ?? [:]
        values[id.uuidString] = data
        try storage.save(values, to: "file-service-bookmarks.json")
    }
    public func removeSecrets(for id: UUID) throws {
        try preferences.saveCredential("", for: "file-service." + id.uuidString)
        try saveBookmark(nil, for: id)
    }
}
