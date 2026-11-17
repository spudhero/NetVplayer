import Foundation
import Models
import Networking

public enum DriveRequestOperation: String, Sendable {
    case authentication, listing, fileMetadata, playback, mutation, signedMedia

    var isRead: Bool { self != .mutation && self != .authentication }
}

/// Contains only fixed classifications and numeric transport evidence. Server
/// messages, credentials, paths and signed URLs never enter the presentation.
public struct DriveServiceFailure: Error, LocalizedError, Sendable {
    public let provider: DriveProvider
    public let reason: AppFailureReason
    public let operation: DriveRequestOperation
    public let statusCode: Int
    public let retryAfter: TimeInterval?
    public let definiteRejection: Bool
    public let serviceCode: String?

    public init(provider: DriveProvider, reason: AppFailureReason, operation: DriveRequestOperation,
                  statusCode: Int = 0, retryAfter: TimeInterval? = nil, definiteRejection: Bool = false,
                  serviceCode: String? = nil) {
        self.provider = provider
        self.reason = reason
        self.operation = operation
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.definiteRejection = definiteRejection
        self.serviceCode = TaskDiagnosticPrivacy.serviceCode(serviceCode)
    }

    public var appFailure: AppFailure { AppFailure(category: .source, reason: reason) }
    public var presentationHint: AppFailurePresentationHint {
        if provider == .baidu, serviceCode == "9019", reason == .credentialExpired {
            return Self.baiduVerificationHint
        }
        return appFailure.presentationHint
    }
    public static var baiduVerificationHint: AppFailurePresentationHint {
        .init(title: L10n.text("百度网盘要求验证当前登录会话（9019）。"),
              suggestedAction: L10n.text("请先在百度网盘官方网页或应用中确认账号可用并完成验证，再到设置中重新扫码授权后重试。"))
    }
    public var errorDescription: String? {
        let hint = presentationHint
        return hint.title + hint.suggestedAction
    }
    var pausesAccountOperation: Bool {
        [.credentialExpired, .permissionDenied, .quotaExceeded].contains(reason)
    }

    public static func isCredentialExpired(_ error: Error, provider: DriveProvider) -> Bool {
        if let failure = error as? Self { return failure.provider == provider && failure.reason == .credentialExpired }
        if case DriveEngineError.loginRequired(let actual) = error { return actual == provider }
        if case DriveEngineError.api(let actual, let status, _, _) = error { return actual == provider && status == 401 }
        return false
    }

