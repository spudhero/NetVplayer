import CryptoKit
import Foundation
import Testing
import DriveEngine
import ProviderRuntime
import ProviderSDK
import SpiderEngine
import Storage
@testable import NetVplayerApp

@MainActor
@Test func extensionSyncFailureIsTrackedWithoutParsingLocalizedCopy() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let verifier = try ProviderManifestVerifier(
        publicKeyData: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
        shellVersion: "1.0.9"
    )
    let bootstrap = ProviderRuntimeBootstrap(manager: ProviderManager(
        store: ProviderPackageStore(rootURL: directory, verifier: verifier)
    ))
    let state = AppState(
        loadDefaultConfig: false,
        startProxyServer: false,
        providerRuntimeRegistrationOverride: { false },
        providerRuntimeStartupOverride: { true }
    )
    await state.providerRuntimeStartupTask?.value
    #expect(!state.providerRuntimeHasFailure)
    // The missing distribution fails before any particular release is selected.
    await state.synchronizeProviderRuntime(using: bootstrap)
    #expect(state.providerRuntimeHasFailure)
    #expect(state.providerRuntimeFailedRelease == nil)
    #expect(state.providerRuntimeInstalled.isEmpty)
    #expect(!state.providerRuntimeBusy)
    #expect(!state.providerRuntimeStatus.contains("失败"))
    #expect(state.providerRuntimeStatus.contains("重试"))
}

@Test func driveBusinessFailureDoesNotPresentHTTP200AsAnError() {
    let message = UserFacingErrorPresenter.message(
        for: DriveEngineError.api(
            provider: .baidu, statusCode: 200, code: -9,
            message: "private response token=secret https://private.example.test/share"
        ),
        context: .playback
    )
    #expect(message.contains("服务错误码 -9"))
    #expect(message.contains("提取码"))
    #expect(!message.contains("200"))
    #expect(!message.contains("secret"))
    #expect(!message.contains("private.example.test"))
    let unknownCode = UserFacingErrorPresenter.message(
        for: DriveEngineError.api(provider: .quark, statusCode: 200, code: nil, message: "raw"),
        context: .playback
    )
    #expect(unknownCode.contains("未能完成操作"))
    #expect(!unknownCode.contains("错误码"))
    #expect(!unknownCode.contains("raw"))
}

@Test func authorizationFailuresDoNotExposeServerBodiesOrCredentialNames() {
    let errors: [Error] = [
        CloudAuthP115QRCodeLoginError.rejected("private body token=secret"),
        CloudAuthQuarkWebLoginError.missingToken,
        CloudAuthUCWebLoginError.missingToken,
        CloudAuthUCWebLoginError.missingCookie,
    ]
    for error in errors {
        let message = UserFacingErrorPresenter.message(for: error, context: .authorization(providerName: "网盘"))
        #expect(message.contains("请"))
        #expect(!message.localizedCaseInsensitiveContains("token"))
        #expect(!message.localizedCaseInsensitiveContains("cookie"))
        #expect(!message.contains("secret"))
    }
}

@MainActor
@Test func pendingProviderUpgradeIsVersionedAndPersistsWithoutDisablingTheInstalledRelease() throws {
    let release = ProviderRelease(
        providerID: "fixture.provider",
        version: "2.0.0",
        architectures: [ProviderManifestVerifier.currentArchitecture],
        archiveURL: URL(string: "https://providers.example.test/provider.zip")!,
        archiveSHA256: String(repeating: "a", count: 64)
    )
    let pending = ProviderRuntimeUpdateState.pendingVersions(
        catalog: [release],
        installedVersions: ["fixture.provider": "1.0.0"]
    )
    #expect(pending == ["fixture.provider": "2.0.0"])
    #expect(ProviderRuntimeUpdateState.pendingVersions(
        catalog: [release],
        installedVersions: ["fixture.provider": "2.0.0"]
    ).isEmpty)

    let suite = "netvplayer-provider-update-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = UserPreferences(defaults: defaults)
    preferences.providerRuntimeInitialInstallCompleted = true
    preferences.providerRuntimePendingVersions = pending
    #expect(preferences.providerRuntimeInitialInstallCompleted)
    #expect(preferences.providerRuntimePendingVersions == pending)
}
