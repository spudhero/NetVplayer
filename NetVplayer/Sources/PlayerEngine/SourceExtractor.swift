// PlayerEngine/SourceExtractor.swift
// Source/Extractor 系统，对应 FongMi: Source.java

import Foundation
import Models
import DriveEngine
import Networking

public enum SourceSupportStatus: String, Sendable {
    case supported
    case passthrough
    case unsupported
}

public struct SourceSupport: Equatable, Sendable {
    public var kind: String
    public var status: SourceSupportStatus
    public var needsParse: Bool
    public var reason: String

    public init(kind: String, status: SourceSupportStatus, needsParse: Bool = false, reason: String = "") {
        self.kind = kind
        self.status = status
        self.needsParse = needsParse
        self.reason = reason
    }
}

public struct ExternalDriveCandidate: Equatable, Sendable {
    public var rawInput: String
    public var canonicalURL: String
    public var provider: String
    public var kind: String
    public var support: SourceSupport
    public var requiresAuth: Bool

    public init(
        rawInput: String,
        canonicalURL: String,
        provider: String,
        kind: String,
        support: SourceSupport,
        requiresAuth: Bool
    ) {
        self.rawInput = rawInput
        self.canonicalURL = canonicalURL
        self.provider = provider
        self.kind = kind
        self.support = support
        self.requiresAuth = requiresAuth
    }
}

public enum SourceManagerError: Error, LocalizedError, Sendable {
    case unsupported(SourceSupport)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let support):
            return support.reason.isEmpty ? "不支持的播放源类型: \(support.kind)" : support.reason
        }
    }
}

/// Source 管理器 — 播放前对特殊协议 URL 进行预处理
public final class SourceManager: @unchecked Sendable {

    public static let shared = SourceManager()

    private static let directMediaExtensions: Set<String> = [
        "m3u8", "mpd", "mp4", "m4v", "mkv", "mov", "webm", "avi", "flv", "ts",
        "mp3", "m4a", "aac", "flac", "wav"
    ]

    private let extractors: [SourceExtractorProtocol]

    public init(extractors: [SourceExtractorProtocol]? = nil) {
        self.extractors = extractors ?? [
            StrmExtractor(),
            VideoExtractor(),
            ProxyPushExtractor(),
            QuarkShareExtractor(),
            UCShareExtractor(),
            AliShareExtractor(),
            P115ShareExtractor(),
            PikPakShareExtractor(),
            BaiduShareExtractor(),
            AListSourceExtractor(),
            WebDAVSourceExtractor(),
            BiliSourceExtractor(),
        ]
    }

