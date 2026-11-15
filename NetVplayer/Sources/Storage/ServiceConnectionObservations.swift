import Foundation
import CryptoKit
import Models

/// Memory-only observations of existing connection operations. Reading never
/// creates a client, reads credentials or refreshes the observation's age.
public final class ServiceConnectionObservations: @unchecked Sendable {
    public static let shared = ServiceConnectionObservations()
    public enum State: String, Encodable, Sendable { case unknown, stale, available, unavailable, needsLogin, permissionDenied }
    public struct Snapshot: Encodable, Sendable {
        public let state: State
        public let lastKnownState: State?
        public let checkedAt: Date?
        public let validForSeconds: Int
    }
    public struct Scope: Sendable {
        let key: String
        let revision: String
        init(namespace: String, id: UUID, revision: String) {
            key = namespace + ":" + id.uuidString; self.revision = revision
        }
    }
    public struct Ticket: Sendable { fileprivate let scope: Scope; fileprivate let id: UUID }
    private struct Entry { let revision: String; let ticket: UUID; var result: State?; var time: Date? }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    public init() {}
    static func revision(_ fields: [String]) -> String {
        SHA256.hash(data: Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    public func begin(_ scope: Scope) -> Ticket {
        lock.withLock {
            if entries.count >= 256, entries[scope.key] == nil { entries.removeAll() }
            let ticket = Ticket(scope: scope, id: UUID())
            entries[scope.key] = .init(revision: scope.revision, ticket: ticket.id)
            return ticket
        }
    }
    public func finish(_ ticket: Ticket, state: State, now: Date = Date()) {
        guard ![.unknown, .stale].contains(state) else { return }
        lock.withLock {
            guard entries[ticket.scope.key]?.ticket == ticket.id else { return }
            entries[ticket.scope.key]?.result = state; entries[ticket.scope.key]?.time = now
        }
    }
    public func invalidate(_ scope: Scope) { lock.withLock { entries[scope.key] = nil } }
    public func snapshot(_ scope: Scope, now: Date = Date()) -> Snapshot {
        lock.withLock {
            guard let entry = entries[scope.key], entry.revision == scope.revision,
                  let result = entry.result, let time = entry.time, time <= now else {
                return .init(state: .unknown, lastKnownState: nil, checkedAt: nil, validForSeconds: 300)
            }
            return .init(state: now.timeIntervalSince(time) >= 300 ? .stale : result,
                         lastKnownState: result, checkedAt: time, validForSeconds: 300)
        }
    }
    public static func failure(_ error: Error) -> State {
        if let error = error as? MediaServerError, case .authentication = error { return .needsLogin }
        switch TaskDiagnosticIssue.local(error).reason {
        case .credentialExpired: return .needsLogin
        case .permissionDenied: return .permissionDenied
        default: return .unavailable
        }
    }
}
