import Foundation

public enum TestRuntime {
    public static let isRunning = detect(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )

    public static func detect(arguments: [String], environment: [String: String]) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        let executable = URL(fileURLWithPath: arguments.first ?? "").lastPathComponent
        if executable.hasSuffix("PackageTests") { return true }
        return arguments.contains {
            $0.hasSuffix(".xctest") || $0.contains(".xctest/") || $0 == "swift-testing"
        }
    }
}
