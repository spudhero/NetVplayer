import Foundation
import Models
import Testing
@testable import DriveEngine
@testable import NetVplayerApp

struct DriveMappingVerificationTests {
    private func fixture(fingerprint: String? = nil, id: String = "saved") throws -> (URL, DriveSavedFileStore, DriveSavedFileIdentity, DriveSavedFileRecord) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DriveSavedFileStore(fileURL: directory.appendingPathComponent("saved.json"))
        let base = DriveSavedFileNaming.identity(provider: .quark, pwdID: "share", fid: "source", name: "same.mp4", size: 100)
        let identity = base.scoped(account: "account-A", target: "folder")
        let record = DriveSavedFileRecord(provider: .quark, cacheKey: identity.cacheKey, pwdID: "share",
            shareFID: "source", fidToken: "", size: 100, originalName: "same.mp4", savedFID: id,
            savedFileName: "same.mp4", parentFID: "folder", contentFingerprint: fingerprint)
        return (directory, store, base, record)
    }

    @Test func accountAndLegacyIsolationDoNotMigrateUnprovenRecords() async throws {
        let (directory, store, base, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(record)
        #expect(try await store.verificationRecord(for: base, account: "account-A") == record)
        #expect(try await store.verificationRecord(for: base, account: "account-B") == nil)
        let legacy = DriveSavedFileRecord(provider: .quark, cacheKey: base.cacheKey, pwdID: "share",
            shareFID: "source", fidToken: "", size: 100, originalName: "same.mp4", savedFID: "legacy",
            savedFileName: "same.mp4", parentFID: "folder")
        try await store.save(legacy)
        do {
            _ = try await store.verificationRecord(for: base, account: "account-B")
            Issue.record("unscoped mapping was adopted by another account")
        } catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingUnconfirmed) }
        #expect(await store.record(for: base.cacheKey) == legacy)
        #expect(await store.record(for: record.cacheKey) == record)
    }

    @Test(arguments: ["partial", "missing-parent", "missing-size", "unrelated-id", "missing-hash", "different-hash"])
    func incompleteEvidenceDoesNotDeleteMapping(scenario: String) async throws {
        let (directory, store, base, record) = try fixture(fingerprint: "original")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(record)
        let file = DriveMappingVerification.File(id: scenario == "unrelated-id" ? "namesake" : "saved",
            parent: scenario == "missing-parent" ? "" : "folder", size: scenario == "missing-size" ? 0 : 100,
            isDirectory: false, fingerprint: scenario == "missing-hash" ? "" : scenario == "different-hash" ? "replacement" : "original")
        do {
            try await DriveMappingVerification.require(record, identity: base.scoped(account: "account-A", target: "folder"),
                file: scenario == "partial" ? nil : file, listingComplete: false, store: store)
            Issue.record("insufficient or mismatched evidence was accepted")
        } catch let failure as DriveServiceFailure {
            #expect(failure.reason == (scenario == "different-hash" ? .mappingChanged : .mappingUnconfirmed))
        }
        #expect(await store.record(for: record.cacheKey) == (scenario == "different-hash" ? nil : record))
    }

    @Test func staleSameIDAndCancelledVerificationCannotInvalidateNewObservation() async throws {
        let (directory, store, base, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var newer = record
        newer.updatedAt = record.updatedAt.addingTimeInterval(1)
        try await store.save(newer)
        try await store.invalidate(record)
        #expect(await store.record(for: record.cacheKey) == newer)
        #expect(await store.rejectedFileIDs(cacheKey: record.cacheKey).isEmpty)
        do {
            try await DriveTransferContext.$current.withValue(.init(revision: "retired", isCurrent: { false })) {
                try await DriveMappingVerification.require(newer, identity: base.scoped(account: "account-A", target: "folder"),
                    file: nil, listingComplete: true, store: store)
            }
            Issue.record("retired context was accepted")
        } catch is CancellationError { }
        #expect(await store.record(for: record.cacheKey) == newer)
    }

    @Test func backgroundDoesNotStartTargetLookupAndReopenOnlyReadsLocalStore() async throws {
        let (directory, store, base, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(record)
        let reopened = DriveSavedFileStore(fileURL: directory.appendingPathComponent("saved.json"))
        #expect(await reopened.record(for: record.cacheKey) == record)
        do {
            try await DriveRequestRecovery.withBudget(background: true) {
                _ = try await reopened.verificationRecord(for: base, account: "account-A")
                Issue.record("background lookup escaped into remote work")
            }
        } catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingUnconfirmed) }
        do {
            _ = try await DriveRequestRecovery.withBudget(background: true) {
                try await DriveMappingVerification.target(record: record, provider: .quark, store: reopened) {
                    Issue.record("background verification started remote target lookup")
                }
            }
        } catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingUnconfirmed) }
        #expect(await reopened.record(for: record.cacheKey) == record)
    }

    @Test @MainActor func mappingActionsUseFixedLocalizedPresentation() {
        for reason in [AppFailureReason.mappingChanged, .mappingUnconfirmed] {
            let failure = DriveServiceFailure(provider: .quark, reason: reason, operation: .fileMetadata)
            let presentation = UserFacingErrorPresenter.presentation(for: failure, context: .playback)
            #expect(presentation.message == reason.presentationHint.title)
            #expect(presentation.recoverySuggestion == reason.presentationHint.suggestedAction)
            #expect(!presentation.message.contains("saved"))
        }
    }

    @Test func verifiedMigrationCannotOverwriteAConcurrentObservation() async throws {
        let (directory, store, _, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(record)
        var newer = record
        newer.updatedAt = record.updatedAt.addingTimeInterval(1)
        try await store.save(newer)
        do { try await store.replaceVerified(record, with: record); Issue.record("stale verification overwrote a newer row") }
        catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingUnconfirmed) }
        #expect(await store.record(for: record.cacheKey) == newer)
    }

    @Test(arguments: ["stale", "occupied", "unscoped", "wrong-base", "cancelled", "directory"])
    func legacyBindingRequiresCurrentObservationAndMatchingScopedIdentity(scenario: String) async throws {
        let (directory, store, base, bound) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = DriveSavedFileRecord(provider: .quark, cacheKey: try #require(base.legacyCacheKey),
            pwdID: "share", shareFID: "source", fidToken: "", size: 100, originalName: "same.mp4",
            savedFID: "saved", savedFileName: "same.mp4", parentFID: "folder")
        try await store.save(old)
        let candidate = try #require(try DriveMappingVerification.legacyCandidate(old, for: base,
            shareID: "share", sourceID: "source", size: 100))
        var observed = old
        if scenario == "stale" {
            observed.updatedAt = old.updatedAt.addingTimeInterval(1)
            try await store.save(observed)
        }
        if scenario == "occupied" { try await store.save(bound) }
        let identity: DriveSavedFileIdentity
        if scenario == "unscoped" { identity = base }
        else if scenario == "wrong-base" {
            identity = DriveSavedFileNaming.identity(provider: .quark, pwdID: "other-share",
                fid: "source", name: "same.mp4", size: 100).scoped(account: "account-A", target: "folder")
        } else { identity = base.scoped(account: "account-A", target: "folder") }
        do {
            let context = DriveTransferContext(revision: "legacy-verification", isCurrent: { scenario != "cancelled" })
            _ = try await DriveTransferContext.$current.withValue(context) {
                try await DriveMappingVerification.verified(old, identity: identity, legacy: candidate,
                    file: .init(id: "saved", parent: "folder", size: 100, isDirectory: scenario == "directory"),
                    listingComplete: true, store: store)
            }
            Issue.record("unproven or stale legacy binding was committed")
        } catch is CancellationError { #expect(scenario == "cancelled") }
        catch let failure as DriveServiceFailure { #expect(failure.reason == .mappingUnconfirmed) }
        #expect(await store.record(for: old.cacheKey) == observed)
        #expect(await store.record(for: bound.cacheKey) == (scenario == "occupied" ? bound : nil))
        if identity.cacheKey != old.cacheKey && identity.cacheKey != bound.cacheKey {
            #expect(await store.record(for: identity.cacheKey) == nil)
        }
    }
}
