import Foundation
import XCTest
@testable import Storage

final class LocalCredentialStoreTests: XCTestCase {
    private final class LegacyReader: LegacyCredentialReader, @unchecked Sendable {
        var values: [String: String] = [:]
        var failure: CredentialStoreError?
        var reads = 0

        func read(_ key: String) throws -> String? {
            reads += 1
            if let failure { throw failure }
            return values[key]
        }
    }

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var messages: [String] = []
        func record(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            count += 1
            messages.append(String(describing: error))
        }
        var total: Int { lock.lock(); defer { lock.unlock() }; return count }
        var details: String { lock.lock(); defer { lock.unlock() }; return messages.joined(separator: ", ") }
    }

    private func withDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalCredentialStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }

    func testAccountsPersistAcrossInstancesWithEncryptedContentsAndPrivatePermissions() throws {
        try withDirectory { directory in
            let first = LocalCredentialStore(directory: directory)
            let second = LocalCredentialStore(directory: directory)
            try first.write("private-cookie-fixture", for: "quarkCookie")
            try second.write("private-token-fixture", for: "aliRefreshToken")
            XCTAssertEqual(try second.read("quarkCookie"), "private-cookie-fixture")
            XCTAssertEqual(try first.read("aliRefreshToken"), "private-token-fixture")

            let encrypted = try Data(contentsOf: directory.appendingPathComponent("accounts.v1.enc"))
            XCTAssertNil(encrypted.range(of: Data("private-cookie-fixture".utf8)))
            XCTAssertNil(encrypted.range(of: Data("private-token-fixture".utf8)))
            XCTAssertNil(encrypted.range(of: Data("quarkCookie".utf8)))
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            for name in ["accounts.v1.enc", "encryption.key", ".lock"] {
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: directory.appendingPathComponent(name).path
                )
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
        }
    }

    func testLegacyMigrationAndLogoutSurviveRestartWithoutResurrectingOldAccounts() throws {
        try withDirectory { directory in
            let legacy = LegacyReader()
            legacy.values = ["quarkCookie": "old-quark-fixture", "ucCookie": "old-uc-fixture"]
            let first = LocalCredentialStore(directory: directory, legacyReader: legacy)
            XCTAssertEqual(try first.read("quarkCookie"), "old-quark-fixture")
            XCTAssertEqual(try first.read("ucCookie"), "old-uc-fixture")
            XCTAssertEqual(legacy.reads, 2)
            try first.remove("quarkCookie")

            let restarted = LocalCredentialStore(directory: directory, legacyReader: legacy)
            XCTAssertNil(try restarted.read("quarkCookie"))
            XCTAssertEqual(try restarted.read("ucCookie"), "old-uc-fixture")
            XCTAssertEqual(legacy.reads, 2)
            XCTAssertEqual(legacy.values["quarkCookie"], "old-quark-fixture", "Migration must preserve legacy data")
        }
    }

    func testLegacyAuthorizationFailureIsNotRetriedByGettersAndNewSignInOverridesIt() throws {
        try withDirectory { directory in
            let legacy = LegacyReader()
            legacy.failure = .legacyAuthorizationRequired
            let store = LocalCredentialStore(directory: directory, legacyReader: legacy)
            for _ in 0..<5 {
                XCTAssertThrowsError(try store.read("quarkCookie")) { error in
                    XCTAssertEqual(error as? CredentialStoreError, .legacyAuthorizationRequired)
                }
            }
            XCTAssertEqual(legacy.reads, 1)

            try store.write("signed-in-again-fixture", for: "quarkCookie")
            XCTAssertEqual(try store.read("quarkCookie"), "signed-in-again-fixture")
            let restarted = LocalCredentialStore(directory: directory, legacyReader: legacy)
            XCTAssertEqual(try restarted.read("quarkCookie"), "signed-in-again-fixture")
            XCTAssertEqual(legacy.reads, 1)
        }
    }

    func testLegacyMissAndEmptyLogoutMarkerAreHandledWithoutRepeatedRequests() throws {
        try withDirectory { directory in
            let legacy = LegacyReader()
            legacy.values["ucCookie"] = ""
            let store = LocalCredentialStore(directory: directory, legacyReader: legacy)
            XCTAssertNil(try store.read("quarkCookie"))
            XCTAssertNil(try store.read("quarkCookie"))
            XCTAssertEqual(legacy.reads, 1)
            XCTAssertNil(try store.read("ucCookie"))
            legacy.values["ucCookie"] = "must-not-resurrect-fixture"
            XCTAssertNil(try LocalCredentialStore(directory: directory, legacyReader: legacy).read("ucCookie"))
            XCTAssertEqual(legacy.reads, 2)
        }
    }

    func testCorruptedCiphertextIsNotOverwrittenAndEncryptionKeyIsPreserved() throws {
        try withDirectory { directory in
            let store = LocalCredentialStore(directory: directory)
            try store.write("original-fixture", for: "quarkCookie")
            let vault = directory.appendingPathComponent("accounts.v1.enc")
            let key = directory.appendingPathComponent("encryption.key")
            let originalKey = try Data(contentsOf: key)
            var corrupted = try Data(contentsOf: vault)
            corrupted[corrupted.count - 1] ^= 1
            try corrupted.write(to: vault)

            let restarted = LocalCredentialStore(directory: directory)
            XCTAssertThrowsError(try restarted.read("quarkCookie"))
            XCTAssertThrowsError(try restarted.write("replacement-fixture", for: "quarkCookie"))
            XCTAssertEqual(try Data(contentsOf: vault), corrupted)
            XCTAssertEqual(try Data(contentsOf: key), originalKey)
        }
    }

    func testMissingKeyDoesNotGenerateReplacementOrEraseExistingAccounts() throws {
        try withDirectory { directory in
            let store = LocalCredentialStore(directory: directory)
            try store.write("original-fixture", for: "quarkCookie")
            let vault = directory.appendingPathComponent("accounts.v1.enc")
            let key = directory.appendingPathComponent("encryption.key")
            let originalVault = try Data(contentsOf: vault)
            try FileManager.default.removeItem(at: key)

            let restarted = LocalCredentialStore(directory: directory)
            XCTAssertThrowsError(try restarted.read("quarkCookie"))
            XCTAssertThrowsError(try restarted.write("replacement-fixture", for: "quarkCookie"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: key.path))
            XCTAssertEqual(try Data(contentsOf: vault), originalVault)
        }
    }

    func testConcurrentWritersDoNotLoseAccounts() throws {
        try withDirectory { directory in
            let failures = Failures()
            DispatchQueue.concurrentPerform(iterations: 20) { index in
                do {
                    try LocalCredentialStore(directory: directory).write("fixture-\(index)", for: "account-\(index)")
                } catch { failures.record(error) }
            }
            XCTAssertEqual(failures.total, 0, failures.details)
            let restarted = LocalCredentialStore(directory: directory)
            for index in 0..<20 {
                XCTAssertEqual(try restarted.read("account-\(index)"), "fixture-\(index)")
            }
        }
    }

    func testSymlinkedKeyIsRejectedWithoutChangingItsTarget() throws {
        try withDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let externalKey = directory.appendingPathComponent("external-key")
            let contents = Data(repeating: 0x42, count: 32)
            try contents.write(to: externalKey)
            try FileManager.default.createSymbolicLink(
                at: directory.appendingPathComponent("encryption.key"), withDestinationURL: externalKey
            )
            XCTAssertThrowsError(try LocalCredentialStore(directory: directory).write("fixture", for: "quarkCookie"))
            XCTAssertEqual(try Data(contentsOf: externalKey), contents)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("accounts.v1.enc").path))
        }
    }

    func testPublic112PlaintextMigrationPreservesSignInWithoutReadingLegacyKeychain() throws {
        try withDirectory { directory in
            let domain = "LocalCredentialStoreTests.preferences.\(UUID().uuidString)"
            let historicalDomain = "LocalCredentialStoreTests.old-preferences.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer {
                defaults.removePersistentDomain(forName: domain)
                defaults.removePersistentDomain(forName: historicalDomain)
            }
            let fixtures = [
                "quarkCookie": "public112-quark-fixture",
                "ucCookie": "public112-uc-fixture",
                "aliRefreshToken": "public112-ali-fixture"
            ]
            defaults.set(fixtures["quarkCookie"], forKey: "quarkCookie")
            var oldPreferences = fixtures
            oldPreferences["currentVodConfigUrl"] = "https://config.example/source.json"
            defaults.setPersistentDomain(oldPreferences, forName: historicalDomain)

            let legacy = LegacyReader()
            legacy.failure = .legacyAuthorizationRequired
            let store = LocalCredentialStore(directory: directory, legacyReader: legacy)
            let preferences = UserPreferences(defaults: defaults, credentialStore: store)
            // Follow startup's public-version migration before any business getter.
            preferences.migrateLegacyPreferenceDomainsIfNeeded(from: [historicalDomain])
            try preferences.retryCredentialPersistence()

            let restarted = UserPreferences(
                defaults: defaults,
                credentialStore: LocalCredentialStore(directory: directory, legacyReader: legacy)
            )
            let snapshot = try JSONEncoder().encode(UserPreferenceSnapshot(preferences: preferences))
            for (key, value) in fixtures {
                XCTAssertNil(defaults.string(forKey: key))
                XCTAssertNil(defaults.persistentDomain(forName: historicalDomain)?[key])
                XCTAssertEqual(try store.read(key), value)
                XCTAssertEqual(restarted.credential(key), value)
                XCTAssertNil(snapshot.range(of: Data(value.utf8)))
            }
            XCTAssertEqual(preferences.currentVodConfigUrl, "https://config.example/source.json")
            XCTAssertEqual(defaults.persistentDomain(forName: historicalDomain)?["currentVodConfigUrl"] as? String,
                           "https://config.example/source.json")
            XCTAssertNoThrow(try restarted.checkCredentialPersistence())
            XCTAssertEqual(legacy.reads, 0, "Public 1.0.12 accounts must bypass legacy Keychain migration")
        }
    }
}
