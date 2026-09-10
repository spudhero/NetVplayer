// Storage/StorageBackup.swift
// 备份包模型，覆盖配置、历史、收藏和非敏感偏好。

import Foundation
import CryptoKit
import Models

public struct StorageBackup: Codable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var configs: [Config]
    public var history: [History]
    public var keeps: [Keep]
    public var tracks: [Track]
    public var preferences: UserPreferenceSnapshot?

    public init(
        schemaVersion: Int = 1,
        exportedAt: Date = Date(),
        configs: [Config] = [],
        history: [History] = [],
        keeps: [Keep] = [],
        tracks: [Track] = [],
        preferences: UserPreferenceSnapshot? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.configs = configs
        self.history = history
        self.keeps = keeps
        self.tracks = tracks
        self.preferences = preferences
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, exportedAt, configs, history, keeps, tracks, preferences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        self.configs = try container.decodeIfPresent([Config].self, forKey: .configs) ?? []
        self.history = try container.decodeIfPresent([History].self, forKey: .history) ?? []
        self.keeps = try container.decodeIfPresent([Keep].self, forKey: .keeps) ?? []
        self.tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        self.preferences = try container.decodeIfPresent(UserPreferenceSnapshot.self, forKey: .preferences)
    }
}

public struct StorageBackupEnvelope: Codable, Sendable {
    public var format: String
    public var schemaVersion: Int
    public var createdAt: Date
    public var payload: Data
    public var payloadSHA256: String

    public init(
        format: String,
        schemaVersion: Int,
        createdAt: Date,
        payload: Data,
        payloadSHA256: String
    ) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.payload = payload
        self.payloadSHA256 = payloadSHA256
    }
}

public struct StorageBackupPreview: Equatable, Sendable {
    public var exportedAt: Date
    public var configCount: Int
    public var historyCount: Int
    public var keepCount: Int
    public var trackCount: Int
    public var includesPreferences: Bool
    public var isLegacy: Bool
}

public enum StorageBackupCodec {
    public static let formatIdentifier = "netvplayer-portable-backup"
    public static let currentEnvelopeVersion = 1
    public static let maximumArchiveByteCount = 32 * 1_024 * 1_024
    public static let maximumConfigCount = 1_000
    public static let maximumHistoryCount = 50_000
    public static let maximumKeepCount = 50_000
    public static let maximumTrackCount = 50_000

