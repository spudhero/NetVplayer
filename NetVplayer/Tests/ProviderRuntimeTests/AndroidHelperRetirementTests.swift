#if DEBUG
import Foundation
import Models
import ProviderSDK
import ProviderRuntime
import Testing
@testable import SpiderEngine

@Test(arguments: ["handshake", "init", "home"])
func androidHelperCancellationWaitsForStateLockReleaseBeforeRestart(phase: String) async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    try AndroidRetirementFixture.helper.write(to: fixture.runtime.appendingPathComponent("jdk/bin/java"),
        atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.runtime.appendingPathComponent("jdk/bin/java").path)
    try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
    try phase.write(to: fixture.state.appendingPathComponent("blocked-phase"), atomically: true, encoding: .utf8)
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let binding = try #require(runtime.manifest.bindings.first)
    let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: binding, stateDirectory: fixture.state)
    let sessionRoot = fixture.state.appendingPathComponent("source-sessions-v1")
    let persistent = try runtime.persistentDataDirectory(base: sessionRoot, binding: binding, site: fixture.site)
    try FileManager.default.createDirectory(at: persistent, withIntermediateDirectories: true)
    let account = persistent.appendingPathComponent("account.fixture")
    try Data("synthetic saved account".utf8).write(to: account)
    let first = Task { try await provider.homeContent(site: fixture.site) }
    let release = fixture.state.appendingPathComponent("release-exit")
    do {
        try await AndroidRetirementFixture.waitFor(fixture.state.appendingPathComponent("blocked"))
        first.cancel()
        let replacement = Task { try await provider.homeContent(site: fixture.site) }
        try await AndroidRetirementFixture.waitFor(fixture.state.appendingPathComponent("retiring"))
        // Hold the actual OS lock while a canceled caller's replacement is queued.
        try await Task.sleep(for: .milliseconds(150))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("lock-conflict").path))
        try Data().write(to: release)
        let result = try await replacement.value
        #expect(result.list.first?.vodId == "after-retirement")
        await #expect(throws: ProviderProcessError.self) { try await first.value }
        #expect(try Data(contentsOf: account) == Data("synthetic saved account".utf8))
        #expect(try runtime.persistentDataDirectory(base: sessionRoot, binding: binding, site: fixture.site) == persistent)
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("lock-conflict").path))
        await provider.shutdown()
    } catch {
        try? Data().write(to: release)
        first.cancel()
        _ = try? await first.value
        await provider.shutdown()
        throw error
    }
}

@Test func processClientUnconfirmedExitBlocksRestartUntilTheOwnerExits() async throws {
    let fixture = try DevelopmentAndroidBridgeFixture()
    defer { fixture.remove() }
    try AndroidRetirementFixture.helper.write(to: fixture.runtime.appendingPathComponent("jdk/bin/java"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.runtime.appendingPathComponent("jdk/bin/java").path)
    try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
    try "never".write(to: fixture.state.appendingPathComponent("blocked-phase"), atomically: true, encoding: .utf8)
    let runtime = try DevelopmentAndroidRuntimeLayout.load(root: fixture.runtime)
    let binding = try #require(runtime.manifest.bindings.first)
    let persistent = fixture.state.appendingPathComponent("persistent")
    let client = ProviderProcessClient(command: try runtime.command(binding: binding, stateDirectory: fixture.state,
        persistentDataDirectory: persistent))
    let release = fixture.state.appendingPathComponent("release-exit")
    do {
        _ = try await client.request(ProviderRequest(providerID: runtime.manifest.providerID, operation: .handshake))
        await client.stop(graceful: false)
        await #expect(throws: ProviderMaintenanceError.processRunning) { try await client.stopAndConfirmExit() }
        await #expect(throws: ProviderProcessError.notRunning) { try await client.start() }
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("lock-conflict").path))
        try Data().write(to: release)
        try await client.stopAndConfirmExit()
        let restarted = try await client.request(ProviderRequest(providerID: runtime.manifest.providerID, operation: .handshake))
        #expect(restarted.ok)
        try await client.stopAndConfirmExit()
    } catch {
        try? Data().write(to: release)
        try? await client.stopAndConfirmExit()
        throw error
    }
}

private enum AndroidRetirementFixture {
    static func waitFor(_ file: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: file.path), "Helper fixture did not reach \(file.lastPathComponent)")
    }

    // Synthetic helper, real advisory file lock, deterministic release gate.
    // No Android runtime, Provider, network or user account is accessed.
    static let helper = #"""
#!/usr/bin/python3
import fcntl, json, os, pathlib, signal, sys, time
cwd = pathlib.Path.cwd()
first = not (cwd / 'started-once').exists()
(cwd / 'started-once').touch()
state = pathlib.Path(next(v.split('=', 1)[1] for v in sys.argv if v.startswith('-Dnetvplayer.android.persistentDataDir=')))
state.mkdir(parents=True, exist_ok=True)
lock = open(state / '.helper.lock', 'a')
locked = False
def acquire():
    global locked
    if locked: return True
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        locked = True
        return True
    except BlockingIOError:
        (cwd / 'lock-conflict').touch()
        return False
def stop(signum=None, frame=None):
    if first:
        (cwd / 'retiring').touch()
        deadline = time.monotonic() + 5
        while not (cwd / 'release-exit').exists() and time.monotonic() < deadline:
            time.sleep(0.01)
    os._exit(0)
signal.signal(signal.SIGTERM, stop)
if first: acquire()
phase = (cwd / 'blocked-phase').read_text()
for raw in sys.stdin:
    request = json.loads(raw)
    operation = request['operation']
    if first and operation == phase:
        (cwd / 'blocked').touch()
        while True: time.sleep(0.01)
    response = {'request_id': request['request_id'], 'ok': True, 'result': {}}
    if operation == 'handshake':
        response['result'] = {'provider_id': request['provider_id'], 'protocol': 1}
    elif operation == 'init' and not acquire():
        response.update(ok=False, error={'code': 'provider_error', 'message': 'Android state is already owned by another helper', 'retryable': False})
    elif operation == 'home':
        response['result'] = {'list': [{'vod_id': 'after-retirement', 'vod_name': 'Fixture'}]}
    print(json.dumps(response), flush=True)
    if operation == 'shutdown': stop()
stop()
"""#
}
#endif
