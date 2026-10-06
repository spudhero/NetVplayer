import Foundation
import Testing
import ConfigEngine
import Models
import Networking
import Storage
@testable import NetVplayerApp

@Suite("Configuration startup recovery", .serialized)
struct ConfigurationStartupRecoveryTests {
    private let cachedJSON = #"{"sites":[{"key":"cached-source","name":"Cached","type":3,"api":"csp_RecoveryFixture"}]}"#
    private let freshJSON = #"{"sites":[{"key":"fresh-source","name":"Fresh","type":3,"api":"csp_RecoveryFixture"}]}"#

    @MainActor
    @Test(arguments: [false, true])
    func cachedStartupFinishesWhileTheRemoteRequestIsStillPending(hasLiveSnapshot: Bool) async throws {
        let context = try RecoveryTestContext(replies: [.held])
        defer { context.cleanup() }
        let state = try context.makeState(cachedJSON: cachedJSON, includeLiveSnapshot: hasLiveSnapshot)
        await state.initialConfigTask?.value
        try await context.fixture.waitUntilRequested()

        #expect(state.isConfigLoaded)
        #expect(state.savedConfigStartupPhase == .ready)
        #expect(state.sites.map(\.key) == ["cached-source"])
        #expect(context.fixture.requestCount == 1)
        let refresh = try #require(state.configurationRefreshTask)

        context.fixture.completeHeld(with: .configuration(freshJSON))
        await refresh.value
        #expect(state.sites.map(\.key) == ["cached-source"])
        let savedJSON = try #require(context.storage.loadConfigs().first(where: { $0.type == .vod })?.json)
        #expect(try object(savedJSON) == object(freshJSON))
        if hasLiveSnapshot {
            #expect(context.storage.loadConfigs().first(where: { $0.type == .live })?.json == cachedJSON)
        }
        #expect(state.configNotice?.contains("下次加载") == true)
    }

    @MainActor
    @Test func handshakeFailureRetriesAndRefreshesTheSnapshotWithoutReplacingCurrentSites() async throws {
        let gate = RecoveryDelayGate()
        let context = try RecoveryTestContext(replies: [.failure(.secureConnectionFailed), .configuration(freshJSON)])
        defer { context.cleanup() }
        let state = try context.makeState(cachedJSON: cachedJSON, delayGate: gate)
        await state.initialConfigTask?.value
        let refresh = try #require(state.configurationRefreshTask)
        try await gate.waitUntilEntered()

        #expect(state.isConfigLoaded)
        #expect(state.configError == nil)
        #expect(state.configNotice?.contains("安全连接") == true)
        #expect(state.sites.map(\.key) == ["cached-source"])
        #expect(context.storage.loadConfigs().first?.json.contains("cached-source") == true)

        await gate.release()
        await refresh.value
        #expect(context.fixture.requestCount == 2)
        #expect(context.fixture.delays == [.seconds(2)])
        let savedJSON = try #require(context.storage.loadConfigs().first?.json)
        #expect(try object(savedJSON) == object(freshJSON))
        #expect(state.sites.map(\.key) == ["cached-source"])
        #expect(context.preferences.currentVodConfigUrl == context.url)
    }

