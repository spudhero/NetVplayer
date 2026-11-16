import Foundation
import Models
import Storage
import Testing
@testable import NetVplayerApp

@Suite("Provider execution preference", .serialized)
struct ProviderExecutionPreferenceTests {
    @Test func persistsTwoImplementationsAndMigratesLegacyAutomatic() throws {
        let name = "netvplayer-provider-preference-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UserPreferences(defaults: defaults)
        #expect(preferences.providerExecutionPreference == .macPreferred)
        defaults.set("automatic", forKey: ProviderExecutionPreference.storageKey)
        #expect(preferences.providerExecutionPreference == .macPreferred)
        #expect(ProviderExecutionPreference.allCases == [.macPreferred, .androidPreferred])
        for mode in ProviderExecutionPreference.allCases {
            preferences.providerExecutionPreference = mode
            #expect(UserPreferences(defaults: defaults).providerExecutionPreference == mode)
        }
        defaults.set("future-unsupported-backend", forKey: ProviderExecutionPreference.storageKey)
        #expect(preferences.providerExecutionPreference == .macPreferred)
    }

    @MainActor @Test func preferenceChangesTakeEffectOnlyInANewSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "netvplayer-provider-session-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults)
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: directory), userPreferences: preferences)
        state.preferredProviderExecution = .androidPreferred
        #expect(state.activeProviderExecutionPreference == .macPreferred)
        #expect(state.providerExecutionRequiresRestart)
        #expect(preferences.providerExecutionPreference == .androidPreferred)
        let next = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: directory), userPreferences: preferences)
        #expect(next.activeProviderExecutionPreference == .androidPreferred)
        #expect(!next.providerExecutionRequiresRestart)
        state.preferredProviderExecution = .macPreferred
        #expect(!state.providerExecutionRequiresRestart)
    }

    @Test func opaqueLibraryIDsAreSeparatedBetweenExecutionPaths() {
        let site = Site(key: "same-source", name: "Same source", type: 3, api: "csp_SharedGuard")
        let url = "https://config.example.test/provider"
        let original = LibrarySourceIdentity.fingerprint(configurationURL: url, site: site)
        let fingerprints = ProviderExecutionPreference.allCases.map {
            LibrarySourceIdentity.fingerprint(configurationURL: url, site: site, executionPreference: $0)
        }
        #expect(!fingerprints.contains(original))
        #expect(Set(fingerprints).count == 2)
        #expect(Set(fingerprints.map { LibrarySourceIdentity.key(source: $0, siteKey: site.key, vodID: "same-opaque-id") }).count == 2)
        let cms = Site(key: "cms", name: "CMS", type: 1, api: "https://cms.example.test")
        #expect(Set(ProviderExecutionPreference.allCases.map {
            LibrarySourceIdentity.fingerprint(configurationURL: url, site: cms, executionPreference: $0)
        }).count == 1)
        #expect(LibrarySourceIdentity.fingerprint(configurationURL: "", site: site, executionPreference: .androidPreferred).isEmpty)
    }

    #if DEBUG
    @Test func auditPreferenceOverrideDoesNotChangeUserSetting() throws {
        let name = "netvplayer-provider-isolation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UserPreferences(defaults: defaults)
        preferences.providerExecutionPreference = .macPreferred
        let session = preferences.makeIsolatedSnapshot()
        defer { session.discardIsolatedSnapshot() }
        session.providerExecutionPreference = .androidPreferred
        #expect(preferences.providerExecutionPreference == .macPreferred)
        #expect(session.providerExecutionPreference == .androidPreferred)
    }
    #endif
}
