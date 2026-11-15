#if DEBUG
import AppKit
import Foundation

/// Opt-in native scene regression, isolated by StartupRecoveryProbe's private tmp root.
@MainActor
enum StartupWindowProbe {
    static func scheduleIfRequested() {
        guard ProcessInfo.processInfo.environment["NETVPLAYER_STARTUP_PROBE_MODE"] == "windows",
              let probe = StartupRecoveryProbe.current else { return }
        Task { await run(root: probe.root) }
    }

    private static var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue == AppWindowID.main && ($0.isVisible || $0.isMiniaturized) }
    }

    private static func run(root: URL) async {
        let startup = AppStartup.shared
        var checkpoints: [[String: Any]] = []
        func record(_ name: String) {
            checkpoints.append(["name": name, "mainWindows": mainWindows.count,
                                "miniaturized": mainWindows.filter(\.isMiniaturized).count,
                                "phase": String(describing: startup.phase),
                                "runtimePresent": startup.runtime != nil])
        }
        do {
            try await wait { startup.phase == .recovery && mainWindows.count == 1 }
            record("recovery-launch")
            for stage in ["recovery", "ready"] {
                if stage == "ready" {
                    startup.start(.deferRestoration)
                    try await wait { startup.phase == .ready && startup.runtime != nil }
                }
                for cycle in 1...3 {
                    let window = try requireWindow()
                    window.performClose(nil)
                    try await wait { mainWindows.isEmpty }
                    record("\(stage)-close-\(cycle)")
                    // LaunchServices sends the same reopen AppleEvent as the Dock/Finder.
                    for _ in 0..<3 { try await reopen() }
                    try await wait { mainWindows.count == 1 }
                    try await Task.sleep(for: .milliseconds(250))
                    guard mainWindows.count == 1 else { throw Failure.duplicate }
                    record("\(stage)-reopen-\(cycle)")
                }
                let window = try requireWindow()
                window.miniaturize(nil)
                try await wait { window.isMiniaturized }
                record("\(stage)-minimized")
                try await reopen()
                try await wait { !window.isMiniaturized && window.isVisible && mainWindows.count == 1 }
                record("\(stage)-restored")
            }
            try write(["passed": true, "processID": ProcessInfo.processInfo.processIdentifier,
                       "checkpoints": checkpoints], root: root)
        } catch {
            try? write(["passed": false, "error": String(describing: error),
                        "checkpoints": checkpoints], root: root)
        }
        _ = await startup.terminate().value
        NSApp.terminate(nil)
    }

    private static func requireWindow() throws -> NSWindow {
        guard mainWindows.count == 1, let window = mainWindows.first else { throw Failure.duplicate }
        return window
    }

    private static func reopen() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        guard app.processIdentifier == ProcessInfo.processInfo.processIdentifier else { throw Failure.process }
    }

    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func write(_ result: [String: Any], root: URL) throws {
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("window-validation.json"), options: .atomic)
    }
    private enum Failure: Error { case duplicate, process, timeout }
}
#endif
