import Foundation
import Testing
import Storage

@Test func auditSnapshotDoesNotRegisterFallbacksOrModifyLegacyDomains() throws {
    let domain = "AuditSnapshotTests." + UUID().uuidString
    let legacyDomain = domain + ".legacy"
    let unrelatedDomain = domain + ".unrelated"
    let defaults = try #require(UserDefaults(suiteName: domain))
    let unrelated = try #require(UserDefaults(suiteName: unrelatedDomain))
    let marker = domain + ".marker"
    defer {
        defaults.removePersistentDomain(forName: domain)
        defaults.removePersistentDomain(forName: legacyDomain)
        unrelated.removePersistentDomain(forName: unrelatedDomain)
    }
    defaults.set("snapshot-only", forKey: marker)
    defaults.set("original-site", forKey: "currentVodSiteKey")
    defaults.set("fixture-legacy-cookie", forKey: "quarkCookie")
    defaults.set([legacyDomain], forKey: "credentialLegacyDomains.quarkCookie")
    defaults.setPersistentDomain(["quarkCookie": "fixture-legacy-cookie"], forName: legacyDomain)
    let source = UserPreferences(defaults: defaults)
    let snapshot = source.makeIsolatedSnapshot()
    defer { snapshot.discardIsolatedSnapshot() }

    #expect(snapshot.currentVodSiteKey == "original-site")
    #expect(snapshot.quarkCookie == "fixture-legacy-cookie")
    snapshot.currentVodSiteKey = "audit-site"
    snapshot.defaultPlaybackSpeed = 1.5
    snapshot.subtitleFontSize = 36
    #expect(snapshot.defaultPlaybackSpeed == 1.5)
    #expect(snapshot.subtitleFontSize == 36)
    #expect(source.currentVodSiteKey == "original-site")
    #expect(defaults.string(forKey: "quarkCookie") == "fixture-legacy-cookie")
    #expect(defaults.persistentDomain(forName: legacyDomain)?["quarkCookie"] as? String == "fixture-legacy-cookie")
    #expect(unrelated.object(forKey: marker) == nil)
    let empty = UserPreferences.makeEmptyIsolatedSession()
    defer { empty.discardIsolatedSnapshot() }
    #expect(empty.currentVodSiteKey.isEmpty)
    #expect(empty.quarkCookie.isEmpty)
    snapshot.discardIsolatedSnapshot()
    #expect(snapshot.currentVodSiteKey.isEmpty)
}

@Test func accountFreeAuditPreferencesKeepAccountsAndSelectionsIndependent() throws {
    let first = UserPreferences.makeEmptyIsolatedSession()
    let second = UserPreferences.makeEmptyIsolatedSession()
    let snapshot = second.makeIsolatedSnapshot()
    defer {
        first.discardIsolatedSnapshot()
        second.discardIsolatedSnapshot()
        snapshot.discardIsolatedSnapshot()
    }
    first.currentVodSiteKey = "saved-source"
    first.quarkCookie = "fixture-only-private-cookie"
    first.aliRefreshToken = "fixture-only-refresh-token"
    #expect(second.currentVodSiteKey.isEmpty)
    #expect(second.quarkCookie.isEmpty)
    #expect(second.aliRefreshToken.isEmpty)
    #expect(snapshot.quarkCookie.isEmpty)
    #expect(snapshot.aliRefreshToken.isEmpty)
    snapshot.quarkCookie = "different-session-cookie"
    #expect(second.quarkCookie.isEmpty)
    #expect(first.quarkCookie == "fixture-only-private-cookie")
}

@Test func legacyPreferenceMigrationRestoresMissingValuesWithoutOverwritingCurrentSettings() throws {
    let targetDomain = "UserPreferencesMigrationTests.target.\(UUID().uuidString)"
    let legacyPrimary = "UserPreferencesMigrationTests.primary.\(UUID().uuidString)"
    let legacyFallback = "UserPreferencesMigrationTests.fallback.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: targetDomain))
    defer {
        defaults.removePersistentDomain(forName: targetDomain)
        defaults.removePersistentDomain(forName: legacyPrimary)
        defaults.removePersistentDomain(forName: legacyFallback)
    }

    defaults.set(false, forKey: "webHomeEnabled")
    defaults.setPersistentDomain([
        "currentVodConfigUrl": "https://legacy.example/config.json",
        "speedDirectEasterEggEnabled": true,
        "webHomeEnabled": true,
        "NSWindow Frame Main": "legacy-frame"
    ], forName: legacyPrimary)
    defaults.setPersistentDomain([
        "currentVodConfigUrl": "https://older.example/config.json",
        "defaultPlaybackSpeed": 1.5
    ], forName: legacyFallback)

    let preferences = UserPreferences(defaults: defaults)
    let migratedCount = preferences.migrateLegacyPreferenceDomainsIfNeeded(
        from: [legacyPrimary, legacyFallback]
    )

    #expect(migratedCount == 3)
    #expect(preferences.currentVodConfigUrl == "https://legacy.example/config.json")
    #expect(preferences.speedDirectEasterEggEnabled)
    #expect(preferences.defaultPlaybackSpeed == 1.5)
    #expect(!preferences.webHomeEnabled)
    #expect(defaults.object(forKey: "NSWindow Frame Main") == nil)
    #expect(preferences.migrateLegacyPreferenceDomainsIfNeeded(from: [legacyPrimary, legacyFallback]) == 0)
}

@Test func cloudDriveAutoDeletePreferencesRemainIndependentByProvider() throws {
    let domain = "UserPreferencesMigrationTests.cloudCleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }

    let preferences = UserPreferences(defaults: defaults)
    preferences.setCloudDriveAutoDeleteSavedFiles(true, providerID: "quark")
    preferences.setCloudDriveAutoDeleteSavedFiles(false, providerID: "uc")
    preferences.setCloudDriveAutoDeleteSavedFiles(true, providerID: "ali")

    #expect(preferences.quarkAutoDeleteSavedFiles)
    #expect(!preferences.cloudDriveAutoDeleteSavedFiles(providerID: "uc"))
    #expect(preferences.cloudDriveAutoDeleteSavedFiles(providerID: "ali"))
    #expect(!preferences.cloudDriveAutoDeleteSavedFiles(providerID: "p115"))

    preferences.quarkAutoDeleteSavedFiles = false
    #expect(!preferences.cloudDriveAutoDeleteSavedFiles(providerID: "quark"))
    #expect(preferences.cloudDriveAutoDeleteSavedFiles(providerID: "ali"))
}

@Test func selectedVodSiteKeyPersists() throws {
    let domain = "UserPreferencesMigrationTests.vodSite.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }

    let preferences = UserPreferences(defaults: defaults)
    #expect(preferences.currentVodSiteKey.isEmpty)

    preferences.currentVodSiteKey = "favorite-site"

    #expect(UserPreferences(defaults: defaults).currentVodSiteKey == "favorite-site")
}
