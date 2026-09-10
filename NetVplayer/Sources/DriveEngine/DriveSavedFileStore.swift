// DriveEngine/DriveSavedFileStore.swift
// Versioned saved-file cache shared by all drive providers.

import CryptoKit
import Foundation
import Models

public enum DrivePlaybackRoute {
    public static let ucOriginalProxy = "uc-original-proxy"
    public static let ucOpenAPIStreaming = "uc-openapi-streaming"
    public static let ucSmartPlay = "uc-smart-play"
    public static let streamVariant = "stream-variant"
    public static let personalTranscode = "personal-transcode"
    public static let originalDownload = "original-download"
    public static let shareFallback = "share-fallback"
}

public struct DriveSavedFileIdentity: Equatable, Sendable {
    public let provider: DriveProvider
    public let cacheKey: String
    public let legacyCacheKey: String?
    public let targetFileName: String

    public init(
        provider: DriveProvider,
        cacheKey: String,
        legacyCacheKey: String? = nil,
        targetFileName: String
    ) {
        self.provider = provider
        self.cacheKey = cacheKey
        self.legacyCacheKey = legacyCacheKey
        self.targetFileName = targetFileName
    }
}

public struct DriveSavedFileRecord: Codable, Equatable, Sendable {
    public let provider: DriveProvider?
    public let cacheKey: String
    public let pwdID: String
    public let shareFID: String
    public let fidToken: String
    public let size: Int64
    public let originalName: String
    public let savedFID: String
    public let savedFileName: String
    public let parentFID: String
    public let driveID: String?
    public var updatedAt: Date

    public init(
        provider: DriveProvider? = .quark,
        cacheKey: String,
        pwdID: String,
        shareFID: String,
        fidToken: String,
        size: Int64,
        originalName: String,
        savedFID: String,
        savedFileName: String,
        parentFID: String,
        driveID: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.provider = provider
        self.cacheKey = cacheKey
        self.pwdID = pwdID
        self.shareFID = shareFID
        self.fidToken = fidToken
        self.size = size
        self.originalName = originalName
        self.savedFID = savedFID
        self.savedFileName = savedFileName
        self.parentFID = parentFID
        self.driveID = driveID
        self.updatedAt = updatedAt
    }

    public var playbackMetadata: [String: String] {
        playbackMetadata(provider: provider ?? .quark)
    }

    public func playbackMetadata(provider: DriveProvider) -> [String: String] {
        var values = [
            DrivePlaybackMetadataKey.provider: provider.rawValue,
            DrivePlaybackMetadataKey.cacheKey: cacheKey,
            DrivePlaybackMetadataKey.fid: savedFID,
            DrivePlaybackMetadataKey.fileName: savedFileName,
            DrivePlaybackMetadataKey.size: String(size),
            DrivePlaybackMetadataKey.temporarySavedFile: "true"
        ]
        if let driveID, !driveID.isEmpty {
            values[DrivePlaybackMetadataKey.driveID] = driveID
            values[DrivePlaybackMetadataKey.personalFileID] = savedFID
        }
        return values
    }

    fileprivate func migrated(cacheKey: String, provider: DriveProvider) -> Self {
        Self(
            provider: provider,
            cacheKey: cacheKey,
            pwdID: pwdID,
            shareFID: shareFID,
            fidToken: fidToken,
            size: size,
            originalName: originalName,
            savedFID: savedFID,
            savedFileName: savedFileName,
            parentFID: parentFID,
            driveID: driveID,
            updatedAt: updatedAt
        )
    }
}

public struct DriveSavedFileTransferResult: Sendable {
    public let record: DriveSavedFileRecord
    public let updatedCookie: String

    public init(record: DriveSavedFileRecord, updatedCookie: String) {
        self.record = record
        self.updatedCookie = updatedCookie
    }
}

public actor DriveSavedFileStore {
    public static let shared = DriveSavedFileStore()

    private let fileURL: URL
    private let legacyFileURL: URL?

    public init(fileURL: URL? = nil, legacyFileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            self.legacyFileURL = legacyFileURL
            Self.copyLegacyStoreIfNeeded(from: legacyFileURL, to: fileURL)
        } else {
            let directory: URL
            if Self.isRunningTests {
                directory = FileManager.default.temporaryDirectory.appendingPathComponent("NetVplayerTests", isDirectory: true)
            } else {
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                directory = appSupport.appendingPathComponent("NetVplayer", isDirectory: true)
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let versionedURL = directory.appendingPathComponent("drive_saved_files.v2.json")
            let legacyURL = directory.appendingPathComponent("quark_saved_files.json")
            self.fileURL = versionedURL
            self.legacyFileURL = legacyURL
            Self.copyLegacyStoreIfNeeded(from: legacyURL, to: versionedURL)
        }
    }

    public func record(for cacheKey: String) -> DriveSavedFileRecord? {
        records()[cacheKey]
    }

    public func record(for identity: DriveSavedFileIdentity) -> DriveSavedFileRecord? {
        var all = records()
        if let current = all[identity.cacheKey] { return current }
        guard let legacyCacheKey = identity.legacyCacheKey,
              let legacy = all[legacyCacheKey] else {
            return nil
        }
        let migrated = legacy.migrated(cacheKey: identity.cacheKey, provider: identity.provider)
        all[legacyCacheKey] = nil
        all[identity.cacheKey] = migrated
        try? write(all)
        return migrated
    }

    public func save(_ record: DriveSavedFileRecord) throws {
        var all = records()
        var updated = record
        updated.updatedAt = Date()
        all[record.cacheKey] = updated
        try write(all)
    }

    public func remove(cacheKey: String) throws {
        var all = records()
        all.removeValue(forKey: cacheKey)
        try write(all)
    }

    public func removeAll() throws {
        try write([:])
    }

    private func records() -> [String: DriveSavedFileRecord] {
        let sourceURL = FileManager.default.fileExists(atPath: fileURL.path)
            ? fileURL
            : legacyFileURL
        guard let sourceURL,
              let data = try? Data(contentsOf: sourceURL),
              !data.isEmpty else {
            return [:]
        }
        let array = (try? JSONDecoder().decode([DriveSavedFileRecord].self, from: data)) ?? []
        return Dictionary(uniqueKeysWithValues: array.map { ($0.cacheKey, $0) })
    }

    private func write(_ records: [String: DriveSavedFileRecord]) throws {
        let sorted = records.values.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.cacheKey < $1.cacheKey
            }
            return $0.updatedAt > $1.updatedAt
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sorted)
        try data.write(to: fileURL, options: .atomic)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") || $0.contains("swift-testing") }
    }

    private static func copyLegacyStoreIfNeeded(from legacyURL: URL?, to versionedURL: URL) {
        guard let legacyURL,
              !FileManager.default.fileExists(atPath: versionedURL.path),
              FileManager.default.fileExists(atPath: legacyURL.path) else {
            return
        }
        try? FileManager.default.copyItem(at: legacyURL, to: versionedURL)
    }
}

