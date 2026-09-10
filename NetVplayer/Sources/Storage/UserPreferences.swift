// Storage/UserPreferences.swift
// 用户偏好设置

import Foundation

/// 用户偏好设置，对应 FongMi: Setting.java / PlayerSetting.java
public final class UserPreferences: @unchecked Sendable {

    public static let shared = UserPreferences()
    public static let stableBundleIdentifier = "com.netvplayer.app"
    public static let legacyPreferenceDomains = [
        stableBundleIdentifier,
        "com.netvplayer.mac",
        "NetVplayerApp",
        "com.netvplayer.dev"
    ]
    private static let defaultSubtitleFontSize = 44

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    public func migrateLegacyPreferenceDomainsIfNeeded(
        from domainNames: [String] = UserPreferences.legacyPreferenceDomains
    ) -> Int {
        var migratedCount = 0

        for domainName in domainNames {
            guard let legacyDomain = defaults.persistentDomain(forName: domainName) else { continue }
            for key in legacyDomain.keys.sorted() {
                guard Self.shouldMigrateLegacyPreference(key: key),
                      defaults.object(forKey: key) == nil,
                      let value = legacyDomain[key] else { continue }
                defaults.set(value, forKey: key)
                migratedCount += 1
            }
        }

        return migratedCount
    }

    private static func shouldMigrateLegacyPreference(key: String) -> Bool {
        !key.hasPrefix("NS") && !key.hasPrefix("Apple")
    }

    // MARK: - 配置源

    public var currentVodConfigUrl: String {
        get { defaults.string(forKey: "currentVodConfigUrl") ?? "" }
        set { defaults.set(newValue, forKey: "currentVodConfigUrl") }
    }

    public var currentVodSiteKey: String {
        get { defaults.string(forKey: "currentVodSiteKey") ?? "" }
        set { defaults.set(newValue, forKey: "currentVodSiteKey") }
    }

    public var currentLiveConfigUrl: String {
        get { defaults.string(forKey: "currentLiveConfigUrl") ?? "" }
        set { defaults.set(newValue, forKey: "currentLiveConfigUrl") }
    }

    public var currentLiveName: String {
        get { defaults.string(forKey: "currentLiveName") ?? "" }
        set { defaults.set(newValue, forKey: "currentLiveName") }
    }

    public var currentLiveGroupName: String {
        get { defaults.string(forKey: "currentLiveGroupName") ?? "" }
        set { defaults.set(newValue, forKey: "currentLiveGroupName") }
    }

    public var currentLiveChannelName: String {
        get { defaults.string(forKey: "currentLiveChannelName") ?? "" }
        set { defaults.set(newValue, forKey: "currentLiveChannelName") }
    }

    public var currentLiveChannelUrlIndex: Int {
        get { defaults.integer(forKey: "currentLiveChannelUrlIndex") }
        set { defaults.set(newValue, forKey: "currentLiveChannelUrlIndex") }
    }

    public var defaultSearchSiteKeys: [String] {
        get { defaults.stringArray(forKey: "defaultSearchSiteKeys") ?? [] }
        set { defaults.set(newValue, forKey: "defaultSearchSiteKeys") }
    }

    public var siteHealthSortingEnabled: Bool {
        get {
            if defaults.object(forKey: "siteHealthSortingEnabled") == nil { return true }
            return defaults.bool(forKey: "siteHealthSortingEnabled")
        }
        set { defaults.set(newValue, forKey: "siteHealthSortingEnabled") }
    }

    public var chunkedRangeRelayEnabled: Bool {
        get { defaults.bool(forKey: "chunkedRangeRelayEnabled") }
        set { defaults.set(newValue, forKey: "chunkedRangeRelayEnabled") }
    }

    public var webHomeEnabled: Bool {
        get { defaults.bool(forKey: "webHomeEnabled") }
        set { defaults.set(newValue, forKey: "webHomeEnabled") }
    }

