#if DEBUG
import Foundation
import Models
import ProviderRuntime
import ProviderSDK
import SpiderEngine
import Storage
import Testing
@testable import NetVplayerApp

@Test func auditStartsWithTheRequestedSourceEvenWhenConfigurationOrderDiffers() {
    #expect(DevelopmentAndroidAuditContract.sourceOrder(available: ["one", "two", "three"],
        requested: ["three", "one", "three"]) == ["three", "one"])
    #expect(DevelopmentAndroidAuditContract.sourceOrder(available: ["one", "two"], requested: nil) == ["one", "two"])
}

@Test func auditEmptyOrFailedHomeCannotBecomePositiveInventory() {
    func status(items: Int, error: String? = nil, failed: Bool = false, completed: Bool = true) -> String {
        DevelopmentAndroidAuditContract.catalogStatus(completed: completed, isCurrentSite: true,
            error: error, items: items, requestFailed: failed)
    }
    #expect(status(items: 0) == "catalog_empty")
    #expect(status(items: 18, error: "upstream unavailable") == "catalog_error")
    // A failed refresh retains old cards in the normal UI. Those cards cannot
    // prove this request succeeded even when the user-facing error is hidden.
    #expect(status(items: 18, failed: true) == "catalog_error")
    #expect(status(items: 18, completed: false) == "catalog_incomplete")
    #expect(status(items: 18) == "catalog_observed")
}

@Test func auditDetailFailureRetainsTheActualFailedStage() {
    #expect(DevelopmentAndroidAuditContract.detailFailure(presented: false, hasDetail: false,
        episodes: 0, requestedIndex: 0) == "detail_missing")
    #expect(DevelopmentAndroidAuditContract.detailFailure(presented: true, hasDetail: true,
        episodes: 0, requestedIndex: 0) == "detail_no_episodes")
    #expect(DevelopmentAndroidAuditContract.detailFailure(presented: true, hasDetail: true,
        episodes: 60, requestedIndex: 60) == "requested_episode_missing")
    #expect(DevelopmentAndroidAuditContract.detailFailure(presented: true, hasDetail: true,
        episodes: 60, requestedIndex: 0) == nil)
}

@MainActor
@Test func audioExpectationIsExplicitAndDoesNotChangeWhenSourceIsRenamed() throws {
    for key in ["MTV1", "arbitrary-renamed-source"] {
        let plan = try JSONDecoder().decode(DevelopmentAndroidAppAudit.Plan.self, from: Data(
            "{\"config\":\"/fixture/config\",\"output\":\"/fixture/out\",\"only\":[\"\(key)\"],\"requiredOutput\":\"audio\"}".utf8))
        let output = try #require(plan.requiredOutput)
        #expect(output.accepts(audioDecoded: true, videoDecoded: false, separateAudio: false))
        #expect(!output.accepts(audioDecoded: false, videoDecoded: true, separateAudio: false))
        #expect(!output.accepts(audioDecoded: true, videoDecoded: false, separateAudio: true))
    }
    #expect(!DevelopmentAndroidAuditContract.RequiredOutput.audioAndVideo.accepts(
        audioDecoded: true, videoDecoded: false, separateAudio: false))
}

@MainActor
@Test func performanceReplayPlanIsOptInAndBounded() throws {
    for (value, expected) in [("null", 0), ("-1", 0), ("1", 1), ("999", 3)] {
        let input = "{\"config\":\"/fixture/config\",\"output\":\"/fixture/out\",\"performanceReplays\":\(value)}"
        let plan = try JSONDecoder().decode(DevelopmentAndroidAppAudit.Plan.self, from: Data(input.utf8))
        #expect(plan.performanceReplayCount == expected)
    }
}

