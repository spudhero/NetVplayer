import Foundation
import Testing
import Storage
@testable import NetVplayerApp

@Suite("Provider installation startup", .serialized)
@MainActor
struct ProviderInstallationStartupTests {
    @Test(arguments: [false, true])
    func firstInstallationNavigatesBeforeNetworkAndCollapsesAfterTheDelay(navigateAway: Bool) async throws {
        let fixture = try InstallationPreferencesFixture()
        defer { fixture.cleanUp() }
        let network = InstallationTestGate()
        let delay = InstallationTestGate()
        let state = fixture.makeState(startup: {
            await network.wait()
            return true
        }, collapseDelay: { await delay.wait() })
        await network.waitUntilEntered()
        #expect(state.selectedTab == .settings)
        #expect(state.settingsNavigationDestination == .providers)
        #expect(state.providerInstallation.detailsExpanded)
        #expect(state.providerInstallation.shouldShowNetworkHint)
        #expect(state.providerInstallation.phase == .fetchingCatalog)
        #expect(!fixture.preferences.providerRuntimeInitialInstallCompleted)
        state.consumeSettingsNavigationDestination(.providers)
        if navigateAway { state.selectedTab = .search }

        await network.open()
        await state.providerRuntimeStartupTask?.value
        #expect(fixture.preferences.providerRuntimeInitialInstallCompleted)
        #expect(state.providerInstallation.phase == .completed)
        #expect(state.providerInstallation.detailsExpanded)
        #expect(!state.providerInstallation.shouldShowNetworkHint)
        let collapse = try #require(state.providerRuntimeCollapseTask)
        await delay.open()
        await collapse.value
        #expect(!state.providerInstallation.detailsExpanded)
        #expect(state.selectedTab == (navigateAway ? .search : .settings))
        #expect(state.settingsNavigationDestination == nil)
    }

    @Test func manualDisclosureChoiceCancelsScheduledCollapse() async throws {
        let fixture = try InstallationPreferencesFixture()
        defer { fixture.cleanUp() }
        let delay = InstallationTestGate()
        let state = fixture.makeState(startup: { true }, collapseDelay: { await delay.wait() })
        await state.providerRuntimeStartupTask?.value
        let collapse = try #require(state.providerRuntimeCollapseTask)
        state.setProviderRuntimeDetailsExpanded(false)
        state.setProviderRuntimeDetailsExpanded(true)
        await delay.open()
        await collapse.value
        #expect(state.providerInstallation.detailsExpanded)
        #expect(state.providerRuntimeCollapseTask == nil)
    }

    @Test func newCheckCancelsThePreviousInstallCollapse() async throws {
        let fixture = try InstallationPreferencesFixture()
        defer { fixture.cleanUp() }
        let delay = InstallationTestGate()
        let state = fixture.makeState(startup: { true }, collapseDelay: { await delay.wait() })
        await state.providerRuntimeStartupTask?.value
        let collapse = try #require(state.providerRuntimeCollapseTask)
        let firstSession = state.providerInstallation.sessionID
        let refresh = try #require(state.refreshProviderRuntimeCatalog())
        await refresh.value
        #expect(state.providerInstallation.sessionID != firstSession)
        #expect(!state.providerInstallation.isInitialInstallation)
        await delay.open()
        await collapse.value
        #expect(state.providerInstallation.detailsExpanded)
    }

    @Test func failedFirstInstallationKeepsDetailsAndRetryDoesNotNavigateAgain() async throws {
        let fixture = try InstallationPreferencesFixture()
        defer { fixture.cleanUp() }
        let state = fixture.makeState(startup: { false })
        await state.providerRuntimeStartupTask?.value
        #expect(state.selectedTab == .settings)
        #expect(state.providerInstallation.detailsExpanded)
        #expect(state.providerInstallation.shouldShowNetworkHint)
        #expect(state.providerRuntimeCollapseTask == nil)
        #expect(!fixture.preferences.providerRuntimeInitialInstallCompleted)
        state.consumeSettingsNavigationDestination(.providers)
        state.selectedTab = .vodHome
        let retry = try #require(state.refreshProviderRuntimeCatalog())
        await retry.value
        #expect(state.selectedTab == .vodHome)
        #expect(state.settingsNavigationDestination == nil)
        #expect(state.providerInstallation.detailsExpanded)
        #expect(state.providerRuntimeHasFailure)
    }

    @Test(arguments: [false, true])
    func completedInstallAndDamagedLocalInstallDoNotNavigate(requiresRepair: Bool) async throws {
        let fixture = try InstallationPreferencesFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.providerRuntimeInitialInstallCompleted = true
        if requiresRepair { fixture.preferences.providerRuntimeInstalledVersions = ["fixture": "1.0.0"] }
        let state = fixture.makeState(registered: !requiresRepair, startup: { false })
        await state.providerRuntimeStartupTask?.value
        #expect(state.selectedTab == .vodHome)
        #expect(state.settingsNavigationDestination == nil)
        #expect(!state.providerInstallation.isInitialInstallation)
        #expect(!state.providerInstallation.detailsExpanded)
        #expect(!state.providerInstallation.shouldShowNetworkHint)
        #expect(state.providerRuntimeLocalPackageInvalid == requiresRepair)
        #expect(state.providerRuntimeCollapseTask == nil)
    }
}

@MainActor
private struct InstallationPreferencesFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "provider-installation-presentation-\(UUID().uuidString)"
    let defaults: UserDefaults
    let preferences: UserPreferences

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
    }

    func makeState(
        registered: Bool = false,
        startup: @escaping @MainActor @Sendable () async -> Bool,
        collapseDelay: @escaping @Sendable () async throws -> Void = { }
    ) -> AppState {
        AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeBootstrap: nil,
            providerRuntimeRegistrationOverride: { registered },
            providerRuntimeStartupOverride: startup,
            providerRuntimeCollapseDelay: collapseDelay
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor InstallationTestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func wait() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
