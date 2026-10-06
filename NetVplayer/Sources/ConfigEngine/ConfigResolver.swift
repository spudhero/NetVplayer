// ConfigEngine/ConfigResolver.swift
// 配置加载总调度，对应 FongMi: VodConfig.load → Decoder.getJson

import Foundation
import CryptoKit
import Models
import NodeBundleRuntime
import Networking
import Storage

public enum VodInputKind: String, Sendable, Equatable {
    case configuration
    case nodeJSBundle
    case macCMSJSON
    case macCMSXML
}

public struct ResolvedVodInput: Sendable {
    public let json: String
    public let config: Config
    public let kind: VodInputKind
    public let canonicalURL: String
    public let initialResult: Result?
    public let providerID: String?
    public let fingerprint: String
    public let usesCachedConfiguration: Bool
    public let configurationRefreshError: (any Error)?

    public init(
        json: String,
        config: Config,
        kind: VodInputKind,
        canonicalURL: String,
        initialResult: Result?,
        providerID: String? = nil,
        fingerprint: String? = nil,
        usesCachedConfiguration: Bool = false,
        configurationRefreshError: (any Error)? = nil
    ) {
        self.json = json
        self.config = config
        self.kind = kind
        self.canonicalURL = canonicalURL
        self.initialResult = initialResult
        self.providerID = providerID
        self.fingerprint = fingerprint ?? StableFingerprint.sha256Prefix(json)
        self.usesCachedConfiguration = usesCachedConfiguration
        self.configurationRefreshError = configurationRefreshError
    }
}

public enum VodInputError: Error, LocalizedError, Sendable {
    case emptyURL
    case invalidURL
    case unrecognizedContent

    public var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "点播源地址不能为空"
        case .invalidURL:
            return "点播源地址无效"
        case .unrecognizedContent:
            return "返回内容不是可识别的点播配置或内容接口"
        }
    }
}

/// 配置加载器 — 下载、解密、解析配置 JSON
public final class ConfigResolver: Sendable {

    public static let shared = ConfigResolver()
    private static let configurationRequestHeaders = ["User-Agent": "okhttp/5.3.2"]

    private let httpClient: HTTPClient
    private let preferences: UserPreferences
    private let allowsProxyFallback: Bool

    public init(httpClient: HTTPClient = .shared, preferences: UserPreferences = .shared, allowsProxyFallback: Bool = true) {
        self.httpClient = httpClient
        self.preferences = preferences
        self.allowsProxyFallback = allowsProxyFallback
    }

    /// 加载并解密配置
    public func load(url: String) async throws -> String {
        try await loadPayload(url: url).payload
    }

    /// Restores only a usable snapshot of this exact source, without making a request.
    public func cachedVodInput(url: String, cachedConfig: Config?) -> ResolvedVodInput? {
        let inputURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sourceURL = URL(string: inputURL),
              sourceURL.isFileURL || ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""),
              !Self.isNodeBundleURL(inputURL),
              let cachedConfig, cachedConfig.type == .vod,
              cachedConfig.url.trimmingCharacters(in: .whitespacesAndNewlines) == inputURL,
              let data = cachedConfig.json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["msg"] == nil, object["urls"] == nil,
              let sites = object["sites"] as? [[String: Any]], !sites.isEmpty,
              let siteData = try? JSONSerialization.data(withJSONObject: sites),
              let decodedSites = try? JSONDecoder().decode([Site].self, from: siteData),
              decodedSites.contains(where: {
                  !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return nil }
        return ResolvedVodInput(
            json: cachedConfig.json,
            config: cachedConfig,
            kind: .configuration,
            canonicalURL: inputURL,
            initialResult: nil,
            usesCachedConfiguration: true
        )
    }

    /// Loads a complete snapshot for background persistence without changing active configuration state.
    public func loadVodSnapshot(url: String) async throws -> ResolvedVodInput {
        let input = try await loadVodInput(url: url)
        guard input.kind != .nodeJSBundle else { throw VodInputError.unrecognizedContent }
        let snapshotResolver = VodConfig(httpClient: httpClient, hygieneStore: nil)
        let json = try await snapshotResolver.resolveConfigurationSnapshot(json: input.json, config: input.config)
        try Task.checkCancellation()
        guard snapshotResolver.externalArrayErrors.isEmpty else { throw ConfigError.invalidJSON }
        return ResolvedVodInput(
            json: json, config: input.config, kind: input.kind,
            canonicalURL: input.canonicalURL, initialResult: input.initialResult
        )
    }

