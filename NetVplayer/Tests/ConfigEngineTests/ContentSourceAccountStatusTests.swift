import Foundation
import Testing
import Models
import DriveEngine
import Storage
@testable import NetVplayerApp

@Suite(.serialized)
@MainActor
struct ContentSourceAccountStatusTests {
    @Test(arguments: [DriveProvider.ali, .pikpak])
    func savedTokensDoNotClaimAccountValidation(provider: DriveProvider) async throws {
        #expect(TestRuntime.isRunning)
        let preferences = UserPreferences.shared
        let previousAliToken = preferences.aliAccessToken
        let previousPikPakToken = preferences.pikpakAccessToken
        let previousPikPakRefresh = preferences.pikpakRefreshToken
        let previousPikPakDevice = preferences.pikpakDeviceID
        defer {
            preferences.aliAccessToken = previousAliToken
            preferences.pikpakAccessToken = previousPikPakToken
            preferences.pikpakRefreshToken = previousPikPakRefresh
            preferences.pikpakDeviceID = previousPikPakDevice
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(
            loadDefaultConfig: false,
            startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory),
            providerRuntimeBootstrap: nil
        )
        let completion = try await state.completeCloudAuth(
            credential: CloudCredential(provider: provider, kind: .accessToken, secret: "example-unverified-token")
        )
        #expect(completion.shouldDismiss)
        #expect(!completion.credentialsValidated)
        #expect(completion.message != nil)
        let stored = provider == .ali ? preferences.aliAccessToken : preferences.pikpakAccessToken
        #expect(stored == "example-unverified-token")
    }
}
