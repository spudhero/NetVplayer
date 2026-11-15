import Foundation
import Models
import Testing
import ConfigEngine
import Networking
import Storage
import CryptoKit
@testable import SpiderEngine
@testable import NetVplayerApp

@Suite("Source-free startup", .serialized)
struct AppStateSourceFreeStartupTests {
    @MainActor
    @Test func automaticMixedConfigurationCompletesRegistrationAndPublishesCapabilities() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-default-" + UUID().uuidString)
        let suite = "netvplayer-mixed-default-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let runtimeRoot = directory.appendingPathComponent("runtime")
        for path in ["inputs", "converted", "lib", "jdk/bin"] {
            try FileManager.default.createDirectory(at: runtimeRoot.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        // ZIP metadata fixtures; no provider bytecode or external source runs.
        let original = Data(base64Encoded: "UEsDBBQAAAAAAAAAWF2XnBGxCwAAAAsAAAALAAAAY2xhc3Nlcy5kZXhkZXgKMDM1AG5ld1BLAQIUAxQAAAAAAAAAWF2XnBGxCwAAAAsAAAALAAAAAAAAAAAAAACAAQAAAABjbGFzc2VzLmRleFBLBQYAAAAAAQABADkAAAA0AAAAAAA=")!
        let converted = Data(base64Encoded: "UEsDBBQAAAAAAAAAWF00aLugCwAAAAsAAAArAAAAY29tL2dpdGh1Yi9jYXR2b2Qvc3BpZGVyL0ZpeHR1cmVHdWFyZC5jbGFzc8r+ur5maXh0dXJlUEsBAhQDFAAAAAAAAABYXTRou6ALAAAACwAAACsAAAAAAAAAAAAAAIABAAAAAGNvbS9naXRodWIvY2F0dm9kL3NwaWRlci9GaXh0dXJlR3VhcmQuY2xhc3NQSwUGAAAAAAEAAQBZAAAAVAAAAAAA")!
        try original.write(to: runtimeRoot.appendingPathComponent("inputs/provider.jar"))
        try converted.write(to: runtimeRoot.appendingPathComponent("converted/provider-jvm.jar"))
        for file in ["lib/macapk-loader.jar", "lib/android-framework.jar", "jdk/bin/java"] {
            try Data(file.utf8).write(to: runtimeRoot.appendingPathComponent(file))
        }
        let manifest = DevelopmentAndroidRuntimeManifest(schema: 2, providerID: "android-original-runtime", backend: "emulated",
            providerSHA256: SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined(),
            hostSHA256: String(repeating: "a", count: 64), bindings: [], bootstrapClass: nil, package: nil)
        let runtime = DevelopmentAndroidRuntimeLayout(root: runtimeRoot, manifest: manifest, classPath: [])
        let store = DevelopmentAndroidArtifactStore(root: directory.appendingPathComponent("artifacts"),
            fetch: { _, _ in original }, convert: { _, _, output in try converted.write(to: output) })
        let registration = DevelopmentAndroidRuntimeRegistration(stateRoot: directory, registry: .shared, arguments: [], artifactStore: store)
        let configURL = "https://mixed.example.test/config.json"
        let json = #"{"spider":"https://mixed.example.test/provider.jar","sites":[{"key":"mixed-java","name":"Java","type":3,"api":"csp_FixtureGuard"},{"key":"mixed-script","name":"Script","type":3,"api":"https://mixed.example.test/drpy2.js"},{"key":"mixed-notice","name":"Notice","type":3,"api":"csp_XPathGuard"}]}"#
        let preferences = UserPreferences(defaults: defaults)
        #expect(preferences.providerExecutionPreference == .automatic)
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory), userPreferences: preferences,
            androidProviderRegistrationOverride: { sites in
                try await registration.register(runtime: runtime, sites: sites)
            })
        let input = ResolvedVodInput(json: json, config: Config(type: .vod, url: configURL), kind: .configuration,
            canonicalURL: configURL, initialResult: Models.Result())

        await state.loadConfig(url: configURL, waitForProviderRuntime: false,
            refreshCachedConfiguration: false, includeLiveContent: false, preparedInput: input)