    public func support(for url: String) -> SourceSupport {
        let rawTrimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmed.isEmpty else {
            return SourceSupport(kind: "empty", status: .unsupported, reason: "播放地址为空")
        }
        if rawTrimmed.lowercased().hasPrefix("netvplayer-unavailable:") {
            return Self.unavailableSupport(for: rawTrimmed)
        }

        let trimmed = Self.canonicalExternalDriveInput(rawTrimmed)

        let lowerTrimmed = trimmed.lowercased()
        if lowerTrimmed.hasPrefix("115://") || lowerTrimmed.hasPrefix("p115://") {
            return SourceSupport(kind: "115", status: .supported, reason: "115 网盘分享链接将由 SourceExtractor 转换为可播放地址")
        }

        let urlObject = Self.normalizedURL(trimmed)
        let scheme = (urlObject.scheme ?? "").lowercased()
        let host = (urlObject.host ?? "").lowercased()
        let pathExtension = urlObject.pathExtension.lowercased()

        if pathExtension == "strm" {
            return SourceSupport(kind: "strm", status: .supported)
        }
        if ["http", "https", "file"].contains(scheme), Self.directMediaExtensions.contains(pathExtension) {
            return SourceSupport(kind: "direct", status: .passthrough)
        }
        if scheme == "video" {
            return SourceSupport(kind: "video", status: .supported, needsParse: true)
        }
        if scheme == "netvplayer-unavailable" {
            return Self.unavailableSupport(for: trimmed)
        }
        if let reference = DriveFileReference.parse(trimmed) {
            switch reference.provider {
            case .quark:
                return SourceSupport(kind: "quark", status: .supported, reason: "夸克网盘文件将由 SourceExtractor 转换为可播放地址")
            case .uc:
                return SourceSupport(kind: "uc", status: .supported, reason: "UC 网盘文件将由 SourceExtractor 转换为可播放地址")
            case .ali:
                return SourceSupport(kind: "ali", status: .supported, reason: "阿里云盘文件将由 SourceExtractor 转换为可播放地址")
            case .p115:
                return SourceSupport(kind: "115", status: .supported, reason: "115 网盘文件将由 SourceExtractor 转换为可播放地址")
            case .pikpak:
                return SourceSupport(kind: "pikpak", status: .supported, reason: "PikPak 个人文件将由 SourceExtractor 转换为可播放地址")
            case .baidu:
                return SourceSupport(kind: "baidu", status: .supported, reason: "百度网盘文件将转存到个人盘并通过原画直链播放")
            case .alist:
                return SourceSupport(kind: "alist", status: .supported, reason: "AList 文件将由 SourceExtractor 转换为直链")
            case .webdav:
                return SourceSupport(kind: "webdav", status: .supported, reason: "WebDAV 文件将由 SourceExtractor 转换为直链")
            case .bilibili:
                return SourceSupport(kind: "bilibili", status: .supported, reason: "Bilibili 播放地址将由 SourceExtractor 转换为媒体地址")
            default:
                return SourceSupport(kind: reference.provider.rawValue, status: .unsupported, reason: "\(reference.provider.displayName) 暂未适配完整播放")
            }
        }
        if scheme == "quark" {
            return SourceSupport(kind: "quark", status: .supported, reason: "夸克网盘分享链接将由 SourceExtractor 转换为可播放地址")
        }
        if scheme == "uc" {
            return SourceSupport(kind: "uc", status: .supported, reason: "UC 网盘分享链接将由 SourceExtractor 转换为可播放地址")
        }
        if scheme == "ali" {
            return SourceSupport(kind: "ali", status: .supported, reason: "阿里云盘分享链接将由 SourceExtractor 转换为可播放地址")
        }
        if scheme == "115" || scheme == "p115" {
            return SourceSupport(kind: "115", status: .supported, reason: "115 网盘分享链接将由 SourceExtractor 转换为可播放地址")
        }
        if scheme == "pikpak" {
            return SourceSupport(kind: "pikpak", status: .supported, reason: "PikPak 个人文件链接将由 SourceExtractor 转换为可播放地址")
        }
        if scheme == "baidu" {
            return SourceSupport(kind: "baidu", status: .supported, reason: "百度网盘分享链接将转存到个人盘并通过原画直链播放")
        }
        if scheme == "alist" {
            return SourceSupport(kind: "alist", status: .supported, reason: "AList 文件将由 SourceExtractor 转换为直链")
        }
        if scheme == "webdav" || scheme == "webdavs" {
            return SourceSupport(kind: "webdav", status: .supported, reason: "WebDAV 文件将由 SourceExtractor 转换为直链")
        }
        if scheme == "bilibili" {
            return SourceSupport(kind: "bilibili", status: .supported, reason: "Bilibili 播放地址将由 SourceExtractor 转换为媒体地址")
        }
        if ProxyPushExtractor.isPushProxy(url: urlObject) {
            return SourceSupport(kind: "push-proxy", status: .supported, reason: "第三方 Quark/UC push 代理地址将映射到原始分享链接")
        }
        let unsupportedByScheme: [String: String] = [
            "thunder": "迅雷链接首版暂不支持",
            "magnet": "磁力链接首版暂不支持",
            "ed2k": "电驴链接首版暂不支持",
            "tvbus": "TVBus 直播源首版暂不支持",
            "mitv": "MiTV 直播源首版暂不支持",
            "p2p": "P2P 直播源首版暂不支持",
            "torrent": "BT 种子首版暂不支持",
            "jianpian": "荐片特殊源首版暂不支持",
            "push": "Push 特殊源首版暂不支持",
            "youtube": "YouTube 特殊源首版暂不支持"
        ]
        if let reason = unsupportedByScheme[scheme] {
            return SourceSupport(kind: scheme, status: .unsupported, reason: reason)
        }

        if host.contains("pan.quark.cn") || host.contains("v.quark.cn") {
            return SourceSupport(kind: "quark", status: .supported, reason: "夸克网盘分享链接将由 SourceExtractor 转换为可播放地址")
        }
        if Self.isUCWebShareURL(urlObject) {
            return SourceSupport(kind: "uc", status: .supported, reason: "UC 网盘分享链接将由 SourceExtractor 转换为可播放地址")
        }
        if host.contains("aliyundrive.com") || host.contains("alipan.com") {
            return SourceSupport(kind: "ali", status: .supported, reason: "阿里云盘分享链接将由 SourceExtractor 转换为可播放地址")
        }
        if host.contains("115.com") || host.contains("115cdn.com") {
            return SourceSupport(kind: "115", status: .supported, reason: "115 网盘分享链接将由 SourceExtractor 转换为可播放地址")
        }
        if host.contains("mypikpak.com") {
            return SourceSupport(kind: "pikpak", status: .supported, reason: "PikPak 链接已识别；个人文件可播放，公开分享消费接口仍需真实抓包验证")
        }
        if host.contains("pan.baidu.com") {
            return SourceSupport(kind: "baidu", status: .supported, reason: "百度网盘分享链接将转存到个人盘并通过原画直链播放")
        }
        let unsupportedByHost: [(match: String, kind: String, reason: String)] = [
            ("pan.xunlei.com", "xunlei", "迅雷云盘分享链接已识别；需要账号授权、验证码/恢复文件与播放接口真实样本，当前暂未适配播放解析"),
            ("123pan.com", "cloud123", "123 网盘分享链接已进入支持矩阵，当前暂未适配播放解析"),
            ("123pan.cn", "cloud123", "123 网盘分享链接已进入支持矩阵，当前暂未适配播放解析"),
            ("123684.com", "cloud123", "123 网盘分享链接已进入支持矩阵，当前暂未适配播放解析"),
            ("123865.com", "cloud123", "123 网盘分享链接已进入支持矩阵，当前暂未适配播放解析"),
            ("123952.com", "cloud123", "123 网盘分享链接已进入支持矩阵，当前暂未适配播放解析"),
            ("123912.com", "cloud123", "123 网盘分享链接已进入支持矩阵，当前暂未适配播放解析"),
            ("yun.139.com", "mobile", "中国移动云盘分享链接已识别；需要账号授权与播放接口真实样本，当前暂未适配播放解析"),
            ("caiyun.139.com", "mobile", "中国移动云盘分享链接已识别；需要账号授权与播放接口真实样本，当前暂未适配播放解析"),
            ("feixin.10086.cn", "mobile", "中国移动云盘分享链接已识别；需要账号授权与播放接口真实样本，当前暂未适配播放解析"),
            ("cloud.189.cn", "tianyi", "天翼云盘分享链接已识别；需要账号授权与播放接口真实样本，当前暂未适配播放解析")
        ]
        if let matched = unsupportedByHost.first(where: { host.contains($0.match) }) {
            return SourceSupport(kind: matched.kind, status: .unsupported, reason: matched.reason)
        }

        if host.contains("youtube.com") || host.contains("youtu.be") {
            return SourceSupport(kind: "youtube", status: .unsupported, reason: "YouTube 特殊源首版暂不支持")
        }
        if ["http", "https", "file"].contains(scheme) {
            return SourceSupport(kind: "direct", status: .passthrough)
        }

        return SourceSupport(kind: scheme.isEmpty ? "unknown" : scheme, status: .passthrough)
    }

