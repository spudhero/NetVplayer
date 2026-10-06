import AppKit
import Foundation
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
final class AppRelaunchCoordinator {
    static let shared = AppRelaunchCoordinator()
    private var scheduled = false

    func relaunch() throws {
        guard !scheduled else { throw AppRelaunchError.alreadyScheduled }
        let command = try AppRelaunchPolicy.command(
            parentPID: ProcessInfo.processInfo.processIdentifier,
            appURL: Bundle.main.bundleURL
        )
        let helper = Process()
        helper.executableURL = command.0
        helper.arguments = command.1
        helper.environment = [:]
        try helper.run()
        scheduled = true
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
