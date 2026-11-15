import Foundation

public enum DriveTransferPhase: String, Codable, Sendable {
    case notSubmitted, submittedAwaitingConfirmation, fileConfirmed
    case playbackAddressPending, failed, outcomeUnknown
}

/// Local recovery evidence for supported share-copy operations, never a saved
/// request. Credentials, share tokens and playback URLs have no fields here.
public struct DriveTransferTask: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let scope: DriveTransferTaskScope
    public var phase: DriveTransferPhase = .notSubmitted
    public var submitted = false
    public var previousIDs: Set<String> = []
    public var fileID: String?
    public var confirmedParentID: String?
    public var remoteTaskID: String?
    public var allowsNameInference = true
    public var cancelled = false
    public var completed = false
    public var remainingReadRetries = 2
    public var lastVerifiedAt: Date?
    public var updatedAt: Date

    public init(id: UUID = UUID(), scope: DriveTransferTaskScope, now: Date = Date()) {
        self.id = id; self.scope = scope; self.updatedAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case id, scope, phase, submitted, previousIDs, fileID, remoteTaskID, confirmedParentID
        case allowsNameInference, cancelled, completed, remainingReadRetries, lastVerifiedAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        scope = try values.decode(DriveTransferTaskScope.self, forKey: .scope)
        phase = try values.decode(DriveTransferPhase.self, forKey: .phase)
        submitted = try values.decode(Bool.self, forKey: .submitted)
        previousIDs = try values.decode(Set<String>.self, forKey: .previousIDs)
        fileID = try values.decodeIfPresent(String.self, forKey: .fileID)
        remoteTaskID = try values.decodeIfPresent(String.self, forKey: .remoteTaskID)
        confirmedParentID = try values.decodeIfPresent(String.self, forKey: .confirmedParentID)
        allowsNameInference = try values.decode(Bool.self, forKey: .allowsNameInference)
        cancelled = try values.decode(Bool.self, forKey: .cancelled)
        completed = try values.decode(Bool.self, forKey: .completed)
        // v1 did not retain the transport retry count; do not replenish it.
        remainingReadRetries = try values.decodeIfPresent(Int.self, forKey: .remainingReadRetries) ?? 0
        lastVerifiedAt = try values.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    /// A cancelled unknown write is still evidence. Never expire it to free a slot.
    public var protectsUncertainWrite: Bool { submitted && !completed && phase != .failed }
    public var canContinue: Bool { !cancelled && !completed }
}

public struct DriveTransferTaskScope: Codable, Equatable, Sendable {
    public let provider: DriveProvider
    public let cacheKey: String
    public let sourceKey: String
    public let accountReference: String
    public let configurationIdentity: String
    public let target: String
    public let driveID: String?
    public let shareID: String
    public let sourceFileID: String
    public let name: String
    public let size: Int64
    public let collectionName: String

    public init(provider: DriveProvider, cacheKey: String, sourceKey: String,
                accountReference: String, configurationIdentity: String, target: String,
                driveID: String? = nil, shareID: String, sourceFileID: String,
                name: String, size: Int64, collectionName: String = "") {
        self.provider = provider; self.cacheKey = cacheKey; self.sourceKey = sourceKey
        self.accountReference = accountReference; self.configurationIdentity = configurationIdentity
        self.target = target; self.driveID = driveID; self.shareID = shareID
        self.sourceFileID = sourceFileID; self.name = name; self.size = size
        self.collectionName = collectionName
    }
}

public enum DriveTaskRecoveryError: Error, Sendable {
    case storageUnavailable, capacityReached, requiresReview, scopeChanged, cancelled, staleRecord
}