    private static func unavailableSupport(for url: String) -> SourceSupport {
        let reason = URLComponents(string: url)?
            .queryItems?
            .first(where: { $0.name == "reason" })?
            .value
        return SourceSupport(
            kind: "unavailable",
            status: .unsupported,
            reason: reason?.isEmpty == false ? reason! : "该资源当前不可用"
        )
    }

    /// 查找匹配的提取器并处理 URL
    public func fetch(url: String) async throws -> (url: String, needParse: Bool) {
        let result = try await fetchResult(url: url)
        return (result.url, result.needParse)
    }

    /// 查找匹配的提取器并处理 URL，保留播放层需要的请求头和直连标记。
    public func fetchResult(url: String) async throws -> (url: String, needParse: Bool, headers: [String: String], fallbackHeaders: [String: String], isDirectMedia: Bool, mpvOptions: [String: String], metadata: [String: String], drivePlaybackPlan: DrivePlaybackPlan?) {
        return try await fetchResult(url: url, depth: 0)
    }

    public static func externalDriveCandidate(for rawInput: String) -> ExternalDriveCandidate? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let canonicalURL = canonicalExternalDriveInput(trimmed)
        let normalized = normalizedURL(canonicalURL)
        let support = SourceManager().support(for: canonicalURL)
        guard let provider = externalDriveProvider(for: canonicalURL, normalizedURL: normalized, support: support) else {
            return nil
        }