    /// A classified terminal response has already exhausted its applicable
    /// transport recovery. Candidate fallbacks must not start another loop.
    public static func stopsRecovery(_ error: Error) -> Bool {
        error is Self || error is DriveTaskRecoveryError || error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

enum DriveFailureClassifier {
    static func operation(provider: DriveProvider, url: String, method: HTTPMethod) -> DriveRequestOperation {
        let path = URL(string: url)?.path ?? ""
        // POST does not imply a write. Only established read endpoints opt in.
        switch provider {
        case .ali:
            if ["/v2/account/token", "/users/v1/users/device/create_session"].contains(path) { return .authentication }
            if path == "/v2/file/get" { return .fileMetadata }
            if ["/adrive/v3/file/list", "/v2/async_task/get"].contains(path) { return .listing }
            if ["/v2/file/get_download_url", "/v2/file/get_share_link_download_url", "/v2/file/get_video_preview_play_info"].contains(path) { return .playback }
        case .quark, .uc:
            if ["/quarkdrive/token", "/ucdrive/token"].contains(path) { return .authentication }
            if ["/1/clouddrive/file/download", "/1/clouddrive/file/v2/play", "/1/clouddrive/file/play"].contains(path) { return .playback }
            if path.hasSuffix("/sharepage/token") { return .authentication }
        case .baidu:
            if path == "/share/verify" { return .authentication }
            if path == "/api/mediainfo" { return .playback }
        case .p115:
            if ["/share/downurl", "/os_windows/2.0/share/downurl", "/app/share/downurl", "/app/chrome/downurl",
                "/android/2.0/ufile/download", "/open/ufile/downurl", "/open/video/play", "/files/video"].contains(path) { return .playback }
            if path == "/open/folder/get_info" { return .fileMetadata }
        case .pikpak:
            if path.hasSuffix("/signin") || path.hasSuffix("/token") { return .authentication }
        default: break
        }
        if method == .get || method == .head {
            return .listing
        }
        return .mutation
    }

    static func response(_ response: HTTPResponse, provider: DriveProvider,
                         operation: DriveRequestOperation, path: String, hasFileIdentity: Bool = false) -> DriveServiceFailure? {
        let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] ?? [:]
        if provider == .ali, path == "/adrive/v4/batch",
           let entries = json["responses"] as? [[String: Any]], entries.count == 1,
           let entry = entries.first, let body = entry["body"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: body) {
            return self.response(HTTPResponse(data: data, statusCode: entry["status"] as? Int ?? 200,
                                             headers: response.headers),
                                 provider: provider, operation: operation, path: "/file/copy")
        }
        let rawCode = json[provider == .baidu ? "errno" : "code"] ?? json["Code"] ?? json["errno"]
        let code = (rawCode as? String) ?? (rawCode as? NSNumber)?.stringValue
        let status = response.statusCode
        let businessStatus = (provider == .quark || provider == .uc) ? (json["status"] as? Int ?? 0) : 0
        var reason: AppFailureReason?
        // Provider-scoped business contracts take precedence over HTTP status.
        switch provider {
        case .ali:
            switch code {
            case "QuotaExhausted": reason = .quotaExceeded
            case "ForbiddenNoPermission", "Forbidden": reason = .permissionDenied
            case "Throttling": reason = .rateLimited
            case "InternalError", "ServiceUnavailable": reason = .temporaryNetwork
            case "NotFound.File", "ForbiddenFileInTheRecycleBin":
                if operation == .fileMetadata || operation == .playback || path == "/v2/recyclebin/trash" { reason = .fileMissing }
            default: break
            }
            // Existing Ali playback refresh contract: 410 is an expired route,
            // not proof that the personal file was removed.
            if reason == nil && status == 410 && operation == .playback { reason = .signedURLExpired }
        case .quark, .uc:
            if code == "31001" { reason = .credentialExpired }
            if ["/quarkdrive/token", "/ucdrive/token"].contains(path), code == "401" { reason = .credentialExpired }
            // 32003 is evidenced by the existing personal-play protocol fixtures.
            if code == "32003", status != 403, operation == .playback { reason = .fileMissing }
        case .baidu:
            if code == "9019", ["/share/list", "/share/verify", "/share/transfer", "/api/list", "/api/create", "/api/mediainfo"].contains(path) {
                reason = .credentialExpired
            }
            // -6 from /api/create is an existing-directory response in this
            // adapter. Never reuse that number as an auth error there.
            if code == "-6", path == "/api/list" { reason = .credentialExpired }
            if ["12", "-9", "-7"].contains(code ?? ""), path == "/api/mediainfo", hasFileIdentity, status != 403 { reason = .fileMissing }
        default: break
        }
        if reason == nil {
            switch businessStatus >= 400 ? businessStatus : status {
            case 401: reason = .credentialExpired
            case 403: reason = .permissionDenied
            case 404 where operation == .fileMetadata: reason = .fileMissing
            case 429: reason = .rateLimited
            case 408, 500, 502, 503, 504: reason = .temporaryNetwork
            default: break
            }
        }
        guard let reason else { return nil }
        return DriveServiceFailure(provider: provider, reason: reason, operation: operation,
            statusCode: status, retryAfter: retryAfter(response.headers),
            definiteRejection: ((400..<500).contains(status) && status != 408)
                || ((200..<300).contains(status) && code != nil && code != "0"), serviceCode: code)
    }

    static func retryAfter(_ headers: [String: String], now: Date = Date()) -> TimeInterval? {
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
