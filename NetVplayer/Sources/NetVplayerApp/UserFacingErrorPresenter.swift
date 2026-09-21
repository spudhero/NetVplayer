import Foundation
import ConfigEngine
import DriveEngine
import Models
import Networking
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
            return "点播源未能加载。"
        case .content(let sourceName):
            if let sourceName = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceName.isEmpty {
                return "视频源“\(sourceName)”暂时无法加载。"
            }
            return "当前视频源暂时无法加载。"
        case .playback:
            return "当前内容暂时无法播放。"
        case .live(let channelName, let lineNumber):
            let channel = channelName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let channelPrefix = channel.flatMap { $0.isEmpty ? nil : "频道“\($0)”" } ?? "当前频道"
            let lineSuffix = lineNumber.map { "的线路 \($0) " } ?? "的当前线路"
            return "\(channelPrefix)\(lineSuffix)暂时无法播放。"
        case .authorization(let providerName):
            return "\(providerName)授权未完成。"
        case .storage(let operation), .extensionOperation(let operation), .feedback(let operation):
            return "\(operation)未完成。"
        case .update:
            return "应用更新未完成。"
        case .webContent:
            return "页面未能加载。"
        }
    }

    fileprivate var recoverySuggestion: String {
        switch self {
        case .configuration:
            return "请检查配置地址和网络后重试。"
        case .content:
            return "请稍后重试或切换其他视频源。"
        case .playback:
            return "请重试或切换线路、视频源。"
        case .live:
            return "请重试或切换其他线路、频道。"
        case .authorization:
            return "请检查网络后刷新登录页面并重试。"
        case .storage:
            return "请检查文件权限和可用存储空间后重试。"
        case .extensionOperation:
            return "请检查网络后重试；已安装的扩展仍可继续使用。"
        case .feedback:
            return "请检查填写内容后重试。"
        case .update:
            return "请检查网络后重新检查更新。"
        case .webContent:
            return "请检查地址和网络后重试。"
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
        let isCancellation = error is CancellationError || isCancelledURLError(error)
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
        if containsAny(normalized, ["401", "403", "expired", "signature", "鉴权", "授权"]) {
            return "播放地址已失效或需要重新授权。请重新打开内容，必要时完成授权后重试。"
        }
        if containsAny(normalized, ["404", "not found"]) {
            return "播放地址已失效或内容已下线。请切换线路或视频源。"
        }
        if containsAny(normalized, ["timed out", "timeout", "connection reset", "network", "tls", "ssl"]) {
            return "连接播放线路失败。请检查网络后重试，或切换其他线路。"
        }
        if containsAny(normalized, ["unsupported", "unrecognized file format", "decoder", "codec"]) {
            return "当前内容的格式暂不受支持。请切换线路或视频源。"
        }
        if containsAny(normalized, ["500", "502", "503", "504"]) {
            return "视频服务暂时异常。请稍后重试或切换其他线路。"
        }
        return "当前内容暂时无法播放。请重试或切换线路、视频源。"
    }

    private static func specificMessage(
        for error: Error,
        context: UserFacingErrorContext
    ) -> String? {
        if error is CancellationError || isCancelledURLError(error) {
            return "操作已取消。"
        }

        if let inputError = error as? VodInputError {
            switch inputError {
            case .emptyURL: return "点播源地址不能为空。"
            case .invalidURL: return "点播源地址格式不正确。"
            case .unrecognizedContent: return "返回内容不是可识别的点播配置或内容接口。"
            }
        }

        if let configError = error as? ConfigError {
            switch configError {
            case .invalidJSON: return "配置内容格式不正确。"
            case .configMessage: return "配置服务返回了错误信息。"
            case .isDepot: return "该地址包含多个子配置，请先选择一个。"
            case .emptyConfig: return "配置中没有可用内容。"
            }
        }

        if let driveError = error as? DriveEngineError {
            return driveMessage(for: driveError)
        }

        if let spiderError = error as? SpiderEngineError {
            switch spiderError {
            case .unsupportedAndroidCrawler:
                return "该视频源使用的格式当前无法加载。"
            case .emptyScript:
                return "该视频源配置不完整，当前无法加载。"
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
            return "服务返回的数据格式异常。"
        }

        if let storageError = error as? StorageError {
            switch storageError {
            case .unsupportedBackupVersion: return "该备份来自不受支持的版本。"
            case .unsupportedProgressVersion: return "该播放进度文件来自不受支持的版本。"
            case .invalidBackup: return "备份文件格式不正确。"
            case .backupTooLarge: return "备份文件过大。"
            case .backupChecksumMismatch: return "备份文件校验失败，内容可能已损坏或被修改。"
            case .backupCollectionLimitExceeded: return "备份文件包含的记录过多。"
            case .unsafeHistoryReference: return "备份中包含不安全的播放记录。"
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
            return "网盘分享链接无效或不完整。"
        case .unsupported:
            return "该网盘分享暂时无法处理。"
        case .loginRequired(let provider):
            return "\(provider.displayName)需要重新授权。"
        case .noPlayableFile:
            return "网盘分享中没有找到可播放的视频文件。"
        case .noDownloadURL:
            return "网盘未能返回完整播放地址，登录状态可能已失效。"
        case .officialPlayURLPending:
            return "文件已转存，但播放地址尚未准备好。请稍后重试，或先在对应网盘应用中打开一次该文件。"
        case .api(let provider, let statusCode, let code, _):
            if !(200..<300).contains(statusCode) {
                return httpStatusMessage(statusCode, serviceName: provider.displayName)
            }
            // Business failures can arrive in a successful HTTP response. Never
            // show the transport success code or echo an untrusted server body.
            let reference = code.map { "（服务错误码 \($0)）" } ?? ""
            return "\(provider.displayName)未能完成操作\(reference)。请检查分享链接、提取码和账号权限后重试。"
        }
    }

    private static func httpMessage(for error: HTTPError) -> String {
        switch error {
        case .invalidURL:
            return "请求地址格式不正确。"
        case .invalidResponse:
            return "服务返回了无法读取的内容。"
        case .originMismatch:
            return "请求被重定向到不受信任的地址。"
        case .httpError(let statusCode, _):
            return httpStatusMessage(statusCode, serviceName: nil)
        }
    }

    private static func httpStatusMessage(_ statusCode: Int, serviceName: String?) -> String {
        let service = serviceName.map { "\($0)服务" } ?? "服务"
        switch statusCode {
        case 401, 403:
            return "\(service)拒绝访问，登录状态可能已失效。"
        case 404, 410:
            return "请求的内容已不存在。"
        case 408:
            return "连接\(service)超时。"
        case 429:
            return "请求过于频繁，\(service)暂时限制访问。"
        case 500...599:
            return "\(service)暂时异常（错误码 \(statusCode)）。"
        default:
            return "\(service)返回异常（错误码 \(statusCode)）。"
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
            return "当前没有可用的网络连接。"
        case .timedOut:
            return "连接超时。"
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return "无法连接到服务地址。"
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return "无法与服务建立安全连接。"
        case .cancelled:
            return "操作已取消。"
        default:
            return "网络请求未能完成。"
        }
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}
