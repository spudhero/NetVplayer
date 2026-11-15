import AppKit
import Foundation
import Combine
import Models

enum AppRelaunchError: LocalizedError {
    case invalidBundle
    case alreadyScheduled
    var errorDescription: String? {
        switch self {
        case .invalidBundle: L10n.text("请从应用程序文件夹运行 NetVplayer 后再重启。")
        case .alreadyScheduled: L10n.text("应用正在重启。")
        }
    }
}

enum AppRelaunchPolicy {
    static let script = """
    while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.05; done
    /usr/bin/open -n "$2"
    """

    static func command(parentPID: Int32, appURL: URL) throws -> (URL, [String]) {
        let url = appURL.standardizedFileURL
        guard url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path) else {
            throw AppRelaunchError.invalidBundle
        }
        // PID and path are positional parameters. They never become shell source.
        return (
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", script, "netvplayer-relaunch", String(parentPID), url.path]
        )
    }
}

@MainActor
final class AppRelaunchCoordinator: ObservableObject {
    static let shared = AppRelaunchCoordinator(showFailure: { NetVplayerWindowCoordinator.shared.showMainWindow() })
    @Published private(set) var failure: String?
    private(set) var helperScheduled = false
    private let gate: AppRestartGate
    private let cleanup: @MainActor () async -> Bool
    private let launchHelper: () throws -> Void
    private let terminate: () -> Void
    private let showFailure: () -> Void
    private var task: Task<Void, Never>?

    init(gate: AppRestartGate = .shared,
         cleanup: @escaping @MainActor () async -> Bool = { await AppStartup.shared.terminate().value },
         launchHelper: @escaping () throws -> Void = {
             let command = try AppRelaunchPolicy.command(
                 parentPID: ProcessInfo.processInfo.processIdentifier, appURL: Bundle.main.bundleURL)
             let helper = Process()
             helper.executableURL = command.0
             helper.arguments = command.1
             helper.environment = [:]
             try helper.run()
         }, terminate: @escaping () -> Void = { NSApp.terminate(nil) },
         showFailure: @escaping () -> Void = {}) {
        self.gate = gate
        self.cleanup = cleanup
        self.launchHelper = launchHelper
        self.terminate = terminate
        self.showFailure = showFailure
    }

    func relaunch() throws {
        guard task == nil else { throw AppRelaunchError.alreadyScheduled }
        guard let lease = gate.acquire(.language) else { throw AppUpdateError.restartBusy }
        failure = nil
        task = Task { @MainActor in
            let completed = await self.gate.prepare(lease, cleanup: self.cleanup)
            guard self.gate.owns(lease) else { self.task = nil; return }
            guard completed else {
                self.failure = L10n.text("清理尚未完成，应用未重启。请重试。")
                self.gate.release(lease)
                self.task = nil
                self.showFailure()
                return
            }
            do {
                try self.gate.deliver(lease) { try self.launchHelper() }
                self.helperScheduled = true
                self.terminate()
            } catch {
                self.failure = error.localizedDescription
                self.gate.release(lease)
                self.task = nil
                self.showFailure()
            }
        }
    }

    func waitForRelaunch() async { await task?.value }
}
