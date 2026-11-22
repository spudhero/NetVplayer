import Foundation
import ProviderSDK
import Testing
@testable import ProviderRuntime

@Suite(.serialized)
struct ProviderInteractionTests {
    @Test func dialogActivationTargetsTheCurrentWorkerOnce() async throws {
        let observer = DialogActivationObserver()
        let fixture = try InteractionFixture(onDialogActive: { await observer.record($0) })
        defer { fixture.remove() }
        let saved = ProviderRequest(providerID: "fixture", operation: .player)
        _ = try await fixture.client.request(saved, interaction: fixture.policy)
        #expect(await observer.processIDs.isEmpty)
        let dialog = ProviderRequest(providerID: "fixture", operation: .player, arguments: ["mode": .string("activation")])
        let response = try await fixture.client.request(dialog, interaction: fixture.policy)
        guard case .number(let processID) = response.result else {
            Issue.record("Expected the responding helper's PID")
            try await fixture.client.stopAndConfirmExit()
            return
        }
        #expect(await observer.processIDs == [Int32(processID)])
        try await fixture.client.stopAndConfirmExit()
    }

    @Test(arguments: ["uc", "ali", "quark", "baidu", "unknown"])
    func dialogWaitDoesNotConsumeNetworkBudgetOrDelaySavedSessions(drive: String) async throws {
        let fixture = try InteractionFixture()
        defer { fixture.remove() }
        let first = ProviderRequest(providerID: "fixture", operation: .player,
            arguments: ["mode": .string("authorize"), "drive": .string(drive)])
        let response = try await fixture.client.request(first, timeout: .seconds(1), interaction: fixture.policy)
        #expect(response.ok)
        #expect(response.result == .string(drive))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("interaction-request").path))
        let clock = ContinuousClock(), start = clock.now
        let saved = try await fixture.client.request(ProviderRequest(providerID: "fixture", operation: .player),
            timeout: .seconds(1), interaction: fixture.policy)
        #expect(saved.ok)
        #expect(start.duration(to: clock.now) < .seconds(1))
        try await fixture.client.stopAndConfirmExit()
    }

    @Test(arguments: ["waiting", "stale", "malformed"])
    func noninteractiveWorkKeepsItsNetworkDeadline(mode: String) async throws {
        let fixture = try InteractionFixture()
        defer { fixture.remove() }
        let request = ProviderRequest(providerID: "fixture", operation: .player, arguments: ["mode": .string(mode)])
        await #expect(throws: ProviderProcessError.timedOut(request.requestID)) {
            try await fixture.client.request(request, timeout: .milliseconds(250), interaction: fixture.policy)
        }
        try await fixture.client.stopAndConfirmExit()
    }

    @Test(arguments: ["canceled", "stuck", "dismissed"])
    func interactionEndsWithoutAnAutomaticNetworkRetry(mode: String) async throws {
        let fixture = try InteractionFixture(maximumWait: .seconds(2))
        defer { fixture.remove() }
        let request = ProviderRequest(providerID: "fixture", operation: .player, arguments: ["mode": .string(mode)])
        await #expect(throws: mode == "canceled" ? ProviderInteractionError.canceled : ProviderInteractionError.timedOut) {
            try await fixture.client.request(request, timeout: .seconds(2), interaction: fixture.policy)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("interaction-request").path))
        try await fixture.client.stopAndConfirmExit()
    }

    @Test func pageCancellationStillStopsAnActiveAuthorizationWait() async throws {
        let fixture = try InteractionFixture()
        defer { fixture.remove() }
        let request = ProviderRequest(providerID: "fixture", operation: .player, arguments: ["mode": .string("stuck")])
        let task = Task { try await fixture.client.request(request, timeout: .seconds(1), interaction: fixture.policy) }
        let state = fixture.directory.appendingPathComponent("interaction-\(request.requestID).state")
        let clock = ContinuousClock(), end = clock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: state.path), clock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: state.path))
        task.cancel()
        await #expect(throws: ProviderProcessError.canceled(request.requestID)) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: state.path))
        try await fixture.client.stopAndConfirmExit()
    }
}

private actor DialogActivationObserver {
    private(set) var processIDs: [Int32] = []
    func record(_ pid: Int32) { processIDs.append(pid) }
}

private struct InteractionFixture {
    let root: URL
    let directory: URL
    let client: ProviderProcessClient
    let policy: ProviderInteractionPolicy

    init(maximumWait: Duration = .seconds(3), onDialogActive: (@Sendable (Int32) async -> Void)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("netvplayer-interaction-\(UUID().uuidString)")
        directory = root.appendingPathComponent(".runtime")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("helper.py")
        try Self.helper.write(to: script, atomically: true, encoding: .utf8)
        client = ProviderProcessClient(command: ProviderCommand(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path, directory.path], currentDirectoryURL: root, stateDirectoryURL: root,
            environment: ["NETVPLAYER_PROVIDER_ID": "fixture", "NETVPLAYER_PROVIDER_STATE": root.path]))
        policy = ProviderInteractionPolicy(directory: directory, maximumWait: maximumWait,
            pollInterval: .milliseconds(10), onDialogActive: onDialogActive)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    static let helper = #"""
    import json, os, pathlib, sys, time, uuid
    root = pathlib.Path(sys.argv[1])
    for line in sys.stdin:
        request = json.loads(line)
        mode = request.get('arguments', {}).get('mode', '')
        state = root / ('interaction-' + request['request_id'] + '.state')
        if mode == 'activation':
            state.write_text('active')
            time.sleep(0.2)
            state.write_text('active')
            time.sleep(0.2)
        elif mode == 'authorize':
            state.write_text('active')
            time.sleep(1.25)
            state.write_text('idle')
        elif mode == 'stale':
            (root / ('interaction-' + str(uuid.uuid4()) + '.state')).write_text('active')
            time.sleep(3)
        elif mode in ['waiting', 'malformed']:
            if mode == 'malformed': state.write_text('active' * 100)
            time.sleep(3)
        elif mode in ['canceled', 'stuck', 'dismissed']:
            state.write_text('active')
            time.sleep(0.1)
            if mode == 'canceled': state.write_text('canceled')
            if mode == 'dismissed': state.write_text('idle')
            time.sleep(3)
        print(json.dumps({'request_id': request['request_id'], 'ok': True,
            'result': os.getpid() if mode == 'activation' else request.get('arguments', {}).get('drive', 'saved')}), flush=True)
        if request.get('operation') == 'shutdown': break
    """#
}