        return ExternalDriveCandidate(
            rawInput: trimmed,
            canonicalURL: canonicalURL,
            provider: provider,
            kind: support.kind,
            support: support,
            requiresAuth: provider != "direct"
        )
    }

    private func fetchResult(url: String, depth: Int) async throws -> (url: String, needParse: Bool, headers: [String: String], fallbackHeaders: [String: String], isDirectMedia: Bool, mpvOptions: [String: String], metadata: [String: String], drivePlaybackPlan: DrivePlaybackPlan?) {
        let currentURL = Self.canonicalExternalDriveInput(url)
        let currentSupport = support(for: currentURL)
        if currentSupport.status == .unsupported {
            throw SourceManagerError.unsupported(currentSupport)
        }

        let parsedURL = Self.normalizedURL(currentURL)

        for extractor in extractors {
            if extractor.match(url: parsedURL) {
                let result = try await extractor.fetchResult(url: currentURL)
                if result.isDirectMedia {
                    return (result.url, currentSupport.needsParse, result.headers, result.fallbackHeaders, true, result.mpvOptions, result.metadata, result.drivePlaybackPlan)
                }
                if depth < 3,
                   result.url != currentURL,
                   support(for: result.url).status == .supported {
                    return try await fetchResult(url: result.url, depth: depth + 1)
                }
                return (result.url, currentSupport.needsParse, result.headers, result.fallbackHeaders, result.isDirectMedia, result.mpvOptions, result.metadata, result.drivePlaybackPlan)
            }
        }

        return (currentURL, currentSupport.needsParse, [:], [:], false, [:], [:], nil)
    }

    static func canonicalExternalDriveInput(_ rawURL: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if DriveFileReference.parse(trimmed) != nil {
            return trimmed
        }
        guard let extractedURL = firstKnownExternalDriveURL(in: trimmed) else {
            return trimmed
        }

        var canonicalURL = canonicalShareHost(for: extractedURL)
        if !hasPasscodeQuery(canonicalURL),
           let passcode = sharePasscode(in: trimmed) {
            canonicalURL = appendingPasscode(passcode, to: canonicalURL)
        }
        return canonicalURL.absoluteString
    }

    private static func firstKnownExternalDriveURL(in text: String) -> URL? {
        let pattern = #"https?://[^\s<>"'，。；、）)】\]]+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let trailingDelimiters = CharacterSet(charactersIn: " \n\t\r,.;，。；、)）]】}'\"")
        let candidate = String(text[range]).trimmingCharacters(in: trailingDelimiters)
        guard let url = URL(string: candidate),
              let host = url.host?.lowercased(),
              isKnownExternalDriveHost(host) else {
            return nil
        }
        return url
    }

    private static func canonicalShareHost(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = url.host?.lowercased() else {
            return url
        }
        if host == "v.quark.cn" {
            components.scheme = "https"
            components.host = "pan.quark.cn"
        }
        return components.url ?? url
    }

    private static func hasPasscodeQuery(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let passcodeKeys: Set<String> = ["pwd", "password", "passcode", "code"]
        return (components.queryItems ?? []).contains { passcodeKeys.contains($0.name.lowercased()) }
    }

    private static func appendingPasscode(_ passcode: String, to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "pwd", value: passcode))
        components.queryItems = queryItems
        return components.url ?? url
    }

    private static func sharePasscode(in text: String) -> String? {
        let patterns = [
            #"(?:提取码|提取碼|密码|密碼|访问码|訪問碼|口令)\s*[:：=]?\s*([A-Za-z0-9]{2,8})"#,
            #"(?i)(?:pwd|password|passcode|code)\s*[:：=]\s*([A-Za-z0-9]{2,8})"#
        ]
        let nsText = text as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(location: 0, length: nsText.length)
            guard let match = regex.firstMatch(in: text, range: fullRange),
                  match.numberOfRanges > 1 else {
                continue
            }
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { continue }
            return nsText.substring(with: range)
        }
        return nil
    }

    private static func isKnownExternalDriveHost(_ host: String) -> Bool {
        let matches = [
            "pan.quark.cn",
            "v.quark.cn",
            "drive.uc.cn",
            "pan.baidu.com",
            "pan.xunlei.com",
            "aliyundrive.com",
            "alipan.com",
            "115.com",
            "115cdn.com",
            "mypikpak.com",
            "123pan.com",
            "123pan.cn",
            "123684.com",
            "123865.com",
            "123952.com",
            "123912.com",
            "yun.139.com",
            "caiyun.139.com",
            "feixin.10086.cn",
            "cloud.189.cn"
        ]
        return matches.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func externalDriveProvider(for canonicalURL: String, normalizedURL: URL, support: SourceSupport) -> String? {
        if let reference = DriveFileReference.parse(canonicalURL),
           reference.provider != .unknown {
            return reference.provider.rawValue
        }

        let scheme = (normalizedURL.scheme ?? "").lowercased()
        let host = (normalizedURL.host ?? "").lowercased()
        let lower = canonicalURL.lowercased()

        switch scheme {
        case "quark": return "quark"
        case "uc": return "uc"
        case "ali": return "ali"
        case "115", "p115": return "115"
        case "pikpak": return "pikpak"
        case "baidu": return "baidu"
        case "123", "cloud123": return "cloud123"
        case "xunlei", "thunder": return "xunlei"
        case "139", "mobile": return "mobile"
        case "189", "tianyi": return "tianyi"
        default: break
        }

        if isKnownExternalDriveHost(host) {
            return support.kind == "direct" ? nil : support.kind
        }
        if lower.contains("pan.quark.cn") || lower.contains("v.quark.cn") { return "quark" }
        if lower.contains("drive.uc.cn") { return "uc" }
        if lower.contains("aliyundrive.com") || lower.contains("alipan.com") { return "ali" }
        if lower.contains("115.com") || lower.contains("115cdn.com") { return "115" }
        if lower.contains("mypikpak.com") { return "pikpak" }
        if lower.contains("pan.baidu.com") { return "baidu" }
        if lower.contains("123pan.com")
            || lower.contains("123pan.cn")
            || lower.contains("123684.com")
            || lower.contains("123865.com")
            || lower.contains("123952.com")
            || lower.contains("123912.com") { return "cloud123" }
        if lower.contains("pan.xunlei.com") { return "xunlei" }
        if lower.contains("yun.139.com") || lower.contains("caiyun.139.com") || lower.contains("feixin.10086.cn") { return "mobile" }
        if lower.contains("cloud.189.cn") { return "tianyi" }
        return nil
    }

    static func isUCWebShareURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        guard host == "drive.uc.cn" || host == "www.drive.uc.cn" else { return false }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if let index = pathComponents.firstIndex(of: "s"),
           pathComponents.indices.contains(index + 1) {
            return true
        }

        let queryNames = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { $0.name.lowercased() })
        return !queryNames.isDisjoint(with: ["pwd_id", "share", "id"])
    }

    static func normalizedURL(_ rawURL: String) -> URL {
        if rawURL.lowercased().hasPrefix("115://"),
           let url = URL(string: "p\(rawURL)") {
            return url
        }
        if let url = URL(string: rawURL), url.scheme != nil {
            return url
        }
        return URL(fileURLWithPath: rawURL)
    }
}

