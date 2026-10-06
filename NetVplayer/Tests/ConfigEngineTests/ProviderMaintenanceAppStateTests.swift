import CryptoKit
import XCTest
import ProviderRuntime
import ProviderSDK
import SpiderEngine
import Storage
@testable import NetVplayerApp

final class ProviderMaintenanceAppStateTests: XCTestCase {
    @MainActor
    func testDisabledStartupFinishesBusyStateAndCanReenable() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-disabled-appstate-\(UUID().uuidString)")
        let providerRoot = temporary.appendingPathComponent("Providers")
        let storageRoot = temporary.appendingPathComponent("Storage")
        let defaultsName = "provider-disabled-appstate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: temporary)
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try ProviderManifestVerifier(
            publicKeyData: privateKey.publicKey.rawRepresentation,
            shellVersion: "1.0.0"
        )
        let store = ProviderPackageStore(rootURL: providerRoot, verifier: verifier)
        try await store.setDisabled(true)
        let manager = ProviderManager(store: store)
        let bootstrap = ProviderRuntimeBootstrap(manager: manager)
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        let state = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            storageManager: StorageManager(storageDirectory: storageRoot),
            userPreferences: preferences,
            providerRuntimeBootstrap: bootstrap
        )

        await state.providerRuntimeStartupTask?.value
        XCTAssertTrue(state.providerComponentsDisabled)
        XCTAssertFalse(state.providerRuntimeBusy)
        XCTAssertEqual(state.selectedTab, .vodHome)
        XCTAssertNil(state.settingsNavigationDestination)
        XCTAssertEqual(state.providerInstallation.phase, .idle)
        XCTAssertFalse(state.providerInstallation.detailsExpanded)

        state.enableProviderComponents()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while state.providerRuntimeBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(state.providerRuntimeBusy)
        XCTAssertFalse(state.providerComponentsDisabled)
        let remainsDisabled = await manager.isDisabled()
        XCTAssertFalse(remainsDisabled)
    }
}
