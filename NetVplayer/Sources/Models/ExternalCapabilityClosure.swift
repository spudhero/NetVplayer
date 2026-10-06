// Models/ExternalCapabilityClosure.swift
// Default-build closure catalog for external-reference migration work.

import Foundation

public enum ExternalCapabilityArea: String, Codable, Sendable, CaseIterable {
    case referenceFixtureCorpus
    case jsGuardNativeRewrite
    case iBoxVideoSourceNativeRewrite
    case publicDriveSharePlayback
    case ucHighBitratePlayback
    case playerTrackListEnumeration
    case proxyDeepRelay
    case liveDeepEPG
    case tvbusP2P
    case webHomeRemotePage
    case danmakuNetworkSource
    case playbackProgressSync
    case uiVisualRegression
    case errorLayering
}

public enum ExternalCapabilityClosureStatus: String, Codable, Sendable, CaseIterable {
    case implementedOffline = "implemented-offline"
    case defaultOff = "default-off"
    case externalEvidenceRequired = "external-evidence-required"
    case unsupportedRuntime = "unsupported-runtime"
}

public struct ExternalCapabilityClosure: Codable, Sendable, Equatable, Identifiable {
    public var area: ExternalCapabilityArea
    public var status: ExternalCapabilityClosureStatus
    public var title: String
    public var safeDefault: String
    public var requiredEvidence: [String]
    public var registersPlaybackCapability: Bool

    public var id: String { area.rawValue }

    public init(
        area: ExternalCapabilityArea,
        status: ExternalCapabilityClosureStatus,
        title: String,
        safeDefault: String,
        requiredEvidence: [String] = [],
        registersPlaybackCapability: Bool = false
    ) {
        self.area = area
        self.status = status
        self.title = title
        self.safeDefault = safeDefault
        self.requiredEvidence = requiredEvidence
        self.registersPlaybackCapability = registersPlaybackCapability
    }

    public var requiresExternalEvidence: Bool {
        status == .externalEvidenceRequired || !requiredEvidence.isEmpty
    }

    public var isClosedForDefaultBuild: Bool {
        !safeDefault.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!requiresExternalEvidence || !registersPlaybackCapability)
    }
}

public enum ExternalCapabilityClosureCatalog {
    public static let defaultClosures: [ExternalCapabilityClosure] = [
        ExternalCapabilityClosure(
            area: .referenceFixtureCorpus,
            status: .implementedOffline,
            title: L10n.text("外部参考 fixture 语料库"),
            safeDefault: L10n.text("默认测试只读取脱敏离线样本，不触发真实网络。")
        ),
        ExternalCapabilityClosure(
            area: .jsGuardNativeRewrite,
            status: .externalEvidenceRequired,
            title: L10n.text("Spider / JS / Guard 原生化"),
            safeDefault: L10n.text("pending/captured Guard 样本只展示诊断，不注册播放 provider。"),
            requiredEvidence: ["CatVod home/category/detail/search/player I/O", "HTTP trace", L10n.text("JS 宿主缺口清单")]
        ),
        ExternalCapabilityClosure(
            area: .iBoxVideoSourceNativeRewrite,
            status: .externalEvidenceRequired,
            title: L10n.text("iBox 视频源爬虫原生化"),
            safeDefault: L10n.text("默认只启用离线 fixture 与显式 iBox-like API key；未脱敏抓包的站点不注册为可播 provider。"),
            requiredEvidence: [L10n.text("api_246.json 脱敏配置样本"), L10n.text("脱敏 home/category/detail/search/player HTTP trace"), L10n.text("VIP parse URL/header 样本")],
            registersPlaybackCapability: false
        ),
        ExternalCapabilityClosure(
            area: .publicDriveSharePlayback,
            status: .externalEvidenceRequired,
            title: L10n.text("网盘公开分享消费接口"),
            safeDefault: L10n.text("PikPak/Baidu/123/Thunder 未验证公开分享保持待抓包，不进入播放链路。"),
            requiredEvidence: [L10n.text("读取接口样本"), L10n.text("转存或播放接口样本"), L10n.text("授权失败样本")]
        ),
        ExternalCapabilityClosure(
            area: .ucHighBitratePlayback,
            status: .externalEvidenceRequired,
            title: L10n.text("UC 高码率候选选择"),
            safeDefault: L10n.text("已记录候选选择诊断，未经真实样本验证不硬编码新接口。"),
            requiredEvidence: [L10n.text("dfi/resolution/accessable/right/memberRight 候选响应"), L10n.text("fallback 路线样本")]
        ),
        ExternalCapabilityClosure(
            area: .playerTrackListEnumeration,
            status: .implementedOffline,
            title: L10n.text("播放器 track-list 深枚举合同"),
            safeDefault: L10n.text("已提供 mpv track-list JSON 解析合同，运行时 shim 未接入时继续使用日志解析 fallback。")
        ),
        ExternalCapabilityClosure(
            area: .proxyDeepRelay,
            status: .defaultOff,
            title: L10n.text("Proxy 深层 relay 能力"),
            safeDefault: L10n.text("Chunked Range Relay 默认关闭，multipart/长连接样本不足时保持现有 /stream 行为。")
        ),
        ExternalCapabilityClosure(
            area: .liveDeepEPG,
            status: .defaultOff,
            title: L10n.text("直播 XMLTV/回看深能力"),
            safeDefault: L10n.text("EPG 失败不阻塞播放，复杂 catchup 和 TVBus/P2P 只显示边界。")
        ),
        ExternalCapabilityClosure(
            area: .tvbusP2P,
            status: .unsupportedRuntime,
            title: L10n.text("TVBus/P2P 二进制运行时"),
            safeDefault: L10n.text("不引入第三方二进制运行时，源显示不可用边界。")
        ),
        ExternalCapabilityClosure(
            area: .webHomeRemotePage,
            status: .defaultOff,
            title: L10n.text("WebHome 真实页面生态"),
            safeDefault: L10n.text("默认关闭；远程 URL 必须通过 ProxyAccessPolicy，bridge 不返回凭据或播放 URL。")
        ),
        ExternalCapabilityClosure(
            area: .danmakuNetworkSource,
            status: .defaultOff,
            title: L10n.text("真实网络弹幕源"),
            safeDefault: L10n.text("只允许手动触发和缓存回放，默认不请求外部 API。")
        ),
        ExternalCapabilityClosure(
            area: .playbackProgressSync,
            status: .implementedOffline,
            title: L10n.text("播放进度同步合同"),
            safeDefault: L10n.text("导入导出只保存 stable episode key / drive reference，不保存临时播放 URL。")
        ),
        ExternalCapabilityClosure(
            area: .uiVisualRegression,
            status: .implementedOffline,
            title: L10n.text("UI 视觉回归入口"),
            safeDefault: L10n.text("用可复现 view state 列出核心截图场景，后续可接真实截图流水线。")
        ),
        ExternalCapabilityClosure(
            area: .errorLayering,
            status: .implementedOffline,
            title: L10n.text("错误分层展示"),
            safeDefault: L10n.text("Config/Spider/Proxy/Parse/Source/Live/Player/UI 均有可读建议动作。")
        )
    ]

    public static func defaultBuildOpenItems(
        in closures: [ExternalCapabilityClosure] = defaultClosures
    ) -> [ExternalCapabilityClosure] {
        closures.filter { !$0.isClosedForDefaultBuild }
    }

    public static func externalEvidenceItems(
        in closures: [ExternalCapabilityClosure] = defaultClosures
    ) -> [ExternalCapabilityClosure] {
        closures.filter(\.requiresExternalEvidence)
    }
}
