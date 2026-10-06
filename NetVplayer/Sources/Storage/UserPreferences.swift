// Storage/UserPreferences.swift
// 用户偏好设置

import Foundation
import Models

public enum CachedCredentialAvailability: Sendable, Equatable {
    case available
    case unavailable
    case unknown
}

/// 用户偏好设置，对应 FongMi: Setting.java / PlayerSetting.java
public final class UserPreferences: @unchecked Sendable {

    public static let shared = UserPreferences(credentialStore:
        TestRuntime.isRunning
            ? MemoryCredentialStore()
            : LocalCredentialStore(legacyReader: LegacyKeychainCredentialReader()))
    public static let credentialsDidChange = Notification.Name("NetVplayer.credentialsDidChange")
    public static let stableBundleIdentifier = "com.netvplayer.app"
    public static let legacyPreferenceDomains = [
        stableBundleIdentifier,
        "com.netvplayer.mac",
        "NetVplayerApp",
        "com.netvplayer.dev"
    ]
    private static let defaultSubtitleFontSize = 44

    private let defaults: UserDefaults
    private let subtitleLock = NSRecursiveLock()

    private let credentialStore: any CredentialStore
    private let credentialLock = NSRecursiveLock()
    private var credentialCache: [String: String] = [:]
    private var pendingCredentials: [String: String] = [:]
    private var credentialErrors: [String: Error] = [:]
    private var credentialRevision: UInt64 = 0

    /// Session-only identity for caches; never exposes or persists credential material.
    public var searchCredentialRevision: UInt64 {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        return credentialRevision
    }

    public init(defaults: UserDefaults = .standard, credentialStore: any CredentialStore = MemoryCredentialStore()) {
        self.defaults = defaults
        self.credentialStore = credentialStore
    }

    /// Returns only in-memory or legacy state and never waits for the backing credential store.
    public func cachedCredentialAvailability(_ key: String) -> CachedCredentialAvailability {
        guard credentialLock.try() else { return .unknown }
        defer { credentialLock.unlock() }

        let value: String?
        if let pending = pendingCredentials[key] {
            value = pending
        } else if let cached = credentialCache[key] {
            value = cached
        } else if !defaults.bool(forKey: "credentialMigrated." + key) {
            value = defaults.string(forKey: key)
        } else {
            value = nil
        }

        guard let value else { return .unknown }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unavailable : .available
    }

    public func credential(_ key: String) -> String {
        var shouldNotify = false
        credentialLock.lock()
        defer {
            credentialLock.unlock()
            if shouldNotify {
                NotificationCenter.default.post(name: Self.credentialsDidChange, object: nil)
            }
        }
        if let pending = pendingCredentials[key] { return pending }
        if let cached = credentialCache[key] { return cached }
        do {
            // A retained legacy value means migration was not committed. Retry it
            // before trusting an unverified write left by an interrupted process.
            if !defaults.bool(forKey: "credentialMigrated." + key),
               let legacy = defaults.string(forKey: key), !legacy.isEmpty {
                try saveCredential(legacy, for: key)
                return legacy
            }
            if let saved = try credentialStore.read(key) {
                credentialCache[key] = saved
                defaults.removeObject(forKey: key)
                defaults.set(true, forKey: "credentialMigrated." + key)
                shouldNotify = credentialErrors.removeValue(forKey: key) != nil
                return saved
            }
            credentialCache[key] = ""
            shouldNotify = credentialErrors.removeValue(forKey: key) != nil
            return ""
        } catch {
            credentialErrors[key] = error
            shouldNotify = true
            return credentialCache[key] ?? defaults.string(forKey: key) ?? ""
        }
    }

