import Foundation
import Storage
import Testing

@Suite("VOD skip settings store")
struct VodSkipSettingsStoreTests {
    @Test("keeps opening and ending skips isolated by series")
    func isolatesSettingsBySeries() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try #require(VodSkipSettingsIdentity(siteKey: "site-a", vodID: "vod-1"))
        let second = try #require(VodSkipSettingsIdentity(siteKey: "site-a", vodID: "vod-2"))
        let sameIDOnAnotherSite = try #require(
            VodSkipSettingsIdentity(siteKey: "site-b", vodID: "vod-1")
        )

        #expect(store.settings(for: first) == .empty)
        _ = store.save(openingSeconds: 42, endingSeconds: 75, for: first)

        #expect(store.settings(for: first) == VodSkipSettings(openingSeconds: 42, endingSeconds: 75))
        #expect(store.settings(for: second) == .empty)
        #expect(store.settings(for: sameIDOnAnotherSite) == .empty)
    }

    @Test("persists clamped settings and removes an empty series record")
    func persistsClampsAndClearsEmptySettings() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let identity = try #require(VodSkipSettingsIdentity(siteKey: "site-a", vodID: "vod-1"))
        let saved = store.save(openingSeconds: -5, endingSeconds: 900, for: identity)
        let reloadedStore = VodSkipSettingsStore(defaults: defaults)

        #expect(saved == VodSkipSettings(openingSeconds: 0, endingSeconds: 600))
        #expect(reloadedStore.settings(for: identity) == saved)

        _ = store.save(openingSeconds: 0, endingSeconds: 0, for: identity)
        #expect(reloadedStore.settings(for: identity) == .empty)
    }

    @Test("resolves playback metadata only when both series identity fields exist")
    func resolvesPlaybackMetadataIdentity() throws {
        let identity = try #require(
            VodSkipSettingsIdentity(playbackMetadata: [
                "vod.siteKey": " site-a ",
                "vod.id": " vod-1 "
            ])
        )

        #expect(identity == VodSkipSettingsIdentity(siteKey: "site-a", vodID: "vod-1"))
        #expect(VodSkipSettingsIdentity(playbackMetadata: ["vod.id": "vod-1"]) == nil)
        #expect(VodSkipSettingsIdentity(playbackMetadata: ["vod.siteKey": "site-a"]) == nil)
    }

    @Test("runtime playback paths do not read legacy global skip defaults")
    func runtimePathsUseSeriesScopedSettings() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = [
            packageRoot.appendingPathComponent("Sources/NetVplayerApp/AppState.swift"),
            packageRoot.appendingPathComponent("Sources/NetVplayerApp/Views/PlayerView.swift")
        ]
        let runtimeSource = try sources
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        #expect(!runtimeSource.contains("UserPreferences.shared.defaultOpeningSkip"))
        #expect(!runtimeSource.contains("UserPreferences.shared.defaultEndingSkip"))
        #expect(runtimeSource.contains("VodSkipSettingsStore.shared.settings"))
    }

    private func makeStore() -> (VodSkipSettingsStore, UserDefaults, String) {
        let suiteName = "VodSkipSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (VodSkipSettingsStore(defaults: defaults), defaults, suiteName)
    }
}
