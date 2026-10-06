import Foundation
import XCTest
@testable import Storage

/// Behavioral edge cases use an injected store and isolated defaults domains only.
/// They never call Security or read/write the user's actual Keychain.
final class CredentialMigrationEdgeTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
        func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private final class Store: CredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var isLocked = false
        private var corruptsWrites = false

        func setLocked(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            isLocked = value
        }

        func setCorruptsWrites(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            corruptsWrites = value
        }

        func read(_ key: String) throws -> String? {
            lock.lock(); defer { lock.unlock() }
            guard !isLocked else { throw CredentialStoreError.unavailable(-1) }
            return values[key]
        }

        func write(_ value: String, for key: String) throws {
            lock.lock(); defer { lock.unlock() }
            guard !isLocked else { throw CredentialStoreError.unavailable(-1) }
            values[key] = corruptsWrites ? "unverified-fixture" : value
        }

        func remove(_ key: String) throws {
            lock.lock(); defer { lock.unlock() }
            guard !isLocked else { throw CredentialStoreError.unavailable(-1) }
            values.removeValue(forKey: key)
        }
    }

    func testRestartAfterVerificationMismatchRetainsOriginalLegacyCredential() throws {
        let domain = "CredentialMigrationEdgeTests.restart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("original-fixture", forKey: "quarkCookie")
        let store = Store()
        store.setCorruptsWrites(true)
        let firstProcess = UserPreferences(defaults: defaults, credentialStore: store)

        XCTAssertEqual(firstProcess.quarkCookie, "original-fixture")
        XCTAssertThrowsError(try firstProcess.checkCredentialPersistence())
        XCTAssertEqual(defaults.string(forKey: "quarkCookie"), "original-fixture")

        // A new preferences instance has no pending in-memory write to protect it.
        store.setCorruptsWrites(false)
        let restartedProcess = UserPreferences(defaults: defaults, credentialStore: store)
        XCTAssertEqual(restartedProcess.quarkCookie, "original-fixture")
        XCTAssertEqual(try store.read("quarkCookie"), "original-fixture")
    }

    func testRetryAfterKeychainUnlockRetriesReadOnlyFailure() throws {
        let domain = "CredentialMigrationEdgeTests.unlock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = Store()
        try store.write("persisted-fixture", for: "ucCookie")
        store.setLocked(true)
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)

        XCTAssertEqual(preferences.ucCookie, "")
        XCTAssertThrowsError(try preferences.checkCredentialPersistence())
        store.setLocked(false)
        XCTAssertNoThrow(try preferences.retryCredentialPersistence())
        XCTAssertEqual(preferences.ucCookie, "persisted-fixture")
    }

    func testSuccessfulReadAfterUnlockPublishesCredentialRecovery() throws {
        let domain = "CredentialMigrationEdgeTests.notification.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = Store()
        try store.write("persisted-fixture", for: "ucCookie")
        store.setLocked(true)
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)
        let notifications = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: UserPreferences.credentialsDidChange,
            object: nil,
            queue: nil
        ) { _ in notifications.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertEqual(preferences.ucCookie, "")
        store.setLocked(false)
        XCTAssertEqual(preferences.ucCookie, "persisted-fixture")
        XCTAssertEqual(notifications.value(), 2, "Both failure and automatic recovery must refresh credential UI")
        XCTAssertNoThrow(try preferences.checkCredentialPersistence())
    }

    func testProactiveStartupMigrationPersistsCredentialsWithoutBusinessGetter() throws {
        let domain = "CredentialMigrationEdgeTests.proactive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("quark-fixture", forKey: "quarkCookie")
        defaults.set("uc-fixture", forKey: "ucFongMiPlaybackToken")
        let store = Store()
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)

        try preferences.retryCredentialPersistence()

        XCTAssertEqual(try store.read("quarkCookie"), "quark-fixture")
        XCTAssertEqual(try store.read("ucFongMiPlaybackToken"), "uc-fixture")
        XCTAssertNil(defaults.object(forKey: "quarkCookie"))
        XCTAssertNil(defaults.object(forKey: "ucFongMiPlaybackToken"))
    }

    func testVerifiedMigrationScrubsOriginLegacyDomainAndPreservesOtherSettings() throws {
        let domain = "CredentialMigrationEdgeTests.target.\(UUID().uuidString)"
        let legacyDomain = "CredentialMigrationEdgeTests.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            defaults.removePersistentDomain(forName: legacyDomain)
        }
        defaults.setPersistentDomain([
            "quarkCookie": "legacy-fixture",
            "currentVodSiteKey": "keep-this-setting"
        ], forName: legacyDomain)
        let store = Store()
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)
        preferences.migrateLegacyPreferenceDomainsIfNeeded(from: [legacyDomain])

        XCTAssertEqual(preferences.quarkCookie, "legacy-fixture")
        XCTAssertEqual(try store.read("quarkCookie"), "legacy-fixture")
        XCTAssertNil(defaults.persistentDomain(forName: legacyDomain)?["quarkCookie"])
        XCTAssertEqual(
            defaults.persistentDomain(forName: legacyDomain)?["currentVodSiteKey"] as? String,
            "keep-this-setting"
        )
    }

    func testFailedDeletionRetriesThenSurvivesRecreationWithoutResurrection() throws {
        let domain = "CredentialMigrationEdgeTests.deletion.\(UUID().uuidString)"
        let legacyDomain = "CredentialMigrationEdgeTests.deletedLegacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            defaults.removePersistentDomain(forName: legacyDomain)
        }
        let store = Store()
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)
        try preferences.saveCredential("old-fixture", for: "quarkCookie")
        try preferences.saveCredential("other-provider-fixture", for: "ucCookie")
        store.setLocked(true)

        XCTAssertThrowsError(try preferences.saveCredential("", for: "quarkCookie"))
        XCTAssertEqual(preferences.quarkCookie, "")
        XCTAssertThrowsError(try preferences.checkCredentialPersistence())
        store.setLocked(false)
        try preferences.retryCredentialPersistence()

        defaults.setPersistentDomain(["quarkCookie": "old-fixture"], forName: legacyDomain)
        let restartedProcess = UserPreferences(defaults: defaults, credentialStore: store)
        restartedProcess.migrateLegacyPreferenceDomainsIfNeeded(from: [legacyDomain])
        XCTAssertEqual(restartedProcess.quarkCookie, "")
        XCTAssertNil(try store.read("quarkCookie"))
        XCTAssertEqual(restartedProcess.ucCookie, "other-provider-fixture")
    }

    func testMigrationScrubsEveryLegacyCopyWhenTargetAlreadyContainsTheCredential() throws {
        let domain = "CredentialMigrationEdgeTests.existingTarget.\(UUID().uuidString)"
        let oldDomains = (0..<2).map { "CredentialMigrationEdgeTests.extra.\($0).\(UUID().uuidString)" }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            for oldDomain in oldDomains { defaults.removePersistentDomain(forName: oldDomain) }
        }
        defaults.set("current-fixture", forKey: "quarkCookie")
        for oldDomain in oldDomains {
            defaults.setPersistentDomain([
                "quarkCookie": "older-fixture",
                "currentVodSiteKey": "keep-other-setting"
            ], forName: oldDomain)
        }
        let store = Store()
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)
        preferences.migrateLegacyPreferenceDomainsIfNeeded(from: oldDomains)

        XCTAssertEqual(preferences.quarkCookie, "current-fixture")
        XCTAssertEqual(try store.read("quarkCookie"), "current-fixture")
        for oldDomain in oldDomains {
            XCTAssertNil(defaults.persistentDomain(forName: oldDomain)?["quarkCookie"])
            XCTAssertEqual(
                defaults.persistentDomain(forName: oldDomain)?["currentVodSiteKey"] as? String,
                "keep-other-setting"
            )
        }
    }

    func testImportedCredentialScrubsAllLegacyCopiesAfterVerifiedMigration() throws {
        let domain = "CredentialMigrationEdgeTests.emptyTarget.\(UUID().uuidString)"
        let oldDomains = (0..<2).map { "CredentialMigrationEdgeTests.duplicate.\($0).\(UUID().uuidString)" }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            for oldDomain in oldDomains { defaults.removePersistentDomain(forName: oldDomain) }
        }
        for oldDomain in oldDomains {
            defaults.setPersistentDomain(["ucCookie": "legacy-fixture"], forName: oldDomain)
        }
        let preferences = UserPreferences(defaults: defaults, credentialStore: Store())
        preferences.migrateLegacyPreferenceDomainsIfNeeded(from: oldDomains)
        XCTAssertEqual(preferences.ucCookie, "legacy-fixture")
        for oldDomain in oldDomains {
            XCTAssertNil(defaults.persistentDomain(forName: oldDomain)?["ucCookie"])
        }
    }

    func testConcurrentCredentialWritesRemainScopedToTheirAccounts() throws {
        let domain = "CredentialMigrationEdgeTests.concurrent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = Store()
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)

        DispatchQueue.concurrentPerform(iterations: 64) { account in
            try? preferences.saveCredential("fixture-\(account)", for: "test-account-\(account)")
        }

        try preferences.checkCredentialPersistence()
        let restartedProcess = UserPreferences(defaults: defaults, credentialStore: store)
        for account in 0..<64 {
            XCTAssertEqual(restartedProcess.credential("test-account-\(account)"), "fixture-\(account)")
        }
    }
}