@Test func inputIdentityIgnoresFormattingButPreservesArrayOrderAndPayloadChanges() throws {
    func hash(_ json: String) throws -> String {
        try DevelopmentAndroidLifecycleDiagnostics.canonicalJSONSHA256(Data(json.utf8))
    }
    #expect(try hash(#"{"sites":["one","two"],"jar":"original"}"#)
        == hash("{\n  \"jar\": \"original\", \"sites\": [\"one\", \"two\"]\n}"))
    #expect(try hash(#"{"sites":["one","two"],"jar":"original"}"#)
        != hash(#"{"sites":["two","one"],"jar":"original"}"#))
    #expect(try hash(#"{"sites":["one","two"],"jar":"original"}"#)
        != hash(#"{"sites":["one","two"],"jar":"updated"}"#))
}

@Test func originalFailureLedgerRetainsClassAndStageWithoutErrorValues() throws {
    let error = ProviderErrorPayload(code: "provider_error", message: "Cookie: secret; https://private.invalid/item",
        diagnostic: "java.lang.NoSuchMethodError")
    let failure = DevelopmentAndroidLifecycleDiagnostics.Failure(error, stage: .initialize)
    #expect(failure.code == "provider_error")
    #expect(failure.exceptionClass == "java.lang.NoSuchMethodError")
    #expect(failure.stage == .initialize)
    let encoded = String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
    #expect(!encoded.contains("secret"))
    #expect(!encoded.contains("private.invalid"))
    let unstructured = DevelopmentAndroidLifecycleDiagnostics.Failure(
        ProviderErrorPayload(code: "https://private.invalid", message: "secret", diagnostic: "account=secret"), stage: .operation)
    #expect(unstructured.code == "provider_error")
    #expect(unstructured.exceptionClass == nil)
    let timeout = DevelopmentAndroidLifecycleDiagnostics.Failure(ProviderProcessError.timedOut("opaque-secret-id"), stage: .operation)
    #expect(timeout.code == "process_timeout")
    #expect(!String(decoding: try JSONEncoder().encode(timeout), as: UTF8.self).contains("opaque-secret-id"))
}

@MainActor
@Test func originalPathWaitsForAClickWhileMacPathsMayPrefetchOnHover() async throws {
    for preference in [ProviderExecutionPreference.androidPreferred, .macPreferred, .automatic] {
        let name = "fixture.android-hover.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        preferences.providerExecutionPreference = preference
        let site = Site(key: name, type: 3, api: "csp_HoverFixture")
        let provider = AuditHoverProvider()
        await SpiderReplacementRegistry.shared.register(originalKey: site.key, originalAPI: site.api, provider: provider)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: storage),
            userPreferences: preferences, providerRuntimeBootstrap: nil)
        state.sites = [site]
        state.activeSite = site
        let vod = Vod(vodId: name, vodName: "Fixture")
        state.updateDetailPrefetch(vod: vod, site: site, hovering: true)
        if preference == .androidPreferred {
            // Observe past the hover debounce without starting Android business code.
            try await Task.sleep(for: .milliseconds(400))
        } else {
            // A fixed sleep cannot guarantee the actor request has run on a busy runner.
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await provider.count() == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let hoverCalls = await provider.count()
        #expect(hoverCalls == (preference == .androidPreferred ? 0 : 1),
            "Hover calls for \(preference): \(hoverCalls)")
        await state.openVodCard(vod)
        #expect(await provider.count() == 1)
        #expect(state.isDetailPresented)
        #expect(state.episodes.count == 1)
        await state.cancelLoading()
    }
}

private actor AuditHoverProvider: SiteContentProvider {
    private var calls = 0
    func count() -> Int { calls }
    func homeContent(site: Site) async throws -> Models.Result { .empty }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Models.Result { .empty }
    func detailContent(site: Site, id: String) async throws -> Models.Result {
        calls += 1
        return Models.Result(list: [Vod(vodId: id, vodPlayFrom: "original", vodPlayUrl: "one$episode")])
    }
    func playerContent(site: Site, flag: String, id: String) async throws -> Models.Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Models.Result { .empty }
}
#endif
