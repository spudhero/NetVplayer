import Foundation
import Models

/// On-demand evidence for one persisted mapping. No task journal or remote repair.
enum DriveMappingVerification {
    @TaskLocal static var readOnly = false

    struct File: Sendable {
        let id: String
        let parent: String
        let size: Int64
        let isDirectory: Bool
        var fingerprint: String = ""
    }

    struct LegacyCandidate: Sendable {
        fileprivate let record: DriveSavedFileRecord
        fileprivate let base: DriveSavedFileIdentity
    }

    /// Opting into lookup does not prove ownership. Reject locally invalid rows
    /// before reading the current account; remote confirmation happens below.
    static func legacyCandidate(_ record: DriveSavedFileRecord?, for base: DriveSavedFileIdentity,
        shareID: String, sourceID: String, size: Int64) throws -> LegacyCandidate? {
        guard let record, record.cacheKey == base.cacheKey || record.cacheKey == base.legacyCacheKey else { return nil }
        guard !DriveRequestRecovery.background, record.provider == base.provider,
              record.pwdID == shareID, record.shareFID == sourceID,
              !record.savedFID.isEmpty, record.savedFID != sourceID,
              !record.parentFID.isEmpty, size > 0, record.size == size else {
            throw unconfirmed(base.provider)
        }
        return LegacyCandidate(record: record, base: base)
    }

    /// Existing account bindings keep the ordinary invalidation policy. An old
    /// row is only replaced after its exact ID, parent and positive size agree;
    /// an inconclusive observation must preserve it without another transfer.
    static func verified(_ record: DriveSavedFileRecord, identity: DriveSavedFileIdentity,
        legacy: LegacyCandidate?, file: File?, listingComplete: Bool = false,
        store: DriveSavedFileStore = .shared) async throws -> DriveSavedFileRecord {
        guard let legacy else {
            try await require(record, identity: identity, file: file, listingComplete: listingComplete, store: store)
            return record
        }
        try await DriveTransferContext.current.check()
        guard !DriveRequestRecovery.background, legacy.record == record,
              record.provider == identity.provider, record.cacheKey != identity.cacheKey,
              identity.legacyCacheKey == legacy.base.cacheKey,
              identity.cacheKey.hasPrefix(legacy.base.cacheKey + ":"),
              let file, file.id == record.savedFID, !file.isDirectory,
              file.parent == record.parentFID, file.size == record.size, file.size > 0 else {
            throw unconfirmed(identity.provider)
        }
        if let fingerprint = record.contentFingerprint, !fingerprint.isEmpty {
            guard !file.fingerprint.isEmpty,
                  fingerprint.caseInsensitiveCompare(file.fingerprint) == .orderedSame else {
                throw unconfirmed(identity.provider)
            }
        }
        let bound = DriveSavedFileRecord(provider: record.provider, cacheKey: identity.cacheKey,
            pwdID: record.pwdID, shareFID: record.shareFID, fidToken: record.fidToken,
            size: record.size, originalName: record.originalName, savedFID: record.savedFID,
            savedFileName: record.savedFileName, parentFID: record.parentFID, driveID: record.driveID,
            targetRootFID: record.targetRootFID, savedPickCode: record.savedPickCode,
            isTemporary: record.isTemporary, contentFingerprint: record.contentFingerprint)
        try await store.replaceVerified(record, with: bound)
        DiagnosticLog.write("[DRIVE_MAPPING_VERIFIED] provider=\(identity.provider.rawValue) legacyMigration=true")
        return bound
    }

    static func unconfirmed(_ provider: DriveProvider) -> DriveServiceFailure {
        .init(provider: provider, reason: .mappingUnconfirmed, operation: .fileMetadata)
    }

    static func changed(_ provider: DriveProvider) -> DriveServiceFailure {
        .init(provider: provider, reason: .mappingChanged, operation: .fileMetadata)
    }

    /// Folder lookup uses the existing policy, but may not create a replacement
    /// directory while examining a saved mapping.
    static func target<T: Sendable>(record: DriveSavedFileRecord?, provider: DriveProvider,
        store: DriveSavedFileStore = .shared,
        legacy: LegacyCandidate? = nil,
        operation: () async throws -> T) async throws -> T {
        try await DriveTransferContext.current.check()
        if record != nil && DriveRequestRecovery.background { throw unconfirmed(provider) }
        do {
            return try await $readOnly.withValue(record != nil) { try await operation() }
        } catch {
            try await handle(error, record: record, provider: provider, store: store, legacy: legacy)
            throw error
        }
    }

    static func require(_ record: DriveSavedFileRecord, identity: DriveSavedFileIdentity,
        file: File?, listingComplete: Bool = false, store: DriveSavedFileStore = .shared) async throws {
        try await DriveTransferContext.current.check()
        let provider = identity.provider
        guard !DriveRequestRecovery.background else { throw unconfirmed(provider) }
        guard await store.record(for: record.cacheKey) == record else { throw unconfirmed(provider) }
        guard record.provider == provider, record.cacheKey == identity.cacheKey,
              !record.savedFID.isEmpty else {
            try await invalidate(record, provider: provider, store: store)
        }
        guard let file else {
            if listingComplete { try await invalidate(record, provider: provider, store: store) }
            throw unconfirmed(provider)
        }
        // An unrelated response is not proof of anything about the requested ID.
        guard file.id == record.savedFID else { throw unconfirmed(provider) }
        guard !file.parent.isEmpty else { throw unconfirmed(provider) }
        let expectedParent = provider == .baidu
            ? (record.parentFID as NSString).deletingLastPathComponent : record.parentFID
        if file.parent != expectedParent || file.isDirectory
            || (record.size > 0 && file.size > 0 && record.size != file.size) {
            try await invalidate(record, provider: provider, store: store)
        }
        if record.size > 0 && file.size <= 0 { throw unconfirmed(provider) }
        if let fingerprint = record.contentFingerprint, !fingerprint.isEmpty {
            guard !file.fingerprint.isEmpty else { throw unconfirmed(provider) }
            if fingerprint.caseInsensitiveCompare(file.fingerprint) != .orderedSame {
                try await invalidate(record, provider: provider, store: store)
            }
        }
    }

    static func invalidate(_ record: DriveSavedFileRecord, provider: DriveProvider,
        store: DriveSavedFileStore = .shared, legacy: LegacyCandidate? = nil) async throws -> Never {
        if legacy?.record == record { throw unconfirmed(provider) }
        try await store.invalidate(record)
        throw changed(provider)
    }

    static func handle(_ error: Error, record: DriveSavedFileRecord?, provider: DriveProvider,
        store: DriveSavedFileStore = .shared, legacy: LegacyCandidate? = nil) async throws {
        try await DriveTransferContext.current.check()
        guard let record else { return }
        if DriveEngineError.invalidatesSavedRecord(error, provider: provider)
            || (error as? DriveServiceFailure)?.reason == .mappingChanged {
            try await invalidate(record, provider: provider, store: store, legacy: legacy)
        }
    }
}
