import Foundation
import Darwin
import Testing
@testable import SpiderEngine

@Test func androidBootstrapSharesConcurrentPreparation() async throws {
    let probe = BootstrapProbe()
    let bootstrap = AndroidRuntimeBootstrap { _, _ in
        await probe.started()
        try await Task.sleep(for: .milliseconds(100))
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<12 { group.addTask { try await bootstrap.prepare() } }
        try await group.waitForAll()
    }
    #expect(await probe.attempts == 1)
}

@Test func androidBootstrapRetriesAfterTransientFailure() async throws {
    let probe = BootstrapProbe()
    let bootstrap = AndroidRuntimeBootstrap { _, _ in
        if await probe.started() == 1 { throw URLError(.notConnectedToInternet) }
    }
    await #expect(throws: URLError.self) { try await bootstrap.prepare() }
    try await bootstrap.prepare()
    #expect(await probe.attempts == 2)
}

@Test func androidBootstrapCancellationDrainsAndAllowsRetry() async throws {
    let probe = BootstrapProbe()
    let bootstrap = AndroidRuntimeBootstrap { _, _ in
        if await probe.started() == 1 { try await Task.sleep(for: .seconds(30)) }
    }
    let preparation = Task { try await bootstrap.prepare() }
    while await probe.attempts == 0 { await Task.yield() }
    await bootstrap.cancel()
    await #expect(throws: CancellationError.self) { try await preparation.value }
    try await bootstrap.prepare()
    #expect(await probe.attempts == 2)
}

private actor BootstrapProbe {
    private(set) var attempts = 0
    @discardableResult func started() -> Int { attempts += 1; return attempts }
}


@Test func androidBootstrapCancelsItsOwnedInstallerAndChild() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-cancel-" + UUID().uuidString)
    let executable = root.appendingPathComponent("runtimes/cpython/bin/python3")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // This controlled installer uses the same private process group as the real
    // installer, and reaps its own child while handling group termination.
    let script = """
    #!/usr/bin/python3
    import os, signal, subprocess, sys
    os.setpgid(0, 0)
    def stop(*args): raise SystemExit(143)
    signal.signal(signal.SIGTERM, stop)
    child = subprocess.Popen(['/bin/sleep', '30'])
    try:
        open('child.pid', 'w').write(str(child.pid))
        print('{"phase":"child-running"}', flush=True)
        child.wait()
    finally:
        child.wait(timeout=2)
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let started = BootstrapProbe()
    let task = Task {
        try await AndroidRuntimeBootstrap.runInstaller(installed: root, assembled: root.appendingPathComponent("component"),
            cache: root.appendingPathComponent("cache"), progress: { _ in _ = await started.started() })
    }
    for _ in 0..<200 {
        if await started.attempts > 0 { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    guard await started.attempts > 0 else {
        task.cancel(); _ = await task.result
        Issue.record("Controlled installer did not start"); return
    }
    let pid = try #require(Int32(String(contentsOf: root.appendingPathComponent("child.pid"), encoding: .utf8)))
    task.cancel()
    _ = await task.result
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
}
