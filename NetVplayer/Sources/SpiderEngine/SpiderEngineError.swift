import Foundation

public enum SpiderEngineError: Error, LocalizedError, Sendable {
    case unsupportedAndroidCrawler(api: String)
    case emptyScript(api: String)
    case nativeReplacementUnsupported(site: String, capability: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAndroidCrawler:
            return "该视频源依赖 Android 组件，当前 macOS 版本无法加载。请切换其他视频源。"
        case .emptyScript:
            return "视频源配置不完整，当前无法加载。请检查配置或切换其他视频源。"
        case .nativeReplacementUnsupported(_, let capability):
            if capability.contains("签名 Provider") {
                return "该 JS 视频源必须通过签名 Provider 包运行，当前不会执行配置中的远程脚本。请安装受信任的 Provider 或切换其他视频源。"
            }
            if let statusCode = Self.httpStatusCode(in: capability) {
                return "源站返回 HTTP \(statusCode)，可能正在维护或网络不稳定。请稍后重试或切换其他视频源。"
            }
            if capability.contains("待抓包") || capability.contains("未实现") || capability.contains("不支持") {
                return "该视频源的这项功能当前在 macOS 上不可用。请切换其他视频源。"
            }
            if capability.localizedCaseInsensitiveContains("WAF")
                || capability.contains("停放")
                || capability.contains("拦截") {
                return "源站当前被安全验证拦截或已停止服务。请稍后重试或切换其他视频源。"
            }
            if capability.contains("无效")
                || capability.contains("无法识别")
                || capability.localizedCaseInsensitiveContains("JSON")
                || capability.localizedCaseInsensitiveContains("HTML") {
                return "源站返回的数据无法读取。请稍后重试或切换其他视频源。"
            }
            return "暂时无法从源站获取内容。请稍后重试或切换其他视频源。"
        }
    }

    private static func httpStatusCode(in capability: String) -> Int? {
        guard let httpRange = capability.range(of: "HTTP", options: .caseInsensitive) else { return nil }
        let suffix = capability[httpRange.upperBound...].drop(while: { $0.isWhitespace })
        let digits = suffix.prefix(while: { $0.isNumber })
        guard digits.count == 3, let statusCode = Int(digits), (100...599).contains(statusCode) else { return nil }
        return statusCode
    }
}
