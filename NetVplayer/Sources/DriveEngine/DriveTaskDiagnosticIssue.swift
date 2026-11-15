import Foundation
import Models

public enum DriveTaskDiagnosticIssue {
    public static func issue(_ error: Error) -> TaskDiagnosticIssue {
        if let failure = error as? DriveServiceFailure {
            return .init(TaskResultReason(rawValue: failure.reason.rawValue) ?? .unavailable,
                         httpStatus: failure.statusCode, serviceCode: failure.serviceCode)
        }
        if let recovery = error as? DriveTaskRecoveryError {
            switch recovery {
            case .scopeChanged: return .init(.configurationChanged)
            case .storageUnavailable: return .init(.storageUnavailable)
            case .capacityReached: return .init(.capacity)
            default: return .init(.outcomeUnknown)
            }
        }
        if let drive = error as? DriveEngineError {
            switch drive {
            case .loginRequired: return .init(.credentialExpired)
            case .transferConfirmationPending: return .init(.outcomeUnknown)
            case .officialPlayURLPending: return .init(.playbackAddressPending)
            case .api(_, let status, let code, _):
                let reason: TaskResultReason = status == 401 ? .credentialExpired : status == 403 ? .permissionDenied
                    : status == 429 ? .rateLimited : [408, 500, 502, 503, 504].contains(status) ? .temporaryNetwork : .unavailable
                return .init(reason, httpStatus: status, serviceCode: code.map(String.init))
            default: return .init(.unavailable)
            }
        }
        return .local(error)
    }
}
