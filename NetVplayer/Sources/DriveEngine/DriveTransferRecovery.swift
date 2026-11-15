import Foundation
import Models
import Networking
import Storage

public enum DriveTransferRecoveryResult: Sendable { case fileConfirmed, readyToRetry }

struct DriveRecoveredFile: Sendable {
    let id: String
    let name: String
    let parent: String
    let size: Int64
    var pickCode: String = ""
    var fingerprint: String = ""
}

extension DriveTransferCoordinator {
    /// Called only by the explicit Continue action. The persisted record is not
    /// executable: adapters can only inspect the original target and known IDs.
    public func continueRecovery(_ id: UUID, credential: CloudCredential,
                                 configurationIdentity: String,
                                 httpClient: HTTPClient = .shared,
                                 mappingStore: DriveSavedFileStore = .shared) async throws -> DriveTransferRecoveryResult {
        guard let taskStore, let record = try taskStore.records().first(where: { $0.id == id }) else {
            throw DriveTaskRecoveryError.storageUnavailable
        }
        guard record.canContinue else { throw DriveTaskRecoveryError.cancelled }
        let scope = record.scope
        let account = credential.provider == .ali
            ? credential.metadata["default_drive_id"] ?? ""
            : DriveTransferContext.account(provider: credential.provider, cookie: credential.secret)
        guard credential.provider == scope.provider, !credential.secret.isEmpty, !account.isEmpty,
              DriveTransferContext.digest([account]) == scope.accountReference,
              configurationIdentity == scope.configurationIdentity else { throw DriveTaskRecoveryError.scopeChanged }
        guard !recovering.contains(id), !hasTransfer(cacheKey: scope.cacheKey) else { throw DriveTaskRecoveryError.requiresReview }
        recovering.insert(id)
        defer { recovering.remove(id) }
        let outer = DriveTransferContext.current
        let context = DriveTransferContext(revision: outer.revision, configurationIdentity: configurationIdentity) {
            guard (try? await outer.check()) != nil else { return false }
            return (try? taskStore.records().first(where: { $0.id == id })?.canContinue) == true
        }
        let attempt = DriveTransferAttempt(record: record, store: taskStore)
        do {
            return try await DriveTransferContext.$current.withValue(context) {
                try await DriveTransferContext.$confirmationDeadline.withValue(.now.advanced(by: .seconds(20))) {
                    try await DriveRequestRecovery.withBudget {
                        try await DriveRequestRecovery.$transferAttempt.withValue(attempt) {
                            try await DriveMappingVerification.$readOnly.withValue(true) {
                                try await context.check()
                                let file: DriveRecoveredFile?
                                switch scope.provider {
                                case .quark: file = try await QuarkDriveClient(httpClient: httpClient).recoverTransfer(record, attempt: attempt, cookie: credential.secret)
                                case .uc: file = try await UCDriveClient(httpClient: httpClient).recoverTransfer(record, attempt: attempt, cookie: credential.secret)
                                case .ali: file = try await AliDriveClient(httpClient: httpClient).recoverTransfer(record, attempt: attempt, credential: credential)
                                case .baidu: file = try await BaiduDriveClient(httpClient: httpClient).recoverTransfer(record, cookie: credential.secret)
                                case .p115: file = try await P115DriveClient(httpClient: httpClient).recoverTransfer(record, cookie: credential.secret)
                                default: throw DriveTaskRecoveryError.scopeChanged
                                }
                                try await context.check()
                                try await attempt.verified()
                                guard let file else {
                                    try await attempt.completed(phase: .notSubmitted)
                                    return .readyToRetry
                                }
                                try await attempt.confirmed(file.id, parent: file.parent)
                                // No credential or playback address is needed to repair this mapping.
                                let mapping = DriveSavedFileRecord(provider: scope.provider, cacheKey: scope.cacheKey,
                                    pwdID: scope.shareID, shareFID: scope.sourceFileID, fidToken: "", size: file.size,
                                    originalName: scope.name, savedFID: file.id, savedFileName: file.name, parentFID: file.parent,
                                    driveID: scope.driveID, targetRootFID: scope.provider == .baidu ? nil : scope.target,
                                    savedPickCode: file.pickCode.isEmpty ? nil : file.pickCode,
                                    contentFingerprint: file.fingerprint.isEmpty ? nil : file.fingerprint)
                                try await context.check()
                                // A newer mapping must not be overwritten by an older journal row.
                                if let existing = await mappingStore.record(for: scope.cacheKey) {
                                    guard existing.savedFID == file.id, existing.parentFID == file.parent,
                                          existing.size == file.size else { throw DriveTaskRecoveryError.requiresReview }
                                } else { try await mappingStore.save(mapping) }
                                try await context.check()
                                try await attempt.completed()
                                return .fileConfirmed
                            }
                        }
                    }
                }
            }
        } catch {
            if TaskDiagnosticIssue.isCancellation(error) || Task.isCancelled { try taskStore.cancel(id) }
            else { await attempt.recordIssue(error) }
            throw error
        }
    }
}
