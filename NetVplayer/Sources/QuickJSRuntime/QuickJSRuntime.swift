import Foundation

public enum QuickJSRuntimeSource: String, Sendable, Codable {
    case configured
    case bundled
    case providerPackage
    case host
}

public struct QuickJSRuntimeLocation: Sendable, Equatable {
    public let executableURL: URL
    public let runtimeURL: URL
    public let arguments: [String]
    public let source: QuickJSRuntimeSource

    public init(
        executableURL: URL,
        runtimeURL: URL,
        arguments: [String] = [],
        source: QuickJSRuntimeSource
    ) {
        self.executableURL = executableURL
        self.runtimeURL = runtimeURL
        self.arguments = arguments
        self.source = source
    }

    public func commandArguments(_ extra: [String] = []) -> [String] {
        arguments + extra
    }
}

public enum QuickJSRuntimeLocator {
    public static let bundledDirectoryName = "QuickJSRuntime"

    public static func locate(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) -> QuickJSRuntimeLocation? {
        if let configured = environment["NETVPLAYER_QUICKJS_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if let location = makeLocation(for: url, source: .configured, fileManager: fileManager) {
                return location
            }
        }

        if let bundleResourceURL {
            let url = bundleResourceURL
                .appendingPathComponent(bundledDirectoryName, isDirectory: true)
                .appendingPathComponent("bin/qjs")
            if let location = makeLocation(for: url, source: .bundled, fileManager: fileManager) {
                return location
            }
        }

        var candidates: [URL] = []
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("qjs") })
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/qjs",
            "/usr/local/bin/qjs",
            "/usr/bin/qjs",
            "/opt/homebrew/bin/quickjs",
            "/usr/local/bin/quickjs",
            "/usr/bin/quickjs",
        ].map { URL(fileURLWithPath: $0) })
        for candidate in candidates {
            if let location = makeLocation(for: candidate, source: .host, fileManager: fileManager) {
                return location
            }
        }
        return nil
    }

    public static func locate(
        runtimeURL: URL,
        source: QuickJSRuntimeSource = .providerPackage,
        fileManager: FileManager = .default
    ) -> QuickJSRuntimeLocation? {
        makeLocation(for: runtimeURL, source: source, fileManager: fileManager)
    }

    private static func makeLocation(
        for runtimeURL: URL,
        source: QuickJSRuntimeSource,
        fileManager: FileManager
    ) -> QuickJSRuntimeLocation? {
        guard fileManager.isExecutableFile(atPath: runtimeURL.path) else { return nil }
        if isCosmopolitanShell(runtimeURL) {
            return QuickJSRuntimeLocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                runtimeURL: runtimeURL,
                arguments: [runtimeURL.path],
                source: source
            )
        }
        return QuickJSRuntimeLocation(
            executableURL: runtimeURL,
            runtimeURL: runtimeURL,
            source: source
        )
    }

    private static func isCosmopolitanShell(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        return data.prefix(8).elementsEqual([0x4D, 0x5A, 0x71, 0x46, 0x70, 0x44, 0x3D, 0x27])
    }
}