    /// 加载地址并识别完整配置或单个 MacCMS 接口。
    public func loadVodInput(url: String, cachedConfig: Config? = nil) async throws -> ResolvedVodInput {
        let inputURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputURL.isEmpty else { throw VodInputError.emptyURL }
        guard URL(string: inputURL) != nil else { throw VodInputError.invalidURL }

        if let uri = URL(string: inputURL), uri.scheme == "netvplayer-xtream",
           let host = uri.host, let id = UUID(uuidString: host),
           let account = preferences.xtreamConfigurations.first(where: { $0.id == id }) {
            let site = try account.site()
            let data = try JSONEncoder().encode([site])
            let sites = try JSONSerialization.jsonObject(with: data)
            let json = try JSONSerialization.data(withJSONObject: ["sites": sites, "home": site.key])
            return ResolvedVodInput(json: String(decoding: json, as: UTF8.self), config: Config(type: .vod, url: account.url, name: account.name), kind: .configuration, canonicalURL: account.url, initialResult: nil)
        }

        if inputURL.hasPrefix("netvplayer-xtream:") { throw XtreamError.authorizationRequired }

        if Self.isNodeBundleURL(inputURL) {
            do {
                let resolution = try await NodeBundleRuntimeRegistry.shared.resolve(url: inputURL)
                let json = try Self.normalizeNodeBundleConfiguration(resolution.configurationData)
                return ResolvedVodInput(
                    json: json,
                    config: .vod(url: resolution.sourceURL),
                    kind: .nodeJSBundle,
                    canonicalURL: resolution.sourceURL,
                    initialResult: nil,
                    providerID: resolution.providerID
                )
            } catch {
                await NodeBundleRuntimeRegistry.shared.shutdown()
                throw error
            }
        }

        let requestURL = inputURL
        let loaded: (payload: String, finalURL: String)
        do {
            loaded = try await loadPayload(url: requestURL)
        } catch {
            try Task.checkCancellation()
            guard ConfigurationRecoveryPolicy.canRestoreCachedConfiguration(after: error),
                  let cached = cachedVodInput(url: requestURL, cachedConfig: cachedConfig) else {
                throw error
            }
            return ResolvedVodInput(
                json: cached.json,
                config: cached.config,
                kind: .configuration,
                canonicalURL: requestURL,
                initialResult: nil,
                usesCachedConfiguration: true,
                configurationRefreshError: error
            )
        }
        let payload = loaded.payload.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = payload.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           Self.isConfigurationObject(object) {
            return ResolvedVodInput(
                json: payload,
                config: .vod(url: requestURL),
                kind: .configuration,
                canonicalURL: requestURL,
                initialResult: nil
            )
        }

        guard var decoded = try MacCMSPayloadDecoder.decodeIfPresent(payload) else {
            throw VodInputError.unrecognizedContent
        }
        let canonicalURL = try Self.canonicalMacCMSURL(inputURL)
        let hostName = Self.displayHost(for: canonicalURL)
        let siteKey = Self.siteKey(for: canonicalURL)
        let siteType = decoded.format == .json ? SiteType.cmsJSON.rawValue : SiteType.cmsXML.rawValue
        let configName = "MacCMS · \(hostName)"

        decoded.result.key = siteKey
        decoded.result.list = decoded.result.list.map { vod in
            var vod = vod
            vod.siteKey = siteKey
            return vod
        }

        let object: [String: Any] = [
            "home": siteKey,
            "sites": [[
                "key": siteKey,
                "name": hostName,
                "type": siteType,
                "api": canonicalURL,
                "searchable": 1,
                "quickSearch": 1,
                "changeable": 1,
            ]],
            "parses": [],
            "lives": [],
            "rules": [],
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw VodInputError.unrecognizedContent
        }
        let configData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(data: configData, encoding: .utf8) else {
            throw VodInputError.unrecognizedContent
        }

        return ResolvedVodInput(
            json: json,
            config: Config(type: .vod, url: canonicalURL, name: configName, home: siteKey),
            kind: decoded.format == .json ? .macCMSJSON : .macCMSXML,
            canonicalURL: canonicalURL,
            initialResult: decoded.result
        )
    }

