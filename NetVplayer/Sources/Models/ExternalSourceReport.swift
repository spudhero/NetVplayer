// Models/ExternalSourceReport.swift
// External TVBox/FongMi configuration compatibility report.

import Foundation

public enum ExternalSourceSupportStatus: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case native
    case nativePartial = "native-partial"
    case js
    case cms
    case pendingGuardCapture = "pending-guard-capture"
    case upstreamUnavailable = "upstream-unavailable"
    case invalidConfiguration = "invalid-configuration"
    case unsupportedAndroidCsp = "unsupported-android-csp"
    case unsupportedBinary = "unsupported-binary"

    public var isNativeReplacement: Bool {
        self == .native || self == .nativePartial
    }
}

public struct ExternalSourceReport: Codable, Sendable, Equatable, Identifiable {
    public var configLocation: String
    public var siteKey: String
    public var siteName: String
    public var api: String
    public var status: ExternalSourceSupportStatus
    public var reason: String
    public var suggestion: String
    public var sourceURL: String
    public var origin: ConfigEntityOrigin?
    public var normalizationEvents: [ConfigNormalizationEvent]
    public var deduplicationReason: String
    public var cleanupReason: String
    public var androidRuntimeDiagnostic: String
    public var credentialRequirements: [ConfigCredentialRequirement]
    public var hygieneDecision: SourceHygieneDecision?
    public var credentialRisk: CredentialRiskAssessment?
    public var resourceDiagnostics: [ExternalResourceDiagnostic]

    public var id: String {
        [configLocation, siteKey, api].joined(separator: "::")
    }

    public init(
        configLocation: String = "",
        siteKey: String,
        siteName: String,
        api: String,
        status: ExternalSourceSupportStatus,
        reason: String = "",
        suggestion: String = "",
        sourceURL: String = "",
        origin: ConfigEntityOrigin? = nil,
        normalizationEvents: [ConfigNormalizationEvent] = [],
        deduplicationReason: String = "",
        cleanupReason: String = "",
        androidRuntimeDiagnostic: String = "",
        credentialRequirements: [ConfigCredentialRequirement] = [],
        hygieneDecision: SourceHygieneDecision? = nil,
        credentialRisk: CredentialRiskAssessment? = nil,
        resourceDiagnostics: [ExternalResourceDiagnostic] = []
    ) {
        self.configLocation = configLocation
        self.siteKey = siteKey
        self.siteName = siteName
        self.api = api
        self.status = status
        self.reason = reason
        self.suggestion = suggestion
        self.sourceURL = sourceURL
        self.origin = origin
        self.normalizationEvents = normalizationEvents
        self.deduplicationReason = deduplicationReason
        self.cleanupReason = cleanupReason
        self.androidRuntimeDiagnostic = androidRuntimeDiagnostic
        self.credentialRequirements = credentialRequirements
        self.hygieneDecision = hygieneDecision
        self.credentialRisk = credentialRisk
        self.resourceDiagnostics = resourceDiagnostics
    }

    enum CodingKeys: String, CodingKey {
        case configLocation, siteKey, siteName, api, status, reason, suggestion
        case sourceURL, origin, normalizationEvents, deduplicationReason, cleanupReason
        case androidRuntimeDiagnostic, credentialRequirements, hygieneDecision, credentialRisk
        case resourceDiagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.configLocation = try container.decodeIfPresent(String.self, forKey: .configLocation) ?? ""
        self.siteKey = try container.decodeIfPresent(String.self, forKey: .siteKey) ?? ""
        self.siteName = try container.decodeIfPresent(String.self, forKey: .siteName) ?? ""
        self.api = try container.decodeIfPresent(String.self, forKey: .api) ?? ""
        self.status = try container.decodeIfPresent(ExternalSourceSupportStatus.self, forKey: .status) ?? .cms
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        self.suggestion = try container.decodeIfPresent(String.self, forKey: .suggestion) ?? ""
        self.sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        self.origin = try container.decodeIfPresent(ConfigEntityOrigin.self, forKey: .origin)
        self.normalizationEvents = try container.decodeIfPresent([ConfigNormalizationEvent].self, forKey: .normalizationEvents) ?? []
        self.deduplicationReason = try container.decodeIfPresent(String.self, forKey: .deduplicationReason) ?? ""
        self.cleanupReason = try container.decodeIfPresent(String.self, forKey: .cleanupReason) ?? ""
        self.androidRuntimeDiagnostic = try container.decodeIfPresent(String.self, forKey: .androidRuntimeDiagnostic) ?? ""
        self.credentialRequirements = try container.decodeIfPresent([ConfigCredentialRequirement].self, forKey: .credentialRequirements) ?? []
        self.hygieneDecision = try container.decodeIfPresent(SourceHygieneDecision.self, forKey: .hygieneDecision)
        self.credentialRisk = try container.decodeIfPresent(CredentialRiskAssessment.self, forKey: .credentialRisk)
        self.resourceDiagnostics = try container.decodeIfPresent([ExternalResourceDiagnostic].self, forKey: .resourceDiagnostics) ?? []
    }
}

