import Foundation
import Models
import Testing
@testable import DriveEngine
@testable import NetVplayerApp

private actor TransferTestState {
    var writes = 0
    var valid = true
    func write() { writes += 1 }
    func invalidate() { valid = false }
}

struct DriveTransferConfirmationTests {
    private func result(_ key: String = "test", fid: String = "confirmed") -> DriveSavedFileTransferResult {
        .init(record: .init(cacheKey: key, pwdID: "share", shareFID: "source", fidToken: "", size: 10,
            originalName: "sample.mp4", savedFID: fid, savedFileName: "sample.mp4", parentFID: "folder"), updatedCookie: "")
    }

    @Test func lostResponseRetryReadsWithoutResubmitting() async throws {
        let coordinator = DriveTransferCoordinator(), remote = TransferTestState()
        for _ in 0..<2 {
            await #expect(throws: DriveEngineError.self) {
                _ = try await coordinator.confirmedTransfer(cacheKey: "lost") { attempt in
                    _ = try await attempt.submit(previousIDs: ["old"]) {
                        await remote.write()
                        throw URLError(.timedOut)
                    }
                    #expect(await attempt.previousIDs == ["old"])
                    throw DriveEngineError.transferConfirmationPending()
                }
            }
        }
        let confirmed = try await coordinator.confirmedTransfer(cacheKey: "lost") { attempt in
            #expect(await attempt.needsSubmission == false)
            try await attempt.confirmed("new")
            return result(fid: "new")
        }
        #expect(confirmed.record.savedFID == "new")
        #expect(await remote.writes == 1)
    }

    @Test func acknowledgedWriteRetainsSubmittedPhaseWhileDirectoryIsPending() async throws {
        let coordinator = DriveTransferCoordinator()
        for _ in 0..<2 {
            do {
                _ = try await coordinator.confirmedTransfer(cacheKey: "acknowledged") { attempt in
                    _ = try await attempt.submit(previousIDs: []) { .init(taskID: "task") }
                    throw DriveEngineError.transferConfirmationPending()
                }
                Issue.record("unconfirmed directory was treated as ready")
            } catch let error as DriveEngineError {
                #expect(error.transferPhase == .submittedAwaitingConfirmation)
            }
        }
    }

    @Test func explicitRejectionAllowsANewUserAttempt() async throws {
        let coordinator = DriveTransferCoordinator(), remote = TransferTestState()
        await #expect(throws: DriveEngineError.self) {
            _ = try await coordinator.confirmedTransfer(cacheKey: "rejected") { attempt in
                _ = try await attempt.submit(previousIDs: []) {
                    await remote.write()
                    throw DriveEngineError.api(provider: .quark, statusCode: 403, code: 123, message: "fixture")
                }
                return result()
            }
        }
        _ = try await coordinator.confirmedTransfer(cacheKey: "rejected") { attempt in
            #expect(await attempt.phase == .failed)
            _ = try await attempt.submit(previousIDs: []) {
                await remote.write()
                return .init(fileID: "confirmed")
            }
            return result()
        }
        #expect(await remote.writes == 2)
    }

    @Test func duplicateClicksJoinOneWrite() async throws {
        let coordinator = DriveTransferCoordinator(), remote = TransferTestState()
        let operation: @Sendable (DriveTransferAttempt) async throws -> DriveSavedFileTransferResult = { attempt in
            _ = try await attempt.submit(previousIDs: []) {
                await remote.write()
                try await Task.sleep(for: .milliseconds(30))
                return .init(fileID: "confirmed")
            }
            return result()
        }
        async let first = coordinator.confirmedTransfer(cacheKey: "duplicate", operation: operation)
        async let second = coordinator.confirmedTransfer(cacheKey: "duplicate", operation: operation)
        let (a, b) = try await (first, second)
        #expect(a.record == b.record)
        #expect(await remote.writes == 1)
    }

    @Test func cancellationRejectsLateResultButRetainsWriteEvidence() async throws {
        let coordinator = DriveTransferCoordinator(), remote = TransferTestState()
        let task = Task {
            try await coordinator.confirmedTransfer(cacheKey: "cancel") { attempt in
                _ = try await attempt.submit(previousIDs: []) {
                    await remote.write()
                    // Simulate a transport that returns after cancellation.
                    await Task.detached { try? await Task.sleep(for: .milliseconds(40)) }.value
                    return .init(fileID: "late")
                }
                throw DriveEngineError.transferConfirmationPending()
            }
        }
        while await remote.writes == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; Issue.record("cancelled caller received a result") }
        catch is CancellationError { }
        catch { Issue.record("cancelled caller received a failure instead of cancellation: \(error)") }
        _ = try await coordinator.confirmedTransfer(cacheKey: "cancel") { attempt in
            #expect(await attempt.fileID == "late")
            #expect(await attempt.needsSubmission == false)
            return result(fid: "late")
        }
        #expect(await remote.writes == 1)
    }

    @Test func changedRevisionDoesNotAdoptOrRepeatUncertainWrite() async throws {
        let coordinator = DriveTransferCoordinator(), remote = TransferTestState()
        await #expect(throws: DriveEngineError.self) {
            _ = try await DriveTransferContext.$current.withValue(.init(revision: "old")) {
                try await coordinator.confirmedTransfer(cacheKey: "same-account-and-folder") { attempt in
                    _ = try await attempt.submit(previousIDs: []) {
                        await remote.write()
                        throw URLError(.networkConnectionLost)
                    }
                    throw DriveEngineError.transferConfirmationPending()
                }
            }
        }
        await #expect(throws: DriveEngineError.self) {
            _ = try await DriveTransferContext.$current.withValue(.init(revision: "new")) {
                try await coordinator.confirmedTransfer(cacheKey: "same-account-and-folder") { _ in
                    Issue.record("new configuration adopted old work")
                    return result()
                }
            }
        }
        #expect(await remote.writes == 1)
    }

    @Test func staleContextStopsBeforeWriteAndBeforeDelivery() async throws {
        let remote = TransferTestState(), coordinator = DriveTransferCoordinator()
        let context = DriveTransferContext(revision: "fixture", isCurrent: { await remote.valid })
        await #expect(throws: CancellationError.self) {
            _ = try await DriveTransferContext.$current.withValue(context) {
                try await coordinator.confirmedTransfer(cacheKey: "stale") { attempt in
                    _ = try await attempt.submit(previousIDs: []) {
                        await remote.write()
                        await remote.invalidate()
                        return .init(fileID: "old-result")
                    }
                    return result()
                }
            }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await DriveTransferContext.$current.withValue(context) {
                try await coordinator.confirmedTransfer(cacheKey: "another") { _ in
                    await remote.write()
                    return result()
                }
            }
        }
        #expect(await remote.writes == 1)
    }

    @Test func identitiesIsolateAccountAndTargetWithoutRetainingSecrets() {
        let identity = DriveSavedFileNaming.identity(provider: .quark, pwdID: "share", fid: "file", name: "sample.mp4", size: 100)
        let a = DriveTransferContext.account(provider: .quark, cookie: "__uid=account-a; session=one")
        let b = DriveTransferContext.account(provider: .quark, cookie: "__uid=account-b; session=one")
        #expect(a == DriveTransferContext.account(provider: .quark, cookie: "__uid=account-a; session=two"))
        #expect(identity.scoped(account: a, target: "one").cacheKey != identity.scoped(account: b, target: "one").cacheKey)
        #expect(identity.scoped(account: a, target: "one").cacheKey != identity.scoped(account: a, target: "two").cacheKey)
        #expect(!a.contains("account-a"))
        #expect(DriveTransferContext.account(provider: .p115, cookie: "UID=115001_A1_first; SEID=one")
            == DriveTransferContext.account(provider: .p115, cookie: "uid=115001_A2_rotated; SEID=two"))
        #expect(DriveTransferContext.account(provider: .p115, cookie: "UID=115001_A1_first")
            != DriveTransferContext.account(provider: .p115, cookie: "UID=115002_A1_first"))
    }

    @Test @MainActor func pendingMessageDoesNotExposeRemoteDataOrPromisePlayback() {
        let text = UserFacingErrorPresenter.message(for: DriveEngineError.transferConfirmationPending(), context: .playback)
        let preparing = UserFacingErrorPresenter.message(for: DriveEngineError.officialPlayURLPending("private-file"), context: .playback)
        #expect(!preparing.contains("private-file"))
        #expect(text != preparing)
        #expect(!text.isEmpty)
        #expect(DriveEngineError.transferConfirmationPending().transferPhase == .outcomeUnknown)
        #expect(DriveEngineError.officialPlayURLPending("private-file").transferPhase == .playbackAddressPending)
        #expect(!DriveEngineError.invalidatesSavedRecord(DriveEngineError.transferConfirmationPending()))
    }
}
