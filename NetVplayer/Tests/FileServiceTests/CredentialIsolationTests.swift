import Foundation
import Testing
import Models
import Storage
import MediaLibraryEngine

@Suite("Independent NAS and metadata credentials")
struct CredentialIsolationTests {
    @Test func bundledTMDBRemainsAvailableWhenOptionalPersonalReadTimesOut() throws {
        try withFixture { directory, defaults in
            let preferences = UserPreferences(defaults: defaults, credentialStore: SelectiveCredentialFixture(failedKeys: ["metadata.tmdb.override"]))
            let bundle = directory.appendingPathComponent("TMDB.json")
            try Data(#"{"kind":"apiKey","value":"publisher-fixture"}"#.utf8).write(to: bundle)
            #expect(try MetadataCredentials.resolve(preferences: preferences, bundleURL: bundle)?.value == "publisher-fixture")
            #expect(throws: CredentialStoreError.timedOut) { try preferences.checkCredentialPersistence(for: "metadata.tmdb.override") }
            #expect(throws: CredentialStoreError.timedOut) { try MetadataCredentials.resolve(preferences: preferences, bundleURL: nil) }
        }
    }

    @Test func validPersonalTMDBStillOverridesBundleDespiteUnrelatedFailure() throws {
        try withFixture { directory, defaults in
            let preferences = UserPreferences(defaults: defaults, credentialStore: SelectiveCredentialFixture(
                failedKeys: ["quarkCookie"], values: ["metadata.tmdb.override": #"{"kind":"readAccessToken","value":"personal-fixture"}"#]))
            _ = preferences.credential("quarkCookie")
            let bundle = directory.appendingPathComponent("TMDB.json")
            try Data(#"{"kind":"apiKey","value":"publisher-fixture"}"#.utf8).write(to: bundle)
            #expect(try MetadataCredentials.resolve(preferences: preferences, bundleURL: bundle)?.value == "personal-fixture")
            #expect(throws: CredentialStoreError.timedOut) { try preferences.checkCredentialPersistence() }
        }
    }

    @Test(arguments: [false, true]) func NASChecksItsOwnCredentialFailure(_ failNAS: Bool) throws {
        try withFixture { directory, defaults in
            let service = FileServiceConfiguration(name: "Fixture NAS", kind: .smb, address: "smb://fixture.invalid", share: "Movies")
            let key = "file-service." + service.id.uuidString
            struct Envelope: Encodable { let endpoint: String; let credentials: FileServiceCredentials }
            let expected = FileServiceCredentials(username: "fixture-user", password: "fixture-password")
            let value = String(decoding: try JSONEncoder().encode(Envelope(endpoint: service.endpointIdentity, credentials: expected)), as: UTF8.self)
            let preferences = UserPreferences(defaults: defaults, credentialStore: SelectiveCredentialFixture(
                failedKeys: failNAS ? ["quarkCookie", key] : ["quarkCookie"], values: [key: value]))
            _ = preferences.credential("quarkCookie")
            let store = FileServiceStore(storage: StorageManager(storageDirectory: directory), preferences: preferences)
            if failNAS {
                #expect(throws: CredentialStoreError.timedOut) { try store.credentials(for: service) }
            } else {
                #expect(try store.credentials(for: service) == expected)
            }
            #expect(throws: CredentialStoreError.timedOut) { try preferences.checkCredentialPersistence() }
        }
    }

    private func withFixture(_ body: (URL, UserDefaults) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "CredentialIsolationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        try body(directory, defaults)
    }
}

private struct SelectiveCredentialFixture: CredentialStore {
    let failedKeys: Set<String>
    var values: [String: String] = [:]
    func read(_ key: String) throws -> String? {
        if failedKeys.contains(key) { throw CredentialStoreError.timedOut }
        return values[key]
    }
    func write(_ value: String, for key: String) throws { throw CredentialStoreError.unavailable(-1) }
    func remove(_ key: String) throws { throw CredentialStoreError.unavailable(-1) }
}
