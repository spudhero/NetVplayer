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

    public var userFacingTitle: String {
        switch self {
        case .native: return "已兼容"
        case .nativePartial: return "部分可用"
        case .js: return "脚本型来源"
        case .cms: return "标准内容接口"
        case .pendingGuardCapture: return "正在适配"
        case .upstreamUnavailable: return "源站暂不可用"
        case .invalidConfiguration: return "配置不完整"
        case .unsupportedAndroidCsp: return "暂不支持"
        case .unsupportedBinary: return "需要额外组件"
        }
    }

    public var userFacingDetail: String {
        switch self {
        case .native:
            return "已提供当前系统可用的兼容实现，实际可用性仍取决于源站和网络。"
        case .nativePartial:
            return "该来源只有部分功能可用，详情请查看兼容状态。"
        case .js, .cms:
            return "该来源可直接尝试加载。"
        case .pendingGuardCapture:
            return "该来源仍在适配中，请先选择其他视频源。"
        case .upstreamUnavailable:
            return "源站当前无法返回内容，请稍后重试或选择其他视频源。"
        case .invalidConfiguration:
            return "该来源缺少必要配置，暂时无法加载。"
        case .unsupportedAndroidCsp, .unsupportedBinary:
            return "该来源使用的格式或组件当前无法加载，请选择其他视频源。"
        }
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
        self.credentialRequirements = credentialRequirements
        self.hygieneDecision = hygieneDecision
        self.credentialRisk = credentialRisk
        self.resourceDiagnostics = resourceDiagnostics
    }

    enum CodingKeys: String, CodingKey {
        case configLocation, siteKey, siteName, api, status, reason, suggestion
        case sourceURL, origin, normalizationEvents, deduplicationReason, cleanupReason
        case credentialRequirements, hygieneDecision, credentialRisk
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
                    reason = "首页和频道可用，详情与播放尚未适配"
                    suggestion = "可先浏览首页和频道；播放时请选择完整可用的视频源"
                } else if searchOnlyCSPNames.contains(normalizedAPI) {
                    status = .nativePartial
                    reason = "目前仅支持网盘搜索，搜索结果可继续展开"
                    switch normalizedAPI {
                    case "bpansoguard":
                        suggestion = "百度分享目录暂未适配，无法播放时请更换来源"
                    default:
                        suggestion = "可在搜索页查找内容，并从结果中进入详情和播放"
                    }
                } else {
                    status = .native
                    reason = "已提供当前系统可用的兼容实现"
                    suggestion = "可直接使用；若加载失败，请检查网络或切换视频源"
                }
            } else if invalidConfigurationCSPNames.contains(normalizedAPI) {
                status = .invalidConfiguration
                reason = "该来源缺少加载内容所需的规则"
                suggestion = "请让配置维护者补充完整信息，或从配置中移除此来源"
            } else if upstreamUnavailableCSPNames.contains(normalizedAPI) {
                status = .upstreamUnavailable
                reason = "源站当前无法返回首页内容"
                suggestion = "请稍后重试，或先切换其他视频源"
            } else if pendingGuardCaptureCSPNames.contains(normalizedAPI) {
                status = .pendingGuardCapture
                reason = "该来源尚未完成适配"
                suggestion = "请先切换其他视频源，等待后续版本支持"
            } else if binaryOrAccountHeavyCSPNames.contains(normalizedAPI) {
                status = .unsupportedBinary
                reason = "该来源需要当前版本未包含的额外组件或账号能力"
                suggestion = "请切换其他视频源，或使用已支持的网盘授权方式"
            } else {
                status = .unsupportedAndroidCsp
                reason = "该来源使用的格式当前无法加载"
                suggestion = "请切换其他视频源"
            }
        } else if site.isSpider || api.lowercased().contains(".js") || api.lowercased().contains("drpy") {
            status = .js
            reason = "脚本型视频源，将在本机受控环境中尝试加载"
            suggestion = "若加载失败，请稍后重试或切换其他视频源"
        } else {
            status = .cms
            reason = "标准内容接口，可直接尝试加载"
            suggestion = "若加载失败，请检查网络或切换其他视频源"
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
