import Foundation
import ConfigEngine
import DriveEngine
import Models
import Networking
import ProviderSDK
import ProviderRuntime
import SpiderEngine
import Storage

protocol UserFacingDescribedError: Error {
    var userFacingDescription: String { get }
}

enum UserFacingErrorContext: Equatable {
    case configuration
    case content(sourceName: String?)
    case playback
    case live(channelName: String?, lineNumber: Int?)
    case authorization(providerName: String)
    case storage(operation: String)
    case extensionOperation(operation: String)
    case feedback(operation: String)
    case update
    case webContent

    fileprivate var fallbackMessage: String {
        switch self {
        case .configuration:
            return L10n.text("点播源未能加载。")
        case .content(let sourceName):
            if let sourceName = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceName.isEmpty {
                return L10n.text("视频源“{0}”暂时无法加载。", ["\(sourceName)"])
            }
            return L10n.text("当前视频源暂时无法加载。")
        case .playback:
            return L10n.text("当前内容暂时无法播放。")
        case .live(let channelName, let lineNumber):
            let channel = channelName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let channelPrefix = channel.flatMap { $0.isEmpty ? nil : L10n.text("频道“{0}”", ["\($0)"]) } ?? L10n.text("当前频道")
            let lineSuffix = lineNumber.map { L10n.text("的线路 {0} ", ["\($0)"]) } ?? L10n.text("的当前线路")
            return L10n.text("{0}{1}暂时无法播放。", ["\(channelPrefix)", "\(lineSuffix)"])
        case .authorization(let providerName):
            return L10n.text("{0}授权未完成。", ["\(providerName)"])
        case .storage(let operation), .extensionOperation(let operation), .feedback(let operation):
            return L10n.text("{0}未完成。", ["\(operation)"])
        case .update:
            return L10n.text("应用更新未完成。")
        case .webContent:
            return L10n.text("页面未能加载。")
        }
    }

    fileprivate var recoverySuggestion: String {
        switch self {
        case .configuration:
            return L10n.text("请检查配置地址和网络后重试。")
        case .content:
            return L10n.text("请稍后重试或切换其他视频源。")
        case .playback:
            return L10n.text("请重试或切换线路、视频源。")
        case .live:
            return L10n.text("请重试或切换其他线路、频道。")
        case .authorization:
            return L10n.text("请检查网络后刷新登录页面并重试。")
        case .storage:
            return L10n.text("请检查文件权限和可用存储空间后重试。")
        case .extensionOperation:
            return L10n.text("请检查网络后重试；已安装的扩展仍可继续使用。")
        case .feedback:
            return L10n.text("请检查填写内容后重试。")
        case .update:
            return L10n.text("请检查网络后重新检查更新。")
        case .webContent:
            return L10n.text("请检查地址和网络后重试。")
        }
    }
}

struct UserFacingErrorPresentation: Equatable {
    let message: String
    let recoverySuggestion: String

    var combinedMessage: String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSuggestion = recoverySuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSuggestion.isEmpty else { return trimmedMessage }
        let alreadyContainsAction = (trimmedMessage.hasPrefix("请") && !trimmedMessage.hasPrefix("请求"))
            || trimmedMessage.contains("。请")
            || trimmedMessage.contains("；请")
            || trimmedMessage.contains("，请")
        guard !trimmedMessage.contains(trimmedSuggestion), !alreadyContainsAction else {
            return trimmedMessage
        }
        return trimmedMessage + trimmedSuggestion
    }
}