public actor DriveTransferCoordinator {
    public static let shared = DriveTransferCoordinator()

    private var tasks: [String: Task<DriveSavedFileTransferResult, Error>] = [:]
    private var cleanupCounts: [String: Int] = [:]
    private var cleanupWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func beginCleanup(cacheKey: String) {
        guard !cacheKey.isEmpty else { return }
        cleanupCounts[cacheKey, default: 0] += 1
    }

    func finishCleanup(cacheKey: String) {
        guard !cacheKey.isEmpty,
              let count = cleanupCounts[cacheKey] else {
            return
        }
        if count > 1 {
            cleanupCounts[cacheKey] = count - 1
            return
        }

        cleanupCounts[cacheKey] = nil
        let waiters = cleanupWaiters.removeValue(forKey: cacheKey) ?? []
        waiters.forEach { $0.resume() }
    }

    func waitForCleanup(cacheKey: String) async {
        guard !cacheKey.isEmpty, cleanupCounts[cacheKey, default: 0] > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            cleanupWaiters[cacheKey, default: []].append(continuation)
        }
    }

    public func transfer(
        cacheKey: String,
        operation: @escaping @Sendable () async throws -> DriveSavedFileTransferResult
    ) async throws -> DriveSavedFileTransferResult {
        await waitForCleanup(cacheKey: cacheKey)
        if let task = tasks[cacheKey] {
            return try await task.value
        }

        let task = Task {
            try await operation()
        }
        tasks[cacheKey] = task

        do {
            let record = try await task.value
            tasks[cacheKey] = nil
            return record
        } catch {
            tasks[cacheKey] = nil
            throw error
        }
    }
}

enum DriveTransferDirectoryPolicy {
    static let rootFolderName = "NetVplayer"

    static func collectionFolderName(collectionName: String, shareID: String) -> String? {
        let title = sanitizedCollectionName(collectionName)
        guard !title.isEmpty else { return nil }
        let suffix = String(shareID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
        return suffix.isEmpty ? title : "\(title)__\(suffix)"
    }

    static func sanitizedCollectionName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .replacingOccurrences(of: "$", with: " ")
            .replacingOccurrences(of: "#", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(60))
    }
}

public enum DriveSavedFileNaming {
    public static func identity(provider: DriveProvider, pwdID: String, file: QuarkShareFile) -> DriveSavedFileIdentity {
        identity(provider: provider, pwdID: pwdID, fid: file.fid, name: file.name, size: file.size)
    }

    public static func identity(provider: DriveProvider, pwdID: String, file: UCShareFile) -> DriveSavedFileIdentity {
        identity(provider: provider, pwdID: pwdID, fid: file.fid, name: file.name, size: file.size)
    }

    public static func identity(provider: DriveProvider, pwdID: String, file: AliShareFile) -> DriveSavedFileIdentity {
        identity(provider: provider, pwdID: pwdID, fid: file.fileID, name: file.name, size: file.size)
    }

    public static func identity(
        provider: DriveProvider,
        pwdID: String,
        fid: String,
        name: String,
        size: Int64 = 0
    ) -> DriveSavedFileIdentity {
        let source = [
            provider.rawValue,
            pwdID,
            fid,
            String(max(0, size))
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let legacySource = [provider.rawValue, pwdID, fid, name].joined(separator: "|")
        let legacyDigest = SHA256.hash(data: Data(legacySource.utf8)).map { String(format: "%02x", $0) }.joined()
        let shortHash = String(digest.prefix(10))
        return DriveSavedFileIdentity(
            provider: provider,
            cacheKey: digest,
            legacyCacheKey: legacyDigest,
            targetFileName: targetFileName(originalName: name, shortHash: shortHash)
        )
    }

    private static func targetFileName(originalName: String, shortHash: String) -> String {
        let url = URL(fileURLWithPath: originalName)
        let rawExtension = url.pathExtension
        let base = rawExtension.isEmpty ? originalName : url.deletingPathExtension().lastPathComponent
        let safeBase = sanitizedName(base).isEmpty ? "video" : sanitizedName(base)
        if rawExtension.isEmpty {
            return "\(safeBase)__nv_\(shortHash)"
        }
        return "\(safeBase)__nv_\(shortHash).\(sanitizedExtension(rawExtension))"
    }

    private static func sanitizedName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return value
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizedExtension(_ value: String) -> String {
        sanitizedName(value).replacingOccurrences(of: " ", with: "")
    }
}
