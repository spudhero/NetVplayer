import XCTest
@testable import Storage

final class CredentialStoreTests: XCTestCase {
    private final class Store: CredentialStore, @unchecked Sendable {
        var values: [String: String] = [:]
        var fails = false
        var corrupts = false
        var readCount = 0
        func read(_ key: String) throws -> String? {
            readCount += 1
            if fails { throw CredentialStoreError.unavailable(-1) }
            return values[key]
        }
        func write(_ value: String, for key: String) throws {
            if fails { throw CredentialStoreError.unavailable(-1) }
            values[key] = corrupts ? "wrong" : value
        }
        func remove(_ key: String) throws {
            if fails { throw CredentialStoreError.unavailable(-1) }
            values.removeValue(forKey: key)
        }
    }

    func testCredentialReadCachesValueAndAvailabilitySnapshotDoesNotTouchStore() throws {
        let name = "credential-test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = Store()
        store.values["quarkCookie"] = "fixture-cookie"
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)

        XCTAssertEqual(preferences.cachedCredentialAvailability("quarkCookie"), .unknown)
        XCTAssertEqual(store.readCount, 0)
        XCTAssertEqual(preferences.quarkCookie, "fixture-cookie")
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(preferences.cachedCredentialAvailability("quarkCookie"), .available)
        XCTAssertEqual(preferences.quarkCookie, "fixture-cookie")
        XCTAssertEqual(store.readCount, 1)
    }

    func testMissingCredentialIsCachedAsUnavailableForTheSession() throws {
        let name = "credential-test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = Store()
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)

        XCTAssertEqual(preferences.cachedCredentialAvailability("quarkCookie"), .unknown)
        XCTAssertEqual(preferences.quarkCookie, "")
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(preferences.cachedCredentialAvailability("quarkCookie"), .unavailable)
        XCTAssertEqual(preferences.quarkCookie, "")
        XCTAssertEqual(store.readCount, 1)
    }

    func testMigrationDeletesPlaintextOnlyAfterVerifiedWrite() throws {
        let name = "credential-test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("fixture-cookie", forKey: "quarkCookie")
        let store = Store()
        store.fails = true
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)
        XCTAssertEqual(preferences.quarkCookie, "fixture-cookie")
        XCTAssertEqual(defaults.string(forKey: "quarkCookie"), "fixture-cookie")
        XCTAssertThrowsError(try preferences.checkCredentialPersistence())
        store.fails = false
        try preferences.retryCredentialPersistence()
        XCTAssertNil(defaults.object(forKey: "quarkCookie"))
        XCTAssertEqual(store.values["quarkCookie"], "fixture-cookie")
        XCTAssertEqual(UserPreferences(defaults: defaults, credentialStore: store).quarkCookie, "fixture-cookie")
    }

    func testFailedWritesStayInMemoryAndAccountDeletionIsScoped() throws {
        let name = "credential-test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = Store()
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)
        preferences.ucCookie = "uc-fixture"
        store.fails = true
        preferences.quarkCookie = "new-fixture"
        XCTAssertNil(defaults.object(forKey: "quarkCookie"))
        XCTAssertEqual(preferences.quarkCookie, "new-fixture")
        XCTAssertThrowsError(try preferences.checkCredentialPersistence())
        store.fails = false
        try preferences.retryCredentialPersistence()
        preferences.quarkCookie = ""
        XCTAssertNil(store.values["quarkCookie"])
        XCTAssertEqual(preferences.ucCookie, "uc-fixture")
    }

    func testVerificationFailurePreservesLegacyAndDoesNotReimportAfterLogout() throws {
        let name = "credential-test-\(UUID())"
        let legacy = "credential-legacy-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); defaults.removePersistentDomain(forName: legacy) }
        defaults.set("old-fixture", forKey: "aliRefreshToken")
        let store = Store(); store.corrupts = true
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)
        XCTAssertEqual(preferences.aliRefreshToken, "old-fixture")
        XCTAssertNotNil(defaults.object(forKey: "aliRefreshToken"))
        store.corrupts = false
        try preferences.retryCredentialPersistence()
        preferences.aliRefreshToken = ""
        defaults.setPersistentDomain(["aliRefreshToken": "old-fixture"], forName: legacy)
        preferences.migrateLegacyPreferenceDomainsIfNeeded(from: [legacy])
        XCTAssertEqual(preferences.aliRefreshToken, "")
        XCTAssertNil(defaults.object(forKey: "aliRefreshToken"))
    }

    func testBackupExcludesCredentials() throws {
        let defaults = UserDefaults(suiteName: "credential-test-\(UUID())")!
        let preferences = UserPreferences(defaults: defaults)
        preferences.quarkCookie = "do-not-export-fixture"
        let data = try JSONEncoder().encode(UserPreferenceSnapshot(preferences: preferences))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("do-not-export-fixture"))
    }

    func testKeychainStorePersistsAcrossInstancesAndDeletesOnlyItsAccount() throws {
        guard ProcessInfo.processInfo.environment["NETVPLAYER_REAL_KEYCHAIN_TEST"] == "1" else {
            throw XCTSkip("Set NETVPLAYER_REAL_KEYCHAIN_TEST=1 outside the test sandbox.")
        }
        let service = "com.netvplayer.tests.credentials.\(UUID().uuidString)"
        let first = KeychainCredentialStore(service: service)
        let second = KeychainCredentialStore(service: service)
        defer {
            try? first.remove("first")
            try? first.remove("second")
        }
        try first.write("fixture-one", for: "first")
        try first.write("fixture-two", for: "second")
        XCTAssertEqual(try second.read("first"), "fixture-one")
        XCTAssertEqual(try second.read("second"), "fixture-two")
        try second.remove("first")
        XCTAssertNil(try first.read("first"))
        XCTAssertEqual(try first.read("second"), "fixture-two")
    }
}
