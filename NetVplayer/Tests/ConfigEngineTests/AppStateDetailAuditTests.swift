#if DEBUG
import Foundation
import Models
import SpiderEngine
import Storage
import Testing
@testable import NetVplayerApp

@Suite(.serialized)
@MainActor
struct AppStateDetailAuditTests {
    @Test(arguments: ["failure", "empty", "zero", "playable"])
    func completedAppCallRetainsItsActualResult(kind: String) async throws {
        let fixture = await DetailAuditFixture()
        defer { fixture.close() }
        await fixture.state.selectVod(Vod(vodId: kind, vodName: kind))
        #expect(!fixture.state.isDetailLoading)
        #expect(fixture.state.isDetailPresented)
        #expect(await fixture.provider.calls() == 1)
        let failure = DevelopmentAndroidAuditContract.detailFailure(presented: fixture.state.isDetailPresented,
            hasDetail: fixture.state.detailVod != nil, episodes: fixture.state.episodes.count,
            requestedIndex: 0, requestOutcome: fixture.state.detailRequestOutcome)
        switch kind {
        case "failure":
            #expect(fixture.state.detailRequestOutcome == .failed)
            #expect(failure == "detail_request_failed")
        case "empty":
            #expect(fixture.state.detailRequestOutcome == .empty)
            #expect(failure == "detail_empty_result")
        case "zero":
            #expect(fixture.state.detailRequestOutcome == .result)
            #expect(failure == "detail_no_episodes")
        default:
            #expect(fixture.state.detailRequestOutcome == .result)
            #expect(failure == nil)
            #expect(fixture.state.episodes.count == 1)
        }
    }

    @Test func lateFailureCannotReplaceNewDetailOutcome() async throws {
        let fixture = await DetailAuditFixture()
        defer { fixture.close() }
        let old = Task { await fixture.state.selectVod(Vod(vodId: "delayed-failure", vodName: "Old")) }
        for _ in 0..<100 {
            if await fixture.provider.calls() > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.state.detailRequestOutcome == .loading)
        await fixture.state.selectVod(Vod(vodId: "playable", vodName: "New"))
        #expect(fixture.state.detailRequestOutcome == .result)
        await old.value
        #expect(fixture.state.detailRequestOutcome == .result)
        #expect(fixture.state.detailVod?.vodId == "playable")
        #expect(fixture.state.episodes.count == 1)
    }
}

@MainActor
private struct DetailAuditFixture {
    let state: AppState
    let provider = DetailAuditProvider()
    let root: URL
    let defaults: UserDefaults
    let name = "fixture.detail-audit.\(UUID().uuidString)"

    init() async {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        defaults = UserDefaults(suiteName: name)!
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        preferences.providerExecutionPreference = .macPreferred
        let site = Site(key: name, type: 3, api: "csp_DetailAuditFixture")
        await SpiderReplacementRegistry.shared.register(originalKey: site.key, originalAPI: site.api, provider: provider)
        state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: root), userPreferences: preferences,
            providerRuntimeBootstrap: nil)
        state.sites = [site]
        state.activeSite = site
    }

    func close() {
        state.isDetailPresented = false
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor DetailAuditProvider: SiteContentProvider {
    private var count = 0
    func calls() -> Int { count }
    func detailContent(site: Site, id: String) async throws -> Result {
        count += 1
        if id == "delayed-failure" { try? await Task.sleep(for: .milliseconds(200)) }
        if id.contains("failure") { throw URLError(.cannotFindHost) }
        if id == "empty" { return .empty }
        return Result(list: [Vod(vodId: id, vodName: id, vodPlayFrom: id == "zero" ? "" : "Original",
            vodPlayUrl: id == "zero" ? "" : "Episode$https://local-fixture.invalid/media.mp4")])
    }
    func homeContent(site: Site) async throws -> Result { .empty }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result { .empty }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}
#endif
