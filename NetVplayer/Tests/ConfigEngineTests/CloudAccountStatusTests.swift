import Foundation
import Models
import Storage
import Testing

@Suite("Cloud account status persistence")
struct CloudAccountStatusTests {
    @Test func authorizationSurvivesReopeningAndRemainsBoundToExactAccount() throws {
        let name = "cloud-account-status-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MemoryCredentialStore()
        let preferences = UserPreferences(defaults: defaults, credentialStore: store)
        #expect(preferences.cloudAccountStatus(for: .quark) == .disconnected)
        preferences.quarkCookie = "fixture-account-a"
        #expect(preferences.cloudAccountStatus(for: .quark) == .saved)
        preferences.markCloudAccountVerified(.quark)
        let reopened = UserPreferences(defaults: defaults, credentialStore: store)
        #expect(reopened.cloudAccountStatus(for: .quark) == .verified)
        #expect(reopened.cloudAccountStatus(for: .uc) == .disconnected)
        reopened.quarkCookie = "fixture-account-b"
        #expect(reopened.cloudAccountStatus(for: .quark) == .saved)
        reopened.quarkCookie = "fixture-account-a"
        #expect(reopened.cloudAccountStatus(for: .quark) == .saved)
        reopened.markCloudAccountVerified(.quark)
        reopened.quarkCookie = ""
        #expect(reopened.cloudAccountStatus(for: .quark) == .disconnected)
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains("fixture-account"))
    }

    @Test func tokenAccountsAndProviderSwitchesRetainIndependentStatus() throws {
        let name = "cloud-account-status-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UserPreferences(defaults: defaults)
        preferences.quarkTVRefreshToken = "fixture-tv"
        preferences.ucCookie = "fixture-uc"
        preferences.pikpakRefreshToken = "fixture-pikpak"
        preferences.markCloudAccountVerified(.quark)
        preferences.markCloudAccountVerified(.uc)
        #expect(preferences.cloudAccountStatus(for: .quark) == .verified)
        #expect(preferences.cloudAccountStatus(for: .pikpak) == .saved)
        preferences.ucCookie = ""
        #expect(preferences.cloudAccountStatus(for: .uc) == .disconnected)
        #expect(preferences.cloudAccountStatus(for: .quark) == .verified)
        #expect(preferences.cloudAccountStatus(for: .webdav) == .disconnected)
    }
}
