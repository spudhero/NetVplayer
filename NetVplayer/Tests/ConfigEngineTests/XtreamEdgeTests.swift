import Foundation
import XCTest
import ConfigEngine
import Models
import Networking
import Storage
@testable import SpiderEngine
@testable import NetVplayerApp

private final class XtreamEdgeCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var value: XtreamCredentials?
    init(_ value: XtreamCredentials?) { self.value = value }
    func set(_ value: XtreamCredentials?) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func read() throws -> XtreamCredentials {
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw XtreamError.authorizationRequired }
        return value
    }
}

/// Each test gets its own host/route. Every request is intercepted; no real network is used.
private final class XtreamEdgeProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> String
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Handler] = [:]

    static func install(host: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }; routes[host] = handler
    }
    static func remove(host: String) { lock.lock(); defer { lock.unlock() }; routes.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = request.url?.host.flatMap { Self.routes[$0] }
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(handler(request).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct XtreamEdgeFixture {
    let configuration: XtreamConfiguration
    let session: URLSession
    let credentials: XtreamEdgeCredentials
    let provider: XtreamSiteProvider
    let site: Site
    let host: String

    init(authJSON: String = "{\"user_info\":{\"auth\":1,\"status\":\"Active\",\"exp_date\":\"0\"}}",
         liveRows: String = "[]",
         initialCredentials: XtreamCredentials = .init(username: "alice", password: "fictional-secret")) throws {
        host = "fixture-\(UUID().uuidString.lowercased()).invalid"
        configuration = try XtreamConfiguration(name: "Fixture", server: "https://\(host)/base")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [XtreamEdgeProtocol.self]
        session = URLSession(configuration: sessionConfiguration)
        credentials = XtreamEdgeCredentials(initialCredentials)
        let credentials = credentials
        provider = try XtreamSiteProvider(configuration: configuration,
            client: HTTPClient(session: session), credentials: { try credentials.read() })
        site = try configuration.site()
        XtreamEdgeProtocol.install(host: host) { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let action = query.first { $0.name == "action" }?.value ?? "auth"
            let username = query.first { $0.name == "username" }?.value ?? ""
            switch action {
            case "auth": return authJSON
            case "get_vod_categories", "get_series_categories", "get_live_categories":
                return "[{\"category_id\":\"1\",\"category_name\":\"Fixture\"}]"
            case "get_vod_streams":
                return username == "bob"
                    ? "[{\"stream_id\":22,\"name\":\"Bob private catalogue\"}]"
                    : "[{\"stream_id\":11,\"name\":\"Alice private catalogue\"}]"
            case "get_series": return "[]"
            case "get_live_streams": return liveRows
            default: return "[]"
            }
        }
    }

    func cleanup() { session.invalidateAndCancel(); XtreamEdgeProtocol.remove(host: host) }
}

final class XtreamEdgeTests: XCTestCase {
    func testAuthorizationRequiresExplicitPositiveAuthValue() async throws {
        for auth in ["", "\"auth\":null,", "\"auth\":0,", "\"auth\":false,", "\"auth\":2,", "\"auth\":\"false\","] {
            let fixture = try XtreamEdgeFixture(authJSON: "{\"user_info\":{\(auth)\"status\":\"Active\"}}")
            defer { fixture.cleanup() }
            do {
                try await fixture.provider.authenticate()
                XCTFail("An Active status must not replace explicit successful authentication: \(auth)")
            } catch {
                XCTAssertEqual(error as? XtreamError, .authorizationRequired)
            }
        }
    }

    func testAuthorizationAcceptsDocumentedBooleanNumberAndStringSuccess() async throws {
        for auth in ["true", "1", "\"1\""] {
            let fixture = try XtreamEdgeFixture(authJSON: "{\"user_info\":{\"auth\":\(auth),\"status\":\"Active\"}}")
            defer { fixture.cleanup() }
            try await fixture.provider.authenticate()
        }
    }

    func testChangingCredentialsInvalidatesPreviousAccountsCachedCatalogue() async throws {
        let fixture = try XtreamEdgeFixture()
        defer { fixture.cleanup() }
        let alice = try await fixture.provider.homeContent(site: fixture.site)
        XCTAssertEqual(alice.list.map(\.vodName), ["Alice private catalogue"])
        fixture.credentials.set(XtreamCredentials(username: "bob", password: "other-fictional-secret"))
        let bob = try await fixture.provider.homeContent(site: fixture.site)
        XCTAssertEqual(bob.list.map(\.vodName), ["Bob private catalogue"])
        XCTAssertEqual(bob.list.map(\.vodId), ["movie:22"])
    }

    func testLogoutRejectsPreviouslyCachedCatalogueAndResourcePlayback() async throws {
        let fixture = try XtreamEdgeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.provider.homeContent(site: fixture.site)
        let resource = try XtreamResource(accountID: fixture.configuration.id, kind: "movie", streamID: "11", format: "mp4")
        fixture.credentials.set(nil)
        do {
            _ = try await fixture.provider.homeContent(site: fixture.site)
            XCTFail("Logged-out credentials must not expose a previously cached catalogue")
        } catch { XCTAssertEqual(error as? XtreamError, .authorizationRequired) }
        do {
            _ = try await fixture.provider.playerContent(site: fixture.site, flag: "Xtream", id: resource.encoded)
            XCTFail("A restorable reference must still require current authorization")
        } catch { XCTAssertEqual(error as? XtreamError, .authorizationRequired) }
    }

    func testRegistryRefreshesProviderWhenSameAccountChangesServer() async throws {
        let registry = SpiderReplacementRegistry()
        let original = try XtreamConfiguration(name: "Original", server: "https://original.invalid")
        let first = await registry.nativeProvider(for: try original.site())
        XCTAssertTrue(first is XtreamSiteProvider)
        let replacement = try XtreamConfiguration(id: original.id, name: "Updated", server: "https://updated.invalid")
        let updated = await registry.nativeProvider(for: try replacement.site())
        let provider = try XCTUnwrap(updated as? XtreamSiteProvider)
        XCTAssertEqual(provider.configuration, replacement)
    }

    func testCredentialFreeResourceSurvivesProviderRecreationAndEscapesPathSegments() async throws {
        let fixture = try XtreamEdgeFixture(initialCredentials: .init(username: "fixture/user?x", password: "fixture#pass%"))
        defer { fixture.cleanup() }
        let resource = try XtreamResource(accountID: fixture.configuration.id, kind: "movie", streamID: "11", format: "mp4")
        XCTAssertEqual(try XtreamResource(resource.encoded), resource)
        XCTAssertEqual(HistoryPersistencePolicy.sanitizedEpisodeLocator(resource.encoded), resource.encoded)
        XCTAssertFalse(resource.encoded.contains("fixture"))
        let credentials = fixture.credentials
        let recreated = try XtreamSiteProvider(configuration: fixture.configuration,
            client: HTTPClient(session: fixture.session), credentials: { try credentials.read() })
        let player = try await recreated.playerContent(site: fixture.site, flag: "Xtream", id: resource.encoded)
        XCTAssertEqual(URLComponents(string: player.url)?.percentEncodedPath,
            "/base/movie/fixture%2Fuser%3Fx/fixture%23pass%25/11.mp4")
    }

    func testLiveCataloguePreservesUncategorizedChannelsWithSameChannelCandidates() async throws {
        let fixture = try XtreamEdgeFixture(liveRows: """
        [{"stream_id":41,"name":"Known","category_id":"1"},
         {"stream_id":42,"name":"Missing category"},
         {"stream_id":43,"name":"Unknown category","category_id":"missing"}]
        """)
        defer { fixture.cleanup() }
        let groups = try await fixture.provider.liveGroups()
        let channels = groups.flatMap(\.channels)
        XCTAssertEqual(Set(channels.map(\.number)), Set(["41", "42", "43"]))
        for channel in channels {
            XCTAssertEqual(channel.urls.count, 2)
            let candidates = try channel.urls.map(XtreamResource.init)
            XCTAssertEqual(Set(candidates.map(\.streamID)), [channel.number])
            XCTAssertEqual(Set(candidates.map(\.accountID)), [fixture.configuration.id])
            XCTAssertEqual(Set(candidates.map(\.format)), ["ts", "m3u8"])
        }
    }

    func testBackupCannotRebindExistingAccountOriginOrChangeCredentials() throws {
        let suite = "XtreamEdgeTests.binding.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        let account = try XtreamConfiguration(name: "Owned", server: "https://owned.invalid")
        preferences.xtreamConfigurations = [account]
        try preferences.saveXtreamCredentials(.init(username: "fixture", password: "private-fixture"), for: account.id)
        var snapshot = UserPreferenceSnapshot(preferences: preferences)
        snapshot.xtreamConfigurations = [try XtreamConfiguration(id: account.id, name: "Imported", server: "https://other.invalid")]
        snapshot.apply(to: preferences)
        XCTAssertEqual(preferences.xtreamConfigurations, [account])
        XCTAssertEqual(try preferences.xtreamCredentials(for: account.id).password, "private-fixture")
    }

    func testBackupCannotRebindRetainedKeychainCredentialsAfterPreferencesReset() throws {
        let originalSuite = "XtreamEdgeTests.original.\(UUID().uuidString)"
        let restoredSuite = "XtreamEdgeTests.restored.\(UUID().uuidString)"
        let originalDefaults = try XCTUnwrap(UserDefaults(suiteName: originalSuite))
        let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: restoredSuite))
        defer {
            originalDefaults.removePersistentDomain(forName: originalSuite)
            restoredDefaults.removePersistentDomain(forName: restoredSuite)
        }
        let retainedKeychain = MemoryCredentialStore()
        let original = UserPreferences(defaults: originalDefaults, credentialStore: retainedKeychain)
        let account = try XtreamConfiguration(name: "Owned", server: "https://owned.invalid")
        original.xtreamConfigurations = [account]
        try original.saveXtreamCredentials(.init(username: "fixture", password: "private-fixture"), for: account.id)
        var snapshot = UserPreferenceSnapshot(preferences: original)
        snapshot.xtreamConfigurations = [try XtreamConfiguration(id: account.id, name: "Changed", server: "https://other.invalid")]

        // A preferences reset does not imply the Keychain has been cleared.
        let restored = UserPreferences(defaults: restoredDefaults, credentialStore: retainedKeychain)
        snapshot.apply(to: restored)
        XCTAssertThrowsError(try restored.xtreamCredentials(for: account.id)) {
            XCTAssertEqual($0 as? XtreamError, .authorizationRequired)
        }
    }

    func testBackupRestoresValidAccountsAndDropsInvalidCredentialBearingServer() throws {
        let account = try XtreamConfiguration(name: "Valid", server: "https://valid.invalid")
        var invalid = account
        invalid.id = UUID()
        invalid.server = "https://username:private-fixture@invalid.invalid"
        let data = try JSONSerialization.data(withJSONObject: [
            "xtreamConfigurations": try JSONSerialization.jsonObject(with: JSONEncoder().encode([account, invalid]))
        ])
        let snapshot = try JSONDecoder().decode(UserPreferenceSnapshot.self, from: data)
        XCTAssertEqual(snapshot.xtreamConfigurations, [account])
    }

    func testConfigurationReferenceResolvesWithoutCredentialsOrExternalProvider() async throws {
        let fixture = try XtreamEdgeFixture()
        defer { fixture.cleanup() }
        let suite = "XtreamEdgeTests.config.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        preferences.xtreamConfigurations = [fixture.configuration]
        let resolver = ConfigResolver(httpClient: HTTPClient(session: fixture.session), preferences: preferences)

        let resolved = try await resolver.loadVodInput(url: fixture.configuration.url)
        XCTAssertEqual(resolved.canonicalURL, fixture.configuration.url)
        XCTAssertNil(resolved.providerID)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(resolved.json.utf8)) as? [String: Any])
        let sites = try XCTUnwrap(payload["sites"] as? [[String: Any]])
        let ext = try XCTUnwrap(sites.first?["ext"] as? [String: Any])
        let restoredAccount = try JSONDecoder().decode(XtreamConfiguration.self,
            from: JSONSerialization.data(withJSONObject: ext))
        XCTAssertEqual(restoredAccount.server, fixture.configuration.server)
        XCTAssertFalse(resolved.json.contains("fictional-secret"))
        XCTAssertThrowsError(try preferences.xtreamCredentials(for: fixture.configuration.id))
    }

    func testUnknownLocalAccountReferenceRequiresAuthorizationWithoutNetworkFallback() async throws {
        let fixture = try XtreamEdgeFixture()
        defer { fixture.cleanup() }
        let suite = "XtreamEdgeTests.missing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        let resolver = ConfigResolver(httpClient: HTTPClient(session: fixture.session), preferences: preferences)
        do {
            _ = try await resolver.loadVodInput(url: fixture.configuration.url)
            XCTFail("Unknown local account IDs must require reauthorization")
        } catch { XCTAssertEqual(error as? XtreamError, .authorizationRequired) }
    }

    @MainActor
    func testSavedXtreamStartupAndRetryDoNotRequireExternalComponents() async throws {
        let fixture = try XtreamEdgeFixture()
        defer { fixture.cleanup() }
        let suite = "XtreamEdgeTests.startup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xtream-startup-tests-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        preferences.xtreamConfigurations = [fixture.configuration]
        preferences.currentVodConfigUrl = fixture.configuration.url
        let state = AppState(
            startProxyServer: false,
            configResolver: ConfigResolver(httpClient: HTTPClient(session: fixture.session), preferences: preferences),
            storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences,
            providerRuntimeRegistrationOverride: { false },
            providerRuntimeStartupOverride: { false }
        )
        await state.initialConfigTask?.value
        XCTAssertTrue(state.isConfigLoaded)
        XCTAssertEqual(state.savedConfigStartupPhase, .ready)
        XCTAssertEqual(state.sites.map(\.key), [fixture.configuration.url])

        state.retrySavedConfigStartup()
        await state.initialConfigTask?.value
        XCTAssertTrue(state.isConfigLoaded)
        XCTAssertEqual(state.savedConfigStartupPhase, .ready)
        XCTAssertEqual(state.sites.map(\.key), [fixture.configuration.url])
    }
}