public enum ExternalSourceCompatibilityAuditor {
    private static let nativeCSPNames: Set<String> = [
        "alist",
        "webdav",
        "bili",
        "bilibili",
        "bilibililive",
        "push",
        "pushshare",
        "alishare",
        "alips",
        "p115share",
        "115share",
        "quarkshare",
        "ucshare",
        "wogg",
        "woggguard",
        "mogg",
        "wobg",
        "mydriveguard",
        "seedhubguard",
        "s_zpsguard",
        "bttwooguard",
        "jpjguard",
        "jianpian",
        "newczguard",
        "firstaidguard",
        "anime1guard",
        "dm84guard",
        "dm84",
        "aueteguard",
        "libvioguard",
        "hmysguard",
        "hmys",
        "nmyswvguard",
        "doubaoguard",
        "ycyzguard",
        "tingshu275guard",
        "appgzguard",
        "hbguazi",
        "hbtiantianv3",
        "hbtiantian",
        "musicguard",
        "allliveguard",
        "kanqiuguard",
        "kanqiu",
        "livegzguard",
        "sixvguard",
        "xb6v",
        "ygpguard",
        "ypansoguard",
        "bpansoguard",
        "uussguard",
        "kkssguard",
        "biliguard",
        "pushguard",
        "douban",
        "doubanguard",
        "doudouguard",
        "hbpianku8",
        "hbcms10",
        "hbpq",
        "wcai",
        "hbwwgg",
        "hbtangdou",
        "duboku"
    ]

    private static let nativeKeyedCSPNames: Set<String> = [
        "点我切源::doudouguard",
        "奶酪::t4guard",
        "光影::t4guard",
        "热播::appttguard",
        "文采::jpysguard",
        "视界::app99guard",
        "柠檬::nmvod",
        "播客::appsxguard",
        "剧圈::appsxguard",
        "咕咕::appsxguard"
    ]

    private static let homepageOnlyKeyedCSPNames: Set<String> = []

    private static let searchOnlyCSPNames: Set<String> = []

    private static let pendingGuardCaptureCSPNames: Set<String> = []

    private static let upstreamUnavailableCSPNames: Set<String> = []

    private static let invalidConfigurationCSPNames: Set<String> = [
        "xpathguard"
    ]

    private static let binaryOrAccountHeavyCSPNames: Set<String> = [
        "pikpakshare",
        "thundershare",
        "youtube",
        "sambashare",
        "samba",
        "tgyunpan",
        "tgyunpanlocal"
    ]

    public static func reports(
        configLocation: String = "",
        sites: [Site],
        snapshot: ConfigAggregationSnapshot? = nil
    ) -> [ExternalSourceReport] {
        sites.map { report(configLocation: configLocation, site: $0, snapshot: snapshot) }
    }