/// .strm 文件提取器
public final class StrmExtractor: SourceExtractorProtocol {
    public func match(url: URL) -> Bool {
        url.pathExtension.lowercased() == "strm"
    }

    public func fetch(url: String) async throws -> String {
        // 下载 .strm 文件，读取第一行真实 URL
        let requestURL = SourceManager.normalizedURL(url)
        let data: Data
        if requestURL.isFileURL {
            data = try Data(contentsOf: requestURL)
        } else {
            let (remoteData, _) = try await URLSession.shared.data(from: requestURL)
            data = remoteData
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.components(separatedBy: CharacterSet.newlines).first?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? url
    }

}

public final class ProxyPushExtractor: SourceExtractorProtocol {
    public init() {}

    public func match(url: URL) -> Bool {
        Self.isPushProxy(url: url)
    }

    public func fetch(url: String) async throws -> String {
        try await fetchResult(url: url).url
    }

    public func fetchResult(url: String) async throws -> SourceFetchResult {
        guard let parsed = URL(string: url),
              let components = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "url" })?.value,
              !target.isEmpty else {
            return SourceFetchResult(url: url)
        }
        return SourceFetchResult(url: target)
    }

    static func isPushProxy(url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        guard (host == "127.0.0.1" || host == "localhost"),
              url.path == "/proxy",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") })
        let action = query["do"]?.lowercased()
        let type = query["type"]?.lowercased()
        return (action == "quark" || action == "uc") && type == "push" && !(query["url"] ?? "").isEmpty
    }
}

