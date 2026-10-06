// Networking/URLHelper.swift
// URL 工具类

import Foundation

/// URL 工具
public enum URLHelper {
    /// 解析相对路径，对应 FongMi: UrlUtil.resolve
    public static func resolve(base: String, relative: String) -> String {
        guard let baseURL = URL(string: base) else { return relative }
        guard let resolved = URL(string: relative, relativeTo: baseURL) else { return relative }
        return resolved.absoluteString
    }

    /// 归一化网页嗅探到的媒体地址。嗅探结果常见为根相对路径，例如
    /// `/20260615/xxx/index.m3u8?sign=...`，需要按原网页地址补全。
    public static func resolveMediaURL(base: String, candidate: String) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidate }
        if isValid(trimmed) {
            return trimmed
        }
        return resolve(base: base, relative: trimmed)
    }

    /// 判断是否为有效 URL
    public static func isValid(_ url: String) -> Bool {
        guard let url = URL(string: url) else { return false }
        return url.scheme != nil
    }

    /// URL 编码
    public static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

    /// Base64 URL-safe 编码
    public static func base64URLSafe(_ string: String) -> String {
        let data = string.data(using: .utf8) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 修正 header key (ua -> User-Agent)
    public static func fixHeaderKey(_ key: String) -> String {
        switch key.lowercased() {
        case "ua": return "User-Agent"
        case "referer": return "Referer"
        case "cookie": return "Cookie"
        default: return key
        }
    }

    /// 规范化并对可能含有中文/空格的 URL 字符串进行安全 percent-encoding 转义
    public static func formatUrl(_ urlString: String) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let url = URL(string: trimmed) {
            return url
        }
        
        // 包含非 ASCII 字符或未转义字符，进行安全的百分号编码
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.formUnion(.urlPathAllowed)
        allowedCharacters.formUnion(.urlHostAllowed)
        allowedCharacters.formUnion(.urlPasswordAllowed)
        allowedCharacters.formUnion(.urlUserAllowed)
        allowedCharacters.insert(charactersIn: ":/")
        
        if let encodedString = trimmed.addingPercentEncoding(withAllowedCharacters: allowedCharacters) {
            return URL(string: encodedString)
        }
        return nil
    }
}
