// Models/AppFailure.swift
// 统一错误归因模型

import Foundation

/// 跨模块错误归因分类，用于真实源验证和 UI 展示。
public enum AppFailureCategory: String, Codable, Sendable {
    case config = "Config"
    case spider = "Spider"
    case proxy = "Proxy"
    case parse = "Parse"
    case source = "Source"
    case live = "Live"
    case player = "Player"
    case ui = "UI"
    case unknown = "Unknown"
}

public struct AppFailure: Codable, Sendable, LocalizedError {
    public var category: AppFailureCategory
    public var message: String
    public var detail: String
    public var reason: AppFailureReason?

    public init(category: AppFailureCategory = .unknown, message: String = "", detail: String = "", reason: AppFailureReason? = nil) {
        self.category = category
        self.message = message
        self.detail = detail
        self.reason = reason
    }

    public var errorDescription: String? {
        detail.isEmpty ? "[\(category.rawValue)] \(message)" : "[\(category.rawValue)] \(message): \(detail)"
    }

    public var presentationHint: AppFailurePresentationHint {
        reason?.presentationHint ?? category.presentationHint
    }
}

/// Actionable reasons, independent of the module that detected the failure.
/// Never populated by searching an untrusted error message.
public enum AppFailureReason: String, Codable, Sendable {
    case credentialExpired, permissionDenied, quotaExceeded, rateLimited
    case temporaryNetwork, fileMissing, signedURLExpired, outcomeUnknown
    case mappingChanged, mappingUnconfirmed

    public var presentationHint: AppFailurePresentationHint {
        switch self {
        case .credentialExpired:
            return .init(title: L10n.text("网盘登录凭据已失效。"), suggestedAction: L10n.text("请在设置中重新授权该账号后重试。"))
        case .permissionDenied:
            return .init(title: L10n.text("当前账号没有执行此操作的权限。"), suggestedAction: L10n.text("请在对应网盘中确认文件和目录权限，或切换有权限的账号后重试。"))
        case .quotaExceeded:
            return .init(title: L10n.text("当前账号的可用配额不足。"), suggestedAction: L10n.text("请在对应网盘中检查空间或操作配额，处理后再手动重试。"))
        case .rateLimited:
            return .init(title: L10n.text("网盘暂时限制了请求频率。"), suggestedAction: L10n.text("请等待服务限制解除后再重试。"))
        case .temporaryNetwork:
            return .init(title: L10n.text("网盘连接暂时中断或服务暂时不可用。"), suggestedAction: L10n.text("请检查网络，稍后手动重试。"))
        case .fileMissing:
            return .init(title: L10n.text("网盘文件已不存在。"), suggestedAction: L10n.text("请在对应网盘中确认文件仍然存在，再重新打开有效的文件或分享。"))
        case .signedURLExpired:
            return .init(title: L10n.text("临时播放地址已过期。"), suggestedAction: L10n.text("请重新打开当前文件以刷新播放地址。"))
        case .outcomeUnknown:
            return .init(title: L10n.text("转存结果仍待确认。"), suggestedAction: L10n.text("请稍后重试以核对文件，本次不会重复提交转存。"))
        case .mappingChanged:
            return .init(title: L10n.text("当前文件的本地映射已失效。"), suggestedAction: L10n.text("请在网盘中确认原文件和转存目录；确认后手动重试，将按现有权限重新转存当前文件。"))
        case .mappingUnconfirmed:
            return .init(title: L10n.text("暂时无法确认当前文件的映射。"), suggestedAction: L10n.text("请检查账号、目录和文件状态，稍后重试；不会自动重新转存。"))
        }
    }
}

public struct AppFailurePresentationHint: Codable, Sendable, Equatable {
    public var title: String
    public var suggestedAction: String

    public init(title: String, suggestedAction: String) {
        self.title = title
        self.suggestedAction = suggestedAction
    }
}

public extension AppFailureCategory {
    var presentationHint: AppFailurePresentationHint {
        switch self {
        case .config:
            AppFailurePresentationHint(title: L10n.text("配置错误"), suggestedAction: L10n.text("请检查配置地址是否正确，并确认相关文件仍可访问。"))
        case .spider:
            AppFailurePresentationHint(title: L10n.text("视频源错误"), suggestedAction: L10n.text("请稍后重试或切换其他视频源；若持续失败，请查看站点兼容状态。"))
        case .proxy:
            AppFailurePresentationHint(title: L10n.text("网络代理错误"), suggestedAction: L10n.text("请检查网络和本地代理状态，确认上游服务可访问后重试。"))
        case .parse:
            AppFailurePresentationHint(title: L10n.text("解析失败"), suggestedAction: L10n.text("请重试或切换其他解析方式；如持续失败，请更换视频源。"))
        case .source:
            AppFailurePresentationHint(title: L10n.text("资源链接错误"), suggestedAction: L10n.text("请确认分享链接未失效；如需登录，请先完成授权后重试。"))
        case .live:
            AppFailurePresentationHint(title: L10n.text("直播源错误"), suggestedAction: L10n.text("请重试或切换其他线路、频道。节目单或台标加载失败通常不影响播放。"))
        case .player:
            AppFailurePresentationHint(title: L10n.text("播放失败"), suggestedAction: L10n.text("请重试或切换线路；如持续失败，该视频格式可能暂不受支持。"))
        case .ui:
            AppFailurePresentationHint(title: L10n.text("界面异常"), suggestedAction: L10n.text("请返回上一页后重试；如持续出现，请重新启动应用。"))
        case .unknown:
            AppFailurePresentationHint(title: L10n.text("发生错误"), suggestedAction: L10n.text("请重试；如持续失败，请重新启动应用并保留诊断日志。"))
        }
    }
}
