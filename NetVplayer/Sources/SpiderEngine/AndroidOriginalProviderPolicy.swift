import Foundation
import Models
import ProviderSDK

/// The original route is selected from the source configuration, never from a
/// native-provider registration or its business-specific allowlist.
public enum AndroidOriginalProviderPolicy {
    public static func applies(to site: Site) -> Bool {
        site.isSpider && !site.api.hasPrefix("netvplayer-")
    }

    static func className(for site: Site) -> String? {
        guard applies(to: site) else { return nil }
        // FongMi x9 selects Python before JavaScript using the configured API.
        if site.api.contains(".py") { return nil }
        if site.api.contains(".js") { return "com.fongmi.quickjs.crawler.Spider" }
        let value = site.api.hasPrefix("csp_")
            ? "com.github.catvod.spider." + String(site.api.dropFirst(4))
            : site.api
        guard value.range(of: "\\A([A-Za-z_$][A-Za-z0-9_$]*\\.)+[A-Za-z_$][A-Za-z0-9_$]*\\z", options: .regularExpression) != nil else { return nil }
        return value
    }

    public static func registerUnavailable(
        sites: [Site], reason: AndroidOriginalUnavailableReason,
        registry: SpiderReplacementRegistry = .shared
    ) async {
        for site in sites where applies(to: site) {
            await registry.register(originalKey: site.key, originalAPI: site.api,
                provider: AndroidOriginalUnavailableProvider(reason: reason))
        }
    }
}

public enum AndroidOriginalUnavailableReason: String, Sendable {
    case runtimeUnavailable
    case runtimeInvalid
    case unsupportedSourceAPI
    case missingProviderArtifact

    var error: ProviderErrorPayload {
        let message: String
        switch self {
        case .runtimeUnavailable: message = L10n.text("请先在设置中安装 Android 原版运行组件。")
        case .runtimeInvalid: message = L10n.text("Android 原版运行组件校验失败，请重新安装或回滚组件。")
        case .unsupportedSourceAPI: message = L10n.text("此入口的原版脚本或加载接口尚未接入通用运行环境。")
        case .missingProviderArtifact: message = L10n.text("此 Android 入口未提供原始 JAR，请检查配置中的 spider 或 jar。")
        }
        return ProviderErrorPayload(code: "android_original_" + rawValue, message: message)
    }
}

struct AndroidOriginalUnavailableProvider: SiteContentProvider {
    let reason: AndroidOriginalUnavailableReason
    func homeContent(site: Site) async throws -> Result { throw reason.error }
    func homeVideoContent(site: Site) async throws -> Result? { throw reason.error }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result { throw reason.error }
    func detailContent(site: Site, id: String) async throws -> Result { throw reason.error }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result { throw reason.error }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { throw reason.error }
    func action(site: Site, action: String, value: String) async throws { throw reason.error }
}