    public static func encode(_ backup: StorageBackup) throws -> Data {
        let payload = try validatedPayload(backup, allowHistoryMigration: true)
        let payloadData = try encoder().encode(payload)
        let envelope = StorageBackupEnvelope(
            format: formatIdentifier,
            schemaVersion: currentEnvelopeVersion,
            createdAt: payload.exportedAt,
            payload: payloadData,
            payloadSHA256: sha256Hex(payloadData)
        )
        let data = try encoder().encode(envelope)
        guard data.count <= maximumArchiveByteCount else {
            throw StorageError.backupTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> (backup: StorageBackup, isLegacy: Bool) {
        guard !data.isEmpty else { throw StorageError.invalidBackup }
        guard data.count <= maximumArchiveByteCount else { throw StorageError.backupTooLarge }

        let header = try? decoder().decode(StorageBackupEnvelopeHeader.self, from: data)
        if let format = header?.format {
            guard format == formatIdentifier else { throw StorageError.invalidBackup }
            let envelope: StorageBackupEnvelope
            do {
                envelope = try decoder().decode(StorageBackupEnvelope.self, from: data)
            } catch {
                throw StorageError.invalidBackup
            }
            guard envelope.schemaVersion == currentEnvelopeVersion else {
                throw StorageError.unsupportedBackupVersion(envelope.schemaVersion)
            }
            guard sha256Hex(envelope.payload) == envelope.payloadSHA256 else {
                throw StorageError.backupChecksumMismatch
            }
            let payload: StorageBackup
            do {
                payload = try decoder().decode(StorageBackup.self, from: envelope.payload)
            } catch {
                throw StorageError.invalidBackup
            }
            let validated = try validatedPayload(payload, allowHistoryMigration: false)
            return (validated, false)
        }

        let legacy: StorageBackup
        do {
            legacy = try decoder().decode(StorageBackup.self, from: data)
        } catch {
            throw StorageError.invalidBackup
        }
        return (try validatedPayload(legacy, allowHistoryMigration: true), true)
    }

    public static func preview(_ data: Data) throws -> StorageBackupPreview {
        let decoded = try decode(data)
        return StorageBackupPreview(
            exportedAt: decoded.backup.exportedAt,
            configCount: decoded.backup.configs.count,
            historyCount: decoded.backup.history.count,
            keepCount: decoded.backup.keeps.count,
            trackCount: decoded.backup.tracks.count,
            includesPreferences: decoded.backup.preferences != nil,
            isLegacy: decoded.isLegacy
        )
    }

    public static func validatedPayload(
        _ backup: StorageBackup,
        allowHistoryMigration: Bool
    ) throws -> StorageBackup {
        guard backup.schemaVersion == 1 else {
            throw StorageError.unsupportedBackupVersion(backup.schemaVersion)
        }
        guard backup.configs.count <= maximumConfigCount,
              backup.history.count <= maximumHistoryCount,
              backup.keeps.count <= maximumKeepCount,
              backup.tracks.count <= maximumTrackCount else {
            throw StorageError.backupCollectionLimitExceeded
        }
        var result = backup
        result.history = backup.history.map(HistoryPersistencePolicy.sanitized)
        if !allowHistoryMigration, result.history != backup.history {
            throw StorageError.unsafeHistoryReference
        }
        let payloadData = try encoder().encode(result)
        guard payloadData.count <= maximumArchiveByteCount else {
            throw StorageError.backupTooLarge
        }
        return result
    }

    private struct StorageBackupEnvelopeHeader: Decodable {
        var format: String?
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public struct UserPreferenceSnapshot: Codable, Sendable {
    public var currentVodConfigUrl: String
    public var currentLiveConfigUrl: String
    public var currentLiveName: String
    public var currentLiveGroupName: String
    public var currentLiveChannelName: String
    public var currentLiveChannelUrlIndex: Int
    public var defaultDecodeMode: Int
    public var defaultPlaybackSpeed: Float
    public var defaultOpeningSkip: Int
    public var defaultEndingSkip: Int
    public var subtitleFontSize: Int
    public var subtitlePosition: Int
    public var subtitleOverrideSourceStyle: Bool
    public var proxyMode: Int
    public var customProxyServer: String
    public var customProxyPort: Int
    public var defaultSearchSiteKeys: [String]
    public var siteHealthSortingEnabled: Bool
    public var chunkedRangeRelayEnabled: Bool
    public var webHomeEnabled: Bool
    public var webHomeURL: String
    public var danmakuEnabled: Bool
    public var danmakuOpacity: Double
    public var danmakuFontSize: Int
    public var danmakuOffsetMs: Int
    public var appearanceThemeID: String?

    enum CodingKeys: String, CodingKey {
        case currentVodConfigUrl, currentLiveConfigUrl, currentLiveName, currentLiveGroupName
        case currentLiveChannelName, currentLiveChannelUrlIndex, defaultDecodeMode, defaultPlaybackSpeed
        case defaultOpeningSkip, defaultEndingSkip, subtitleFontSize, subtitlePosition
        case subtitleOverrideSourceStyle, proxyMode, customProxyServer, customProxyPort, defaultSearchSiteKeys
        case siteHealthSortingEnabled, chunkedRangeRelayEnabled, webHomeEnabled, webHomeURL
        case danmakuEnabled, danmakuOpacity, danmakuFontSize, danmakuOffsetMs
        case appearanceThemeID
    }

    public init(preferences: UserPreferences = .shared) {
        self.currentVodConfigUrl = preferences.currentVodConfigUrl
        self.currentLiveConfigUrl = preferences.currentLiveConfigUrl
        self.currentLiveName = preferences.currentLiveName
        self.currentLiveGroupName = preferences.currentLiveGroupName
        self.currentLiveChannelName = preferences.currentLiveChannelName
        self.currentLiveChannelUrlIndex = preferences.currentLiveChannelUrlIndex
        self.defaultDecodeMode = preferences.defaultDecodeMode
        self.defaultPlaybackSpeed = preferences.defaultPlaybackSpeed
        self.defaultOpeningSkip = preferences.defaultOpeningSkip
        self.defaultEndingSkip = preferences.defaultEndingSkip
        self.subtitleFontSize = preferences.subtitleFontSize
        self.subtitlePosition = preferences.subtitlePosition
        self.subtitleOverrideSourceStyle = preferences.subtitleOverrideSourceStyle
        self.proxyMode = preferences.proxyMode
        self.customProxyServer = preferences.customProxyServer
        self.customProxyPort = preferences.customProxyPort
        self.defaultSearchSiteKeys = preferences.defaultSearchSiteKeys
        self.siteHealthSortingEnabled = preferences.siteHealthSortingEnabled
        self.chunkedRangeRelayEnabled = preferences.chunkedRangeRelayEnabled
        self.webHomeEnabled = preferences.webHomeEnabled
        self.webHomeURL = preferences.webHomeURL
        self.danmakuEnabled = preferences.danmakuEnabled
        self.danmakuOpacity = preferences.danmakuOpacity
        self.danmakuFontSize = preferences.danmakuFontSize
        self.danmakuOffsetMs = preferences.danmakuOffsetMs
        self.appearanceThemeID = preferences.appearanceThemeID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currentVodConfigUrl = try container.decodeIfPresent(String.self, forKey: .currentVodConfigUrl) ?? ""
        self.currentLiveConfigUrl = try container.decodeIfPresent(String.self, forKey: .currentLiveConfigUrl) ?? ""
        self.currentLiveName = try container.decodeIfPresent(String.self, forKey: .currentLiveName) ?? ""
        self.currentLiveGroupName = try container.decodeIfPresent(String.self, forKey: .currentLiveGroupName) ?? ""
        self.currentLiveChannelName = try container.decodeIfPresent(String.self, forKey: .currentLiveChannelName) ?? ""
        self.currentLiveChannelUrlIndex = try container.decodeIfPresent(Int.self, forKey: .currentLiveChannelUrlIndex) ?? 0
        self.defaultDecodeMode = try container.decodeIfPresent(Int.self, forKey: .defaultDecodeMode) ?? 0
        self.defaultPlaybackSpeed = try container.decodeIfPresent(Float.self, forKey: .defaultPlaybackSpeed) ?? 1.0
        self.defaultOpeningSkip = try container.decodeIfPresent(Int.self, forKey: .defaultOpeningSkip) ?? 0
        self.defaultEndingSkip = try container.decodeIfPresent(Int.self, forKey: .defaultEndingSkip) ?? 0
        self.subtitleFontSize = try container.decodeIfPresent(Int.self, forKey: .subtitleFontSize) ?? 44
        self.subtitlePosition = try container.decodeIfPresent(Int.self, forKey: .subtitlePosition) ?? 95
        self.subtitleOverrideSourceStyle = try container.decodeIfPresent(Bool.self, forKey: .subtitleOverrideSourceStyle) ?? true
        self.proxyMode = try container.decodeIfPresent(Int.self, forKey: .proxyMode) ?? 0
        self.customProxyServer = try container.decodeIfPresent(String.self, forKey: .customProxyServer) ?? "127.0.0.1"
        self.customProxyPort = try container.decodeIfPresent(Int.self, forKey: .customProxyPort) ?? 7897
        self.defaultSearchSiteKeys = try container.decodeIfPresent([String].self, forKey: .defaultSearchSiteKeys) ?? []
        self.siteHealthSortingEnabled = try container.decodeIfPresent(Bool.self, forKey: .siteHealthSortingEnabled) ?? true
        self.chunkedRangeRelayEnabled = try container.decodeIfPresent(Bool.self, forKey: .chunkedRangeRelayEnabled) ?? false
        self.webHomeEnabled = try container.decodeIfPresent(Bool.self, forKey: .webHomeEnabled) ?? false
        self.webHomeURL = try container.decodeIfPresent(String.self, forKey: .webHomeURL) ?? ""
        self.danmakuEnabled = try container.decodeIfPresent(Bool.self, forKey: .danmakuEnabled) ?? false
        self.danmakuOpacity = min(1, max(0, try container.decodeIfPresent(Double.self, forKey: .danmakuOpacity) ?? 0.8))
        self.danmakuFontSize = min(72, max(18, try container.decodeIfPresent(Int.self, forKey: .danmakuFontSize) ?? 36))
        self.danmakuOffsetMs = min(120_000, max(-120_000, try container.decodeIfPresent(Int.self, forKey: .danmakuOffsetMs) ?? 0))
        self.appearanceThemeID = try container.decodeIfPresent(String.self, forKey: .appearanceThemeID)
    }

    public func apply(to preferences: UserPreferences = .shared) {
        preferences.currentVodConfigUrl = currentVodConfigUrl
        preferences.currentLiveConfigUrl = currentLiveConfigUrl
        preferences.currentLiveName = currentLiveName
        preferences.currentLiveGroupName = currentLiveGroupName
        preferences.currentLiveChannelName = currentLiveChannelName
        preferences.currentLiveChannelUrlIndex = currentLiveChannelUrlIndex
        preferences.defaultDecodeMode = defaultDecodeMode
        preferences.defaultPlaybackSpeed = defaultPlaybackSpeed
        preferences.defaultOpeningSkip = defaultOpeningSkip
        preferences.defaultEndingSkip = defaultEndingSkip
        preferences.subtitleFontSize = subtitleFontSize
        preferences.subtitlePosition = subtitlePosition
        preferences.subtitleOverrideSourceStyle = subtitleOverrideSourceStyle
        preferences.proxyMode = proxyMode
        preferences.customProxyServer = customProxyServer
        preferences.customProxyPort = customProxyPort
        preferences.defaultSearchSiteKeys = defaultSearchSiteKeys
        preferences.siteHealthSortingEnabled = siteHealthSortingEnabled
        preferences.chunkedRangeRelayEnabled = chunkedRangeRelayEnabled
        preferences.webHomeEnabled = webHomeEnabled
        preferences.webHomeURL = webHomeURL
        preferences.danmakuEnabled = danmakuEnabled
        preferences.danmakuOpacity = danmakuOpacity
        preferences.danmakuFontSize = danmakuFontSize
        preferences.danmakuOffsetMs = danmakuOffsetMs
        if let appearanceThemeID {
            preferences.appearanceThemeID = appearanceThemeID
        }
    }
}