    /// A failed write remains in memory for this session; no new plaintext is persisted.
    public func saveCredential(_ value: String, for key: String) throws {
        credentialLock.lock()
        credentialRevision &+= 1
        defer {
            credentialLock.unlock()
            NotificationCenter.default.post(name: Self.credentialsDidChange, object: nil)
        }
        do {
            if value.isEmpty { try credentialStore.remove(key) }
            else {
                try credentialStore.write(value, for: key)
                guard try credentialStore.read(key) == value else { throw CredentialStoreError.verificationFailed }
            }
            credentialCache[key] = value
            pendingCredentials.removeValue(forKey: key)
            credentialErrors.removeValue(forKey: key)
            defaults.removeObject(forKey: key)
            for domainName in defaults.stringArray(forKey: "credentialLegacyDomains." + key) ?? [] {
                if var domain = defaults.persistentDomain(forName: domainName) {
                    domain.removeValue(forKey: key)
                    defaults.setPersistentDomain(domain, forName: domainName)
                }
            }
            defaults.removeObject(forKey: "credentialLegacyDomains." + key)
            defaults.set(true, forKey: "credentialMigrated." + key)
        } catch {
            pendingCredentials[key] = value
            credentialErrors[key] = error
            throw error
        }
    }

    public func retryCredentialPersistence() throws {
        credentialLock.lock(); defer { credentialLock.unlock() }
        for (key, value) in pendingCredentials { try saveCredential(value, for: key) }
        let retryKeys = Set(credentialErrors.keys).union(Self.sensitiveCredentialKeys.filter { defaults.string(forKey: $0) != nil })
        for key in retryKeys { _ = credential(key) }
        try checkCredentialPersistence()
    }

    public func checkCredentialPersistence() throws {
        credentialLock.lock(); defer { credentialLock.unlock() }
        if let error = credentialErrors.sorted(by: { $0.key < $1.key }).first?.value { throw error }
    }

    /// A feature checks its own account without inheriting another provider's failure.
    public func checkCredentialPersistence(for key: String) throws {
        credentialLock.lock(); defer { credentialLock.unlock() }
        if let error = credentialErrors[key] { throw error }
    }

    public static let sensitiveCredentialKeys: Set<String> = [
        "quarkCookie", "ucCookie", "baiduCookie", "aliRefreshToken", "aliAccessToken", "aliOpenToken",
        "p115Cookie", "p115AccessToken", "pikpakAccessToken", "pikpakRefreshToken",
        "quarkTVQueryToken", "quarkTVRefreshToken", "quarkTVAccessToken",
        "ucTVQueryToken", "ucTVRefreshToken", "ucTVAccessToken", "ucOriginalPlaybackToken",
        "ucFongMiAccountToken", "ucFongMiPlaybackToken"
    ]

    @discardableResult
    public func migrateLegacyPreferenceDomainsIfNeeded(
        from domainNames: [String] = UserPreferences.legacyPreferenceDomains
    ) -> Int {
        var migratedCount = 0

        for domainName in domainNames {
            guard let legacyDomain = defaults.persistentDomain(forName: domainName) else { continue }
            for key in legacyDomain.keys.sorted() {
                if Self.sensitiveCredentialKeys.contains(key) {
                    if defaults.bool(forKey: "credentialMigrated." + key) {
                        var cleaned = defaults.persistentDomain(forName: domainName) ?? [:]
                        cleaned.removeValue(forKey: key)
                        defaults.setPersistentDomain(cleaned, forName: domainName)
                        continue
                    }
                    var domains = defaults.stringArray(forKey: "credentialLegacyDomains." + key) ?? []
                    if !domains.contains(domainName) { domains.append(domainName) }
                    defaults.set(domains, forKey: "credentialLegacyDomains." + key)
                }
                guard Self.shouldMigrateLegacyPreference(key: key),
                      !defaults.bool(forKey: "credentialMigrated." + key),
                      defaults.object(forKey: key) == nil,
                      let value = legacyDomain[key] else { continue }
                defaults.set(value, forKey: key)
                if Self.sensitiveCredentialKeys.contains(key) {
                    var domains = defaults.stringArray(forKey: "credentialLegacyDomains." + key) ?? []
                    if !domains.contains(domainName) { domains.append(domainName) }
                    defaults.set(domains, forKey: "credentialLegacyDomains." + key)
                }
                migratedCount += 1
            }
        }

        return migratedCount
    }

    private static func shouldMigrateLegacyPreference(key: String) -> Bool {
        !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !key.hasPrefix("credentialMigrated.") && !key.hasPrefix("credentialLegacyDomains.")
    }

