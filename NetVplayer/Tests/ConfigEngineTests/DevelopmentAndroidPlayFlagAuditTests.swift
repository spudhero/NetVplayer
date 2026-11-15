#if DEBUG
import Foundation
import Models
import Storage
import Testing
@testable import NetVplayerApp

@Suite("Audit playback line selection", .serialized)
@MainActor
struct DevelopmentAndroidPlayFlagAuditTests {
    @Test func requestedLineChangesTheEpisodeListBeforePlayback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plan = try JSONDecoder().decode(DevelopmentAndroidAppAudit.Plan.self, from: Data(
            #"{"config":"/fixture/config.json","output":"/fixture/audit","requestedPlayFlag":"自营t"}"#.utf8))
        fixture.state.applyPlaybackAvailability(for: Self.detail, preferredFlag: "蓝光2k")
        #expect(fixture.state.episodes.first?.url == "580-1-1")
        #expect(DevelopmentAndroidAppAudit.selectRequestedPlayFlag(plan.requestedPlayFlag, state: fixture.state))
        #expect(fixture.state.selectedPlayFlag == "自营t")
        #expect(fixture.state.episodes.map(\.url) == ["580-2-1", "580-2-2"])
    }

    @Test func unknownLineFailsAndOmittedLinePreservesTheCurrentSelection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.state.applyPlaybackAvailability(for: Self.detail, preferredFlag: "自营t")
        #expect(DevelopmentAndroidAppAudit.selectRequestedPlayFlag(nil, state: fixture.state))
        #expect(fixture.state.selectedPlayFlag == "自营t")
        #expect(!DevelopmentAndroidAppAudit.selectRequestedPlayFlag("missing-line", state: fixture.state))
        #expect(fixture.state.selectedPlayFlag == "自营t")
        #expect(fixture.state.episodes.map(\.url) == ["580-2-1", "580-2-2"])
    }

    private static let detail = Vod(vodId: "580", vodName: "Audit fixture",
        vodPlayFrom: "蓝光2k$$$自营t", vodPlayUrl: "第1集$580-1-1$$$第1集$580-2-1#第2集$580-2-2")

    @MainActor
    private struct Fixture {
        let root: URL
        let state: AppState

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-line-\(UUID().uuidString)")
            let preferences = UserPreferences(defaults: UserDefaults(suiteName: "fixture.audit-line.\(UUID().uuidString)")!,
                credentialStore: MemoryCredentialStore())
            state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
                storageManager: StorageManager(storageDirectory: root), userPreferences: preferences,
                providerRuntimeBootstrap: nil)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
#endif