    public static func report(
        configLocation: String = "",
        site: Site,
        snapshot: ConfigAggregationSnapshot? = nil
    ) -> ExternalSourceReport {
        let api = site.api.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAPI = normalizedCrawlerName(api)
        let status: ExternalSourceSupportStatus
        let reason: String
        let suggestion: String

        if site.isAndroidCrawlerSource {
            let keyedName = "\(site.key)::\(normalizedAPI)"
            if nativeCSPNames.contains(normalizedAPI) || nativeKeyedCSPNames.contains(keyedName) {
                if homepageOnlyKeyedCSPNames.contains(keyedName) {
                    status = .nativePartial
                    reason = "已注册 macOS Swift 首页/频道 provider，详情播放待继续抓包"
                    suggestion = "当前可切源并加载首页/频道；详情和播放需后续按抓包补齐"
                } else if searchOnlyCSPNames.contains(normalizedAPI) {
                    status = .nativePartial
                    reason = "已注册 macOS Swift 网盘搜索 provider；搜索结果可进入现有网盘展开链路"
                    switch normalizedAPI {
                    case "bpansoguard":
                        suggestion = "百度分享暂未适配目录展开时明确不可播，不伪装媒体直链"
                    default:
                        suggestion = "夸克分享复用 DriveShareExpander 展开详情与播放"
                    }
                } else {
                    status = .native
                    reason = "已注册 macOS Swift SiteContentProvider 替代实现"
                    suggestion = "通过 SpiderReplacementRegistry 注册 Swift provider"
                }
            } else if invalidConfigurationCSPNames.contains(normalizedAPI) {
                status = .invalidConfiguration
                reason = "当前远端站点仅声明 csp_XPathGuard，未提供 ext/XPath 规则；连续两版顶层 JAR 均缺少 XPathGuard 类"
                suggestion = "从远端配置移除该占位项，或同时补齐可加载实现与完整 XPath 规则后再评估原生迁移"
            } else if upstreamUnavailableCSPNames.contains(normalizedAPI) {
                status = .upstreamUnavailable
                reason = "Fongmi 5.5.6 在两个 fresh process 中均由上游首页解析抛出相同异常，且没有缓存目录"
                suggestion = "等待原站或 Guard 上游恢复；不运行 Android Jar/Dex/so，也不伪造可播放状态"
            } else if pendingGuardCaptureCSPNames.contains(normalizedAPI) {
                status = .pendingGuardCapture
                reason = "已确认 Android Guard 空壳委托 BaseSpiderGuard 和 Android .so，待动态抓包复刻"
                suggestion = "需要 home/category/detail/search/player 输入输出和 HTTP trace fixture 后再接 Swift 原生 provider"
            } else if binaryOrAccountHeavyCSPNames.contains(normalizedAPI) {
                status = .unsupportedBinary
                reason = "依赖账号、Android Jar/so 或外部代理组件，第一阶段不打包"
                suggestion = "后续按单个网盘/服务独立评估 Swift 原生实现"
            } else {
                status = .unsupportedAndroidCsp
                reason = "Android csp_ Jar/Dex 爬虫源，macOS 不运行 DexClassLoader"
                suggestion = "切换 JS/CMS 源，或为该 api 新增原生替代 provider"
            }
        } else if site.isSpider || api.lowercased().contains(".js") || api.lowercased().contains("drpy") {
            status = .js
            reason = "JS/drpy 爬虫源，可由 JavaScriptCore 运行时尝试加载"
            suggestion = "若失败，补齐 JS 宿主 API 或 drpy 模板兼容层"
        } else {
            status = .cms
            reason = "CMS/XPath/HTTP API 源，可通过现有 SiteApi 直接请求"
            suggestion = "按 ConfigEngine/SiteApi 现有合同解析"
        }

        let siteOrigin = snapshot?.origins.first {
            $0.entityType == .site && ($0.entityKey == site.key || $0.entityName == site.name)
        }
        let siteEvents = snapshot?.normalizationEvents.filter {
            $0.entityType == .site && ($0.entityKey == site.key || $0.entityKey == site.name)
        } ?? []
        let credentialRequirements = snapshot?.credentialRequirements.filter {
            $0.siteKey == site.key || $0.siteName == site.name
        } ?? []
        let hygieneDecision = snapshot?.hygieneDecisions.first {
            $0.entityType == .site && ($0.entityKey == site.key || $0.entityName == site.name)
        }
        let credentialRisk = snapshot?.credentialRiskAssessments.first {
            $0.siteKey == site.key || $0.siteName == site.name
        }
        let resourceDiagnostics = snapshot?.resourceDiagnostics.filter {
            $0.ownerType == .site && ($0.ownerKey == site.key || $0.ownerName == site.name)
        } ?? []
        let deduplicationReason = siteEvents.first(where: { $0.kind == .duplicateRemoved })?.reason ?? ""
        let cleanupReason = siteEvents.first(where: { $0.kind == .externalArrayFailed })?.reason ?? ""
        let androidRuntimeDiagnostic = siteEvents.first(where: { $0.kind == .androidRuntimeUnsupported })?.reason
            ?? (site.isAndroidCrawlerSource
                && !status.isNativeReplacement
                && status != .upstreamUnavailable
                && status != .invalidConfiguration
                ? "Android Jar/Dex/so 运行时不在 macOS 执行，仅保留兼容诊断"
                : "")

        return ExternalSourceReport(
            configLocation: configLocation,
            siteKey: site.key,
            siteName: site.name,
            api: site.api,
            status: status,
            reason: reason,
            suggestion: suggestion,
            sourceURL: siteOrigin?.sourceURL ?? configLocation,
            origin: siteOrigin,
            normalizationEvents: siteEvents,
            deduplicationReason: deduplicationReason,
            cleanupReason: cleanupReason,
            androidRuntimeDiagnostic: androidRuntimeDiagnostic,
            credentialRequirements: credentialRequirements,
            hygieneDecision: hygieneDecision,
            credentialRisk: credentialRisk,
            resourceDiagnostics: resourceDiagnostics
        )
    }

    private static func normalizedCrawlerName(_ api: String) -> String {
        var value = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("csp_") {
            value.removeFirst("csp_".count)
        }
        if value.hasSuffix("()") {
            value.removeLast(2)
        }
        return value
    }
}
