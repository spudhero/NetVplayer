import Foundation

public enum TaskResultState: String, Codable, Sendable { case processing, waitingConfirmation, needsLogin, needsAttention, cancelled, completed }
public enum TaskResultStage: String, Codable, Sendable { case queued, submitting, confirming, fileConfirmed, preparingPlayback, scanning, finished }
public enum TaskDiagnosticKind: String, Codable, Sendable { case driveTransfer, mediaScan, metadataMatch }
public enum TaskResultReason: String, Codable, Sendable {
    case credentialExpired, permissionDenied, quotaExceeded, rateLimited, temporaryNetwork, fileMissing
    case signedURLExpired, outcomeUnknown, mappingChanged, mappingUnconfirmed
    case interrupted, configurationChanged, expired, capacity, storageUnavailable, unavailable, partial, playbackAddressPending, reopenOriginal
    public var failureReason: AppFailureReason? { AppFailureReason(rawValue: rawValue) }
}

/// Only protocol codes with an established meaning may cross the local export
/// boundary. Arbitrary strings, even apparently harmless correlation IDs, cannot.
public enum TaskDiagnosticPrivacy {
    public static func serviceCode(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 32 else { return nil }
        let known: Set<String> = ["QuotaExhausted", "ForbiddenNoPermission", "Forbidden", "Throttling",
            "InternalError", "ServiceUnavailable", "NotFound.File", "ForbiddenFileInTheRecycleBin"]
        if known.contains(value) { return value }
        let digits = value.hasPrefix("-") ? String(value.dropFirst()) : value
        guard !digits.isEmpty, digits.count <= 7, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(value), String(number) == value else { return nil }
        return value
    }
    public static func httpStatus(_ value: Int?) -> Int? { value.flatMap { (100...599).contains($0) ? $0 : nil } }
}

/// Safe classification, never an Error envelope. Nested NSError/userInfo and
/// localizedDescription are deliberately not inspected.
public struct TaskDiagnosticIssue: Equatable, Sendable {
    public let reason: TaskResultReason
    public let httpStatus: Int?
    public let serviceCode: String?
    public init(_ reason: TaskResultReason, httpStatus: Int? = nil, serviceCode: String? = nil) {
        self.reason = reason; self.httpStatus = TaskDiagnosticPrivacy.httpStatus(httpStatus)
        self.serviceCode = TaskDiagnosticPrivacy.serviceCode(serviceCode)
    }
    public static func local(_ error: Error) -> Self {
        if let failure = error as? AppFailure, let reason = failure.reason { return .init(TaskResultReason(rawValue: reason.rawValue) ?? .unavailable) }
        if let scan = error as? MediaScanRecoveryError {
            switch scan {
            case .configurationChanged: return .init(.configurationChanged)
            case .expired: return .init(.expired)
            case .capacity, .readBudget: return .init(.capacity)
            default: return .init(.interrupted)
            }
        }
        if let file = error as? FileServiceError {
            switch file {
            case .authentication: return .init(.credentialExpired)
            case .permission: return .init(.permissionDenied)
            case .authorizationExpired, .invalidConfiguration: return .init(.configurationChanged)
            case .path: return .init(.fileMissing)
            case .network: return .init(.temporaryNetwork)
            default: return .init(.unavailable)
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .init(.temporaryNetwork) }
        return .init(.unavailable)
    }
    public static func isCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        return error is CancellationError || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
            || (error as? MediaScanRecoveryError) == .cancelled
    }
}

public struct TaskDiagnosticEvent: Codable, Equatable, Sendable {
    public let mediaMetrics: MediaLibraryMetrics?
    public let time: Date
    public let stage: TaskResultStage
    public let state: TaskResultState
    public let reason: TaskResultReason?
    public let retryCount: Int
    public let httpStatus: Int?
    public let serviceCode: String?
    public init(time: Date = Date(), stage: TaskResultStage, state: TaskResultState,
                issue: TaskDiagnosticIssue? = nil, retryCount: Int = 0, mediaMetrics: MediaLibraryMetrics? = nil) {
        self.mediaMetrics = mediaMetrics?.projected()
        self.time = time; self.stage = stage; self.state = state; reason = issue?.reason
        self.retryCount = min(99, max(0, retryCount)); httpStatus = issue?.httpStatus
        serviceCode = issue?.serviceCode
    }
    public var issue: TaskDiagnosticIssue? { reason.map { .init($0, httpStatus: httpStatus, serviceCode: serviceCode) } }
    public func projected() -> Self { .init(time: time, stage: stage, state: state, issue: issue, retryCount: retryCount, mediaMetrics: mediaMetrics) }
}

