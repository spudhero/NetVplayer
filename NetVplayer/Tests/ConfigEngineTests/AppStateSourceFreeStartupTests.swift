import Foundation
import Testing
import ConfigEngine
import Networking
import Storage
@testable import NetVplayerApp

@Suite("Source-free startup", .serialized)
struct AppStateSourceFreeStartupTests {
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
            providerRuntimeStartupOverride: { false }
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
            }
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
            }
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
            }
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
            providerRuntimeStartupOverride: { false }
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
            providerRuntimeStartupOverride: { false }
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
            providerRuntimeStartupOverride: { false }
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
            providerRuntimeStartupOverride: { await attempts.nextSucceeds() }
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

private final class RetryingSavedSourceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var attempts = 0

    static var attemptCount: Int {
        lock.withLock { attempts }
    }

    static func reset() {
        lock.withLock { attempts = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let attempt = Self.lock.withLock {
            Self.attempts += 1
            return Self.attempts
        }
        guard attempt > 1 else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"sites":[{"key":"user-configured-fixture","name":"User fixture","type":3,"api":"csp_UserConfiguredFixture"}],"lives":[],"parses":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
