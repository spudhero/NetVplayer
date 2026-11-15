import Foundation
import Testing
import Models
import Storage
import DriveEngine

@Suite("Cloud directory playback credential refresh")
struct CloudDirectoryCredentialRefreshTests {
    @Test(arguments: [DriveProvider.quark, .uc, .p115])
    func cookiePlaybackRefreshPreservesDirectoryBinding(_ provider: DriveProvider) throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let original = try fixture.cookie(provider, value: "saved-cookie")
        let before = try fixture.preferences.cloudDirectoryAccount(provider)
        let refresh = try #require(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences))
        var updated = original; updated.secret = "refreshed-cookie"
        #expect(refresh.save(updated))
        let after = try fixture.preferences.cloudDirectoryAccount(provider)
        #expect(after.binding == before.binding)
        #expect(after.values[fixture.cookieKey(provider)] == "refreshed-cookie")
        if provider == .p115 { #expect(after.values["p115AccessToken"] == "saved-access") }
    }

    @Test(arguments: [DriveProvider.quark, .uc, .p115])
    func delayedPlaybackCannotOverwriteNewAccount(_ provider: DriveProvider) throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let original = try fixture.cookie(provider, value: "old-account")
        let refresh = try #require(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences))
        try fixture.preferences.saveCredential("new-account", for: fixture.cookieKey(provider))
        let replacement = try fixture.preferences.cloudDirectoryAccount(provider)
        var late = original; late.secret = "late-old-account-refresh"
        #expect(!refresh.save(late))
        #expect(try fixture.preferences.cloudDirectoryAccount(provider) == replacement)
    }

    @Test(arguments: [DriveProvider.quark, .uc, .p115])
    func environmentCredentialsDoNotAdoptTheSavedAccount(_ provider: DriveProvider) throws {
        let fixture = Fixture(); defer { fixture.clean() }
        var original = try fixture.cookie(provider, value: "saved-account")
        let before = try fixture.preferences.cloudDirectoryAccount(provider)
        original.secret = "environment-account"
        #expect(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences) == nil)
        #expect(try fixture.preferences.cloudDirectoryAccount(provider) == before)
    }

    @Test func duplicateResponsesAreIdempotentAndOlderResponsesDoNotRollBack() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let original = try fixture.cookie(.quark, value: "original")
        let before = try fixture.preferences.cloudDirectoryAccount(.quark)
        let first = try #require(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences))
        let duplicate = try #require(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences))
        let old = try #require(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences))
        let accepted = CloudCredential.cookie(provider: .quark, value: "accepted-refresh")
        #expect(first.save(accepted))
        #expect(duplicate.save(accepted))
        _ = old.save(.cookie(provider: .quark, value: "late-different-refresh"))
        let after = try fixture.preferences.cloudDirectoryAccount(.quark)
        #expect(after.binding == before.binding)
        #expect(after.values["quarkCookie"] == "accepted-refresh")
    }

    @Test func aliPlaybackRefreshUpdatesTokensAndMetadataWithoutChangingBinding() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let original = try fixture.ali(prefix: "before")
        let before = try fixture.preferences.cloudDirectoryAccount(.ali)
        let refresh = try #require(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences))
        let updated = fixture.aliCredential(prefix: "after")
        #expect(refresh.save(updated))
        #expect(refresh.save(updated))
        let after = try fixture.preferences.cloudDirectoryAccount(.ali)
        #expect(after.binding == before.binding)
        #expect(after.values["aliRefreshToken"] == "after-refresh")
        #expect(after.values["aliAccessToken"] == "after-access")
        #expect(after.values["aliDefaultDriveID"] == "after-drive")
        #expect(after.values["aliAuthDomain"] == "after-domain")
        #expect(after.values["aliUserID"] == "after-user")
        #expect(fixture.preferences.aliOpenToken == "after-open")
        #expect(after.values["aliOpenToken"] == nil)
    }

    @Test func aliAccountSwitchRejectsAllLateTokensIncludingOpenToken() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let original = try fixture.ali(prefix: "old")
        let refresh = try #require(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences))
        _ = try fixture.ali(prefix: "replacement")
        let replacement = try fixture.preferences.cloudDirectoryAccount(.ali)
        #expect(!refresh.save(fixture.aliCredential(prefix: "late")))
        #expect(try fixture.preferences.cloudDirectoryAccount(.ali) == replacement)
        #expect(fixture.preferences.aliOpenToken == "replacement-open")
    }

    @Test func aliEnvironmentOverridesCannotPublishIntoTheSavedAccount() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let original = try fixture.ali(prefix: "saved")
        let before = try fixture.preferences.cloudDirectoryAccount(.ali)
        for key in ["refresh", "access", "open"] {
            var environment = original
            switch key {
            case "refresh": environment.refreshToken = "environment-refresh"
            case "access": environment.accessToken = "environment-access"
            default: environment.metadata["open_token"] = "environment-open"
            }
            #expect(CloudDirectoryCredentialRefresh(original: environment, preferences: fixture.preferences) == nil)
        }
        #expect(try fixture.preferences.cloudDirectoryAccount(.ali) == before)
        #expect(fixture.preferences.aliOpenToken == "saved-open")
    }

    @Test func replacingOnlyAliOpenTokenRejectsTheLateResponseBeforeAnyWrite() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let original = try fixture.ali(prefix: "saved")
        let before = try fixture.preferences.cloudDirectoryAccount(.ali)
        let refresh = try #require(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences))
        try fixture.preferences.saveCredential("replacement-open", for: "aliOpenToken")
        #expect(try fixture.preferences.cloudDirectoryAccount(.ali) == before)
        #expect(!refresh.save(fixture.aliCredential(prefix: "late")))
        #expect(try fixture.preferences.cloudDirectoryAccount(.ali) == before)
        #expect(fixture.preferences.aliOpenToken == "replacement-open")
    }

    @Test func repeatedOpenTokenOnlyRefreshIsIdempotent() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let original = try fixture.ali(prefix: "saved")
        let before = try fixture.preferences.cloudDirectoryAccount(.ali)
        let refresh = try #require(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences))
        var updated = original; updated.metadata["open_token"] = "refreshed-open"
        #expect(refresh.save(updated))
        #expect(refresh.save(updated))
        #expect(try fixture.preferences.cloudDirectoryAccount(.ali) == before)
        #expect(fixture.preferences.aliOpenToken == "refreshed-open")
    }

    @Test func p115EnvironmentAccessTokenCannotPublishIntoTheSavedAccount() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        var original = try fixture.cookie(.p115, value: "saved")
        let before = try fixture.preferences.cloudDirectoryAccount(.p115)
        original.metadata["access_token"] = "environment-access"
        #expect(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences) == nil)
        #expect(try fixture.preferences.cloudDirectoryAccount(.p115) == before)
    }

    @Test func invalidResponseCannotClearCredentialsOrChangeProvider() throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let original = try fixture.cookie(.uc, value: "saved")
        let before = try fixture.preferences.cloudDirectoryAccount(.uc)
        let refresh = try #require(CloudDirectoryCredentialRefresh(original: original, preferences: fixture.preferences))
        #expect(!refresh.save(.cookie(provider: .uc, value: "  ")))
        #expect(!refresh.save(.cookie(provider: .quark, value: "different-provider")))
        #expect(try fixture.preferences.cloudDirectoryAccount(.uc) == before)
    }

    private struct Fixture {
        let domain: String
        let defaults: UserDefaults
        let preferences: UserPreferences
        init() {
            domain = "CloudDirectoryRefreshTests." + UUID().uuidString
            defaults = UserDefaults(suiteName: domain)!
            preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        }
        func clean() { defaults.removePersistentDomain(forName: domain) }
        func cookieKey(_ provider: DriveProvider) -> String {
            provider == .p115 ? "p115Cookie" : provider.rawValue + "Cookie"
        }
        func cookie(_ provider: DriveProvider, value: String) throws -> CloudCredential {
            try preferences.saveCredential(value, for: cookieKey(provider))
            var credential = CloudCredential.cookie(provider: provider, value: value)
            if provider == .p115 {
                try preferences.saveCredential("saved-access", for: "p115AccessToken")
                credential.metadata["access_token"] = "saved-access"
            }
            return credential
        }
        func aliCredential(prefix: String) -> CloudCredential {
            .init(provider: .ali, kind: .refreshToken, secret: prefix + "-access",
                  refreshToken: prefix + "-refresh", accessToken: prefix + "-access",
                  metadata: ["open_token": prefix + "-open", "default_drive_id": prefix + "-drive",
                             "ali_auth_domain": prefix + "-domain", "user_id": prefix + "-user"])
        }
        func ali(prefix: String) throws -> CloudCredential {
            let credential = aliCredential(prefix: prefix)
            try preferences.saveCredential(credential.refreshToken!, for: "aliRefreshToken")
            try preferences.saveCredential(credential.accessToken!, for: "aliAccessToken")
            try preferences.saveCredential(credential.metadata["open_token"]!, for: "aliOpenToken")
            preferences.aliDefaultDriveID = credential.metadata["default_drive_id"]!
            preferences.aliAuthDomain = credential.metadata["ali_auth_domain"]!
            preferences.aliUserID = credential.metadata["user_id"]!
            return credential
        }
    }
}
