import Foundation

actor BaiduShareSessionStore {
    static let shared = BaiduShareSessionStore()

    private let fileURL: URL?
    private var keys: [String: String]

    init(fileURL: URL? = BaiduShareSessionStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.keys = Self.load(from: fileURL)
    }

    func key(for shareToken: String) -> String? {
        keys[shareToken]
    }

    func setKey(_ key: String, for shareToken: String) throws {
        guard !shareToken.isEmpty, !key.isEmpty else { return }
        keys[shareToken] = key
        try persist()
    }

    func removeKey(for shareToken: String) throws {
        guard keys.removeValue(forKey: shareToken) != nil else { return }
        try persist()
    }

    func removeAll() throws {
        guard !keys.isEmpty else { return }
        keys.removeAll()
        try persist()
    }

    private func persist() throws {
        guard let fileURL else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(keys)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func load(from fileURL: URL?) -> [String: String] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return stored
    }

    private static func defaultFileURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["NETVPLAYER_BAIDU_SHARE_SESSION_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let executablePath = CommandLine.arguments.first?.lowercased() ?? ""
        if ProcessInfo.processInfo.processName.lowercased().contains("test") ||
            executablePath.contains(".xctest/") ||
            environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil ||
            NSClassFromString("XCTest.XCTestCase") != nil {
            return nil
        }
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return applicationSupport
            .appendingPathComponent("NetVplayer", isDirectory: true)
            .appendingPathComponent("baidu_share_sessions.v1.json", isDirectory: false)
    }
}
