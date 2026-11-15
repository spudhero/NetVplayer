import Foundation

public enum LivePreviewError: Error, LocalizedError, Sendable {
    case connectionLimit, unsupported, failed
    public var errorDescription: String? {
        switch self {
        case .connectionLimit: L10n.text("账号连接额度不足或未知，已为主播放保留连接。")
        case .unsupported: L10n.text("此频道暂不支持缓存画面。")
        case .failed: L10n.text("画面刷新失败，已保留已有缓存。")
        }
    }
}
