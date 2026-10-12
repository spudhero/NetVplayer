import Foundation
import Models
import Testing
@testable import DriveEngine

struct DriveSavedFileRejectionTests {
    @Test func lateInvalidationPreservesReplacementAndExpiresRejection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DriveSavedFileStore(fileURL: directory.appendingPathComponent("saved.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = record(fid: "stale")
        let fresh = record(fid: "fresh")
        try await store.save(fresh)
        try await store.invalidate(stale, now: now)
        #expect(await store.record(for: "fixture")?.savedFID == "fresh")
        #expect(await store.rejectedFileIDs(cacheKey: "fixture", now: now) == ["stale"])
        #expect(await store.rejectedFileIDs(cacheKey: "other", now: now).isEmpty)
        #expect(await store.rejectedFileIDs(cacheKey: "fixture", now: now.addingTimeInterval(301)).isEmpty)
    }

    @Test func invalidationRemovesOnlyTheFailedRecordAndResetClearsRejections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DriveSavedFileStore(fileURL: directory.appendingPathComponent("saved.json"))
        let failed = record(fid: "failed")
        try await store.save(failed)
        try await store.invalidate(failed)
        #expect(await store.record(for: "fixture") == nil)
        #expect(await store.rejectedFileIDs(cacheKey: "fixture") == ["failed"])
        try await store.removeAll()
        #expect(await store.rejectedFileIDs(cacheKey: "fixture").isEmpty)
    }

    private func record(fid: String) -> DriveSavedFileRecord {
        DriveSavedFileRecord(
            provider: .uc, cacheKey: "fixture", pwdID: "share", shareFID: "source",
            fidToken: "fixture-token", size: 1024, originalName: "episode.mp4",
            savedFID: fid, savedFileName: "episode__nv_fixture.mp4", parentFID: "folder"
        )
    }
}
