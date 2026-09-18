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
            userPreferences: preferences
        )
        let task = try #require(state.initialConfigTask)
        await task.value

        #expect(preferences.currentVodConfigUrl == url)
        #expect(state.savedConfigs.map(\.url) == [url])
        #expect(state.sites.map(\.key) == ["user-configured-fixture"])
        #expect(state.sites.map(\.api) == ["csp_UserConfiguredFixture"])
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
            providerRuntimeStartupOverride: {
                await providerStartup.wait()
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
    @Test func failedEarlyRestoreRetriesAfterProviderSynchronization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-startup-retry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            RetryingSavedSourceURLProtocol.reset()
        }
        let preferences = UserPreferences(defaults: defaults)
        let url = "https://user-source.example.test/config.json"
        preferences.currentVodConfigUrl = url
        RetryingSavedSourceURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryingSavedSourceURLProtocol.self]
        let providerStartup = ProviderStartupBarrier()
        let state = AppState(
            startProxyServer: false,
            configResolver: ConfigResolver(httpClient: HTTPClient(session: URLSession(configuration: configuration))),
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeStartupOverride: {
                await providerStartup.wait()
            }
        )
        let task = try #require(state.initialConfigTask)

        let deadline = ContinuousClock.now + .seconds(2)
        while RetryingSavedSourceURLProtocol.attemptCount < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(RetryingSavedSourceURLProtocol.attemptCount == 1)
        #expect(!state.isConfigLoaded)

        await providerStartup.release()
        await task.value
        #expect(RetryingSavedSourceURLProtocol.attemptCount == 2)
        #expect(state.isConfigLoaded)
        #expect(state.sites.map(\.key) == ["user-configured-fixture"])
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