    public var xtreamConfigurations: [XtreamConfiguration] {
        get {
            guard let data = defaults.data(forKey: "xtreamConfigurations.v1") else { return [] }
            return ((try? JSONDecoder().decode([XtreamConfiguration].self, from: data)) ?? []).compactMap { try? $0.validated() }
        }
        set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "xtreamConfigurations.v1") } }
    }

    private struct StoredXtreamCredentials: Codable {
        let server: String
        let credentials: XtreamCredentials
    }

    public func xtreamCredentials(for id: UUID, server: String? = nil) throws -> XtreamCredentials {
        let value = credential("xtream." + id.uuidString.lowercased())
        let expected = server ?? xtreamConfigurations.first(where: { $0.id == id })?.server
        guard let expected, !value.isEmpty, let data = value.data(using: .utf8),
              let record = try? JSONDecoder().decode(StoredXtreamCredentials.self, from: data),
              record.server == expected else { throw XtreamError.authorizationRequired }
        return record.credentials
    }

    public func saveXtreamCredentials(_ credentials: XtreamCredentials, for id: UUID, server: String? = nil) throws {
        guard !credentials.username.isEmpty, !credentials.password.isEmpty else { throw XtreamError.authorizationRequired }
        guard let endpoint = server ?? xtreamConfigurations.first(where: { $0.id == id })?.server else { throw XtreamError.invalidServer }
        let record = StoredXtreamCredentials(server: endpoint, credentials: credentials)
        try saveCredential(String(decoding: JSONEncoder().encode(record), as: UTF8.self), for: "xtream." + id.uuidString.lowercased())
    }

    // MARK: - 配置源

    public var currentVodConfigUrl: String {
        get { defaults.string(forKey: "currentVodConfigUrl") ?? "" }
        set { defaults.set(newValue, forKey: "currentVodConfigUrl") }
    }

    public var providerRuntimeInitialInstallCompleted: Bool {
        get { defaults.bool(forKey: "providerRuntimeInitialInstallCompleted") }
        set { defaults.set(newValue, forKey: "providerRuntimeInitialInstallCompleted") }
    }

    public var providerRuntimeInitialInstallRecorded: Bool {
        defaults.object(forKey: "providerRuntimeInitialInstallCompleted") != nil
    }

    public var providerRuntimePendingVersions: [String: String] {
        get { defaults.dictionary(forKey: "providerRuntimePendingVersions") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "providerRuntimePendingVersions") }
    }

    public var providerRuntimeInstalledVersions: [String: String] {
        get { defaults.dictionary(forKey: "providerRuntimeInstalledVersions") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "providerRuntimeInstalledVersions") }
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
        get { credential("quarkCookie") }
        set { try? saveCredential(newValue, for: "quarkCookie") }
    }

    public var ucCookie: String {
        get { credential("ucCookie") }
        set { try? saveCredential(newValue, for: "ucCookie") }
    }

    public var baiduCookie: String {
        get { credential("baiduCookie") }
        set { try? saveCredential(newValue, for: "baiduCookie") }
    }

    public var aliRefreshToken: String {
        get { credential("aliRefreshToken") }
        set { try? saveCredential(newValue, for: "aliRefreshToken") }
    }

    public var aliAccessToken: String {
        get { credential("aliAccessToken") }
        set { try? saveCredential(newValue, for: "aliAccessToken") }
    }

    public var aliOpenToken: String {
        get { credential("aliOpenToken") }
        set { try? saveCredential(newValue, for: "aliOpenToken") }
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
        get { credential("p115Cookie") }
        set { try? saveCredential(newValue, for: "p115Cookie") }
    }

    public var p115AccessToken: String {
        get { credential("p115AccessToken") }
        set { try? saveCredential(newValue, for: "p115AccessToken") }
    }

    public var pikpakAccessToken: String {
        get { credential("pikpakAccessToken") }
        set { try? saveCredential(newValue, for: "pikpakAccessToken") }
    }

    public var pikpakRefreshToken: String {
        get { credential("pikpakRefreshToken") }
        set { try? saveCredential(newValue, for: "pikpakRefreshToken") }
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
        get { credential("quarkTVQueryToken") }
        set { try? saveCredential(newValue, for: "quarkTVQueryToken") }
    }

    public var quarkTVRefreshToken: String {
        get { credential("quarkTVRefreshToken") }
        set { try? saveCredential(newValue, for: "quarkTVRefreshToken") }
    }

    public var quarkTVAccessToken: String {
        get { credential("quarkTVAccessToken") }
        set { try? saveCredential(newValue, for: "quarkTVAccessToken") }
    }

    public var ucTVDeviceID: String {
        get { defaults.string(forKey: "ucTVDeviceID") ?? "" }
        set { defaults.set(newValue, forKey: "ucTVDeviceID") }
    }

    public var ucTVQueryToken: String {
        get { credential("ucTVQueryToken") }
        set { try? saveCredential(newValue, for: "ucTVQueryToken") }
    }

    public var ucTVRefreshToken: String {
        get { credential("ucTVRefreshToken") }
        set { try? saveCredential(newValue, for: "ucTVRefreshToken") }
    }

    public var ucTVAccessToken: String {
        get { credential("ucTVAccessToken") }
        set { try? saveCredential(newValue, for: "ucTVAccessToken") }
    }

    public var ucOriginalPlaybackToken: String {
        get { credential("ucOriginalPlaybackToken") }
        set { try? saveCredential(newValue, for: "ucOriginalPlaybackToken") }
    }

    public var ucFongMiAccountToken: String {
        get { credential("ucFongMiAccountToken") }
        set { try? saveCredential(newValue, for: "ucFongMiAccountToken") }
    }

    public var ucFongMiPlaybackToken: String {
        get { credential("ucFongMiPlaybackToken") }
        set { try? saveCredential(newValue, for: "ucFongMiPlaybackToken") }
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
            guard defaults.object(forKey: "subtitlePosition") != nil else { return 95 }
            return min(max(defaults.integer(forKey: "subtitlePosition"), 0), 100)
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

    public var onlineSubtitleSearchEnabled: Bool {
        get { defaults.bool(forKey: "onlineSubtitleSearchEnabled") }
        set { defaults.set(newValue, forKey: "onlineSubtitleSearchEnabled") }
    }

    public var subtitleAppearance: SubtitleAppearance {
        get {
            guard let data = defaults.data(forKey: "subtitleAppearance.v1"), data.count <= 4096,
                  let value = try? JSONDecoder().decode(SubtitleAppearance.self, from: data) else { return .init() }
            return value
        }
        set { if let data = try? JSONEncoder().encode(newValue.normalized) { defaults.set(data, forKey: "subtitleAppearance.v1") } }
    }

    public var subtitleDelayRecords: [SubtitleDelayRecord] {
        get {
            subtitleLock.lock(); defer { subtitleLock.unlock() }
            guard let data = defaults.data(forKey: "subtitleDelays.v1"), data.count <= 256 * 1024,
                  let records = try? JSONDecoder().decode([SubtitleDelayRecord].self, from: data) else { return [] }
            return SubtitleDelayRecord.sanitized(records)
        }
        set {
            subtitleLock.lock(); defer { subtitleLock.unlock() }
            if let data = try? JSONEncoder().encode(SubtitleDelayRecord.sanitized(newValue)) {
                defaults.set(data, forKey: "subtitleDelays.v1")
            }
        }
    }

    public func subtitleDelay(for spec: PlaySpec, secondary: Bool = false) -> Double {
        guard let key = SubtitleMediaIdentity.key(for: spec) else { return 0 }
        let record = subtitleDelayRecords.last { $0.key == key }
        return (secondary ? record?.secondarySeconds : record?.seconds) ?? 0
    }

    public func saveSubtitleDelay(_ seconds: Double, for spec: PlaySpec, secondary: Bool = false) {
        guard let key = SubtitleMediaIdentity.key(for: spec) else { return }
        subtitleLock.lock(); defer { subtitleLock.unlock() }
        var record = subtitleDelayRecords.last { $0.key == key } ?? SubtitleDelayRecord(key: key, seconds: 0)
        if secondary { record.secondarySeconds = SubtitleMediaIdentity.normalizedDelay(seconds) }
        else { record.seconds = SubtitleMediaIdentity.normalizedDelay(seconds) }
        var records = subtitleDelayRecords.filter { $0.key != key }
        records.append(record)
        subtitleDelayRecords = records
    }

    public func resetSubtitlePreferences() {
        subtitleFontSize = Self.defaultSubtitleFontSize
        subtitlePosition = 95
        subtitleOverrideSourceStyle = true
        subtitleAppearance = .init()
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
