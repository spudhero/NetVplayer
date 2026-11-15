// DriveEngine/DriveSavedFileStore.swift
// Versioned saved-file cache shared by all drive providers.

import CryptoKit
import Foundation
import Models
import Storage

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
    public let targetRootFID: String?
    public let savedPickCode: String?
    public let isTemporary: Bool?
    public let contentFingerprint: String?
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
        targetRootFID: String? = nil,
        savedPickCode: String? = nil,
        isTemporary: Bool? = nil,
        contentFingerprint: String? = nil,
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
        self.targetRootFID = targetRootFID
        self.savedPickCode = savedPickCode
        self.isTemporary = isTemporary
        self.contentFingerprint = contentFingerprint
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
            DrivePlaybackMetadataKey.temporarySavedFile: String(isTemporary ?? true)
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
            targetRootFID: targetRootFID,
            savedPickCode: savedPickCode,
            isTemporary: isTemporary,
            contentFingerprint: contentFingerprint,
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
    private struct RejectedFile: Hashable {
        let cacheKey: String
        let fid: String
    }
    private var rejectedFiles: [RejectedFile: Date] = [:]

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

    public func record(for identity: DriveSavedFileIdentity) async -> DriveSavedFileRecord? {
        guard (try? await DriveTransferContext.current.check()) != nil else { return nil }
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

    public func save(_ record: DriveSavedFileRecord) async throws {
        try await DriveTransferContext.current.check()
        var all = records()
        all[record.cacheKey] = record
        try write(all)
    }

    /// The account-bound cache key is evidence; an unscoped legacy row is not.
    /// Searching these local rows never enumerates a remote service.
    public func verificationRecord(for base: DriveSavedFileIdentity, account: String,
        allowUnscopedCandidate: Bool = false) async throws -> DriveSavedFileRecord? {
        try await DriveTransferContext.current.check()
        let all = records()
        let candidates = all.values.filter { record in
            let target = record.provider == .baidu
                ? (record.parentFID as NSString).deletingLastPathComponent
                : record.targetRootFID ?? record.parentFID
            return record.cacheKey == base.scoped(account: account, target: target).cacheKey
        }
        guard candidates.count <= 1 else { throw DriveMappingVerification.unconfirmed(base.provider) }
        if let record = candidates.first {
            guard !DriveRequestRecovery.background else { throw DriveMappingVerification.unconfirmed(base.provider) }
            return record
        }
        let legacyKeys = Set([base.cacheKey, base.legacyCacheKey].compactMap { $0 })
        let legacy = legacyKeys.compactMap { all[$0] }
        if !legacy.isEmpty {
            // This returns a candidate only. The provider must prove the exact
            // personal file in the current account before binding it.
            guard allowUnscopedCandidate,
                  !DriveRequestRecovery.background, legacy.count == 1,
                  legacy[0].provider == base.provider else {
                throw DriveMappingVerification.unconfirmed(base.provider)
            }
            return legacy[0]
        }
        return nil
    }

    /// Commit a verified observation only while the examined row is unchanged.
    /// A legacy row is removed in the same write that creates its account binding.
    func replaceVerified(_ record: DriveSavedFileRecord, with verified: DriveSavedFileRecord) async throws {
        try await DriveTransferContext.current.check()
        var all = records()
        guard all[record.cacheKey] == record,
              record.cacheKey == verified.cacheKey || all[verified.cacheKey] == nil else {
            throw DriveMappingVerification.unconfirmed(verified.provider ?? .quark)
        }
        all[record.cacheKey] = nil
        all[verified.cacheKey] = verified
        try write(all)
    }

    public func remove(cacheKey: String) throws {
        var all = records()
        all.removeValue(forKey: cacheKey)
        try write(all)
    }

    func confirmedRecords(provider: DriveProvider, fileID: String, account: String) -> [DriveSavedFileRecord] {
        records().values.filter {
            $0.provider == provider && $0.savedFID == fileID
                && $0.cacheKey.hasSuffix(":" + DriveTransferContext.digest([account, $0.parentFID]))
        }
    }

    /// Keep a brief rejection across preparation retries, including a directory rescan.
    func invalidate(_ record: DriveSavedFileRecord, now: Date = Date()) async throws {
        try await DriveTransferContext.current.check()
        var all = records()
        // Also protect a newer observation of the same ID from a late failure.
        let matches = all[record.cacheKey] == record
        if !matches && all[record.cacheKey]?.savedFID == record.savedFID { return }
        rejectedFiles[RejectedFile(cacheKey: record.cacheKey, fid: record.savedFID)] = now
        if rejectedFiles.count > 256,
           let oldest = rejectedFiles.min(by: { $0.value < $1.value })?.key {
            rejectedFiles.removeValue(forKey: oldest)
        }
        if matches {
            all.removeValue(forKey: record.cacheKey)
            try write(all)
        }
    }

    func rejectedFileIDs(cacheKey: String, now: Date = Date()) -> Set<String> {
        rejectedFiles = rejectedFiles.filter { now.timeIntervalSince($0.value) < 300 }
        return Set(rejectedFiles.keys.filter { $0.cacheKey == cacheKey }.map(\.fid))
    }

    public func removeAll() throws {
        try write([:])
        rejectedFiles.removeAll()
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
        TestRuntime.isRunning
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
    public static let shared = DriveTransferCoordinator(store: TestRuntime.isRunning ? nil : .shared)
    @TaskLocal public static var current = shared
    var recovering = Set<UUID>()
    func hasTransfer(cacheKey: String) -> Bool { tasks[cacheKey] != nil }
    let taskStore: DriveTransferTaskStore?
    public init(store: DriveTransferTaskStore? = nil) { taskStore = store }

    /// Gate before folder creation: a restored/cancelled write cannot be bypassed
    /// by changing its destination. Existing in-process attempts retain MSC-01.
    func checkRecovery(sourceKey: String, account: String) throws {
        guard let taskStore else { return }
        for record in try taskStore.records() where record.scope.sourceKey == sourceKey
            && record.scope.accountReference == DriveTransferContext.digest([account]) && !record.completed {
            if record.cancelled || attempts[record.scope.cacheKey] == nil
                || record.scope.configurationIdentity != DriveTransferContext.current.configurationIdentity {
                throw DriveTaskRecoveryError.requiresReview
            }
        }
    }

    public func summaries() throws -> [DriveTransferTask] { try taskStore?.records() ?? [] }
    public func activeDiagnosticIDs() async -> Set<UUID> {
        var ids = recovering
        for (key, attempt) in attempts where tasks[key] != nil {
            if let id = await attempt.record?.id { ids.insert(id) }
        }
        return ids
    }
    public func cancelRecovery(_ id: UUID) throws {
        guard let record = try taskStore?.records().first(where: { $0.id == id }) else { return }
        try taskStore?.cancel(id)
        tasks[record.scope.cacheKey]?.cancel()
    }

    private var tasks: [String: Task<DriveSavedFileTransferResult, Error>] = [:]
    private var attempts: [String: DriveTransferAttempt] = [:]
    private var attemptRevisions: [String: String] = [:]
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
        try await DriveTransferContext.current.check()
        await waitForCleanup(cacheKey: cacheKey)
        try await DriveTransferContext.current.check()
        if let task = tasks[cacheKey] {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try await DriveTransferContext.current.check()
            return result
        }

        let task = Task {
            try await operation()
        }
        tasks[cacheKey] = task

        do {
            let record = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            tasks[cacheKey] = nil
            try await DriveTransferContext.current.check()
            return record
        } catch {
            tasks[cacheKey] = nil
            throw error
        }
    }

    /// Re-enter the adapter with retained evidence; the attempt refuses a second
    /// uncertain submission. Revision changes cannot adopt an old in-flight task.
    func confirmedTransfer(
        cacheKey: String,
        scope: DriveTransferTaskScope? = nil,
        operation: @escaping @Sendable (DriveTransferAttempt) async throws -> DriveSavedFileTransferResult
    ) async throws -> DriveSavedFileTransferResult {
        try await DriveTransferContext.current.check()
        let revision = DriveTransferContext.current.revision
        let remainingRetries = await DriveRequestRecovery.budget?.availableRetries ?? 2
        if let prior = attemptRevisions[cacheKey], prior != revision {
            if tasks[cacheKey] != nil {
                throw DriveEngineError.transferConfirmationPending()
            }
            if let attempt = attempts[cacheKey], !(await attempt.needsSubmission) {
                throw DriveEngineError.transferConfirmationPending()
            }
            attempts[cacheKey] = nil
        }
        // Never evict unresolved writes to make room: that would allow a replay.
        guard attempts[cacheKey] != nil || attempts.count < 256 else {
            throw DriveEngineError.transferConfirmationPending()
        }
        let attempt: DriveTransferAttempt
        if let existing = attempts[cacheKey] { attempt = existing }
        else if let taskStore {
            guard let scope else { throw DriveTaskRecoveryError.storageUnavailable }
            // All unfinished rows, including pre-submit rows, require an explicit
            // continue after reopening. No transport runs during this lookup.
            guard !(try taskStore.records()).contains(where: {
                !$0.completed && $0.scope.sourceKey == scope.sourceKey
                    && $0.scope.accountReference == scope.accountReference
            }) else { throw DriveTaskRecoveryError.requiresReview }
            var record = DriveTransferTask(scope: scope)
            record.remainingReadRetries = remainingRetries
            try taskStore.insert(record)
            attempt = DriveTransferAttempt(record: record, store: taskStore)
        } else { attempt = DriveTransferAttempt() }
        attempts[cacheKey] = attempt
        attemptRevisions[cacheKey] = revision
        do {
            let result = try await transfer(cacheKey: cacheKey) {
                try await DriveTransferContext.$confirmationDeadline.withValue(.now.advanced(by: .seconds(20))) {
                    try await DriveRequestRecovery.withBudget {
                        try await DriveRequestRecovery.$transferAttempt.withValue(attempt) {
                            try await operation(attempt)
                        }
                    }
                }
            }
            try await attempt.completed()
            if attempts[cacheKey] === attempt {
                attempts[cacheKey] = nil
                attemptRevisions[cacheKey] = nil
            }
            return result
        } catch {
            if TaskDiagnosticIssue.isCancellation(error) || Task.isCancelled { try await attempt.cancel() }
            else { await attempt.recordIssue(error) }
            if error is DriveTaskRecoveryError { throw error }
            await attempt.interrupted()
            let phase = await attempt.phase
            try await DriveTransferContext.current.check()
            if error is CancellationError { throw error }
            if phase == .submittedAwaitingConfirmation || phase == .outcomeUnknown {
                throw DriveEngineError.transferConfirmationPending(phase)
            }
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