    private func loadPayload(url: String) async throws -> (payload: String, finalURL: String) {
        let response = try await httpClient.get(
            url: url,
            headers: Self.configurationRequestHeaders,
            allowsProxyFallback: allowsProxyFallback
        )
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError.httpError(response.statusCode, HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
        }
        let finalURL = response.finalURL?.absoluteString ?? url
        let text = response.text

        // 尝试按文本解码
        if let decoded = try? SourceDecoder.decode(text, url: finalURL) {
            return (decoded, finalURL)
        }

        // 尝试按二进制解码（图片隐写）
        return (try SourceDecoder.decodeFromImageData(response.data, url: finalURL), finalURL)
    }

    private static func isConfigurationObject(_ object: [String: Any]) -> Bool {
        let keys: Set<String> = [
            "sites", "urls", "lives", "parses", "spider", "home", "parse",
            "wallpaper", "rules", "doh", "proxy", "headers", "hosts", "flags",
            "ads", "logo", "notice", "danmaku",
        ]
        return !keys.isDisjoint(with: object.keys)
    }

    private static func isNodeBundleURL(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return components.path.lowercased().hasSuffix(".js.md5")
    }

    private static func normalizeNodeBundleConfiguration(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VodInputError.unrecognizedContent
        }
        var video = (root["video"] as? [String: Any]) ?? root
        guard var sites = video["sites"] as? [[String: Any]], !sites.isEmpty else {
            throw VodInputError.unrecognizedContent
        }

        sites = sites.compactMap { rawSite in
            var site = rawSite
            let key = (site["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let api = (site["api"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty, !api.isEmpty else { return nil }
            site["key"] = key
            site["api"] = api
            site["type"] = (site["type"] as? Int) ?? 3
            site["timeout"] = (site["timeout"] as? Int) ?? 30
            site["searchable"] = (site["searchable"] as? Int) ?? 1
            site["quickSearch"] = (site["quickSearch"] as? Int) ?? 1
            site["changeable"] = (site["changeable"] as? Int) ?? 1
            return site
        }
        guard !sites.isEmpty else { throw VodInputError.unrecognizedContent }
        video["sites"] = sites
        if let home = video["home"] as? String, !home.isEmpty {
            video["home"] = home
        } else {
            video["home"] = sites.first?["key"] as? String ?? ""
        }
        if video["parses"] == nil { video["parses"] = [] }
        if video["lives"] == nil { video["lives"] = [] }
        if video["rules"] == nil { video["rules"] = [] }
        guard JSONSerialization.isValidJSONObject(video) else {
            throw VodInputError.unrecognizedContent
        }
        let normalized = try JSONSerialization.data(withJSONObject: video, options: [.sortedKeys])
        guard let json = String(data: normalized, encoding: .utf8) else {
            throw VodInputError.unrecognizedContent
        }
        return json
    }

    private static func canonicalMacCMSURL(_ rawURL: String) throws -> String {
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            throw VodInputError.invalidURL
        }

        let transientKeys: Set<String> = [
            "ac", "t", "ids", "pg", "wd", "quick", "f", "extend", "pagesize",
        ]
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        let retainedItems = (components.queryItems ?? []).filter {
            !transientKeys.contains($0.name.lowercased())
        }
        components.queryItems = retainedItems.isEmpty ? nil : retainedItems

        guard let canonicalURL = components.url?.absoluteString else {
            throw VodInputError.invalidURL
        }
        return canonicalURL
    }

    private static func displayHost(for url: String) -> String {
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else {
            return "MacCMS"
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func siteKey(for canonicalURL: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalURL.utf8))
        let digestPrefix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "maccms_\(digestPrefix)"
    }
}