enum UserFacingErrorPresenter {
    static func presentation(
        for error: Error,
        context: UserFacingErrorContext
    ) -> UserFacingErrorPresentation {
        if let interaction = error as? ProviderInteractionError {
            return UserFacingErrorPresentation(message: interaction == .canceled
                ? L10n.text("操作已取消。")
                : L10n.text("扫码或交互等待超时，请重新播放并按来源提示完成操作。"), recoverySuggestion: "")
        }
        if let artifact = error as? DevelopmentAndroidArtifactError {
            return UserFacingErrorPresentation(
                message: artifact.localizedDescription,
                recoverySuggestion: ""
            )
        }
        if let failure = error as? DriveServiceFailure {
            let hint = failure.appFailure.presentationHint
            return UserFacingErrorPresentation(message: hint.title, recoverySuggestion: hint.suggestedAction)
        }
        if let failure = error as? AppFailure, failure.reason != nil {
            let hint = failure.presentationHint
            return UserFacingErrorPresentation(message: hint.title, recoverySuggestion: hint.suggestedAction)
        }
        let isCancellation = TaskDiagnosticIssue.isCancellation(error) || isCancelledURLError(error)
            || { if case DriveTaskRecoveryError.cancelled = error { return true }; return false }()
        return UserFacingErrorPresentation(
            message: specificMessage(for: error, context: context) ?? context.fallbackMessage,
            recoverySuggestion: isCancellation ? "" : context.recoverySuggestion
        )
    }

    static func message(for error: Error, context: UserFacingErrorContext) -> String {
        presentation(for: error, context: context).combinedMessage
    }

    static func playbackMessage(from rawMessage: String) -> String {
        let normalized = rawMessage.lowercased()
        if containsAny(normalized, ["401", "403", "expired", "signature", "authorization", "鉴权", "授权"]) {
            return L10n.text("播放地址已失效或需要重新授权。请重新打开内容，必要时完成授权后重试。")
        }
        if containsAny(normalized, ["404", "not found"]) {
            return L10n.text("播放地址已失效或内容已下线。请切换线路或视频源。")
        }
        if containsAny(normalized, ["timed out", "timeout", "connection reset", "network", "tls", "ssl"]) {
            return L10n.text("连接播放线路失败。请检查网络后重试，或切换其他线路。")
        }
        if containsAny(normalized, ["unsupported", "unrecognized file format", "decoder", "codec"]) {
            return L10n.text("当前内容的格式暂不受支持。请切换线路或视频源。")
        }
        if containsAny(normalized, ["500", "502", "503", "504"]) {
            return L10n.text("视频服务暂时异常。请稍后重试或切换其他线路。")
        }
        return L10n.text("当前内容暂时无法播放。请重试或切换线路、视频源。")
    }

