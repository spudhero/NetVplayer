// ConfigEngine/VodConfig.swift
// 点播配置管理器，对应 FongMi: config/VodConfig.java

import Foundation
import Models
import Networking
import Storage

/// 点播配置管理器
public final class VodConfig: @unchecked Sendable {

    public static let shared = VodConfig()

    private let httpClient: HTTPClient
    private let hygieneStore: SourceHygieneStore?
    private var preservesAggregationSnapshotForMergedParse = false

    // MARK: - 状态
    public private(set) var sites: [Site] = []
    public private(set) var parses: [Parse] = []
    public private(set) var rules: [Rule] = []
    public private(set) var doh: [Doh] = []
    public private(set) var proxy: [ProxyRule] = []
    public private(set) var headers: [HeaderRule] = []
    public private(set) var hosts: [String] = []
    public private(set) var flags: [String] = []
    public private(set) var ads: [String] = []
    public private(set) var depots: [Depot] = []
    public private(set) var externalArrayErrors: [String: String] = [:]
    public private(set) var aggregationSnapshot = ConfigAggregationSnapshot()
    public private(set) var home: Site?
    public private(set) var currentParse: Parse?
    public private(set) var config: Config?
    public private(set) var wall: String = ""
    public private(set) var spider: String = ""

    public init(httpClient: HTTPClient = .shared, hygieneStore: SourceHygieneStore? = SourceHygieneStore.shared) {
        self.httpClient = httpClient
        self.hygieneStore = hygieneStore
    }

    // MARK: - 公开方法

    /// 解析配置，并先按 FongMi fetchArray 语义拉取/合并外部数组字段。
    public func parseResolvingExternalArrays(json: String, config: Config) async throws {
        guard let data = json.data(using: .utf8),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalidJSON
        }