/// Local navigation uses only an app-owned UUID. It is omitted from exports.
/// No account/configuration, remote ID, filename, path, URL or error field exists.
public struct TaskDiagnosticRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: TaskDiagnosticKind
    public let provider: DriveProvider?
    public let localSubjectID: UUID?
    public var events: [TaskDiagnosticEvent]
    public var latest: TaskDiagnosticEvent { events.last! }
    public init(id: UUID, kind: TaskDiagnosticKind, provider: DriveProvider? = nil,
                localSubjectID: UUID? = nil, event: TaskDiagnosticEvent) {
        self.id = id; self.kind = kind; self.provider = provider; self.localSubjectID = localSubjectID
        events = [event.projected()]
    }
    public static func transfer(_ task: DriveTransferTask) -> Self {
        let stage: TaskResultStage
        switch task.phase {
        case .notSubmitted: stage = .queued
        case .submittedAwaitingConfirmation, .outcomeUnknown: stage = .confirming
        case .fileConfirmed: stage = .fileConfirmed
        case .playbackAddressPending: stage = .preparingPlayback
        case .failed: stage = .submitting
        }
        let state: TaskResultState = task.cancelled ? .cancelled : task.completed ? .completed
            : task.phase == .notSubmitted ? .processing : task.phase == .failed ? .needsAttention : .waitingConfirmation
        let reason: TaskResultReason? = task.completed ? (task.phase == .notSubmitted ? .reopenOriginal : .playbackAddressPending)
            : task.phase == .outcomeUnknown ? .outcomeUnknown : nil
        return .init(id: task.id, kind: .driveTransfer, provider: task.scope.provider,
            event: .init(time: task.updatedAt, stage: stage, state: state,
                         issue: reason.map { .init($0) }, retryCount: 2 - task.remainingReadRetries))
    }
}

/// Explicit output DTOs, independent of persistence and recovery objects.
public enum TaskDiagnosticsExport {
    public static let retention: TimeInterval = 14 * 24 * 3600
    public static func data(records: [TaskDiagnosticRecord], now: Date = Date(), activeTaskIDs: Set<UUID> = []) throws -> Data {
        struct Event: Encodable {
            let time: Date; let stage: TaskResultStage; let state: TaskResultState
            let reason: TaskResultReason?; let retryCount: Int; let httpStatus: Int?; let serviceCode: String?
            let mediaMetrics: MediaLibraryMetrics?
        }
        struct Summary: Encodable {
            let correlationID: UUID; let kind: TaskDiagnosticKind; let provider: DriveProvider?; let events: [Event]
        }
        struct Report: Encodable { let schemaVersion: Int; let generatedAt: Date; let tasks: [Summary] }
        let tasks = records.filter { !$0.events.isEmpty && now.timeIntervalSince($0.latest.time) <= retention }
            .sorted { $0.latest.time > $1.latest.time }.prefix(100).map { record in
            Summary(correlationID: record.id, kind: record.kind, provider: record.provider,
                events: record.events.filter { now.timeIntervalSince($0.time) <= retention }.suffix(12).map {
                    let interrupted = $0 == record.latest && $0.state == .processing && !activeTaskIDs.contains(record.id)
                    return Event(time: $0.time, stage: $0.stage, state: interrupted ? .waitingConfirmation : $0.state,
                          reason: interrupted ? .interrupted : $0.reason,
                          retryCount: min(99, max(0, $0.retryCount)),
                          httpStatus: TaskDiagnosticPrivacy.httpStatus($0.httpStatus),
                          serviceCode: TaskDiagnosticPrivacy.serviceCode($0.serviceCode),
                          mediaMetrics: $0.mediaMetrics?.projected())
                })
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Report(schemaVersion: 1, generatedAt: now, tasks: tasks))
    }
}