    @MainActor
    @Test func backgroundRefreshSavesMergedArraysWithoutChangingActiveLiveSources() async throws {
        let context = try RecoveryTestContext(replies: [.held])
        defer { context.cleanup() }
        let remoteSites = #"[{"key":"fresh-source","name":"Fresh","type":3,"api":"csp_RecoveryFixture"}]"#
        let remoteLives = #"[{"name":"Refreshed live source","url":"https://live.example.test/channels.m3u"}]"#
        context.fixture.setReplies([.configuration(remoteSites)], forPath: "/sites.json")
        context.fixture.setReplies([.configuration(remoteLives)], forPath: "/lives.json")
        let state = try context.makeState(cachedJSON: cachedJSON)
        await state.initialConfigTask?.value
        try await context.fixture.waitUntilRequested()
        let refresh = try #require(state.configurationRefreshTask)
        let activeLiveNames = LiveConfig.shared.lives.map(\.name)

        context.fixture.completeHeld(with: .configuration(#"{"sites":"/sites.json","lives":"/lives.json"}"#))
        await refresh.value

        let saved = try object(try #require(context.storage.loadConfigs().first?.json))
        #expect((saved["sites"] as? [[String: Any]])?.first?["key"] as? String == "fresh-source")
        #expect((saved["lives"] as? [[String: Any]])?.first?["name"] as? String == "Refreshed live source")
        #expect(state.sites.map(\.key) == ["cached-source"])
        #expect(LiveConfig.shared.lives.map(\.name) == activeLiveNames)
        #expect(context.fixture.requestCount == 3)
    }

    @MainActor
    @Test func anIncompleteExternalArrayRefreshDoesNotReplaceTheUsableSnapshot() async throws {
        let context = try RecoveryTestContext(replies: [.held])
        defer { context.cleanup() }
        context.fixture.setReplies([.status(503)], forPath: "/sites.json")
        let state = try context.makeState(cachedJSON: cachedJSON)
        await state.initialConfigTask?.value
        try await context.fixture.waitUntilRequested()
        let refresh = try #require(state.configurationRefreshTask)

        context.fixture.completeHeld(with: .configuration(#"{"sites":"/sites.json"}"#))
        await refresh.value

        #expect(state.isConfigLoaded)
        #expect(state.sites.map(\.key) == ["cached-source"])
        #expect(context.storage.loadConfigs().first?.json == cachedJSON)
        #expect(state.configNotice?.contains("已保留") == true)
    }

    @MainActor
    @Test func aDirectMacCMSResponseRefreshesItsNormalizedSnapshot() async throws {
        let context = try RecoveryTestContext(replies: [.held])
        defer { context.cleanup() }
        let state = try context.makeState(cachedJSON: cachedJSON)
        await state.initialConfigTask?.value
        try await context.fixture.waitUntilRequested()
        let refresh = try #require(state.configurationRefreshTask)

        context.fixture.completeHeld(with: .configuration(#"{"code":1,"page":1,"pagecount":1,"limit":20,"total":0,"class":[{"type_id":1,"type_name":"Movies"}],"list":[]}"#))
        await refresh.value

        let saved = try object(try #require(context.storage.loadConfigs().first?.json))
        #expect((saved["sites"] as? [[String: Any]])?.first?["api"] as? String == context.url)
        #expect(state.configNotice?.contains("下次加载") == true)
        #expect(state.sites.map(\.key) == ["cached-source"])
        #expect(context.fixture.requestCount == 1)
    }

    @MainActor
    @Test func startupWithoutASnapshotRecoversAfterATemporaryHandshakeFailure() async throws {
        let gate = RecoveryDelayGate()
        let context = try RecoveryTestContext(replies: [.failure(.secureConnectionFailed), .configuration(freshJSON)])
        defer { context.cleanup() }
        let state = try context.makeState(delayGate: gate)
        await state.initialConfigTask?.value
        let refresh = try #require(state.configurationRefreshTask)
        #expect(!state.isConfigLoaded)
        #expect(state.configError?.contains("安全连接") == true)

        await gate.release()
        await refresh.value
        #expect(state.isConfigLoaded)
        #expect(state.savedConfigStartupPhase == .ready)
        #expect(state.configError == nil)
        #expect(state.sites.map(\.key) == ["fresh-source"])
        #expect(context.fixture.requestCount == 2)
        #expect(context.fixture.delays == [.seconds(2)])
    }

    @MainActor
    @Test func fileServicesBecomingReadyDoNotPreventRecoveryOfTheRemoteSource() async throws {
        let gate = RecoveryDelayGate()
        let context = try RecoveryTestContext(replies: [.failure(.secureConnectionFailed), .configuration(freshJSON)])
        defer { context.cleanup() }
        let state = try context.makeState(delayGate: gate)
        await state.initialConfigTask?.value
        let refresh = try #require(state.configurationRefreshTask)
        try await gate.waitUntilEntered()
        let service = FileServiceConfiguration(name: "Local fixture", kind: .local, rootPath: context.directory.path)
        try FileServiceStore(storage: context.storage, preferences: context.preferences).save(.init(services: [service]))
        state.reloadFileServiceSites()
        #expect(state.isConfigLoaded)
        #expect(state.sites.map(\.key) == [service.siteKey])

        await gate.release()
        await refresh.value

        #expect(state.libraryConfigurationURL == context.url)
        #expect(state.configError == nil)
        #expect(state.sites.map(\.key) == ["fresh-source", service.siteKey])
        #expect(context.fixture.requestCount == 2)
    }

    @MainActor
    @Test func continuousHandshakeFailuresStopAfterThreeRetriesAndKeepTheSnapshot() async throws {
        let context = try RecoveryTestContext(replies: [.failure(.secureConnectionFailed)])
        defer { context.cleanup() }
        let state = try context.makeState(cachedJSON: cachedJSON)
        await state.initialConfigTask?.value
        await state.configurationRefreshTask?.value

        #expect(context.fixture.requestCount == 4)
        #expect(context.fixture.delays == [.seconds(2), .seconds(5), .seconds(10)])
        #expect(state.configurationRefreshTask == nil)
        #expect(state.isConfigLoaded)
        #expect(state.savedConfigStartupPhase == .ready)
        #expect(state.sites.map(\.key) == ["cached-source"])
        #expect(context.storage.loadConfigs().first?.json.contains("cached-source") == true)
    }

    @MainActor
    @Test(arguments: [401, 403])
    func authorizationFailureRemainsVisibleWithoutAutomaticRetries(status: Int) async throws {
        let context = try RecoveryTestContext(replies: [.status(status)])
        defer { context.cleanup() }
        let state = try context.makeState(cachedJSON: cachedJSON)
        await state.initialConfigTask?.value
        await state.configurationRefreshTask?.value

        #expect(context.fixture.requestCount == 1)
        #expect(context.fixture.delays.isEmpty)
        #expect(state.isConfigLoaded)
        #expect(state.configNotice?.contains("拒绝访问") == true)
        #expect(context.storage.loadConfigs().first?.json.contains("cached-source") == true)
    }

    @MainActor
    @Test func certificateFailureKeepsSavedSitesAndDoesNotRetryTheCertificate() async throws {
        let context = try RecoveryTestContext(replies: [.failure(.serverCertificateUntrusted)])
        defer { context.cleanup() }
        let state = try context.makeState(cachedJSON: cachedJSON)
        await state.initialConfigTask?.value
        await state.configurationRefreshTask?.value
        #expect(state.isConfigLoaded)
        #expect(context.fixture.requestCount == 1)
        #expect(context.fixture.delays.isEmpty)
        #expect(state.configNotice?.contains("安全连接") == true)
    }

    @MainActor
    @Test func switchingSourcesDuringRetryPreventsTheOldSnapshotFromBeingUpdated() async throws {
        let gate = RecoveryDelayGate()
        let context = try RecoveryTestContext(replies: [.failure(.secureConnectionFailed), .configuration(freshJSON)])
        defer { context.cleanup() }
        context.fixture.setReplies([.configuration(freshJSON)], forPath: "/replacement")
        let state = try context.makeState(cachedJSON: cachedJSON, delayGate: gate)
        await state.initialConfigTask?.value
        let refresh = try #require(state.configurationRefreshTask)
        try await gate.waitUntilEntered()
        let replacementURL = context.origin + "/replacement"
        await state.loadConfig(url: replacementURL, waitForProviderRuntime: false)
        await gate.release()
        await refresh.value

        #expect(context.preferences.currentVodConfigUrl == replacementURL)
        #expect(state.sites.map(\.key) == ["fresh-source"])
        #expect(context.fixture.count(forPath: "/config") == 1)
        #expect(context.storage.loadConfigs().first(where: { $0.url == context.url })?.json.contains("cached-source") == true)
    }

    @MainActor
    @Test(arguments: [true, false])
    func removingTheCurrentSourceCancelsItsPendingRetry(isDefaultSource: Bool) async throws {
        let gate = RecoveryDelayGate()
        let context = try RecoveryTestContext(replies: [.failure(.secureConnectionFailed), .configuration(freshJSON)])
        defer { context.cleanup() }
        let state = try context.makeState(cachedJSON: cachedJSON, delayGate: gate)
        await state.initialConfigTask?.value
        let refresh = try #require(state.configurationRefreshTask)
        try await gate.waitUntilEntered()
        let defaultURL = context.origin + "/default"
        if !isDefaultSource { context.preferences.currentVodConfigUrl = defaultURL }
        #expect(state.deleteSavedConfig(try #require(state.savedConfigs.first)))
        await gate.release()
        await refresh.value
        #expect(context.preferences.currentVodConfigUrl == (isDefaultSource ? "" : defaultURL))
        #expect(context.storage.loadConfigs().isEmpty)
        #expect(context.fixture.requestCount == 1)
    }

    private func object(_ json: String) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    }
}

@MainActor
private final class RecoveryTestContext {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "netvplayer-startup-recovery-\(UUID().uuidString)"
    let origin = "https://recovery-\(UUID().uuidString.lowercased()).example.test"
    let defaults: UserDefaults
    let preferences: UserPreferences
    let storage: StorageManager
    let fixture: RecoveryRequestFixture
    var url: String { origin + "/config" }

    init(replies: [RecoveryRequestFixture.Reply]) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        preferences = UserPreferences(defaults: defaults)
        storage = StorageManager(storageDirectory: directory)
        fixture = RecoveryRequestFixture(replies: replies)
        RecoveryRequestRegistry.shared.register(fixture, host: URL(string: origin)!.host!)
        preferences.currentVodConfigUrl = url
    }

    func makeState(cachedJSON: String? = nil, delayGate: RecoveryDelayGate? = nil, includeLiveSnapshot: Bool = false) throws -> AppState {
        if let cachedJSON {
            var configs = [Config(url: url, json: cachedJSON)]
            if includeLiveSnapshot { configs.insert(Config(type: .live, url: url, json: cachedJSON), at: 0) }
            try storage.saveConfigs(configs)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryURLProtocol.self]
        let fixture = fixture
        return AppState(
            startProxyServer: false,
            configResolver: ConfigResolver(httpClient: HTTPClient(session: URLSession(configuration: configuration)), allowsProxyFallback: false),
            storageManager: storage,
            userPreferences: preferences,
            providerRuntimeRegistrationOverride: { true },
            providerRuntimeStartupOverride: { false },
            configurationRefreshSleeper: { delay in
                fixture.record(delay: delay)
                if let delayGate { await delayGate.wait() }
                try Task.checkCancellation()
            }
        )
    }

    func cleanup() {
        RecoveryRequestRegistry.shared.remove(host: URL(string: origin)!.host!)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor RecoveryDelayGate {
    private var released = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered)
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class RecoveryRequestFixture: @unchecked Sendable {
    enum Reply { case failure(URLError.Code), status(Int), configuration(String), held }
    private let lock = NSLock()
    private var replies: [String: [Reply]]
    private var counts: [String: Int] = [:]
    private var recordedDelays: [Duration] = []
    private var held: [RecoveryURLProtocol] = []

    init(replies: [Reply]) { self.replies = ["/config": replies] }
    var requestCount: Int { lock.withLock { counts.values.reduce(0, +) } }
    var delays: [Duration] { lock.withLock { recordedDelays } }
    func count(forPath path: String) -> Int { lock.withLock { counts[path] ?? 0 } }
    func record(delay: Duration) { lock.withLock { recordedDelays.append(delay) } }
    func setReplies(_ replies: [Reply], forPath path: String) { lock.withLock { self.replies[path] = replies } }

    func waitUntilRequested() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while requestCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(requestCount > 0)
    }

    func handle(_ request: RecoveryURLProtocol) {
        let reply: Reply = lock.withLock {
            let path = request.request.url!.path
            let count = counts[path] ?? 0
            counts[path] = count + 1
            let options = replies[path] ?? [.status(404)]
            let reply = options[min(count, options.count - 1)]
            if case .held = reply { held.append(request) }
            return reply
        }
        request.complete(with: reply)
    }

    func completeHeld(with reply: Reply) {
        let pending = lock.withLock { let pending = held; held.removeAll(); return pending }
        pending.forEach { $0.complete(with: reply) }
    }

    func stop(_ request: RecoveryURLProtocol) { lock.withLock { held.removeAll { $0 === request } } }
}

private final class RecoveryRequestRegistry: @unchecked Sendable {
    static let shared = RecoveryRequestRegistry()
    private let lock = NSLock()
    private var fixtures: [String: RecoveryRequestFixture] = [:]
    func register(_ fixture: RecoveryRequestFixture, host: String) { lock.withLock { fixtures[host] = fixture } }
    func fixture(host: String) -> RecoveryRequestFixture? { lock.withLock { fixtures[host] } }
    func remove(host: String) { lock.withLock { _ = fixtures.removeValue(forKey: host) } }
}

private final class RecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let fixture = RecoveryRequestRegistry.shared.fixture(host: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        fixture.handle(self)
    }
    override func stopLoading() {
        if let host = request.url?.host { RecoveryRequestRegistry.shared.fixture(host: host)?.stop(self) }
    }
    func complete(with reply: RecoveryRequestFixture.Reply) {
        switch reply {
        case .held: return
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .configuration(let json):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                          headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
