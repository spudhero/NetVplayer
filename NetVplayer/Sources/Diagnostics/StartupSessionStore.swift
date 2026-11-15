import Foundation

/// One small local marker, independent of preferences, providers and the business stores.
/// An interrupted run is evidence of an unclean exit, not proof of a captured crash.
public final class StartupSessionStore {
    public enum Phase: String, Codable, Sendable {
        case preparing, recovery, starting, ready, failed, terminating, clean
    }

    public struct Record: Codable, Equatable, Sendable {
        public let version: Int
        public let phase: Phase
        public let recoveryPending: Bool
        public init(phase: Phase, recoveryPending: Bool) {
            version = 1
            self.phase = phase
            self.recoveryPending = recoveryPending
        }
    }

    public let url: URL
    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetVplayer/Startup/session.json")
    }

    /// Missing is a first run; malformed/oversized markers conservatively require recovery.
    public func needsRecovery() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4096 else { return true }
        let data = try Data(contentsOf: url)
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1 else {
            return true
        }
        return record.phase != .clean || record.recoveryPending
    }

    public func write(_ phase: Phase, recoveryPending: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Record(phase: phase, recoveryPending: recoveryPending))
            .write(to: url, options: .atomic)
    }
}
