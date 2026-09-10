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

    public init(category: AppFailureCategory = .unknown, message: String = "", detail: String = "") {
        self.category = category
        self.message = message
        self.detail = detail
    }

    public var errorDescription: String? {
        detail.isEmpty ? "[\(category.rawValue)] \(message)" : "[\(category.rawValue)] \(message): \(detail)"
    }

    public var presentationHint: AppFailurePresentationHint {
        category.presentationHint
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
            AppFailurePresentationHint(title: "配置错误", suggestedAction: "请检查配置地址是否正确，并确认相关文件仍可访问。")
        case .spider:
            AppFailurePresentationHint(title: "视频源错误", suggestedAction: "请稍后重试或切换其他视频源；若持续失败，请查看站点兼容状态。")
        case .proxy:
            AppFailurePresentationHint(title: "网络代理错误", suggestedAction: "请检查网络和本地代理状态，确认上游服务可访问后重试。")
        case .parse:
            AppFailurePresentationHint(title: "解析失败", suggestedAction: "请重试或切换其他解析方式；如持续失败，请更换视频源。")
        case .source:
            AppFailurePresentationHint(title: "资源链接错误", suggestedAction: "请确认分享链接未失效；如需登录，请先完成授权后重试。")
        case .live:
            AppFailurePresentationHint(title: "直播源错误", suggestedAction: "请重试或切换其他线路、频道。节目单或台标加载失败通常不影响播放。")
        case .player:
            AppFailurePresentationHint(title: "播放失败", suggestedAction: "请重试或切换线路；如持续失败，该视频格式可能暂不受支持。")
        case .ui:
            AppFailurePresentationHint(title: "界面异常", suggestedAction: "请返回上一页后重试；如持续出现，请重新启动应用。")
        case .unknown:
            AppFailurePresentationHint(title: "发生错误", suggestedAction: "请重试；如持续失败，请重新启动应用并保留诊断日志。")
        }
    }
}