public final class AListSourceExtractor: SourceExtractorProtocol {
    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    public func match(url: URL) -> Bool {
        url.scheme?.lowercased() == "alist"
    }

    public func fetch(url: String) async throws -> String {
        try await fetchResult(url: url).url
    }

    public func fetchResult(url: String) async throws -> SourceFetchResult {
        let request = try AListSourceRequest(url: url)
        let body = try JSONSerialization.data(withJSONObject: ["path": request.path, "password": request.password])
        var headers = request.headers
        headers["Content-Type"] = "application/json; charset=utf-8"
        let response = try await httpClient.post(url: request.server.appendingPathComponent("/api/fs/get"), headers: headers, body: body, timeout: 30)
        let object = (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]) ?? [:]
        let data = object["data"] as? [String: Any] ?? [:]
        let rawURL = firstString(data, keys: ["raw_url", "url", "download_url"])
        guard !rawURL.isEmpty else {
            throw SourceManagerError.unsupported(SourceSupport(kind: "alist", status: .unsupported, reason: "AList 未返回可播放直链"))
        }
        return SourceFetchResult(url: rawURL, headers: request.headers, isDirectMedia: true, metadata: ["provider": DriveProvider.alist.rawValue])
    }

}

public final class WebDAVSourceExtractor: SourceExtractorProtocol {
    public init() {}

    public func match(url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "webdav" || scheme == "webdavs"
    }

    public func fetch(url: String) async throws -> String {
        try await fetchResult(url: url).url
    }

    public func fetchResult(url: String) async throws -> SourceFetchResult {
        let request = try WebDAVSourceRequest(url: url)
        return SourceFetchResult(url: request.url, headers: request.headers, isDirectMedia: true, metadata: ["provider": DriveProvider.webdav.rawValue])
    }

}

public final class BiliSourceExtractor: SourceExtractorProtocol {
    private let httpClient: HTTPClient
    private let cookieProvider: @Sendable () -> String?

    public init(httpClient: HTTPClient = .shared, cookieProvider: @escaping @Sendable () -> String? = { nil }) {
        self.httpClient = httpClient
        self.cookieProvider = cookieProvider
    }

    public func match(url: URL) -> Bool {
        url.scheme?.lowercased() == "bilibili"
    }

    public func fetch(url: String) async throws -> String {
        try await fetchResult(url: url).url
    }

