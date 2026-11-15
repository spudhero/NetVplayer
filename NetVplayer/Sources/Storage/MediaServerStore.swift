import Foundation
import Models

public final class MediaServerStore: @unchecked Sendable {
    public static let shared = MediaServerStore()
    private let storage: StorageManager
    private let preferences: UserPreferences
    public init(storage: StorageManager = .shared, preferences: UserPreferences = .shared) {
        self.storage = storage; self.preferences = preferences
    }
    public func load() -> [MediaServerConfiguration] {
        (try? storage.loadBounded([MediaServerConfiguration].self, from: "media-servers.json", maximumBytes: 1024 * 1024)) ?? []
    }
    public func save(_ accounts: [MediaServerConfiguration]) throws {
        for account in load() where !accounts.contains(where: {
            $0.id == account.id && connectionObservationScope($0).revision == connectionObservationScope(account).revision
        }) {
            ServiceConnectionObservations.shared.invalidate(connectionObservationScope(account))
        }
        try storage.save(accounts, to: "media-servers.json")
    }
    public func connectionObservationScope(_ account: MediaServerConfiguration) -> ServiceConnectionObservations.Scope {
        .init(namespace: storage.connectionObservationNamespace + ":servers", id: account.id,
              revision: ServiceConnectionObservations.revision([account.credentialBinding, account.deviceID.uuidString,
                  String(account.allowsHTTP), String(preferences.searchCredentialRevision)]))
    }
    private struct Credential: Codable { let binding: String; let token: String }
    private func key(_ account: MediaServerConfiguration) -> String { "media-server." + account.id.uuidString.lowercased() }
    public func token(for account: MediaServerConfiguration) throws -> String {
        let value = preferences.credential(key(account))
        try preferences.checkCredentialPersistence(for: key(account))
        guard let data = value.data(using: .utf8), let credential = try? JSONDecoder().decode(Credential.self, from: data),
              credential.binding == account.credentialBinding, !credential.token.isEmpty else { throw MediaServerError.authentication }
        return credential.token
    }
    public func saveToken(_ token: String, for account: MediaServerConfiguration) throws {
        ServiceConnectionObservations.shared.invalidate(connectionObservationScope(account))
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw MediaServerError.authentication }
        let data = try JSONEncoder().encode(Credential(binding: account.credentialBinding, token: token))
        try preferences.saveCredential(String(decoding: data, as: UTF8.self), for: key(account))
    }
    public func removeToken(for account: MediaServerConfiguration) throws {
        ServiceConnectionObservations.shared.invalidate(connectionObservationScope(account))
        try preferences.saveCredential("", for: key(account))
    }
}