        aggregationSnapshot = ConfigAggregationSnapshot(rootURL: config.url)
        object = await resolveExternalArrayFields(in: object, baseURL: config.url)
        guard JSONSerialization.isValidJSONObject(object),
              let mergedData = try? JSONSerialization.data(withJSONObject: object),
              let mergedJSON = String(data: mergedData, encoding: .utf8) else {
            throw ConfigError.invalidJSON
        }
        preservesAggregationSnapshotForMergedParse = true
        defer { preservesAggregationSnapshotForMergedParse = false }
        try parse(json: mergedJSON, config: config)
    }

    /// 从 JSON 字符串解析配置
    public func parse(json: String, config: Config) throws {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalidJSON
        }

        // 检查错误消息
        if let msg = object["msg"] as? String {
            throw ConfigError.configMessage(msg)
        }

        // 检查配置仓库
        if let urls = object["urls"] as? [[String: Any]] {
            let depots = urls.compactMap { dict -> Depot? in
                guard let name = dict["name"] as? String, let url = dict["url"] as? String else { return nil }
                return Depot(name: name, url: url)
            }
            throw ConfigError.isDepot(depots)
        }

        resetParsedState(preserveAggregation: preservesAggregationSnapshotForMergedParse)
        if aggregationSnapshot.rootURL.isEmpty {
            aggregationSnapshot = ConfigAggregationSnapshot(rootURL: config.url)
        }

        // 解析站点
        self.spider = object["spider"] as? String ?? ""
        var parsedConfig = config
        parsedConfig.logo = object["logo"] as? String ?? parsedConfig.logo
        parsedConfig.home = object["home"] as? String ?? parsedConfig.home
        parsedConfig.parse = object["parse"] as? String ?? parsedConfig.parse
        parsedConfig.notice = object["notice"] as? String ?? parsedConfig.notice
        parsedConfig.danmaku = object["danmaku"] as? String ?? parsedConfig.danmaku
        parsedConfig.json = json
        self.config = parsedConfig

        self.doh = Self.decodeArray(from: object, key: "doh", as: Doh.self)
        self.proxy = Self.decodeArray(from: object, key: "proxy", as: ProxyRule.self)
        self.headers = Self.decodeArray(from: object, key: "headers", as: HeaderRule.self)
        self.hosts = Self.decodeStringArray(from: object, key: "hosts")

        // 解析 sites
        if let sitesArray = object["sites"] as? [[String: Any]] {
            let jsonData = try JSONSerialization.data(withJSONObject: sitesArray)
            do {
                var decodedSites = try JSONDecoder().decode([Site].self, from: jsonData).map { site in
                    var site = site
                    if site.jar.isEmpty {
                        site.jar = self.spider
                    }
                    return self.resolveSiteResources(site, baseURL: config.url)
                }
                for site in decodedSites {
                    recordSiteOriginIfNeeded(site, sourceURL: config.url, action: "imported")
                    recordCredentialRequirements(for: site)
                    recordCredentialRiskAssessment(for: site)
                    recordAndroidRuntimeDiagnosticIfNeeded(for: site, sourceURL: config.url)
                }
                decodedSites = uniqueSitesWithDiagnostics(decodedSites, sourceURL: config.url)
                decodedSites = applySiteHygieneRules(decodedSites, sourceURL: config.url)
                self.sites = decodedSites
            } catch {
                print("[DEBUG_LOGGER] Site 模型解码失败! 错误: \(error)")
                fflush(stdout)
                self.sites = []
            }
        }

        // 解析 parses
        if let parsesArray = object["parses"] as? [[String: Any]] {
            let jsonData = try JSONSerialization.data(withJSONObject: parsesArray)
            do {
                let decodedParses = try JSONDecoder().decode([Parse].self, from: jsonData)
                self.parses = applyParseHygieneRules(decodedParses, sourceURL: config.url)
            } catch {
                print("[DEBUG_LOGGER] Parse 模型解码失败! 错误: \(error)")
                fflush(stdout)
                self.parses = []
            }
            if !parses.isEmpty {
                var allParses = [Parse.god()]
                allParses.append(contentsOf: parses)
                self.parses = allParses
            }
        }

        // 解析其他字段
        self.flags = Self.decodeStringArray(from: object, key: "flags")
        self.ads = Self.decodeStringArray(from: object, key: "ads")
        self.wall = object["wallpaper"] as? String ?? ""

        // 解析 rules
        if let rulesArray = object["rules"] as? [[String: Any]] {
            let jsonData = try JSONSerialization.data(withJSONObject: rulesArray)
            self.rules = (try? JSONDecoder().decode([Rule].self, from: jsonData)) ?? []
        }

        // 解析 lives
        if let livesArray = object["lives"] as? [[String: Any]] {
            LiveConfig.shared.parse(livesArray: livesArray, hygieneStore: hygieneStore)
            recordHygieneDecisions(LiveConfig.shared.hygieneDecisions, sourceURL: config.url)
        }

        recordResourceDiagnostics()

        // 设置默认站点
        var defaultHomeKey = parsedConfig.home
        if defaultHomeKey.isEmpty {
            defaultHomeKey = sites.first?.key ?? ""
        }
        
        if !defaultHomeKey.isEmpty {
            setHome(key: defaultHomeKey)
        }

        // 设置默认解析器
        if let parseName = parsedConfig.parse.isEmpty ? parses.first?.name : parsedConfig.parse {
            setParse(name: parseName)
        }
    }

    /// 获取站点
    public func getSite(key: String) -> Site {
        sites.first { $0.key == key } ?? Site()
    }

    /// 设置首页站点
    public func setHome(key: String) {
        home = sites.first { $0.key == key }
    }

    /// 设置当前解析器
    public func setParse(name: String) {
        currentParse = parses.first { $0.name == name }
    }

    /// 获取指定类型的解析器
    public func getParses(type: Int) -> [Parse] {
        parses.filter { $0.type == type }
    }

    /// 获取指定类型且匹配 flag 的解析器；无匹配项时回退到同类型全集。
    public func getParses(type: Int, flag: String) -> [Parse] {
        let items = getParses(type: type)
        let filtered = items.filter { $0.ext.flag.contains(flag) }
        return filtered.isEmpty ? items : filtered
    }

    /// 清理
    public func clear() {
        resetParsedState(preserveAggregation: false)
    }

    private func resetParsedState(preserveAggregation: Bool) {
        sites = []
        parses = []
        rules = []
        doh = []
        proxy = []
        headers = []
        hosts = []
        flags = []
        ads = []
        depots = []
        if !preserveAggregation {
            externalArrayErrors = [:]
            aggregationSnapshot = ConfigAggregationSnapshot()
        }
        home = nil
        currentParse = nil
        config = nil
        spider = ""
        wall = ""
        LiveConfig.shared.clear()
    }

    // MARK: - Helpers

    private static func decodeArray<T: Decodable>(from object: [String: Any], key: String, as type: T.Type) -> [T] {
        guard let value = object[key], !(value is NSNull) else { return [] }
        let array: [Any]
        if let items = value as? [Any] {
            array = items
        } else if let item = value as? [String: Any] {
            array = [item]
        } else {
            return []
        }

        guard JSONSerialization.isValidJSONObject(array),
              let data = try? JSONSerialization.data(withJSONObject: array) else {
            return []
        }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private static func decodeStringArray(from object: [String: Any], key: String) -> [String] {
        guard let value = object[key], !(value is NSNull) else { return [] }
        if let strings = value as? [String] {
            return strings
        }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return []
    }

    private func resolveExternalArrayFields(in object: [String: Any], baseURL: String) async -> [String: Any] {
        var result = object
        externalArrayErrors = [:]

        for key in ["sites", "parses", "lives", "doh", "proxy", "headers", "rules"] {
            guard let value = result[key] else { continue }
            let merged = await resolveExternalArrayValue(value, key: key, baseURL: baseURL)
            if merged != nil {
                result[key] = merged
            }
        }

        return result
    }

    private func resolveExternalArrayValue(_ value: Any, key: String, baseURL: String) async -> [Any]? {
        if let url = value as? String {
            return await fetchExternalArray(url: url, key: key, baseURL: baseURL)
        }

        guard let items = value as? [Any] else {
            return nil
        }

        var merged: [Any] = []
        for item in items {
            if let url = item as? String {
                let fetched = await fetchExternalArray(url: url, key: key, baseURL: baseURL)
                merged.append(contentsOf: fetched)
            } else if let nested = item as? [Any] {
                merged.append(contentsOf: nested)
            } else if item is [String: Any] {
                merged.append(item)
            }
        }
        return merged
    }

    private func fetchExternalArray(url: String, key: String, baseURL: String) async -> [Any] {
        let resolvedURL = resolveConfigURL(url, baseURL: baseURL)
        do {
            let response = try await httpClient.get(url: resolvedURL)
            let finalURL = response.finalURL?.absoluteString ?? resolvedURL
            let decoded = (try? SourceDecoder.decode(response.text, url: finalURL))
                ?? (try? SourceDecoder.decodeFromImageData(response.data))
                ?? response.text

            guard let data = decoded.data(using: .utf8),
                  let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                externalArrayErrors["\(key):\(resolvedURL)"] = "返回内容不是 JSON 数组"
                aggregationSnapshot.fetchedSources.append(ConfigFetchedSource(
                    field: key,
                    requestedURL: url,
                    resolvedURL: resolvedURL,
                    finalURL: finalURL,
                    status: "failed",
                    error: "返回内容不是 JSON 数组"
                ))
                return []
            }
            aggregationSnapshot.fetchedSources.append(ConfigFetchedSource(
                field: key,
                requestedURL: url,
                resolvedURL: resolvedURL,
                finalURL: finalURL,
                status: "success",
                itemCount: array.count
            ))
            recordExternalOrigins(array: array, field: key, sourceURL: finalURL)
            return array
        } catch {
            externalArrayErrors["\(key):\(resolvedURL)"] = error.localizedDescription
            aggregationSnapshot.fetchedSources.append(ConfigFetchedSource(
                field: key,
                requestedURL: url,
                resolvedURL: resolvedURL,
                status: "failed",
                error: error.localizedDescription
            ))
            return []
        }
    }

    private func resolveConfigURL(_ url: String, baseURL: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://") || trimmed.hasPrefix("assets://") {
            return URLNormalizer.convert(trimmed, baseURL: baseURL)
        }
        return URLNormalizer.convert(trimmed, baseURL: baseURL)
    }

    private func resolveSiteResources(_ site: Site, baseURL: String) -> Site {
        var site = site
        if shouldResolveSiteResource(site.api) {
            let original = site.api
            site.api = URLNormalizer.convert(site.api, baseURL: baseURL)
            recordURLNormalizationIfChanged(site: site, field: "api", original: original, normalized: site.api, baseURL: baseURL)
        }
        if shouldResolveSiteResource(site.jar) {
            let original = site.jar
            site.jar = URLNormalizer.convert(site.jar, baseURL: baseURL)
            recordURLNormalizationIfChanged(site: site, field: "jar", original: original, normalized: site.jar, baseURL: baseURL)
        }
        if !site.ext.isEmpty {
            let original = site.ext
            site.ext = URLNormalizer.convertEmbeddedResources(site.ext, baseURL: baseURL)
            recordURLNormalizationIfChanged(site: site, field: "ext", original: original, normalized: site.ext, baseURL: baseURL)
        }
        return site
    }

    private func shouldResolveSiteResource(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("csp_") || trimmed.hasPrefix("clan://") {
            return false
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://") || trimmed.hasPrefix("assets://") {
            return true
        }
        if trimmed.contains("://") {
            return false
        }
        return trimmed.hasPrefix("./") || trimmed.hasPrefix("../") || URL(fileURLWithPath: trimmed).pathExtension.isEmpty == false
    }

    private func recordExternalOrigins(array: [Any], field: String, sourceURL: String) {
        guard field == "sites" else { return }
        for item in array {
            guard let dict = item as? [String: Any] else { continue }
            let key = (dict["key"] as? String) ?? ""
            let name = (dict["name"] as? String) ?? ""
            guard !key.isEmpty || !name.isEmpty else { continue }
            aggregationSnapshot.origins.append(ConfigEntityOrigin(
                entityType: .site,
                entityKey: key,
                entityName: name,
                sourceURL: sourceURL,
                originalKey: key,
                action: "external-array:\(field)"
            ))
        }
    }

    private func recordSiteOriginIfNeeded(_ site: Site, sourceURL: String, action: String) {
        let alreadyRecorded = aggregationSnapshot.origins.contains {
            $0.entityType == .site && (($0.entityKey == site.key && !site.key.isEmpty) || ($0.entityName == site.name && !site.name.isEmpty))
        }
        guard !alreadyRecorded else { return }
        aggregationSnapshot.origins.append(ConfigEntityOrigin(
            entityType: .site,
            entityKey: site.key,
            entityName: site.name,
            sourceURL: sourceURL,
            originalKey: site.key,
            action: action
        ))
    }

    private func recordURLNormalizationIfChanged(site: Site, field: String, original: String, normalized: String, baseURL: String) {
        guard original != normalized else { return }
        aggregationSnapshot.normalizationEvents.append(ConfigNormalizationEvent(
            kind: .urlNormalized,
            entityType: .site,
            entityKey: site.key,
            field: field,
            originalValue: original,
            normalizedValue: normalized,
            reason: "按配置地址补全相对资源路径",
            sourceURL: baseURL
        ))
    }

    private func uniqueSitesWithDiagnostics(_ sites: [Site], sourceURL: String) -> [Site] {
        var seen = Set<String>()
        var result: [Site] = []
        for site in sites {
            guard !site.key.isEmpty else { continue }
            if seen.insert(site.key).inserted {
                result.append(site)
            } else {
                aggregationSnapshot.normalizationEvents.append(ConfigNormalizationEvent(
                    kind: .duplicateRemoved,
                    entityType: .site,
                    entityKey: site.key,
                    field: "sites",
                    originalValue: site.name,
                    normalizedValue: "",
                    reason: "站点 key 重复，保留首次出现的配置",
                    sourceURL: sourceURL
                ))
            }
        }
        return result
    }

    private func applySiteHygieneRules(_ sites: [Site], sourceURL: String) -> [Site] {
        guard let rules = hygieneStore?.loadRules(), !rules.isEmpty else { return sites }
        let filtered = SourceHygienePolicy.filterSites(sites, rules: rules)
        recordHygieneDecisions(filtered.decisions, sourceURL: sourceURL)
        return filtered.items
    }

    private func applyParseHygieneRules(_ parses: [Parse], sourceURL: String) -> [Parse] {
        guard let rules = hygieneStore?.loadRules(), !rules.isEmpty else { return parses }
        let filtered = SourceHygienePolicy.filterParses(parses, rules: rules)
        recordHygieneDecisions(filtered.decisions, sourceURL: sourceURL)
        return filtered.items
    }

    private func recordHygieneDecisions(_ decisions: [SourceHygieneDecision], sourceURL: String) {
        for decision in decisions {
            aggregationSnapshot.hygieneDecisions.append(decision)
            aggregationSnapshot.normalizationEvents.append(ConfigNormalizationEvent(
                kind: .blockedByUser,
                entityType: decision.entityType,
                entityKey: decision.entityKey,
                field: decision.kind.rawValue,
                originalValue: decision.value,
                normalizedValue: "",
                reason: decision.reason,
                sourceURL: sourceURL
            ))
        }
    }

    private func recordCredentialRequirements(for site: Site) {
        for requirement in Self.credentialRequirements(for: site) {
            guard !aggregationSnapshot.credentialRequirements.contains(requirement) else { continue }
            aggregationSnapshot.credentialRequirements.append(requirement)
            aggregationSnapshot.normalizationEvents.append(ConfigNormalizationEvent(
                kind: .credentialRequired,
                entityType: .site,
                entityKey: site.key,
                field: "credential",
                originalValue: requirement.provider,
                normalizedValue: "",
                reason: requirement.reason,
                sourceURL: aggregationSnapshot.rootURL
            ))
        }
    }

    private func recordCredentialRiskAssessment(for site: Site) {
        let assessment = CredentialRiskAssessment.assess(site: site)
        guard !aggregationSnapshot.credentialRiskAssessments.contains(assessment) else { return }
        aggregationSnapshot.credentialRiskAssessments.append(assessment)
        guard assessment.riskLevel != .safe else { return }
        aggregationSnapshot.normalizationEvents.append(ConfigNormalizationEvent(
            kind: .credentialRiskDetected,
            entityType: .site,
            entityKey: site.key,
            field: "ext",
            originalValue: assessment.redactedEvidence,
            normalizedValue: "",
            reason: assessment.reason,
            sourceURL: aggregationSnapshot.rootURL
        ))
    }

    private func recordResourceDiagnostics() {
        let diagnostics = ExternalResourceDiagnosticCollector.collect(
            spider: spider,
            sites: sites,
            parses: parses.filter { !$0.url.isEmpty }
        )
        aggregationSnapshot.resourceDiagnostics = diagnostics
        for diagnostic in diagnostics {
            aggregationSnapshot.normalizationEvents.append(ConfigNormalizationEvent(
                kind: .resourceDiagnosticRecorded,
                entityType: diagnostic.ownerType,
                entityKey: diagnostic.ownerKey,
                field: diagnostic.field,
                originalValue: diagnostic.url,
                normalizedValue: diagnostic.status.rawValue,
                reason: diagnostic.reason,
                sourceURL: aggregationSnapshot.rootURL
            ))
        }
    }

    private func recordAndroidRuntimeDiagnosticIfNeeded(for site: Site, sourceURL: String) {
        guard site.isAndroidCrawlerSource else { return }
        let lowerAPI = site.api.lowercased()
        let knownNativeNames = [
            "woggguard", "wogg", "alist", "webdav", "bili", "bilibili", "push",
            "mydriveguard", "seedhubguard", "s_zpsguard", "bttwooguard", "jpjguard",
            "newczguard", "doudouguard", "t4guard", "appttguard", "jpysguard"
        ]
        guard !knownNativeNames.contains(where: { lowerAPI.contains($0) }) else { return }
        aggregationSnapshot.normalizationEvents.append(ConfigNormalizationEvent(
            kind: .androidRuntimeUnsupported,
            entityType: .site,
            entityKey: site.key,
            field: "api",
            originalValue: site.api,
            normalizedValue: "",
            reason: "Android csp_ Jar/Dex/so 运行时不在 macOS 执行；需要抓包后 Swift 原生重写",
            sourceURL: sourceURL
        ))
    }

    private static func credentialRequirements(for site: Site) -> [ConfigCredentialRequirement] {
        let haystack = [
            site.key,
            site.name,
            site.api,
            site.ext
        ].joined(separator: " ").lowercased()

        var requirements: [ConfigCredentialRequirement] = []
        func append(_ provider: String, _ reason: String) {
            let requirement = ConfigCredentialRequirement(
                provider: provider,
                siteKey: site.key,
                siteName: site.name,
                reason: reason
            )
            if !requirements.contains(requirement) {
                requirements.append(requirement)
            }
        }

        if haystack.contains("quark") || haystack.contains("夸克") {
            append("quark", "夸克分享/个人盘播放需要 Cookie 或扫码 Token")
        }
        if haystack.contains("drive.uc.cn") || haystack.contains("ucshare") || haystack.contains("uc网盘") || haystack.contains("uc ") {
            append("uc", "UC 分享/个人盘播放需要 Cookie 或扫码 Token")
        }
        if haystack.contains("aliyundrive") || haystack.contains("alipan") || haystack.contains("alishare") || haystack.contains("阿里") {
            append("ali", "阿里云盘播放需要 refresh/access/open token")
        }
        if haystack.contains("115") || haystack.contains("p115") {
            append("p115", "115 网盘播放需要 Cookie 或 Open API access token")
        }
        if haystack.contains("pikpak") || haystack.contains("mypikpak") {
            append("pikpak", "PikPak 个人文件播放需要 access/refresh token")
        }
        return requirements
    }
}

/// 配置错误
public enum ConfigError: Error, LocalizedError {
    case invalidJSON
    case configMessage(String)
    case isDepot([Depot])
    case emptyConfig

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "无效的配置 JSON"
        case .configMessage(let msg): return msg
        case .isDepot: return "配置为仓库类型，需用户选择"
        case .emptyConfig: return "配置为空"
        }
    }
}
