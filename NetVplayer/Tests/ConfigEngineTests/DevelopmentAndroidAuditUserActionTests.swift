import AppKit
import Foundation
import Models
import SpiderEngine
import Storage
import Testing
@testable import NetVplayerApp

@Suite("Android audit user action stops", .serialized)
@MainActor
struct DevelopmentAndroidAuditUserActionTests {
    @Test(arguments: ["home", "detail", "player"], [false, true])
    func interactionEndsSamplesReplaysAndSources(stage: String, authentication: Bool) async throws {
        _ = NSApplication.shared
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sharedHealth = try encoder.encode(SiteHealthStore.shared.allEvents())
        let suite = "AuditUserAction.\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!, credentialStore: MemoryCredentialStore())
        preferences.providerExecutionPreference = .macPreferred
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: root.appendingPathComponent("state")),
            userPreferences: preferences, providerRuntimeBootstrap: nil,
            androidProviderRegistrationOverride: { _ in }, catalogRepository: CatalogRepository())
        let sites = ["first", "second"].map { Site(key: suite + "." + $0, type: 3, api: "csp_" + suite + "." + $0) }
        let firstKey = sites[0].key
        let provider = AuditUserActionProvider { [weak state] key, operation in
            guard key == firstKey, operation == stage, let state else { return }
            if authentication {
                state.cloudAuthRequest = .init(provider: .uc)
            } else {
                state.playbackVerificationRequest = .init(interaction: PlaybackInteraction(
                    kind: .manualVerification, url: "https://verification.invalid/fixture", message: "Fixture"),
                    episode: Episode(name: "Fixture", url: "fixture-episode"))
            }
        }
        for site in sites {
            await SpiderReplacementRegistry.shared.register(originalKey: site.key, originalAPI: site.api, provider: provider)
        }
        let config = root.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: ["sites": sites.map {
            ["key": $0.key, "type": 3, "api": $0.api] as [String: Any]
        }]).write(to: config)
        let output = root.appendingPathComponent("audit")
        let plan = try JSONDecoder().decode(DevelopmentAndroidAppAudit.Plan.self, from: JSONSerialization.data(withJSONObject: [
            "config": config.path, "output": output.path, "only": sites.map(\.key),
            "providerExecutionPreference": "macPreferred", "homeOnly": true,
            "sampleCount": 3, "allSelectedSamples": true, "singlePlaybackAttempt": true, "performanceReplays": 2
        ]))
        await DevelopmentAndroidAppAudit.run(plan, state: state)
        let ledger = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            output.appendingPathComponent("app-audit.json"))) as? [String: Any])
        #expect(ledger["status"] as? String == "stopped_user_action")
        #expect(ledger["authentication_required"] as? Bool == authentication)
        #expect(ledger["verification_required"] as? Bool == !authentication)
        #expect(ledger["failure_stage"] as? String == (authentication ? "authentication_required" : "verification_required"))
        let records = try #require(ledger["sites"] as? [[String: Any]])
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record["performance_round"] as? Int == 0)
        #expect(record["status"] as? String == "stopped_user_action")
        #expect(record["all_samples_played"] as? Bool == false)
        let attempts = try #require(record["attempts"] as? [[String: Any]])
        #expect(attempts.count == (stage == "home" ? 0 : 1))
        if let attempt = attempts.first {
            #expect(attempt["status"] as? String == "stopped_user_action")
            #expect(attempt["authentication_required"] as? Bool == authentication)
            #expect(attempt["verification_required"] as? Bool == !authentication)
        }
        let calls = await provider.calls()
        #expect(calls[sites[1].key] == nil)
        #expect(calls[firstKey] == (stage == "home" ? ["home"] : stage == "detail" ? ["home", "detail"] : ["home", "detail", "player"]))
        #expect(state.allowsAutomaticVodPlaybackActions)
        SiteHealthStore.shared.flushPendingWrites()
        #expect(try encoder.encode(SiteHealthStore.shared.allEvents()) == sharedHealth)
        print("[AUDIT_USER_ACTION_STOP] stage=\(stage) authentication=\(authentication) sources=\(records.count) samples=\(attempts.count) calls=\(calls[firstKey] ?? [])")
        await state.cancelLoading()
    }
}

private actor AuditUserActionProvider: SiteContentProvider {
    let observe: @MainActor @Sendable (String, String) -> Void
    private var requests = [String: [String]]()
    init(observe: @escaping @MainActor @Sendable (String, String) -> Void) { self.observe = observe }
    func calls() -> [String: [String]] { requests }
    private func request(_ site: Site, _ operation: String) async {
        requests[site.key, default: []].append(operation)
        await observe(site.key, operation)
    }
    func homeContent(site: Site) async throws -> Models.Result {
        await request(site, "home")
        return Models.Result(list: (0..<3).map { Vod(vodId: "fixture-\($0)", vodName: "Fixture \($0)") })
    }
    func detailContent(site: Site, id: String) async throws -> Models.Result {
        await request(site, "detail")
        return Models.Result(list: [Vod(vodId: id, vodName: "Fixture", vodPlayFrom: "original", vodPlayUrl: "one$fixture-episode")])
    }
    func playerContent(site: Site, flag: String, id: String) async throws -> Models.Result {
        await request(site, "player")
        return .empty
    }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Models.Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Models.Result { .empty }
}
