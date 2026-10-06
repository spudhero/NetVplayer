import Foundation

public enum NodeRuntimeSource: String, Sendable {
    case configured
    case bundled
    case host
}

public struct NodeRuntimeLocation: Sendable, Equatable {
    public let executableURL: URL
    public let source: NodeRuntimeSource

    public init(executableURL: URL, source: NodeRuntimeSource) {
        self.executableURL = executableURL
        self.source = source
    }
}

public enum NodeRuntimeLocator {
    public static let bundledDirectoryName = "NodeRuntime"

    public static func locate(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) -> NodeRuntimeLocation? {
        if let configured = environment["NETVPLAYER_NODE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if fileManager.isExecutableFile(atPath: url.path) {
                return NodeRuntimeLocation(executableURL: url, source: .configured)
            }
        }

        if let bundleResourceURL {
            let url = bundleResourceURL
                .appendingPathComponent(bundledDirectoryName, isDirectory: true)
                .appendingPathComponent("bin/node")
            if fileManager.isExecutableFile(atPath: url.path) {
                return NodeRuntimeLocation(executableURL: url, source: .bundled)
            }
        }

        var hostCandidates: [URL] = []
        if let path = environment["PATH"] {
            hostCandidates.append(contentsOf: path
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("node") })
        }
        hostCandidates.append(contentsOf: [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ].map { URL(fileURLWithPath: $0) })
        if let url = hostCandidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return NodeRuntimeLocation(executableURL: url, source: .host)
        }
        return nil
    }
}
