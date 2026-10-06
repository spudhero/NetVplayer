import Foundation
import Testing
import ConfigEngine
import Models
import Networking
import Storage
@testable import NetVplayerApp

@Suite("Saved configuration recovery", .serialized)
struct CachedConfigurationTests {
    private let cachedJSON = #"{"sites":[{"key":"cached-fixture","name":"Cached","type":3,"api":"csp_CachedFixture"}]}"#

    private func resolver() -> ConfigResolver {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CachedConfigurationURLProtocol.self]
        return ConfigResolver(httpClient: HTTPClient(session: URLSession(configuration: configuration)), allowsProxyFallback: false)
    }

    @Test(arguments: ["offline", "empty", "unavailable", "tls", "tls-handshake", "tls-bad-date", "tls-unknown-root", "tls-not-yet-valid", "tls-client-rejected", "tls-client-required"])
    func temporaryFailureRestoresOnlyTheMatchingConfiguration(mode: String) async throws {
        let url = "https://source.example.test/\(mode)"
        let cached = Config(url: url, name: "Saved source", json: cachedJSON)
        let result = try await resolver().loadVodInput(url: url, cachedConfig: cached)
        #expect(result.usesCachedConfiguration)
        #expect(result.json == cachedJSON)
        #expect(result.canonicalURL == url)
        #expect(result.config.name == "Saved source")
        #expect(result.configurationRefreshError != nil)
    }

    @Test func successfulRefreshTakesPrecedenceOverCache() async throws {
        let url = "https://source.example.test/online"
        let result = try await resolver().loadVodInput(
            url: url, cachedConfig: Config(url: url, json: cachedJSON)
        )
        #expect(!result.usesCachedConfiguration)
        #expect(result.json.contains("fresh-fixture"))
    }

    @Test(arguments: ["unauthorized", "malformed", "cancelled"])
    func permanentOrCancelledFailuresRemainVisible(mode: String) async {
        let url = "https://source.example.test/\(mode)"
        await #expect(throws: (any Error).self) {
            try await resolver().loadVodInput(url: url, cachedConfig: Config(url: url, json: cachedJSON))
        }
    }

    @Test(arguments: ["different-url", "invalid-json", "empty-sites", "empty-key", "missing-api", "invalid-site", "live"])
    func unrelatedOrInvalidCacheIsNotRestored(mode: String) async {
        let url = "https://source.example.test/empty"
        var cached = Config(url: url, json: cachedJSON)
        switch mode {
        case "different-url": cached.url = "https://other.example.test/empty"
        case "invalid-json": cached.json = "broken"
        case "empty-sites": cached.json = #"{"sites":[]}"#
        case "empty-key": cached.json = #"{"sites":[{"key":"","api":"csp_Invalid"}]}"#
        case "missing-api": cached.json = #"{"sites":[{"key":"invalid"}]}"#
        case "invalid-site": cached.json = #"{"sites":[{"key":42,"api":"csp_Invalid"}]}"#
        default: cached.type = .live
        }
        await #expect(throws: (any Error).self) {
            try await resolver().loadVodInput(url: url, cachedConfig: cached)
        }
    }

    @Test func tlsFailureWithoutAMatchingSnapshotStillThrows() async {
        await #expect(throws: URLError.self) {
            try await resolver().loadVodInput(url: "https://source.example.test/tls-handshake")
        }
    }

    @Test(arguments: ["https://source.example.test/runtime.js.md5", "netvplayer-xtream://account"])
    func runtimeDependentInputsAreNotRestoredAsPlainConfiguration(url: String) {
        #expect(resolver().cachedVodInput(url: url, cachedConfig: Config(url: url, json: cachedJSON)) == nil)
    }

    @MainActor
    @Test func applicationStartupRestoresSavedSitesWithoutChangingTheSourceURL() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "netvplayer-cached-source-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults)
        let url = "https://source.example.test/empty"
        preferences.currentVodConfigUrl = url
        let storage = StorageManager(storageDirectory: directory)
        try storage.saveConfigs([Config(url: url, json: cachedJSON)])
        let state = AppState(
            startProxyServer: false,
            configResolver: resolver(),
            storageManager: storage,
            userPreferences: preferences,
            providerRuntimeRegistrationOverride: { true },
            providerRuntimeStartupOverride: { false }
        )
        await state.initialConfigTask?.value
        #expect(state.isConfigLoaded)
        #expect(state.sites.map(\.key) == ["cached-fixture"])
        #expect(state.savedConfigStartupPhase == .ready)
        #expect(state.configNotice?.contains("上次成功加载") == true)
        #expect(preferences.currentVodConfigUrl == url)
        let savedJSON = try #require(storage.loadConfigs().first?.json.data(using: .utf8))
        let saved = try JSONSerialization.jsonObject(with: savedJSON) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: Data(cachedJSON.utf8)) as? NSDictionary
        #expect(saved == expected)
    }
}

private final class CachedConfigurationURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let mode = url.lastPathComponent
        let failure: URLError.Code? = switch mode {
        case "offline": .networkConnectionLost
        case "cancelled": .cancelled
        case "tls": .serverCertificateUntrusted
        case "tls-handshake": .secureConnectionFailed
        case "tls-bad-date": .serverCertificateHasBadDate
        case "tls-unknown-root": .serverCertificateHasUnknownRoot
        case "tls-not-yet-valid": .serverCertificateNotYetValid
        case "tls-client-rejected": .clientCertificateRejected
        case "tls-client-required": .clientCertificateRequired
        default: nil
        }
        if let failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let status = mode == "unavailable" ? 503 : mode == "unauthorized" ? 401 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = mode == "empty" ? "" : mode == "malformed" ? "not configuration data"
            : #"{"sites":[{"key":"fresh-fixture","name":"Fresh","type":3,"api":"csp_FreshFixture"}]}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
