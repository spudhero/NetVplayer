import Foundation
import CryptoKit

/// Content identity is independent of a renewable URL or display name. Account
/// namespaces must be stable IDs, never credentials. Opaque digests stay in memory.
public struct PlaybackMediaIdentity: Hashable, Sendable {
    public let source: String
    public let account: String
    public let item: String
    public init(source: String, account: String, item: String) {
        self.source = source; self.account = account; self.item = item
    }
    public var cacheKey: String {
        let data = (try? JSONEncoder().encode([source, account, item])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func resolved(for spec: PlaySpec) -> Self? {
        if let identity = spec.mediaIdentity { return identity }
        if let server = spec.mediaServer { return server.identity }
        if let disc = spec.disc { return disc.selection.mediaIdentity }
        if let reference = FileResourceReference(locator: spec.metadata["vod.episodeURL"] ?? "") {
            return .init(source: "file-service", account: reference.serviceID.uuidString,
                         item: reference.path)
        }
        if let asset = spec.drivePlaybackPlan?.asset {
            // An unknown personal account must never alias another account.
            let account = spec.metadata[DrivePlaybackMetadataKey.driveID].flatMap { $0.isEmpty ? nil : $0 }
                ?? (asset.shareID.isEmpty ? nil : "share:" + asset.shareID)
            guard let account, !asset.sourceFileID.isEmpty else { return nil }
            return .init(source: asset.provider.rawValue,
                         account: account,
                         item: asset.sourceFileID)
        }
        let m = spec.metadata
        if let source = m["library.sourceFingerprint"], let site = m["vod.siteKey"],
           let id = m["vod.id"] {
            return .init(source: source, account: site,
                         item: [id, m["vod.episodeName"] ?? ""].joined(separator: "\u{0}"))
        }
        if let url = URL(string: spec.url), url.isFileURL {
            return .init(source: "file", account: "local", item: url.standardizedFileURL.path)
        }
        return nil // Unknown sources receive a session-local ID, never a URL key.
    }
}

public enum PlaybackReadPurpose: String, Sendable {
    case foreground, seek, probe, readAhead, chapterPreview, subtitleExtraction, nextEpisode
    public var isBackground: Bool {
        switch self { case .foreground, .seek, .probe: false; default: true }
    }
    public var priority: Int {
        switch self {
        case .seek: 100
        case .foreground: 90
        case .probe: 70
        case .readAhead: 40
        case .chapterPreview: 30
        case .subtitleExtraction: 20
        case .nextEpisode: 10
        }
    }
    public var phase: PlaybackTransferPhase {
        switch self {
        case .seek: .seek
        case .foreground: .playback
        case .probe: .startup
        case .chapterPreview: .preview
        default: .preload
        }
    }
}

public struct PlaybackReadHint: Sendable {
    public let mediaIdentity: PlaybackMediaIdentity
    public let sessionID: UUID
    public let generation: UInt64
    public let owner: UUID
    public let purpose: PlaybackReadPurpose
    public let ranges: [Range<Int64>]
    public let priority: Int
    public let expiry: TimeInterval
    public let cancellation: PlaybackReadOwner
}

/// A seek retires every owner of the previous generation, including queued work.
/// Callbacks run outside the lock; cancellation cannot deadlock resource teardown.
public final class PlaybackReadSession: @unchecked Sendable {
    public let id = UUID()
    private let lock = NSLock()
    private var version: UInt64 = 0
    private var stopped = false
    private struct WeakOwner { weak var value: PlaybackReadOwner? }
    private var owners: [WeakOwner] = []
    public init() {}
    public var generation: UInt64 { lock.withLock { version } }
    public func isCurrent(_ generation: UInt64) -> Bool { lock.withLock { !stopped && version == generation } }
    public func makeOwner(mediaIdentity: PlaybackMediaIdentity, purpose: PlaybackReadPurpose,
                          expiry: TimeInterval = .greatestFiniteMagnitude,
                          cancellation: PlaybackReadCancellation? = nil) -> PlaybackReadOwner {
        let owner = lock.withLock {
            let owner = PlaybackReadOwner(session: self, generation: version, mediaIdentity: mediaIdentity,
                                          purpose: purpose, expiry: expiry, cancellation: cancellation)
            owners.removeAll { $0.value == nil }
            owners.append(WeakOwner(value: owner))
            return owner
        }
        if !isCurrent(owner.generation) { owner.cancel() }
        return owner
    }
    public func advance() { retire(stop: false) }
    public func stop() { retire(stop: true) }
    private func retire(stop: Bool) {
        let retired = lock.withLock {
            version &+= 1; stopped = stopped || stop
            let retired = owners.compactMap(\.value); owners.removeAll()
            return retired
        }
        for owner in retired { owner.cancel() }
    }
}

public enum PlaybackReadScope {
    @TaskLocal public static var owner: PlaybackReadOwner?
    @TaskLocal public static var priority: PlaybackReadPriority?
}

/// Shared upstream admission can be promoted when a foreground reader joins.
public final class PlaybackReadPriority: @unchecked Sendable {
    public let purpose: PlaybackReadPurpose?
    private let lock = NSLock()
    private var promoted = false
    public init(purpose: PlaybackReadPurpose? = nil) { self.purpose = purpose }
    public var isForeground: Bool { lock.withLock { promoted } }
    public func promote() { lock.withLock { promoted = true } }
}

public final class PlaybackReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    fileprivate func observe(_ action: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let immediate = lock.withLock {
            if cancelled { return true }; callbacks[id] = action; return false
        }
        if immediate { action() }; return id
    }
    fileprivate func remove(_ id: UUID) { _ = lock.withLock { callbacks.removeValue(forKey: id) } }
    public func cancel() {
        let pending = lock.withLock {
            cancelled = true; let pending = Array(callbacks.values); callbacks.removeAll(); return pending
        }
        for action in pending { action() }
    }
}

public final class PlaybackReadOwner: @unchecked Sendable {
    public let id = UUID()
    public let sessionID: UUID
    public let generation: UInt64
    public let mediaIdentity: PlaybackMediaIdentity
    public let purpose: PlaybackReadPurpose
    public let expiry: TimeInterval
    private let session: PlaybackReadSession
    private let scopeCancellation: PlaybackReadCancellation?
    private let lock = NSLock()
    private var cancelled = false
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    fileprivate init(session: PlaybackReadSession, generation: UInt64, mediaIdentity: PlaybackMediaIdentity,
                     purpose: PlaybackReadPurpose, expiry: TimeInterval, cancellation: PlaybackReadCancellation?) {
        self.session = session; self.sessionID = session.id; self.generation = generation
        self.mediaIdentity = mediaIdentity; self.purpose = purpose; self.expiry = expiry
        scopeCancellation = cancellation
    }
    public var isCancelled: Bool {
        lock.withLock { cancelled } || scopeCancellation?.isCancelled == true
            || !session.isCurrent(generation) || ProcessInfo.processInfo.systemUptime >= expiry
    }
    public func check() throws {
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
    }
    public func hint(ranges: [Range<Int64>]) -> PlaybackReadHint {
        .init(mediaIdentity: mediaIdentity, sessionID: sessionID, generation: generation, owner: id,
              purpose: purpose, ranges: ranges, priority: purpose.priority, expiry: expiry, cancellation: self)
    }
    public func sibling(purpose: PlaybackReadPurpose) throws -> PlaybackReadOwner {
        guard session.isCurrent(generation), scopeCancellation?.isCancelled != true,
              ProcessInfo.processInfo.systemUptime < expiry else { throw CancellationError() }
        let sibling = session.makeOwner(mediaIdentity: mediaIdentity, purpose: purpose, expiry: expiry, cancellation: scopeCancellation)
        guard sibling.generation == generation else { sibling.cancel(); throw CancellationError() }
        return sibling
    }
    public func cancel() {
        let pending = lock.withLock {
            cancelled = true
            let pending = Array(callbacks.values); callbacks.removeAll()
            return pending
        }
        for callback in pending { callback() }
    }
    /// Cancels this operation promptly without cancelling another owner's shared
    /// upstream task. Also waits for non-cooperative work before releasing its source.
    public func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try check()
        let task = Task { try await PlaybackReadScope.$owner.withValue(self) { try await operation() } }
        let callbackID = UUID()
        let mustCancel = lock.withLock {
            if cancelled { return true }
            callbacks[callbackID] = { task.cancel() }; return false
        }
        if mustCancel || isCancelled { task.cancel() }
        let scopeObserver = scopeCancellation?.observe { task.cancel() }
        let timer: Task<Void, Never>? = expiry < .greatestFiniteMagnitude ? Task {
            do {
                while ProcessInfo.processInfo.systemUptime < expiry {
                    try await Task.sleep(for: .seconds(min(expiry - ProcessInfo.processInfo.systemUptime, 86_400)))
                }
                task.cancel()
            }
            catch { }
        } : nil
        defer {
            timer?.cancel()
            if let scopeObserver { scopeCancellation?.remove(scopeObserver) }
            _ = lock.withLock { callbacks.removeValue(forKey: callbackID) }
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try check()
            return result
        } onCancel: { task.cancel() }
    }
}
