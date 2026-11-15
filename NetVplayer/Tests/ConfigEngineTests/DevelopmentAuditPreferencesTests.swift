import Foundation
import Models
import Storage
import DriveEngine
import Testing

#if DEBUG
struct DevelopmentAuditPreferencesTests {
    @Test func playbackRefreshAndDirectoryBindingStayInsideAuditSession() throws {
        let name = "com.netvplayer.test.audit-preservation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MemoryCredentialStore()
        store.write("original-cookie", for: "quarkCookie")
        let originalID = UUID().uuidString
        defaults.set(originalID, forKey: "cloudDirectoryAccount.v1.quark.id")
        defaults.set("previous-digest", forKey: "cloudDirectoryAccount.v1.quark.digest")
        defaults.set("aurora-violet", forKey: "appearanceThemeID")
        let before = defaults.persistentDomain(forName: name)!
        let original = UserPreferences(defaults: defaults, credentialStore: store)
        let session = original.makeIsolatedSnapshot()
        defer { session.discardIsolatedSnapshot() }

        #expect(session.credential("quarkCookie") == "original-cookie")
        let refresh = try #require(CloudDirectoryCredentialRefresh(
            original: .cookie(provider: .quark, value: "original-cookie"), preferences: session))
        #expect(refresh.save(.cookie(provider: .quark, value: "refreshed-cookie")))
        #expect(session.credential("quarkCookie") == "refreshed-cookie")
        #expect(store.read("quarkCookie") == "original-cookie")
        #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: name)!).isEqual(to: before))
    }

    @Test func auditLogoutDoesNotRevealOrRemoveOriginalCredential() throws {
        let name = "com.netvplayer.test.audit-logout." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MemoryCredentialStore()
        store.write("original-cookie", for: "ucCookie")
        let original = UserPreferences(defaults: defaults, credentialStore: store)
        let session = original.makeIsolatedSnapshot()
        defer { session.discardIsolatedSnapshot() }
        try session.saveCredential("", for: "ucCookie")
        #expect(session.credential("ucCookie").isEmpty)
        #expect(store.read("ucCookie") == "original-cookie")
    }
}
#endif
