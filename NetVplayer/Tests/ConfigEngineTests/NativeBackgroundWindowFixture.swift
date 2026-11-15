import Foundation

/// XCTest does not run NSApplication's event loop. Use an isolated AppKit host
/// with the production observers to exercise actual WindowServer notifications.
@MainActor
enum NativeBackgroundWindowFixture {
    static let output = Task.detached(priority: .utility) { () throws -> String in
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("window-budget-native-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("WindowProbe")
        let log = directory.appendingPathComponent("probe.log")
        func run(_ command: String, _ arguments: [String]) throws -> String {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.standardOutput = handle; process.standardError = handle
            try process.run()
            process.waitUntilExit()
            let output = try String(contentsOf: log, encoding: .utf8)
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "NativeBackgroundWindowFixture", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: output])
            }
            return output
        }
        _ = try run("/usr/bin/xcrun", ["swiftc",
            "NetVplayer/Sources/NetVplayerApp/Views/PlaybackInformationVisibility.swift",
            "NetVplayer/Sources/NetVplayerApp/Views/PosterDemandVisibility.swift",
            "NetVplayer/Sources/NetVplayerApp/Views/PosterWorkScheduling.swift",
            "script/fixtures/background_window_visibility.swift", "-o", executable.path])
        let result = try run(executable.path, [])
        guard result.contains("OV91_WINDOW_PROBE_PASS") else {
            throw NSError(domain: "Incomplete native window probe", code: 1)
        }
        print(result)
        return result
    }
}
