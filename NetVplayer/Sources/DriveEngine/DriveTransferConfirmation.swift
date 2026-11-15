import CryptoKit
import Foundation
import Models
import Storage

public typealias DriveTransferPhase = Models.DriveTransferPhase

/// Inherited by coalesced work. No credential, file name or URL is retained here.
public struct DriveTransferContext: Sendable {
    @TaskLocal public static var current = DriveTransferContext()
    @TaskLocal static var confirmationDeadline: ContinuousClock.Instant?
    public let revision: String
    public let configurationIdentity: String
    private let isCurrent: @Sendable () async -> Bool

    public init(revision: String = "", configurationIdentity: String = "", isCurrent: @escaping @Sendable () async -> Bool = { true }) {
        self.revision = revision
        self.configurationIdentity = configurationIdentity
        self.isCurrent = isCurrent
    }

    public func check() async throws {
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }
    }

    static func readTimeout(_ maximum: TimeInterval) throws -> TimeInterval {
        guard let deadline = confirmationDeadline else { return maximum }
        let duration = ContinuousClock.now.duration(to: deadline).components
        let remaining = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        guard remaining > 0 else { throw DriveEngineError.transferConfirmationPending() }
        return min(maximum, remaining)
    }

    public static func digest(_ values: [String]) -> String {
        // Length prefixes avoid ambiguous concatenation. The digest stays local.
        SHA256.hash(data: Data(values.map { "\($0.utf8.count):\($0)" }.joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func account(provider: DriveProvider, cookie: String) -> String {
        let pairs = cookie.split(separator: ";").compactMap { item -> (String, String)? in
            let pair = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        }
        if provider == .p115, let rawUID = pairs.first(where: { $0.0.caseInsensitiveCompare("UID") == .orderedSame })?.1 {
            let decoded = rawUID.removingPercentEncoding ?? rawUID
            let userID = String(decoded.split(separator: "_", maxSplits: 1).first ?? "")
            if !userID.isEmpty, userID.allSatisfy({ $0.isNumber }) {
                return digest([provider.rawValue, "UID=" + userID])
            }
        }
        let keys: [String]
        switch provider {
        case .quark: keys = ["__uid", "__puus", "__pus"]
        case .uc: keys = ["__uid", "__puus", "__pus"]
        case .baidu: keys = ["BDUSS", "BDUSS_BFESS"]
        case .p115: keys = ["UID"]
        default: keys = []
        }
        // Prefer an account identifier; when unavailable, isolate the credential
        // itself instead of guessing that two sessions belong to one account.
        let identity = keys.lazy.compactMap { key in pairs.first { $0.0 == key }.map { key + "=" + $0.1 } }.first
        return digest([provider.rawValue, identity ?? pairs.sorted { $0.0 < $1.0 }.map { $0.0 + "=" + $0.1 }.joined(separator: ";")])
    }
}

extension DriveSavedFileIdentity {
    public func scoped(account: String, target: String) -> Self {
        Self(provider: provider, cacheKey: cacheKey + ":" + DriveTransferContext.digest([account, target]),
             legacyCacheKey: cacheKey, targetFileName: targetFileName)
    }
}

struct DriveTransferSubmission: Sendable {
    var fileID: String?
    var taskID: String?
    var updatedCookie: String = ""
}

/// The write-ahead record commits synchronously before transport is entered.
actor DriveTransferAttempt {
    private(set) var phase: DriveTransferPhase = .notSubmitted
    private(set) var previousIDs = Set<String>()
    private(set) var fileID: String?
    private(set) var taskID: String?
    private(set) var allowsNameInference = true
    private var acknowledged = false
    private let store: DriveTransferTaskStore?
    private(set) var record: DriveTransferTask?

    init(record: DriveTransferTask? = nil, store: DriveTransferTaskStore? = nil) {
        self.record = record; self.store = store
        if let record {
            phase = record.phase; previousIDs = record.previousIDs
            fileID = record.fileID; taskID = record.remoteTaskID
            allowsNameInference = record.allowsNameInference
            acknowledged = record.phase == .submittedAwaitingConfirmation
        }
    }

    var needsSubmission: Bool { phase == .notSubmitted || phase == .failed }

    private func persist(_ change: (inout DriveTransferTask) -> Void) throws {
        guard let old = record, let store else { return }
        guard !old.cancelled else { throw DriveTaskRecoveryError.cancelled }
        var next = old
        change(&next); next.updatedAt = Date()
        try store.replace(next, expected: old)
        record = next
    }

    func submit(previousIDs: Set<String>,
                operation: @Sendable () async throws -> DriveTransferSubmission) async throws -> DriveTransferSubmission? {
        guard needsSubmission else { return nil }
        try await DriveTransferContext.current.check()
        guard previousIDs.count <= 4096 else { throw DriveTaskRecoveryError.capacityReached }
        try persist { $0.previousIDs = previousIDs; $0.submitted = true; $0.phase = .outcomeUnknown }
        self.previousIDs = previousIDs
        phase = .submittedAwaitingConfirmation
        let receipt: DriveTransferSubmission
        do { receipt = try await operation() }
        catch {
            if Self.isDefiniteRejection(error) {
                phase = .failed
                try persist { $0.phase = .failed }
                throw error
            }
            phase = .outcomeUnknown
            // Durable state already says unknown even if this write fails.
            try persist { $0.phase = .outcomeUnknown }
            if error is CancellationError { throw error }
            return nil
        }
        acknowledged = true
        // A late receipt may enrich only this original attempt's evidence. The
        // cancellation/scope check below still forbids delivery or mapping writes.
        try update(fileID: receipt.fileID, taskID: receipt.taskID)
        try persist { $0.phase = .submittedAwaitingConfirmation }
        try await DriveTransferContext.current.check()
        return receipt
    }

    func update(fileID: String? = nil, taskID: String? = nil) throws {
        try persist {
            if let fileID, !fileID.isEmpty { $0.fileID = fileID }
            if let taskID, !taskID.isEmpty { $0.remoteTaskID = taskID }
        }
        if let fileID, !fileID.isEmpty { self.fileID = fileID }
        if let taskID, !taskID.isEmpty { self.taskID = taskID }
    }

    func rejectIdentityEvidence() throws {
        try persist { $0.allowsNameInference = false }
        allowsNameInference = false
    }

    func confirmed(_ fileID: String, parent: String? = nil) throws {
        try persist { $0.fileID = fileID; $0.confirmedParentID = parent; $0.phase = .fileConfirmed; $0.lastVerifiedAt = Date() }
        self.fileID = fileID; phase = .fileConfirmed
    }

    func completed(phase: DriveTransferPhase = .playbackAddressPending) throws { try persist { $0.completed = true; $0.phase = phase } }
    func cancel() throws { if let record, let store { try store.cancel(record.id) } }
    func consumeRetry() throws {
        guard record?.remainingReadRetries != 0 else { throw DriveTaskRecoveryError.requiresReview }
        try persist { $0.remainingReadRetries = max(0, $0.remainingReadRetries - 1) }
    }
    func verified() throws { try persist { $0.lastVerifiedAt = Date() } }
    func recordIssue(_ error: Error) {
        guard let record, let store, !record.cancelled, !record.completed else { return }
        let issue = DriveTaskDiagnosticIssue.issue(error)
        let state: TaskResultState = issue.reason == .credentialExpired ? .needsLogin
            : record.protectsUncertainWrite ? .waitingConfirmation : .needsAttention
        var summary = TaskDiagnosticRecord.transfer(record)
        summary.events = [.init(stage: summary.latest.stage, state: state, issue: issue,
                                retryCount: 2 - record.remainingReadRetries)]
        try? store.diagnostics.record(summary)
    }
    func interrupted() {
        if phase == .submittedAwaitingConfirmation && !acknowledged { phase = .outcomeUnknown }
    }

    private static func isDefiniteRejection(_ error: Error) -> Bool {
        if let failure = error as? DriveServiceFailure { return failure.definiteRejection }
        if case DriveEngineError.loginRequired = error { return true }
        guard case let DriveEngineError.api(_, status, code, _) = error else { return false }
        // Only an explicit service rejection is proof that this write failed.
        return ((400..<500).contains(status) && status != 408) || ((200..<300).contains(status) && code != nil && code != 0)
    }
}

extension DriveTransferTaskScope {
    static func make(identity: DriveSavedFileIdentity, account: String, target: String,
                     driveID: String? = nil, shareID: String, sourceFileID: String,
                     name: String, size: Int64, collectionName: String = "") -> Self {
        .init(provider: identity.provider, cacheKey: identity.cacheKey,
              sourceKey: identity.legacyCacheKey ?? identity.cacheKey,
              accountReference: DriveTransferContext.digest([account]),
              configurationIdentity: DriveTransferContext.current.configurationIdentity,
              target: target, driveID: driveID, shareID: shareID, sourceFileID: sourceFileID,
              name: name, size: size, collectionName: collectionName)
    }
}
