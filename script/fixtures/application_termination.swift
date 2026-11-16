import AppKit

func record(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

@MainActor
enum AppStartup {
    static let shared = StartupFixture()
}

@MainActor
final class StartupFixture {
    enum Phase { case ready, stopped, terminationFailed }
    var phase = Phase.ready
    var attempts = 0

    func terminate() -> Task<Bool, Never> {
        attempts += 1
        let attempt = attempts
        return Task { @MainActor in
            record("cleanup_started:\(attempt)")
            try? await Task.sleep(for: .milliseconds(150))
            if CommandLine.arguments.last == "retry" && attempt == 1 {
                phase = .terminationFailed
                return false
            }
            phase = .stopped
            record("cleanup_completed:\(attempt)")
            return true
        }
    }
}

@MainActor
final class TerminationDelegate: NSObject, NSApplicationDelegate {
    var terminationReplyTask: Task<Void, Never>?
    var restartHandoffPending = false

    // The runner inserts the actual application's delegate method here.
    // __APPLICATION_SHOULD_TERMINATE__

    func applicationDidFinishLaunching(_ notification: Notification) {
        record("fixture_pid:\(ProcessInfo.processInfo.processIdentifier)")
        let handoff = CommandLine.arguments.last == "handoff"
        restartHandoffPending = handoff
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if handoff {
                precondition(AppStartup.shared.attempts == 0, "quit must preserve the restart handoff")
                record("handoff_preserved")
                self.restartHandoffPending = false
            } else {
                record("concurrent_quit")
            }
            NSApp.terminate(nil)
        }
    }

    func showMainWindowIfNeeded() {
        record("cleanup_failed_app_retained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSApp.terminate(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        precondition(AppStartup.shared.phase == .stopped, "must complete cleanup before exit")
        record("will_terminate:\(AppStartup.shared.attempts)")
    }
}

@main
struct TerminationProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = TerminationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