    public func fetchResult(url: String) async throws -> SourceFetchResult {
        let request = try BiliSourceRequest(url: url)
        let playURL = "https://api.bilibili.com/x/player/playurl?avid=\(urlEncode(request.aid))&cid=\(urlEncode(request.cid))&qn=80&fnval=4048&fourk=1"
        let headers = biliHeaders()
        let response = try await httpClient.get(url: playURL, headers: headers, timeout: 30)
        let object = (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]) ?? [:]
        let data = object["data"] as? [String: Any] ?? [:]
        let mediaURL = BiliSourceExtractor.playbackURL(from: data)
        guard !mediaURL.isEmpty else {
            throw SourceManagerError.unsupported(SourceSupport(kind: "bilibili", status: .unsupported, reason: "Bilibili 未返回可播放地址"))
        }
        return SourceFetchResult(url: mediaURL, headers: headers, isDirectMedia: true, metadata: ["provider": DriveProvider.bilibili.rawValue])
    }

    private func biliHeaders() -> [String: String] {
        var headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36",
            "Referer": "https://www.bilibili.com"
        ]
        if let cookie = cookieProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }

    private static func playbackURL(from data: [String: Any]) -> String {
        if let durl = data["durl"] as? [[String: Any]], let first = durl.first {
            return firstString(first, keys: ["url"])
        }
        if let dash = data["dash"] as? [String: Any],
           let videos = dash["video"] as? [[String: Any]],
           let first = videos.first {
            return firstString(first, keys: ["baseUrl", "base_url"])
        }
        return ""
    }
}

private struct AListSourceRequest {
    let server: String
    let path: String
    let password: String
    let headers: [String: String]

    init(url: String) throws {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "alist" else {
            throw SourceManagerError.unsupported(SourceSupport(kind: "alist", status: .unsupported, reason: "无效的 AList 播放地址"))
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        self.server = query["server"] ?? ""
        self.path = query["path"] ?? ""
        self.password = query["password"] ?? ""
        self.headers = decodeStringMap(query["headers"])
    }
}

private struct WebDAVSourceRequest {
    let url: String
    let headers: [String: String]

    init(url: String) throws {
        guard let components = URLComponents(string: url),
              ["webdav", "webdavs"].contains(components.scheme?.lowercased() ?? "") else {
            throw SourceManagerError.unsupported(SourceSupport(kind: "webdav", status: .unsupported, reason: "无效的 WebDAV 播放地址"))
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        self.url = query["url"] ?? url
        self.headers = decodeStringMap(query["headers"])
    }
}

private struct BiliSourceRequest {
    let aid: String
    let cid: String

    init(url: String) throws {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "bilibili" else {
            throw SourceManagerError.unsupported(SourceSupport(kind: "bilibili", status: .unsupported, reason: "无效的 Bilibili 播放地址"))
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        self.aid = query["aid"] ?? ""
        self.cid = query["cid"] ?? ""
    }
}

private func firstString(_ dict: [String: Any], keys: [String]) -> String {
    for key in keys {
        if let value = dict[key] {
            if let text = value as? String, !text.isEmpty { return text }
            if let number = value as? NSNumber { return number.stringValue }
        }
    }
    return ""
}

private func decodeStringMap(_ encoded: String?) -> [String: String] {
    guard let encoded, let data = decodeBase64URL(encoded),
          let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
    return map
}

private func decodeBase64URL(_ value: String) -> Data? {
    var normalized = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder > 0 {
        normalized.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: normalized)
}

private func urlEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
}

private extension String {
    func appendingPathComponent(_ path: String) -> String {
        let base = hasSuffix("/") ? self : "\(self)/"
        let child = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base + child
    }
}

/// video:// 协议提取器
public final class VideoExtractor: SourceExtractorProtocol {
    public func match(url: URL) -> Bool {
        url.scheme == "video"
    }

    public func fetch(url: String) async throws -> String {
        // 去掉 video:// 前缀
        if url.hasPrefix("video://") {
            return String(url.dropFirst(8))
        }
        return url
    }

}