        #expect(state.isConfigLoaded)
        #expect(state.configError == nil)
        #expect(state.savedConfigStartupPhase == .ready)
        #expect(state.nativeReplacementSiteKeys.isSuperset(of: ["mixed-java", "mixed-script", "mixed-notice"]))
        for key in ["mixed-java", "mixed-script", "mixed-notice"] {
            #expect(state.providerExecutionBackends[key] == .androidOriginal)
        }
        await registration.shutdownAll()
    }

    @MainActor
    @Test func mediaServerSitesBelongToTheInjectedStorage() throws {
        for name in ["Account A", "Account B"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let suite = "netvplayer-server-isolation-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
            let storage = StorageManager(storageDirectory: directory)
            let preferences = UserPreferences(defaults: defaults)
            let account = MediaServerConfiguration(name: name, kind: .emby,
                server: "https://isolated-media.example.test", serverID: name, userID: "test")
            try MediaServerStore(storage: storage, preferences: preferences).save([account])
            let state = AppState(loadDefaultConfig: false, startProxyServer: false,
                storageManager: storage, userPreferences: preferences)
              #expect(state.sites.isEmpty)
            state.reloadFileServiceSites()
            #expect(state.sites.map(\.key) == [account.siteKey])
        }
    }

    @MainActor
    @Test(arguments: ["", " \n\t "])
    func newInstallationDoesNotScheduleSourceLoading(savedURL: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-source-free-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults)
        preferences.currentVodConfigUrl = savedURL
        let state = AppState(
            startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences
        )

        #expect(state.initialConfigTask == nil)
        #expect(state.savedConfigStartupPhase == .unconfigured)
        #expect(state.sites.isEmpty)
        #expect(state.savedConfigs.isEmpty)
        #expect(state.activeSite == nil)
        #expect(state.activeLive == nil)
        #expect(state.channelGroups.isEmpty)
        #expect(preferences.currentLiveConfigUrl.isEmpty)
    }

    @MainActor
    @Test func restartLoadsOnlyTheUsersSavedConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-saved-source-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let previousLegacyFlag = UserPreferences.shared.speedDirectEasterEggEnabled
        UserPreferences.shared.speedDirectEasterEggEnabled = true
        defer {
            UserPreferences.shared.speedDirectEasterEggEnabled = previousLegacyFlag
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults)
        let url = "https://user-source.example.test/config.json"
        preferences.currentVodConfigUrl = " \(url) \n"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SavedSourceURLProtocol.self]
        let state = AppState(
            startProxyServer: false,
            configResolver: ConfigResolver(httpClient: HTTPClient(session: URLSession(configuration: configuration))),
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeRegistrationOverride: { true },
            providerRuntimeStartupOverride: { false },
            androidProviderRegistrationOverride: { _ in }
        )
        let task = try #require(state.initialConfigTask)
        #expect(state.savedConfigStartupPhase == .preparingExtension)
        await task.value

        #expect(preferences.currentVodConfigUrl == url)
        #expect(state.savedConfigs.map(\.url) == [url])
        #expect(state.sites.map(\.key) == ["user-configured-fixture"])
        #expect(state.sites.map(\.api) == ["csp_UserConfiguredFixture"])
        #expect(state.savedConfigStartupPhase == .ready)
        #expect(preferences.providerRuntimeInitialInstallCompleted)
    }

    @MainActor
    @Test func savedConfigurationRestoresBeforeProviderNetworkSynchronizationFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-startup-order-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults)
        let url = "https://user-source.example.test/config.json"
        preferences.currentVodConfigUrl = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SavedSourceURLProtocol.self]
        let providerStartup = ProviderStartupBarrier()
        let state = AppState(
            startProxyServer: false,
            configResolver: ConfigResolver(httpClient: HTTPClient(session: URLSession(configuration: configuration))),
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeRegistrationOverride: { true },
            providerRuntimeStartupOverride: {
                await providerStartup.wait()
                return false
            },
            androidProviderRegistrationOverride: { _ in }
        )
        let task = try #require(state.initialConfigTask)

        let deadline = ContinuousClock.now + .seconds(2)
        while !state.isConfigLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.isConfigLoaded)
        #expect(state.sites.map(\.key) == ["user-configured-fixture"])
        #expect(await providerStartup.isWaiting)

        await providerStartup.release()
        await task.value
    }

    @MainActor
    @Test func savedConfigurationWaitsForInstalledProviderRegistrationButNotNetworkSynchronization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-provider-registration-order-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults)
        let url = "https://user-source.example.test/config.json"
        preferences.currentVodConfigUrl = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SavedSourceURLProtocol.self]
        let providerRegistration = ProviderStartupBarrier()
        let providerSynchronization = ProviderStartupBarrier()
        let state = AppState(
            startProxyServer: false,
            configResolver: ConfigResolver(httpClient: HTTPClient(session: URLSession(configuration: configuration))),
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeRegistrationOverride: {
                await providerRegistration.wait()
                return true
            },
            providerRuntimeStartupOverride: {
                await providerSynchronization.wait()
                return false
            },
            androidProviderRegistrationOverride: { _ in }
        )
        let task = try #require(state.initialConfigTask)

        let registrationDeadline = ContinuousClock.now + .seconds(2)
        while !(await providerRegistration.isWaiting), ContinuousClock.now < registrationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await providerRegistration.isWaiting)
        #expect(!state.isConfigLoaded)

        await providerRegistration.release()
        let restoreDeadline = ContinuousClock.now + .seconds(2)
        while !state.isConfigLoaded, ContinuousClock.now < restoreDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.isConfigLoaded)
        #expect(state.sites.map(\.key) == ["user-configured-fixture"])
        #expect(await providerSynchronization.isWaiting)

        await providerSynchronization.release()
        await task.value
    }

    @MainActor
    @Test func firstInstallWaitsForExtensionBeforeLoadingSavedSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-startup-retry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults)
        let url = "https://user-source.example.test/config.json"
        preferences.currentVodConfigUrl = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SavedSourceURLProtocol.self]
        let providerStartup = ProviderStartupBarrier()
        let state = AppState(
            startProxyServer: false,
            configResolver: ConfigResolver(httpClient: HTTPClient(session: URLSession(configuration: configuration))),
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeStartupOverride: {
                await providerStartup.wait()
                return true
            },
            androidProviderRegistrationOverride: { _ in }
        )
        let task = try #require(state.initialConfigTask)
        #expect(state.savedConfigStartupPhase == .preparingExtension)
        #expect(!state.isConfigLoaded)
        #expect(state.sites.isEmpty)

        let deadline = ContinuousClock.now + .seconds(2)
        while !(await providerStartup.isWaiting), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await providerStartup.isWaiting)

        await providerStartup.release()
        await task.value
        #expect(state.isConfigLoaded)
        #expect(state.sites.map(\.key) == ["user-configured-fixture"])
        #expect(preferences.providerRuntimeInitialInstallCompleted)
    }

    @MainActor
    @Test func firstInstallFailureDoesNotLoadSavedSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-first-install-failed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults)
        preferences.currentVodConfigUrl = "https://user-source.example.test/config.json"
        let state = AppState(
            startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeStartupOverride: { false },
            androidProviderRegistrationOverride: { _ in }
        )
        await state.initialConfigTask?.value
        #expect(!state.isConfigLoaded)
        #expect(state.sites.isEmpty)
        #expect(!preferences.providerRuntimeInitialInstallCompleted)
        guard case .failed = state.savedConfigStartupPhase else {
            Issue.record("First install failure should be visible on the home screen")
            return
        }
    }

    @MainActor
    @Test func invalidLocalInstallMarkerRequiresRepair() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-invalid-provider-marker-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults)
        preferences.currentVodConfigUrl = "https://user-source.example.test/config.json"
        preferences.providerRuntimeInitialInstallCompleted = true
        preferences.providerRuntimeInstalledVersions = ["fixture.provider": "1.0.0"]
        let state = AppState(
            startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeRegistrationOverride: { false },
            providerRuntimeStartupOverride: { false },
            androidProviderRegistrationOverride: { _ in }
        )
        await state.initialConfigTask?.value
        #expect(state.providerRuntimeLocalPackageInvalid)
        #expect(!preferences.providerRuntimeInitialInstallCompleted)
        #expect(!state.isConfigLoaded)
    }

    @MainActor
    @Test func missingOnePreviouslyInstalledPackageInvalidatesTheCompletionRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-missing-provider-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults)
        preferences.currentVodConfigUrl = "https://user-source.example.test/config.json"
        preferences.providerRuntimeInitialInstallCompleted = true
        preferences.providerRuntimeInstalledVersions = ["first.provider": "1.0.0", "second.provider": "1.0.0"]
        let state = AppState(
            startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeRegistrationOverride: { true },
            providerRuntimeStartupOverride: { false },
            androidProviderRegistrationOverride: { _ in }
        )
        await state.initialConfigTask?.value
        #expect(state.providerRuntimeLocalPackageInvalid)
        #expect(!preferences.providerRuntimeInitialInstallCompleted)
        #expect(!state.isConfigLoaded)
    }

    @MainActor
    @Test func retryAfterFirstInstallFailureLoadsSavedSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-first-install-retry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults)
        preferences.currentVodConfigUrl = "https://user-source.example.test/config.json"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SavedSourceURLProtocol.self]
        let attempts = ProviderStartupAttempts()
        let state = AppState(
            startProxyServer: false,
            configResolver: ConfigResolver(httpClient: HTTPClient(session: URLSession(configuration: configuration))),
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeStartupOverride: { await attempts.nextSucceeds() },
            androidProviderRegistrationOverride: { _ in }
        )
        await state.initialConfigTask?.value
        #expect(!state.isConfigLoaded)

        state.retrySavedConfigStartup()
        await state.initialConfigTask?.value
        #expect(state.isConfigLoaded)
        #expect(state.savedConfigStartupPhase == .ready)
        #expect(preferences.providerRuntimeInitialInstallCompleted)
        #expect(await attempts.count == 2)
    }
}

private actor ProviderStartupAttempts {
    private(set) var count = 0

    func nextSucceeds() -> Bool {
        count += 1
        return count > 1
    }
}

private actor ProviderStartupBarrier {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class SavedSourceURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.absoluteString == "https://user-source.example.test/config.json" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"sites":[{"key":"user-configured-fixture","name":"User fixture","type":3,"api":"csp_UserConfiguredFixture"}],"lives":[],"parses":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