    private static func specificMessage(
        for error: Error,
        context: UserFacingErrorContext
    ) -> String? {
        if let magnet = error as? WebTorrentMagnetPlaybackError {
            // The bridge can include private paths or URLs in its diagnostic.
            // Present the typed failure stage using fixed product copy instead.
            switch magnet {
            case .invalidMagnet:
                return L10n.text("磁力链接无效，请选择其他资源。")
            case .bridgeResourcesMissing, .nodeRuntimeMissing:
                return L10n.text("磁力播放组件不可用，请重新安装应用后重试。")
            case .launchFailed:
                return L10n.text("无法启动磁力播放，请稍后重试或选择其他资源。")
            case .bridgeFailed:
                return L10n.text("未能读取磁力文件信息，请稍后重试或选择其他资源。")
            case .timedOut:
                return L10n.text("等待磁力文件信息超时，请稍后重试或选择其他资源。")
            }
        }
        if let provider = error as? ProviderErrorPayload {
            // Use fixed local copy; never display a remote Provider's message.
            switch provider.code {
            case "android_original_runtimeUnavailable":
                return L10n.text("请先在设置中安装 Android 原版运行组件。")
            case "android_original_runtimeInvalid":
                return L10n.text("Android 原版运行组件校验失败，请重新安装或回滚组件。")
            case "android_player_address_missing":
                return L10n.text("视频源未返回播放地址，请重试或切换线路。")
            default: break
            }
        }
        if let file = error as? FileServiceError {
            let issue = TaskDiagnosticIssue.local(file)
            if let reason = issue.reason.failureReason { return AppFailure(category: .source, reason: reason).presentationHint.title }
            switch file {
            case .authorizationExpired: return L10n.text("目录授权已失效，请在设置中重新选择文件夹。")
            case .invalidConfiguration: return L10n.text("服务设置不完整，请在设置中检查连接信息。")
            default: return L10n.text("服务暂时不可用，请检查设置后重试。")
            }
        }
        if let scan = error as? MediaScanRecoveryError {
            switch scan {
            case .configurationChanged:
                return L10n.text("服务、账号或媒体库设置已变化，请重新扫描。旧索引仍可浏览。")
            case .expired:
                return L10n.text("扫描检查点已过期，请手动重新扫描。旧索引仍可浏览。")
            case .cancelled:
                return L10n.text("扫描已取消，请手动重新扫描。旧索引仍可浏览。")
            case .capacity, .readBudget:
                return L10n.text("扫描达到本次读取或检查点上限，旧索引已保留。请缩小媒体库目录后重扫。")
            case .unavailable, .superseded:
                return L10n.text("此扫描检查点已不可继续，请重新扫描。旧索引仍可浏览。")
            }
        }
        if error is CancellationError || isCancelledURLError(error) {
            return L10n.text("操作已取消。")
        }

        if let inputError = error as? VodInputError {
            switch inputError {
            case .emptyURL: return L10n.text("点播源地址不能为空。")
            case .invalidURL: return L10n.text("点播源地址格式不正确。")
            case .unrecognizedContent: return L10n.text("返回内容不是可识别的点播配置或内容接口。")
            }
        }

        if let configError = error as? ConfigError {
            switch configError {
            case .invalidJSON: return L10n.text("配置内容格式不正确。")
            case .configMessage: return L10n.text("配置服务返回了错误信息。")
            case .isDepot: return L10n.text("该地址包含多个子配置，请先选择一个。")
            case .emptyConfig: return L10n.text("配置中没有可用内容。")
            }
        }

        if let recovery = error as? DriveTaskRecoveryError {
            switch recovery {
            case .storageUnavailable:
                return L10n.text("无法保存或读取转存记录，已停止转存。请检查本机存储后重试。")
            case .capacityReached:
                return L10n.text("待核对的转存记录已达上限。请先处理未完成任务。")
            case .scopeChanged:
                return L10n.text("账号、来源配置或目标目录已变化。请核对原设置，任务未继续。")
            case .cancelled:
                return L10n.text("任务已取消，不会恢复执行。")
            case .requiresReview, .staleRecord:
                return L10n.text("上次转存仍待核对。请在转存记录中手动继续，本次不会重复提交。")
            }
        }
        if let driveError = error as? DriveEngineError {
            return driveMessage(for: driveError)
        }

        if let spiderError = error as? SpiderEngineError {
            switch spiderError {
            case .unsupportedAndroidCrawler:
                return L10n.text("该视频源使用的格式当前无法加载。")
            case .emptyScript:
                return L10n.text("该视频源配置不完整，当前无法加载。")
            case .nativeReplacementUnsupported:
                return spiderError.localizedDescription
            }
        }

        if let httpError = error as? HTTPError {
            return httpMessage(for: httpError)
        }

        if let urlError = urlError(from: error) {
            return urlMessage(for: urlError)
        }

        if error is DecodingError {
            return L10n.text("服务返回的数据格式异常。")
        }

        if let storageError = error as? StorageError {
            switch storageError {
            case .unsupportedBackupVersion: return L10n.text("该备份来自不受支持的版本。")
            case .unsupportedProgressVersion: return L10n.text("该播放进度文件来自不受支持的版本。")
            case .invalidBackup: return L10n.text("备份文件格式不正确。")
            case .backupTooLarge: return L10n.text("备份文件过大。")
            case .backupChecksumMismatch: return L10n.text("备份文件校验失败，内容可能已损坏或被修改。")
            case .backupCollectionLimitExceeded: return L10n.text("备份文件包含的记录过多。")
            case .unsafeHistoryReference: return L10n.text("备份中包含不安全的播放记录。")
            }
        }

        if error is PublicSourceValidationError
            || error is FeedbackValidationError
            || error is GitHubIssueDraftError {
            return error.localizedDescription
        }

        if let describedError = error as? UserFacingDescribedError {
            return describedError.userFacingDescription
        }

        if let failure = error as? AppFailure {
            let hint = failure.presentationHint
            return UserFacingErrorPresentation(
                message: context.fallbackMessage,
                recoverySuggestion: hint.suggestedAction
            ).combinedMessage
        }

        return nil
    }

