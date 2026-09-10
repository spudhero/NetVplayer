// Storage/StorageManager.swift
// 持久化管理器

import Foundation
import Models

/// 持久化管理器 — 使用 JSON 文件存储
/// 后续可替换为 SwiftData/Core Data 实现
public final class StorageManager: @unchecked Sendable {

    public static let shared = StorageManager()

    private let fileManager = FileManager.default
    private let storageDirectory: URL

    public init(storageDirectory: URL? = nil) {
        if let storageDirectory {
            self.storageDirectory = storageDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.storageDirectory = appSupport.appendingPathComponent("NetVplayer", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 通用存取

    public func save<T: Encodable>(_ object: T, to filename: String) throws {
        let url = storageDirectory.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(object)
        try data.write(to: url, options: .atomic)
    }

    public func load<T: Decodable>(_ type: T.Type, from filename: String) throws -> T {
        let url = storageDirectory.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    public func delete(_ filename: String) throws {
        let url = storageDirectory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - 业务方法

    public func saveConfigs(_ configs: [Config]) throws {
        try save(configs, to: "configs.json")
    }

    public func loadConfigs() -> [Config] {
        (try? load([Config].self, from: "configs.json")) ?? []
    }

    public func saveHistory(_ items: [History]) throws {
        try save(items.map(HistoryPersistencePolicy.sanitized), to: "history.json")
    }

    public func loadHistory() -> [History] {
        guard let stored = try? load([History].self, from: "history.json") else { return [] }
        let sanitized = stored.map(HistoryPersistencePolicy.sanitized)
        if sanitized != stored {
            try? save(sanitized, to: "history.json")
        }
        return sanitized
    }

    public func saveKeeps(_ items: [Keep]) throws {
        try save(items, to: "keeps.json")
    }

    public func loadKeeps() -> [Keep] {
        (try? load([Keep].self, from: "keeps.json")) ?? []
    }

    public func saveTracks(_ items: [Track]) throws {
        try save(items, to: "tracks.json")
    }

    public func loadTracks() -> [Track] {
        (try? load([Track].self, from: "tracks.json")) ?? []
    }

    // MARK: - 备份与还原

    public func makeBackup(includePreferences: Bool = true) -> StorageBackup {
        StorageBackup(
            configs: loadConfigs(),
            history: loadHistory(),
            keeps: loadKeeps(),
            tracks: loadTracks(),
            preferences: includePreferences ? UserPreferenceSnapshot() : nil
        )
    }

    public func restoreBackup(_ backup: StorageBackup, restorePreferences: Bool = true) throws {
        let backup = try StorageBackupCodec.validatedPayload(backup, allowHistoryMigration: true)
        let filenames = ["configs.json", "history.json", "keeps.json", "tracks.json"]
        var snapshots: [String: Data?] = [:]
        for filename in filenames {
            let url = storageDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: url.path) {
                snapshots.updateValue(try Data(contentsOf: url), forKey: filename)
            } else {
                snapshots.updateValue(nil, forKey: filename)
            }
        }

        do {
            try saveConfigs(backup.configs)
            try saveHistory(backup.history)
            try saveKeeps(backup.keeps)
            try saveTracks(backup.tracks)
        } catch {
            for filename in filenames {
                let url = storageDirectory.appendingPathComponent(filename)
                if case .some(.some(let data)) = snapshots[filename] {
                    try? data.write(to: url, options: .atomic)
                } else if case .some(.none) = snapshots[filename] {
                    try? fileManager.removeItem(at: url)
                }
            }
            throw error
        }

        if restorePreferences, let preferences = backup.preferences {
            preferences.apply()
        }
    }

    public func exportBackup(to url: URL, includePreferences: Bool = true) throws {
        let backup = makeBackup(includePreferences: includePreferences)
        let data = try StorageBackupCodec.encode(backup)
        try data.write(to: url, options: .atomic)
    }

    public func inspectBackup(from url: URL) throws -> StorageBackupPreview {
        try StorageBackupCodec.preview(readBackupData(from: url))
    }

    @discardableResult
    public func importBackup(from url: URL, restorePreferences: Bool = true) throws -> StorageBackup {
        let backup = try StorageBackupCodec.decode(readBackupData(from: url)).backup
        try restoreBackup(backup, restorePreferences: restorePreferences)
        return backup
    }

    private func readBackupData(from url: URL) throws -> Data {
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize > 0 else { throw StorageError.invalidBackup }
        guard fileSize <= StorageBackupCodec.maximumArchiveByteCount else {
            throw StorageError.backupTooLarge
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    public func makePlaybackProgressExport() -> PlaybackProgressExport {
        PlaybackProgressExport(records: loadHistory().map(PlaybackProgressRecord.init(history:)))
    }

    public func exportPlaybackProgress(to url: URL) throws {
        let progress = makePlaybackProgressExport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(progress)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public func importPlaybackProgress(from url: URL) throws -> PlaybackProgressExport {
        let data = try Data(contentsOf: url)
        let progress = try JSONDecoder().decode(PlaybackProgressExport.self, from: data)
        guard progress.schemaVersion == 1 else {
            throw StorageError.unsupportedProgressVersion(progress.schemaVersion)
        }
        try saveHistory(PlaybackProgressSyncPolicy.merged(existing: loadHistory(), importing: progress))
        return progress
    }
}

public enum StorageError: LocalizedError, Equatable, Sendable {
    case unsupportedBackupVersion(Int)
    case unsupportedProgressVersion(Int)
    case invalidBackup
    case backupTooLarge
    case backupChecksumMismatch
    case backupCollectionLimitExceeded
    case unsafeHistoryReference

    public var errorDescription: String? {
        switch self {
        case .unsupportedBackupVersion(let version):
            return "不支持的备份版本: \(version)"
        case .unsupportedProgressVersion(let version):
            return "不支持的播放进度版本: \(version)"
        case .invalidBackup:
            return "备份文件格式无效"
        case .backupTooLarge:
            return "备份文件超过 32 MiB 上限"
        case .backupChecksumMismatch:
            return "备份文件校验失败，内容可能已损坏或被修改"
        case .backupCollectionLimitExceeded:
            return "备份文件包含过多记录"
        case .unsafeHistoryReference:
            return "备份包含不安全的播放引用"
        }
    }
}
