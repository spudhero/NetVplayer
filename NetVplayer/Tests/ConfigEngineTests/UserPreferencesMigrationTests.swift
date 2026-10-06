import Foundation
import Testing
import Storage

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
