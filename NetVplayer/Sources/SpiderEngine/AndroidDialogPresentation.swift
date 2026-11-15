import Foundation

/// App-owned presentation code precedes the optional runtime's renderer. It does
/// not replace its framework, Providers, account state or callback dispatcher.
public enum AndroidDialogPresentation {
    public struct Configuration: Sendable {
        public let archive: URL
        public let theme: URL
        public let darkAppearance: Bool?
        public init(archive: URL, theme: URL, darkAppearance: Bool? = nil) {
            self.archive = archive
            self.theme = theme
            self.darkAppearance = darkAppearance
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: Configuration?

    public static func configure(_ configuration: Configuration) {
        lock.lock()
        defer { lock.unlock() }
        current = configuration
    }

    static var configuration: Configuration? {
        lock.lock()
        defer { lock.unlock() }
        guard let current, FileManager.default.fileExists(atPath: current.archive.path),
              FileManager.default.fileExists(atPath: current.theme.path) else { return nil }
        return current
    }
}
