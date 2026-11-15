import Foundation
import Testing
import Models
import Storage
@testable import DriveEngine
import Networking
import FileServiceEngine
import MediaServerEngine
@testable import NetVplayerApp

@Suite("MSC-07 local read-only HTTP boundary", .serialized, .timeLimit(.minutes(2)))
struct LocalAutomationTests {
    private func request(_ port: UInt16, _ path: String = "/v1/health", token: String? = nil,
                         method: String = "GET", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]; configuration.urlCache = nil
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
        request.timeoutInterval = 3; request.httpMethod = method
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }
    private func object(_ data: Data) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]) }

    @Test func authenticationRotationRoutesAndRevocationOverRealHTTP() async throws {
        let counter = AutomationCounter()
        let server = LocalReadOnlyServer { _ in await counter.increment(); return Data("{}".utf8) }
        let initialTokenAbsent = await server.tokenForUser() == nil
        #expect(initialTokenAbsent)
        let port = try await server.start()
        let token = try #require(await server.tokenForUser())
        #expect(try await request(port).1.statusCode == 401)
        #expect(try await request(port, token: "invalid-isolated-token").1.statusCode == 401)
        for endpoint in ["/v1/tasks", "/v1/services", "/v1/health"] {
            let response = try await request(port, endpoint, token: token).1
            #expect(response.statusCode == 200)
            #expect(response.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            #expect(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
        }
        for path in ["/v1/health?token=unsupported", "/file", "/proxy", "/v1/search", "/v1/resume", "/v1/config", "/v1/files"] {
            #expect(try await request(port, path, token: token).1.statusCode == 404)
        }
        for method in ["POST", "PUT", "DELETE", "OPTIONS", "HEAD"] {
            #expect(try await request(port, token: token, method: method).1.statusCode == 405)
        }
        #expect(try await request(port, token: token, headers: ["Origin": "https://untrusted.invalid"]).1.statusCode == 400)
        #expect(try await request(port, token: token, headers: ["Host": "untrusted.invalid"]).1.statusCode == 400)
        #expect(await counter.value == 3)
        try await server.rotateToken()
        #expect(try await request(port, token: token).1.statusCode == 401)
        let next = try #require(await server.tokenForUser())
        let changed = next != token; #expect(changed)
        #expect(try await request(port, token: next).1.statusCode == 200)
        await server.stop()
        let revoked = await server.tokenForUser() == nil; #expect(revoked)
        await #expect(throws: (any Error).self) { _ = try await request(port, token: next) }
        let secondPort = try await server.start()
        #expect(try await request(secondPort, token: next).1.statusCode == 401)
        await server.stop()
    }

    @Test func rotationRejectsAlreadyAdmittedPendingResponse() async throws {
        let gate = AutomationReadGate()
        let server = LocalReadOnlyServer { _ in await gate.read(); return Data("{}".utf8) }
        let port = try await server.start(), token = try #require(await server.tokenForUser())
        let pending = Task { try await request(port, token: token) }
        while !(await gate.entered) { await Task.yield() }
        try await server.rotateToken()
        await gate.release()
        #expect(try await pending.value.1.statusCode == 401)
        await server.stop()
    }

    @Test func allConnectionAttemptsConsumeBudgetAndHeadersAreBounded() async throws {
        let counter = AutomationCounter()
        let server = LocalReadOnlyServer(requestsPerMinute: 3) { _ in await counter.increment(); return Data("{}".utf8) }
        let port = try await server.start(), token = try #require(await server.tokenForUser())
        #expect(try await request(port).1.statusCode == 401)
        #expect(try await request(port, token: token).1.statusCode == 200)
        #expect(try await request(port, token: token, headers: ["X-Padding": String(repeating: "a", count: 9000)]).1.statusCode == 431)
        let response = try await request(port, token: token).1
        #expect(response.statusCode == 429 && response.value(forHTTPHeaderField: "Retry-After") == "60")
        #expect(await counter.value == 1)
        // Rotating credentials must not reset an exhausted rate budget.
        try await server.rotateToken()
        #expect(try await request(port, token: await server.tokenForUser()).1.statusCode == 429)
        await server.stop()
    }

    @Test @MainActor func actualTaskProjectionAndQueriesPreserveRecoveryAndServiceRequests() async throws {
        let fixture = try AutomationAppFixture(); defer { fixture.remove() }
        let app = fixture.app()
        #expect(!app.localAutomation.enabled && !app.localAutomation.busy)
        let calls = AutomationCounter()
        let scope = DriveTransferTaskScope(provider: .quark, cacheKey: "private/cache", sourceKey: "private/source",
            accountReference: "private-account", configurationIdentity: "private-config", target: "/private-target",
            shareID: "private-share", sourceFileID: "private-file", name: "private-title.mkv", size: 1)
        do {
            _ = try await app.driveTransferCoordinator.confirmedTransfer(cacheKey: scope.cacheKey, scope: scope) { attempt in
                _ = try await attempt.submit(previousIDs: []) { await calls.increment(); throw URLError(.networkConnectionLost) }
                throw DriveEngineError.transferConfirmationPending()
            }
        } catch DriveEngineError.transferConfirmationPending { }
        let recovery = try Data(contentsOf: fixture.root.appendingPathComponent(DriveTransferTaskStore.filename))
        let history = try Data(contentsOf: fixture.root.appendingPathComponent(TaskDiagnosticStore.filename))
        let task = try #require(app.driveTaskStore.records().first)
        #expect(task.protectsUncertainWrite)
        let file = FileServiceConfiguration(name: "private-service", kind: .smb, address: "smb://must-not-contact.invalid", share: "private-share")
        let hidden = FileServiceConfiguration(name: "unselected-private-service", kind: .local)
        try app.fileServiceStore.save(.init(services: [file, hidden]))
        let choice = try #require(app.automationServiceChoices.first { $0.name == file.name })
        app.localAutomation.select(choice.id, enabled: true)
        await app.localAutomation.setEnabled(true)
        let port = try #require(app.localAutomation.port)
        // Test server uses the exact same production read closure; controller's
        // token never needs a testing export or a persistent credential.
        let server = LocalReadOnlyServer { endpoint in try await app.localAutomationData(endpoint) }
        let testPort = try await server.start(), token = try #require(await server.tokenForUser())
        for _ in 0..<3 {
            let data = try await request(testPort, "/v1/tasks", token: token).0
            let report = try object(data)
            #expect(Set(report.keys) == ["schemaVersion", "generatedAt", "tasks"])
            let rows = try #require(report["tasks"] as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(Set(rows[0].keys) == ["correlationID", "kind", "provider", "events"])
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("private") && !text.contains(token))
            let services = try object(try await request(testPort, "/v1/services", token: token).0)
            let selected = try #require(services["services"] as? [[String: Any]])
            #expect(selected.count == 1 && Set(selected[0].keys) == ["serviceID", "kind", "connection"])
            #expect((selected[0]["connection"] as? [String: Any])?["state"] as? String == "unknown")
            #expect(selected[0]["serviceID"] as? String != file.id.uuidString)
            let health = try object(try await request(testPort, "/v1/health", token: token).0)
            #expect(Set(health.keys) == ["schemaVersion", "generatedAt", "application", "taskHistory", "readOnly"])
        }
        #expect(await calls.value == 1)
        #expect(app.driveRecoveryOperations.isEmpty)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(DriveTransferTaskStore.filename)) == recovery)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(TaskDiagnosticStore.filename)) == history)
        #expect(try app.driveTaskStore.records().first == task)
        try app.fileServiceStore.save(.init(services: [hidden]))
        let removed = try object(try await request(testPort, "/v1/services", token: token).0)
        #expect((removed["services"] as? [Any])?.isEmpty == true)
        await server.stop(); await app.localAutomation.setEnabled(false)
        await #expect(throws: (any Error).self) { _ = try await request(port) }
        let reopened = fixture.app()
        #expect(!reopened.localAutomation.enabled && reopened.localAutomation.selectedServices.isEmpty)
        #expect(try reopened.driveTaskStore.records().first == task)
    }

    @Test @MainActor func productionMediaConnectionCacheExpiresAndCredentialChangeRejectsLateResult() async throws {
        let fixture = try AutomationAppFixture(); defer { fixture.remove() }
        let app = fixture.app(), counter = AutomationCounter()
        let account = MediaServerConfiguration(name: "private-name", server: "https://fixture.invalid",
            serverID: "private-server", userID: "local-user")
        try app.mediaServerStore.save([account]); try app.mediaServerStore.saveToken(UUID().uuidString, for: account)
        let runtime = MediaServerRuntime(store: app.mediaServerStore, transport: .init(handler: { request, _ in
            await counter.increment()
            let payload = request.url!.path.hasSuffix("/System/Info/Public")
                ? #"{"Id":"private-server"}"# : #"{"Id":"local-user","Name":"private-user"}"#
            return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        let choice = try #require(app.automationServiceChoices.first)
        app.localAutomation.select(choice.id, enabled: true)
        #expect(ServiceConnectionObservations.shared.snapshot(choice.scope).state == .unknown)
        _ = try await runtime.client(for: account.id)
        let current = ServiceConnectionObservations.shared.snapshot(choice.scope)
        #expect(current.state == .available && current.checkedAt != nil)
        let count = await counter.value
        _ = try await app.localAutomationData(.services)
        _ = try await app.localAutomationData(.health)
        #expect(await counter.value == count)
        let stale = ServiceConnectionObservations.shared.snapshot(choice.scope, now: Date().addingTimeInterval(301))
        #expect(stale.state == .stale && stale.lastKnownState == .available && stale.checkedAt == current.checkedAt)
        let late = ServiceConnectionObservations.shared.begin(choice.scope)
        try app.mediaServerStore.saveToken(UUID().uuidString, for: account)
        ServiceConnectionObservations.shared.finish(late, state: .available)
        #expect(ServiceConnectionObservations.shared.snapshot(choice.scope).state == .unknown)
        let first = ServiceConnectionObservations.shared.begin(choice.scope)
        let second = ServiceConnectionObservations.shared.begin(choice.scope)
        ServiceConnectionObservations.shared.finish(second, state: .needsLogin)
        ServiceConnectionObservations.shared.finish(first, state: .available)
        #expect(ServiceConnectionObservations.shared.snapshot(choice.scope).state == .needsLogin)
        var changed = account; changed.server = "https://changed.invalid"
        try app.mediaServerStore.save([changed])
        #expect(ServiceConnectionObservations.shared.snapshot(app.mediaServerStore.connectionObservationScope(changed)).state == .unknown)
        try app.mediaServerStore.removeToken(for: changed)
    }

    @Test @MainActor func actualLocalConnectionAndFreshAppNeverProbeDuringReads() async throws {
        let fixture = try AutomationAppFixture(); defer { fixture.remove() }
        let app = fixture.app()
        let directory = fixture.root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = FileServiceConfiguration(name: "private-folder", kind: .local)
        try app.fileServiceStore.save(.init(services: [config]))
        let bookmark = try directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try app.fileServiceStore.saveBookmark(bookmark, for: config.id)
        let scope = app.fileServiceStore.connectionObservationScope(config)
        let runtime = FileServiceRuntime(store: app.fileServiceStore)
        #expect(ServiceConnectionObservations.shared.snapshot(scope).state == .unknown)
        let client = try await runtime.client(for: config.id)
        #expect(ServiceConnectionObservations.shared.snapshot(scope).state == .available)
        let timestamp = ServiceConnectionObservations.shared.snapshot(scope).checkedAt
        _ = try await app.localAutomationData(.services)
        #expect(ServiceConnectionObservations.shared.snapshot(scope).checkedAt == timestamp)
        try app.fileServiceStore.saveBookmark(bookmark, for: config.id)
        #expect(ServiceConnectionObservations.shared.snapshot(app.fileServiceStore.connectionObservationScope(config)).state == .unknown)
        await client.disconnect(); await runtime.invalidate(serviceID: config.id)
    }

    @Test @MainActor func corruptHistoryReturnsFixedUnavailableWithoutLeakingOrRewriting() async throws {
        let fixture = try AutomationAppFixture(); defer { fixture.remove() }
        let app = fixture.app(), url = fixture.root.appendingPathComponent(TaskDiagnosticStore.filename)
        let bytes = Data("sensitive-internal-error-and-path".utf8); try bytes.write(to: url)
        let server = LocalReadOnlyServer { endpoint in try await app.localAutomationData(endpoint) }
        let port = try await server.start(), token = try #require(await server.tokenForUser())
        let (data, response) = try await request(port, "/v1/tasks", token: token)
        #expect(response.statusCode == 503 && String(decoding: data, as: UTF8.self) == "{\"error\":503}")
        let health = try object(try await request(port, token: token).0)
        #expect(health["taskHistory"] as? String == "unavailable")
        #expect(try Data(contentsOf: url) == bytes)
        await server.stop()
    }
}

private actor AutomationCounter {
    var value = 0
    func increment() { value += 1 }
}
private actor AutomationReadGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func read() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor private struct AutomationAppFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("msc07-" + UUID().uuidString)
    let suite = "msc07-" + UUID().uuidString
    let defaults: UserDefaults
    let preferences: UserPreferences
    let storage: StorageManager
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        storage = StorageManager(storageDirectory: root)
    }
    func app() -> AppState {
        AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
                 storageManager: storage, userPreferences: preferences, providerRuntimeBootstrap: nil)
    }
    func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}