    public var webHomeURL: String {
        get { defaults.string(forKey: "webHomeURL") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "webHomeURL") }
    }

    public var speedDirectEasterEggEnabled: Bool {
        get { defaults.bool(forKey: "speedDirectEasterEggEnabled") }
        set { defaults.set(newValue, forKey: "speedDirectEasterEggEnabled") }
    }

    // MARK: - 外观

    public var appearanceThemeID: String? {
        get { defaults.string(forKey: "appearanceThemeID") }
        set {
            if let newValue {
                defaults.set(newValue, forKey: "appearanceThemeID")
            } else {
                defaults.removeObject(forKey: "appearanceThemeID")
            }
        }
    }

    // MARK: - 网盘源授权

    public var quarkCookie: String {
        get { defaults.string(forKey: "quarkCookie") ?? "" }
        set { defaults.set(newValue, forKey: "quarkCookie") }
    }

    public var ucCookie: String {
        get { defaults.string(forKey: "ucCookie") ?? "" }
        set { defaults.set(newValue, forKey: "ucCookie") }
    }

    public var baiduCookie: String {
        get { defaults.string(forKey: "baiduCookie") ?? "" }
        set { defaults.set(newValue, forKey: "baiduCookie") }
    }

    public var aliRefreshToken: String {
        get { defaults.string(forKey: "aliRefreshToken") ?? "" }
        set { defaults.set(newValue, forKey: "aliRefreshToken") }
    }

    public var aliAccessToken: String {
        get { defaults.string(forKey: "aliAccessToken") ?? "" }
        set { defaults.set(newValue, forKey: "aliAccessToken") }
    }

    public var aliOpenToken: String {
        get { defaults.string(forKey: "aliOpenToken") ?? "" }
        set { defaults.set(newValue, forKey: "aliOpenToken") }
    }

    public var aliDefaultDriveID: String {
        get { defaults.string(forKey: "aliDefaultDriveID") ?? "" }
        set { defaults.set(newValue, forKey: "aliDefaultDriveID") }
    }

    public var aliAuthDomain: String {
        get { defaults.string(forKey: "aliAuthDomain") ?? "" }
        set { defaults.set(newValue, forKey: "aliAuthDomain") }
    }

    public var aliUserID: String {
        get { defaults.string(forKey: "aliUserID") ?? "" }
        set { defaults.set(newValue, forKey: "aliUserID") }
    }

    public var p115Cookie: String {
        get { defaults.string(forKey: "p115Cookie") ?? "" }
        set { defaults.set(newValue, forKey: "p115Cookie") }
    }

    public var p115AccessToken: String {
        get { defaults.string(forKey: "p115AccessToken") ?? "" }
        set { defaults.set(newValue, forKey: "p115AccessToken") }
    }

    public var pikpakAccessToken: String {
        get { defaults.string(forKey: "pikpakAccessToken") ?? "" }
        set { defaults.set(newValue, forKey: "pikpakAccessToken") }
    }

    public var pikpakRefreshToken: String {
        get { defaults.string(forKey: "pikpakRefreshToken") ?? "" }
        set { defaults.set(newValue, forKey: "pikpakRefreshToken") }
    }

    public var pikpakDeviceID: String {
        get { defaults.string(forKey: "pikpakDeviceID") ?? "" }
        set { defaults.set(newValue, forKey: "pikpakDeviceID") }
    }

    public var quarkTVDeviceID: String {
        get { defaults.string(forKey: "quarkTVDeviceID") ?? "" }
        set { defaults.set(newValue, forKey: "quarkTVDeviceID") }
    }

    public var quarkTVQueryToken: String {
        get { defaults.string(forKey: "quarkTVQueryToken") ?? "" }
        set { defaults.set(newValue, forKey: "quarkTVQueryToken") }
    }

    public var quarkTVRefreshToken: String {
        get { defaults.string(forKey: "quarkTVRefreshToken") ?? "" }
        set { defaults.set(newValue, forKey: "quarkTVRefreshToken") }
    }

    public var quarkTVAccessToken: String {
        get { defaults.string(forKey: "quarkTVAccessToken") ?? "" }
        set { defaults.set(newValue, forKey: "quarkTVAccessToken") }
    }

    public var ucTVDeviceID: String {
        get { defaults.string(forKey: "ucTVDeviceID") ?? "" }
        set { defaults.set(newValue, forKey: "ucTVDeviceID") }
    }

    public var ucTVQueryToken: String {
        get { defaults.string(forKey: "ucTVQueryToken") ?? "" }
        set { defaults.set(newValue, forKey: "ucTVQueryToken") }
    }

    public var ucTVRefreshToken: String {
        get { defaults.string(forKey: "ucTVRefreshToken") ?? "" }
        set { defaults.set(newValue, forKey: "ucTVRefreshToken") }
    }

    public var ucTVAccessToken: String {
        get { defaults.string(forKey: "ucTVAccessToken") ?? "" }
        set { defaults.set(newValue, forKey: "ucTVAccessToken") }
    }

    public var ucOriginalPlaybackToken: String {
        get { defaults.string(forKey: "ucOriginalPlaybackToken") ?? "" }
        set { defaults.set(newValue, forKey: "ucOriginalPlaybackToken") }
    }

    public var ucFongMiAccountToken: String {
        get { defaults.string(forKey: "ucFongMiAccountToken") ?? "" }
        set { defaults.set(newValue, forKey: "ucFongMiAccountToken") }
    }

    public var ucFongMiPlaybackToken: String {
        get { defaults.string(forKey: "ucFongMiPlaybackToken") ?? "" }
        set { defaults.set(newValue, forKey: "ucFongMiPlaybackToken") }
    }

    public var ucFongMiAccountExpiresAt: String {
        get { defaults.string(forKey: "ucFongMiAccountExpiresAt") ?? "" }
        set { defaults.set(newValue, forKey: "ucFongMiAccountExpiresAt") }
    }

    public var ucFongMiPlaybackExpiresAt: String {
        get { defaults.string(forKey: "ucFongMiPlaybackExpiresAt") ?? "" }
        set { defaults.set(newValue, forKey: "ucFongMiPlaybackExpiresAt") }
    }

    public var ucFongMiFixtureID: String {
        get { defaults.string(forKey: "ucFongMiFixtureID") ?? "" }
        set { defaults.set(newValue, forKey: "ucFongMiFixtureID") }
    }

    public var ucFongMiEvidenceStatus: String {
        get { defaults.string(forKey: "ucFongMiEvidenceStatus") ?? "" }
        set { defaults.set(newValue, forKey: "ucFongMiEvidenceStatus") }
    }

    public var quarkAutoDeleteSavedFiles: Bool {
        get { cloudDriveAutoDeleteSavedFiles(providerID: "quark") }
        set { setCloudDriveAutoDeleteSavedFiles(newValue, providerID: "quark") }
    }

    public func cloudDriveAutoDeleteSavedFiles(providerID: String) -> Bool {
        defaults.bool(forKey: "\(providerID)AutoDeleteSavedFiles")
    }

    public func setCloudDriveAutoDeleteSavedFiles(_ enabled: Bool, providerID: String) {
        defaults.set(enabled, forKey: "\(providerID)AutoDeleteSavedFiles")
    }

    // MARK: - 播放设置

    public var defaultDecodeMode: Int {
        get { defaults.integer(forKey: "defaultDecodeMode") }  // 0=自动, 1=硬解, 2=软解
        set { defaults.set(newValue, forKey: "defaultDecodeMode") }
    }

    public var defaultPlaybackSpeed: Float {
        get { defaults.float(forKey: "defaultPlaybackSpeed").isZero ? 1.0 : defaults.float(forKey: "defaultPlaybackSpeed") }
        set { defaults.set(newValue, forKey: "defaultPlaybackSpeed") }
    }

    public var defaultOpeningSkip: Int {
        get { defaults.integer(forKey: "defaultOpeningSkip") }
        set { defaults.set(newValue, forKey: "defaultOpeningSkip") }
    }

    public var defaultEndingSkip: Int {
        get { defaults.integer(forKey: "defaultEndingSkip") }
        set { defaults.set(newValue, forKey: "defaultEndingSkip") }
    }

    public var subtitleFontSize: Int {
        get {
            let value = defaults.integer(forKey: "subtitleFontSize")
            return value == 0 ? Self.defaultSubtitleFontSize : min(max(value, 16), 72)
        }
        set {
            defaults.set(min(max(newValue, 16), 72), forKey: "subtitleFontSize")
            defaults.set(true, forKey: "subtitlePreferencesTouched")
        }
    }

    public var subtitlePosition: Int {
        get {
            let value = defaults.integer(forKey: "subtitlePosition")
            return value == 0 ? 95 : min(max(value, 0), 100)
        }
        set { defaults.set(min(max(newValue, 0), 100), forKey: "subtitlePosition") }
    }

    public var subtitleOverrideSourceStyle: Bool {
        get {
            guard defaults.object(forKey: "subtitleOverrideSourceStyle") != nil else { return true }
            return defaults.bool(forKey: "subtitleOverrideSourceStyle")
        }
        set { defaults.set(newValue, forKey: "subtitleOverrideSourceStyle") }
    }

    public var danmakuEnabled: Bool {
        get { defaults.bool(forKey: "danmakuEnabled") }
        set { defaults.set(newValue, forKey: "danmakuEnabled") }
    }

    public var danmakuOpacity: Double {
        get {
            let value = defaults.double(forKey: "danmakuOpacity")
            return value == 0 ? 0.8 : min(1, max(0, value))
        }
        set { defaults.set(min(1, max(0, newValue)), forKey: "danmakuOpacity") }
    }

    public var danmakuFontSize: Int {
        get {
            let value = defaults.integer(forKey: "danmakuFontSize")
            return value == 0 ? 36 : min(max(value, 18), 72)
        }
        set { defaults.set(min(max(newValue, 18), 72), forKey: "danmakuFontSize") }
    }

    public var danmakuOffsetMs: Int {
        get { defaults.integer(forKey: "danmakuOffsetMs") }
        set { defaults.set(min(max(newValue, -120_000), 120_000), forKey: "danmakuOffsetMs") }
    }

    public func migrateSubtitleDefaultsIfNeeded() {
        if defaults.object(forKey: "subtitleFontSize") != nil,
           defaults.integer(forKey: "subtitleFontSize") == 30,
           defaults.bool(forKey: "subtitleReadableDefaultMigrationV2") == false {
            defaults.set(Self.defaultSubtitleFontSize, forKey: "subtitleFontSize")
            defaults.set(true, forKey: "subtitleReadableDefaultMigrationV2")
            return
        }

        guard defaults.object(forKey: "subtitleFontSize") != nil,
              defaults.bool(forKey: "subtitlePreferencesTouched") == false else { return }
        let legacyDefault = defaults.integer(forKey: "subtitleFontSize")
        guard legacyDefault == 36 else { return }
        defaults.set(Self.defaultSubtitleFontSize, forKey: "subtitleFontSize")
    }

    public func resetSubtitlePreferences() {
        subtitleFontSize = Self.defaultSubtitleFontSize
        subtitlePosition = 95
        subtitleOverrideSourceStyle = true
    }

    // MARK: - 网络代理设置

    public var proxyMode: Int { // 0=自动探测, 1=直连模式, 2=自定义代理
        get { defaults.integer(forKey: "networkProxyMode") }
        set { defaults.set(newValue, forKey: "networkProxyMode") }
    }

    public var customProxyServer: String {
        get { defaults.string(forKey: "customProxyServer") ?? "127.0.0.1" }
        set { defaults.set(newValue, forKey: "customProxyServer") }
    }

    public var customProxyPort: Int {
        get { defaults.integer(forKey: "customProxyPort") == 0 ? 7897 : defaults.integer(forKey: "customProxyPort") }
        set { defaults.set(newValue, forKey: "customProxyPort") }
    }
}
