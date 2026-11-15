import DriveEngine
import Foundation
import Models

/// The original directory keeps its IDs and ordering; media resolution runs in
/// the signed native extension after validating an existing host drive account.
struct AndroidCatalogPlaybackProvider: SiteContentProvider, SiteContentCacheClearing {
    let catalog: any SiteContentProvider
    let nativePlayer: RemoteSiteContentProvider?
    let authorization: HostDriveAccountAuthorization
    let rule: AndroidCompatibilityPolicy.NativePlaybackRule

    func homeContent(site: Site) async throws -> Result { try await catalog.homeContent(site: site) }
    func homeVideoContent(site: Site) async throws -> Result? { try await catalog.homeVideoContent(site: site) }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result {
        try await catalog.categoryContent(site: site, tid: tid, page: page, filter: filter, extend: extend)
    }
    func detailContent(site: Site, id: String) async throws -> Result { try await catalog.detailContent(site: site, id: id) }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        try await catalog.searchContent(site: site, keyword: keyword, quick: quick, page: page)
    }
    func action(site: Site, action: String, value: String) async throws {
        try await catalog.action(site: site, action: action, value: value)
    }

    func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        guard rule.accepts(flag: flag, id: id) else {
            throw SpiderEngineError.nativeReplacementUnsupported(site: site.api, capability: "播放标识无效，请重新打开剧集")
        }
        guard let nativePlayer, nativePlayer.providerID == rule.providerID,
              await nativePlayer.manager.activeManifests().contains(where: {
                  $0.manifest.providerID == nativePlayer.providerID
                    && $0.manifest.version.compare(rule.minimumVersion, options: .numeric) != .orderedAscending
              }) else {
            throw SpiderEngineError.nativeReplacementUnsupported(site: site.api, capability: "请安装 \(rule.minimumVersion) 或更新的目录扩展")
        }
        try await authorization.validate()
        try Task.checkCancellation()
        return try await nativePlayer.playerContent(site: site, flag: flag, id: id)
    }

    func clearContentCache() async {
        await (catalog as? any SiteContentCacheClearing)?.clearContentCache()
        await nativePlayer?.clearContentCache()
    }
}

struct HostDriveAccountAuthorization: Sendable {
    typealias Validator = @Sendable (CloudCredential) async throws -> CloudCredential
    let credentialProvider: (@Sendable (DriveProvider) async -> String?)?
    let drives: [DriveProvider]
    var validator: Validator = Self.validateAccount

    func validate() async throws {
        var lastError: (any Error)?
        for drive in drives {
            try Task.checkCancellation()
            guard let cookie = await credentialProvider?(drive)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cookie.isEmpty else { continue }
            let original = CloudCredential.cookie(provider: drive, value: cookie)
            let refresh = CloudDirectoryCredentialRefresh(original: original)
            do {
                let validated = try await validator(original)
                try Task.checkCancellation()
                // A concurrent account switch must not authorize this request.
                guard await credentialProvider?(drive)?.trimmingCharacters(in: .whitespacesAndNewlines) == cookie else {
                    throw CancellationError()
                }
                refresh?.save(validated)
                return
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        if let lastError { throw lastError }
        throw DriveEngineError.loginRequired(drives.first ?? .quark)
    }

    private static func validateAccount(_ credential: CloudCredential) async throws -> CloudCredential {
        switch credential.provider {
        case .quark: return try await QuarkCookieDriver().validate(credential, reference: nil)
        case .uc: return try await UCCookieDriver().validate(credential, reference: nil)
        case .baidu: return try await BaiduDriveClient().validate(credential)
        default: throw DriveEngineError.loginRequired(credential.provider)
        }
    }
}
