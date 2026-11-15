import Foundation
import Models

/// A local opaque alias retains a source independently of its registering owner.
/// Releasing one alias cannot close another alias's reader or shared transfer.
public final class PlaybackReadLease: @unchecked Sendable {
    public let url: String
    private let lock = NSLock()
    private var release: (@Sendable () -> Void)?
    init(url: String, release: @escaping @Sendable () -> Void) { self.url = url; self.release = release }
    public func cancel() {
        let action = lock.withLock { let action = release; release = nil; return action }
        action?()
    }
    deinit { cancel() }
}

final class PlaybackReadBinding: @unchecked Sendable {
    let session: PlaybackReadSession
    let identity: PlaybackMediaIdentity
    let purpose: PlaybackReadPurpose
    let generation: UInt64
    let followsGeneration: Bool
    let expiry: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private var owners: [UUID: PlaybackReadOwner] = [:]
    private let cancellation = PlaybackReadCancellation()
    init(session: PlaybackReadSession, identity: PlaybackMediaIdentity, purpose: PlaybackReadPurpose,
         lifetime: TimeInterval?) {
        self.session = session; self.identity = identity; self.purpose = purpose
        generation = session.generation; followsGeneration = !purpose.isBackground
        expiry = lifetime.map { ProcessInfo.processInfo.systemUptime + max(0, min(86_400, $0)) } ?? .greatestFiniteMagnitude
    }
    func begin() throws -> PlaybackReadOwner {
        guard followsGeneration || session.isCurrent(generation) else { throw CancellationError() }
        let owner = session.makeOwner(mediaIdentity: identity, purpose: purpose, expiry: expiry, cancellation: cancellation)
        let invalid = lock.withLock {
            guard !cancelled else { return true }
            owners[owner.id] = owner; return false
        }
        if invalid || (!followsGeneration && owner.generation != generation) { owner.cancel() }
        try owner.check()
        return owner
    }
    func finish(_ owner: PlaybackReadOwner) {
        _ = lock.withLock { owners.removeValue(forKey: owner.id) }
        owner.cancel()
    }
    func cancel() {
        cancellation.cancel()
        let retired = lock.withLock {
            cancelled = true
            let retired = Array(owners.values); owners.removeAll(); return retired
        }
        for owner in retired { owner.cancel() }
    }
}

/// The read closure retains this lifetime even if an upstream ignores cancellation.
/// Its close callback therefore runs only after the final alias AND read release.
final class SeekableResourceLifetime: @unchecked Sendable {
    let resource: SeekableResource
    init(_ resource: SeekableResource) { self.resource = resource }
    deinit {
        let close = resource.close
        Task { await close() }
    }
}