    private static func driveMessage(for error: DriveEngineError) -> String {
        switch error {
        case .invalidShareURL:
            return L10n.text("网盘分享链接无效或不完整。")
        case .unsupported:
            return L10n.text("该网盘分享暂时无法处理。")
        case .loginRequired(let provider):
            return L10n.text("{0}需要重新授权。", ["\(provider.localizedDisplayName)"])
        case .noPlayableFile:
            return L10n.text("网盘分享中没有找到可播放的视频文件。")
        case .noDownloadURL:
            return L10n.text("网盘未能返回完整播放地址，登录状态可能已失效。")
        case .officialPlayURLPending:
            return L10n.text("文件已转存，但播放地址尚未准备好。请稍后重试，或先在对应网盘应用中打开一次该文件。")
        case .transferConfirmationPending:
            return L10n.text("转存结果仍待确认。请稍后重试以核对文件，本次不会重复提交转存。")
        case .api(let provider, let statusCode, let code, _):
            if !(200..<300).contains(statusCode) {
                return httpStatusMessage(statusCode, serviceName: provider.localizedDisplayName)
            }
            // Business failures can arrive in a successful HTTP response. Never
            // show the transport success code or echo an untrusted server body.
            let reference = code.map { L10n.text("（服务错误码 {0}）", ["\($0)"]) } ?? ""
            return L10n.text("{0}未能完成操作{1}。请检查分享链接、提取码和账号权限后重试。", ["\(provider.localizedDisplayName)", "\(reference)"])
        }
    }

    private static func httpMessage(for error: HTTPError) -> String {
        switch error {
        case .invalidURL:
            return L10n.text("请求地址格式不正确。")
        case .invalidResponse:
            return L10n.text("服务返回了无法读取的内容。")
        case .originMismatch:
            return L10n.text("请求被重定向到不受信任的地址。")
        case .httpError(let statusCode, _):
            return httpStatusMessage(statusCode, serviceName: nil)
        }
    }

    private static func httpStatusMessage(_ statusCode: Int, serviceName: String?) -> String {
        let service = serviceName.map { L10n.text("{0}服务", ["\($0)"]) } ?? L10n.text("服务")
        switch statusCode {
        case 401, 403:
            return L10n.text("{0}拒绝访问，登录状态可能已失效。", ["\(service)"])
        case 404, 410:
            return L10n.text("请求的内容已不存在。")
        case 408:
            return L10n.text("连接{0}超时。", ["\(service)"])
        case 429:
            return L10n.text("请求过于频繁，{0}暂时限制访问。", ["\(service)"])
        case 500...599:
            return L10n.text("{0}暂时异常（错误码 {1}）。", ["\(service)", "\(statusCode)"])
        default:
            return L10n.text("{0}返回异常（错误码 {1}）。", ["\(service)", "\(statusCode)"])
        }
    }

    private static func urlError(from error: Error) -> URLError? {
        if let urlError = error as? URLError { return urlError }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        return URLError(URLError.Code(rawValue: nsError.code))
    }

    private static func isCancelledURLError(_ error: Error) -> Bool {
        urlError(from: error)?.code == .cancelled
    }

    private static func urlMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return L10n.text("当前没有可用的网络连接。")
        case .timedOut:
            return L10n.text("连接超时。")
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return L10n.text("无法连接到服务地址。")
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return L10n.text("无法与服务建立安全连接。")
        case .cancelled:
            return L10n.text("操作已取消。")
        default:
            return L10n.text("网络请求未能完成。")
        }
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0.lowercased()) }
    }
}
