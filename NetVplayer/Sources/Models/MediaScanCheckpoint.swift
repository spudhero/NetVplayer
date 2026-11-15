import Foundation

/// Local scan evidence only. Credentials and resolved resource URLs never belong here.
public struct MediaScanCheckpoint: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case running, interrupted, partial, completed, cancelled, invalidated }
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    public static let maximumDirectories = 20_000
    public var version = 1
    public var id: UUID
    public var libraryID: UUID
    public var serviceID: UUID
    public var rootPath: String
    public var configurationRevision: String
    public var phase: Phase
    public var updatedAt: Date
    public var fullTraversal = true
    public var directories: [MediaScanDirectory] = []
    public init(library: MediaLibraryConfiguration, revision: String, now: Date = Date()) {
        id = UUID(); libraryID = library.id; serviceID = library.serviceID; rootPath = library.path
        configurationRevision = revision; phase = .running; updatedAt = now
    }
    public var failedDirectories: [String] { directories.filter { $0.state == .failed }.map(\.path).sorted() }
    public var completedDirectories: Int { directories.filter { $0.state == .completed }.count }
    public var pendingDirectories: Int { directories.filter { $0.state == .pending }.count }
    public func isExpired(at now: Date = Date()) -> Bool { now.timeIntervalSince(updatedAt) > Self.retention }
    public func canContinue(revision: String, now: Date = Date()) -> Bool {
        configurationRevision == revision && !isExpired(at: now) && [.running, .interrupted, .partial].contains(phase)
    }
}

public struct MediaScanDirectory: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, completed, failed }
    public var path: String
    public var state: State
    /// Digest of the complete listing and inherited metadata fingerprint, never a server cursor.
    public var fingerprint: String?
    public var scanID: UUID?
    public init(path: String, state: State = .pending, fingerprint: String? = nil, scanID: UUID? = nil) {
        self.path = path; self.state = state; self.fingerprint = fingerprint; self.scanID = scanID
    }
}

public enum MediaScanRequest: Equatable, Sendable {
    case rescan
    case resume
    case retryFailed(paths: [String])
}

public enum MediaScanRecoveryError: Error, Equatable, Sendable {
    case unavailable, configurationChanged, expired, cancelled, capacity, superseded, readBudget
}
