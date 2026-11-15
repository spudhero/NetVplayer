import Foundation
import Models

/// Failure metadata only; never retain provider URLs, headers or response bodies.
public enum ProviderDanmakuLoadError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case emptyResponse
    case invalidPayload(DanmakuPayloadFailureCategory)
    case noComments

    public var diagnosticCode: String {
        switch self {
        case .invalidURL: "invalidURL"
        case .httpStatus(let status): "http_\(status)"
        case .emptyResponse: "emptyResponse"
        case .invalidPayload(let failure): failure.rawValue
        case .noComments: "noComments"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .emptyResponse: L10n.text("弹幕源未返回内容，暂时无法显示弹幕。")
        case .noComments: L10n.text("所选来源暂无弹幕。")
        case .httpStatus: L10n.text("弹幕源暂时不可用，请稍后重试。")
        case .invalidPayload(.payloadTooLarge): L10n.text("弹幕数据过大，无法加载。")
        case .invalidURL, .invalidPayload: L10n.text("弹幕源返回的数据无法识别。")
        }
    }
}
