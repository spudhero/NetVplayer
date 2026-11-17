import Foundation
import Storage
import Testing
@testable import PlayerEngine

@Suite @MainActor struct SystemHDRControllerTests {
    @Test func repeatedDecoderUpdatesDoNotEnumerateStableDisplays() {
        let fixture = HDRFixture()
        let controller = SystemHDRController(coordinator: fixture.controller, ownHDMIHog: { 0 })
        let owner = UUID()
        for _ in 0..<120 {
            #expect(controller.update(ownerID: owner, displayID: 10, wantsHDR: false) == .inactive)
        }
        #expect(fixture.backend.readCount == 1)
        #expect(!fixture.controller.hasWork)
        fixture.backend.replace(enabled: true)
        controller.displayConfigurationDidChange()
        #expect(controller.observedHDR(forDisplayID: 10) == true)
        #expect(fixture.backend.readCount == 2)
        #expect(fixture.backend.writes.isEmpty)
    }

    @Test func stableHDRLeaseStopsPollingAndDisplayEventStillRevokesOwnership() {
        let fixture = HDRFixture()
        let owner = UUID()
        _ = fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true)
        #expect(fixture.controller.hasWork)
        fixture.controller.refresh()
        #expect(!fixture.controller.hasWork)
        fixture.backend.replace(enabled: false)
        fixture.controller.refresh()
        #expect(fixture.controller.status(ownerID: owner) == .userOverride)
        #expect(!fixture.controller.hasWork)
        fixture.controller.release(ownerID: owner)
        #expect(fixture.backend.writes.map(\.enabled) == [true])
    }

    private var hdrVideo: PlaybackDiagnostics.Video {
        PlaybackDiagnostics(mediaID: UUID(), properties: [
            "video-dec-params": Data(#"{"gamma":"pq"}"#.utf8)
        ]).video
    }

    @Test func followSystemNeitherEnablesNorOwnsAnAlreadyEnabledDisplay() {
        for initiallyEnabled in [false, true] {
            let fixture = HDRFixture(enabled: initiallyEnabled)
            let owner = UUID()
            let wantsHDR = PlaybackVideoOutputPolicy.requestsSystemHDR(mode: .automatic, video: hdrVideo)
            #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: wantsHDR) == .inactive)
            #expect(fixture.controller.observedHDR(forDisplayID: 10) == initiallyEnabled)
            fixture.controller.release(ownerID: owner)
            fixture.controller.restoreAll()
            #expect(fixture.backend.writes.isEmpty)
            #expect(fixture.journal.records.isEmpty)
            #expect(fixture.controller.observedHDR(forDisplayID: 10) == initiallyEnabled)
        }
    }

    @Test func inactiveUpdatesReadDisplaysOnceAndUnownedReleaseDoesNotRead() {
        let fixture = HDRFixture()
        let owner = UUID()

        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: false) == .inactive)
        #expect(fixture.backend.readCount == 1)
        fixture.backend.replace(enabled: true)
        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: false) == .inactive)
        #expect(fixture.backend.readCount == 2)
        #expect(fixture.controller.observedHDR(forDisplayID: 10) == true)

        fixture.controller.release(ownerID: owner)
        #expect(fixture.backend.readCount == 2)
        #expect(fixture.backend.writes.isEmpty)
    }

    @Test func leavingTemporaryHDRUsesOneReadAndStillRestoresTheDisplay() {
        let fixture = HDRFixture()
        let owner = UUID()
        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true) == .requesting)
        #expect(fixture.backend.readCount == 1)
        fixture.controller.refresh()
        let reads = fixture.backend.readCount

        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: false) == .inactive)
        #expect(fixture.backend.readCount == reads + 1)
        #expect(fixture.backend.writes.map(\.enabled) == [true, false])
        fixture.controller.refresh()
        #expect(fixture.journal.records.isEmpty)
    }

    @Test func leavingTemporaryModeRestoresOnlyAfterOtherTemporaryOwnersRelease() {
        let fixture = HDRFixture()
        let first = UUID(), second = UUID()
        let temporary = PlaybackVideoOutputPolicy.requestsSystemHDR(mode: .hdrIfAvailable, video: hdrVideo)
        #expect(temporary)
        _ = fixture.controller.update(ownerID: first, displayID: 10, wantsHDR: temporary)
        fixture.controller.refresh()
        _ = fixture.controller.update(ownerID: second, displayID: 10, wantsHDR: temporary)
        // Changing one window to automatic relinquishes only its own lease.
        _ = fixture.controller.update(ownerID: first, displayID: 10,
            wantsHDR: PlaybackVideoOutputPolicy.requestsSystemHDR(mode: .automatic, video: hdrVideo))
        #expect(fixture.backend.writes.map(\.enabled) == [true])
        _ = fixture.controller.update(ownerID: second, displayID: 10,
            wantsHDR: PlaybackVideoOutputPolicy.requestsSystemHDR(mode: .automatic, video: hdrVideo))
        fixture.controller.refresh()
        #expect(fixture.backend.writes.map(\.enabled) == [true, false])
        #expect(fixture.journal.records.isEmpty)
    }

    @Test func temporaryEnableRestoresOnlyAfterLastWindowCloses() {
        let fixture = HDRFixture()
        let first = UUID(), second = UUID()
        #expect(fixture.controller.update(ownerID: first, displayID: 10, wantsHDR: true) == .requesting)
        fixture.controller.refresh()
        #expect(fixture.controller.status(ownerID: first) == .enabledTemporarily)
        #expect(fixture.controller.update(ownerID: second, displayID: 10, wantsHDR: true) == .enabledTemporarily)
        #expect(fixture.backend.writes.map(\.enabled) == [true])
        #expect(fixture.journal.records.count == 1)
        fixture.controller.release(ownerID: first)
        #expect(fixture.backend.writes.map(\.enabled) == [true])
        fixture.controller.release(ownerID: second)
        fixture.controller.refresh()
        #expect(fixture.backend.writes.map(\.enabled) == [true, false])
        #expect(fixture.journal.records.isEmpty)
    }

    @Test func existingHDRAndBuiltInEDRAreNeverOwnedOrTurnedOff() {
        let fixture = HDRFixture(enabled: true)
        let owner = UUID()
        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true) == .alreadyEnabled)
        fixture.controller.restoreAll()
        #expect(fixture.backend.writes.isEmpty)
        #expect(fixture.journal.records.isEmpty)
        fixture.backend.replace(builtin: true)
        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true) == .nativeEDR)
        fixture.controller.restoreAll()
        #expect(fixture.backend.writes.isEmpty)
    }

    @Test func unsupportedDisplayAndReadFailuresNeverWrite() {
        let fixture = HDRFixture()
        let owner = UUID()
        fixture.backend.replace(supported: false)
        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true) == .unavailable)
        fixture.backend.readFails = true
        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true) == .unavailable)
        fixture.controller.restoreAll()
        #expect(fixture.backend.writes.isEmpty)
    }

    @Test func manualDisableRevokesOwnershipForTheWholePlayback() {
        let fixture = HDRFixture()
        let owner = UUID()
        _ = fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true)
        fixture.controller.refresh()
        fixture.backend.replace(enabled: false)
        fixture.controller.refresh()
        #expect(fixture.controller.status(ownerID: owner) == .userOverride)
        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true) == .userOverride)
        fixture.controller.release(ownerID: owner)
        #expect(fixture.backend.writes.map(\.enabled) == [true])
        #expect(fixture.journal.records.isEmpty)
    }

    @Test func manualModeChangePreventsRestoringAcrossTheNewMode() {
        let fixture = HDRFixture()
        let owner = UUID()
        _ = fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true)
        fixture.controller.refresh()
        fixture.backend.replace(fingerprint: "1920x1080:60Hz")
        fixture.controller.refresh()
        fixture.controller.release(ownerID: owner)
        #expect(fixture.backend.writes.map(\.enabled) == [true])
        #expect(fixture.journal.records.isEmpty)
    }

    @Test func asynchronousAudioPreflightCannotResurrectAClosedWindow() {
        let fixture = HDRFixture()
        let owner = UUID()
        var ready = false
        fixture.controller.prepareForDisplayChange = { _ in ready }
        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true) == .waitingForAudio)
        #expect(fixture.backend.writes.isEmpty)
        fixture.controller.release(ownerID: owner)
        ready = true
        fixture.controller.refresh()
        #expect(fixture.backend.writes.isEmpty)
    }

    @Test func preflightRechecksOwnersAfterSynchronousRelease() {
        let fixture = HDRFixture()
        let owner = UUID()
        fixture.controller.prepareForDisplayChange = { [weak controller = fixture.controller] _ in
            controller?.release(ownerID: owner)
            return true
        }
        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true) == .inactive)
        #expect(fixture.backend.writes.isEmpty)
    }

    @Test func activationTimeoutUsesMonotonicTimeAndDoesNotRetryTheSetter() {
        let fixture = HDRFixture()
        fixture.backend.applyWrites = false
        var wallClock = Date(timeIntervalSince1970: 100)
        var uptime = 0.0
        let controller = SystemHDRLeaseCoordinator(backend: fixture.backend, journal: fixture.journal,
            now: { wallClock }, uptime: { uptime })
        let owner = UUID()
        _ = controller.update(ownerID: owner, displayID: 10, wantsHDR: true)
        wallClock.addTimeInterval(86_400)
        uptime = 1
        controller.refresh()
        #expect(controller.status(ownerID: owner) == .requesting)
        uptime = 4.1
        controller.refresh()
        #expect(controller.status(ownerID: owner) == .failed)
        controller.refresh()
        #expect(fixture.backend.writes.map(\.enabled) == [true])
    }

    @Test func closeDuringEnableWaitsForTheInFlightRequestBeforeRestore() {
        let fixture = HDRFixture()
        fixture.backend.applyWrites = false
        let owner = UUID()
        _ = fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true)
        fixture.controller.release(ownerID: owner)
        fixture.controller.refresh()
        #expect(fixture.backend.writes.map(\.enabled) == [true])
        fixture.backend.replace(enabled: true)
        fixture.controller.refresh()
        #expect(fixture.backend.writes.map(\.enabled) == [true, false])
        fixture.backend.replace(enabled: false)
        fixture.controller.refresh()
        #expect(fixture.journal.records.isEmpty)
    }

    @Test func changingScreensRestoresTheOldDisplayWithoutOwningTheNewOnState() {
        let fixture = HDRFixture()
        let owner = UUID(), otherUUID = UUID()
        fixture.backend.states.append(.init(displayID: 20, displayUUID: otherUUID, supportsHDR: true,
            prefersHDR: true, isBuiltin: false, configurationFingerprint: "4K:60Hz"))
        _ = fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true)
        fixture.controller.refresh()
        #expect(fixture.controller.update(ownerID: owner, displayID: 20, wantsHDR: true) == .alreadyEnabled)
        fixture.controller.restoreAll()
        #expect(fixture.backend.writes.map(\.enabled) == [true, false])
        #expect(fixture.backend.writes.allSatisfy { $0.uuid == fixture.uuid })
    }

    @Test func unplugAndReusedDisplayIDCannotRestoreTheWrongMonitor() {
        let fixture = HDRFixture()
        let owner = UUID()
        _ = fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true)
        fixture.controller.refresh()
        let replacement = UUID()
        fixture.backend.states = [.init(displayID: 10, displayUUID: replacement, supportsHDR: true,
            prefersHDR: true, isBuiltin: false, configurationFingerprint: "4K:60Hz")]
        fixture.controller.refresh()
        fixture.controller.release(ownerID: owner)
        #expect(fixture.backend.writes.map(\.enabled) == [true])
        #expect(fixture.controller.pendingRecovery.map(\.displayUUID) == [fixture.uuid])
        #expect(!fixture.controller.restoreInterruptedChange(displayUUID: fixture.uuid))
        #expect(fixture.backend.writes.allSatisfy { $0.uuid != replacement })
    }

    @Test func crashJournalRequiresExplicitRecoveryAndSurvivesNewUserOnPreference() {
        let uuid = UUID()
        let journal = HDRMemoryJournal(records: [.init(displayUUID: uuid, originalHDR: false,
            configurationFingerprint: "4K:60Hz", createdAt: Date())])
        let fixture = HDRFixture(uuid: uuid, enabled: true, journal: journal)
        fixture.controller.refresh()
        #expect(fixture.backend.writes.isEmpty)
        #expect(fixture.controller.pendingRecovery.count == 1)
        let owner = UUID()
        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true) == .alreadyEnabled)
        fixture.controller.release(ownerID: owner)
        #expect(fixture.backend.writes.isEmpty)
        #expect(fixture.controller.restoreInterruptedChange(displayUUID: uuid))
        fixture.controller.refresh()
        #expect(fixture.backend.writes.map(\.enabled) == [false])
        #expect(fixture.controller.pendingRecovery.isEmpty)
        #expect(journal.records.isEmpty)
    }

    @Test func oldCrashRecordIsDiscardedIfUserAlreadyDisabledOrChangedMode() {
        for changedMode in [false, true] {
            let uuid = UUID()
            let journal = HDRMemoryJournal(records: [.init(displayUUID: uuid, originalHDR: false,
                configurationFingerprint: "4K:60Hz", createdAt: Date())])
            let fixture = HDRFixture(uuid: uuid, enabled: changedMode, journal: journal)
            if changedMode { fixture.backend.replace(fingerprint: "4K:30Hz") }
            fixture.controller.refresh()
            #expect(fixture.controller.pendingRecovery.isEmpty)
            #expect(fixture.backend.writes.isEmpty)
        }
    }

    @Test func failedJournalWritePreventsEnablingSystemHDR() {
        let fixture = HDRFixture()
        fixture.journal.saveFails = true
        #expect(fixture.controller.update(ownerID: UUID(), displayID: 10, wantsHDR: true) == .failed)
        #expect(fixture.backend.writes.isEmpty)
    }

    @Test func partiallyAppliedPrivateSetterIsPreservedForExplicitRecovery() {
        let fixture = HDRFixture()
        fixture.backend.failAfterApplying = true
        let owner = UUID()
        #expect(fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true) == .failed)
        fixture.controller.release(ownerID: owner)
        fixture.controller.refresh()
        #expect(fixture.backend.writes.map(\.enabled) == [true])
        #expect(fixture.controller.pendingRecovery.count == 1)
        fixture.backend.failAfterApplying = false
        #expect(fixture.controller.restoreInterruptedChange(displayUUID: fixture.uuid))
        fixture.controller.refresh()
        #expect(fixture.backend.writes.map(\.enabled) == [true, false])
    }

    @Test func failedReadDoesNotRestoreFromStalePreference() {
        let fixture = HDRFixture()
        let owner = UUID()
        _ = fixture.controller.update(ownerID: owner, displayID: 10, wantsHDR: true)
        fixture.controller.refresh()
        fixture.backend.readFails = true
        fixture.controller.release(ownerID: owner)
        fixture.controller.refresh()
        #expect(fixture.backend.writes.map(\.enabled) == [true])
        fixture.backend.readFails = false
        fixture.controller.refresh()
        #expect(fixture.backend.writes.map(\.enabled) == [true, false])
    }

    @Test func asyncPreparationFinishesAudioCleanupWhenPlaybackClosesBeforeItCompletes() async {
        let fixture = HDRFixture()
        let controller = SystemHDRController(coordinator: fixture.controller, ownHDMIHog: { 0 })
        let owner = UUID()
        var resume: CheckedContinuation<Bool, Never>?
        var finished: [Bool] = []
        controller.prepareForDisplayChange = { _ in await withCheckedContinuation { resume = $0 } }
        controller.didFinishDisplayChange = { _, success in finished.append(success) }
        _ = controller.update(ownerID: owner, displayID: 10, wantsHDR: true)
        let preparing = await HDRWait.until { resume != nil }
        #expect(preparing)
        controller.release(ownerID: owner)
        resume?.resume(returning: true)
        await controller.restoreAll()
        #expect(fixture.backend.writes.isEmpty)
        #expect(finished == [false])
    }

    @Test func unknownHogReadCancelsTheSetterAndStillRestoresAudio() async {
        let fixture = HDRFixture()
        let controller = SystemHDRController(coordinator: fixture.controller, ownHDMIHog: { -1 })
        var finished: [Bool] = []
        controller.prepareForDisplayChange = { _ in true }
        controller.didFinishDisplayChange = { _, success in finished.append(success) }
        _ = controller.update(ownerID: UUID(), displayID: 10, wantsHDR: true)
        let settled = await HDRWait.until { !controller.isChangingDisplay }
        #expect(settled)
        #expect(fixture.backend.writes.isEmpty)
        #expect(finished == [false])
    }

    @Test func manualPreferenceDuringAsyncPreparationIsRecheckedBeforeWriting() async {
        let fixture = HDRFixture()
        let controller = SystemHDRController(coordinator: fixture.controller, ownHDMIHog: { 0 })
        let owner = UUID()
        var resume: CheckedContinuation<Bool, Never>?
        controller.prepareForDisplayChange = { _ in await withCheckedContinuation { resume = $0 } }
        _ = controller.update(ownerID: owner, displayID: 10, wantsHDR: true)
        let preparing = await HDRWait.until { resume != nil }
        #expect(preparing)
        fixture.backend.replace(enabled: true)
        controller.displayConfigurationDidChange()
        resume?.resume(returning: true)
        let settled = await HDRWait.until { !controller.isChangingDisplay }
        #expect(settled)
        controller.release(ownerID: owner)
        #expect(fixture.backend.writes.isEmpty)
        #expect(fixture.journal.records.isEmpty)
    }

    @Test func asyncTerminationWaitsForRestoreAndPreventsNewLeases() async {
        let fixture = HDRFixture()
        let controller = SystemHDRController(coordinator: fixture.controller, ownHDMIHog: { 0 })
        let owner = UUID()
        var finished: [Bool] = []
        controller.didFinishDisplayChange = { _, success in finished.append(success) }
        _ = controller.update(ownerID: owner, displayID: 10, wantsHDR: true)
        let enabled = await HDRWait.until { !controller.isChangingDisplay }
        #expect(enabled)
        #expect(fixture.backend.writes.map(\.enabled) == [true])
        await controller.restoreForTermination()
        #expect(fixture.backend.writes.map(\.enabled) == [true, false])
        #expect(fixture.journal.records.isEmpty)
        #expect(finished == [true, true])
        #expect(controller.update(ownerID: owner, displayID: 10, wantsHDR: true) == .inactive)
        #expect(fixture.backend.writes.map(\.enabled) == [true, false])
    }

    @Test func separateDisplaysSerializePrepareWriteSettleAndAudioFinish() async {
        let fixture = HDRFixture()
        fixture.backend.states.append(.init(displayID: 20, displayUUID: UUID(), supportsHDR: true,
            prefersHDR: false, isBuiltin: false, configurationFingerprint: "4K:60Hz"))
        let controller = SystemHDRController(coordinator: fixture.controller, ownHDMIHog: { 0 })
        var trace: [String] = []
        controller.prepareForDisplayChange = { transition in
            trace.append("prepare-\(transition.displayID)")
            await Task.yield()
            return true
        }
        controller.didFinishDisplayChange = { transition, success in
            #expect(success)
            trace.append("finish-\(transition.displayID)")
        }
        _ = controller.update(ownerID: UUID(), displayID: 10, wantsHDR: true)
        _ = controller.update(ownerID: UUID(), displayID: 20, wantsHDR: true)
        let settled = await HDRWait.until { !controller.isChangingDisplay && trace.count == 4 }
        #expect(settled)
        #expect(trace == ["prepare-10", "finish-10", "prepare-20", "finish-20"])
        #expect(fixture.backend.writes.count == 2)
        await controller.restoreAll()
        #expect(fixture.journal.records.isEmpty)
    }
}

@MainActor private enum HDRWait {
    static func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor private final class HDRFixture {
    let uuid: UUID
    let backend: HDRFakeDisplayBackend
    let journal: HDRMemoryJournal
    let controller: SystemHDRLeaseCoordinator
    init(uuid: UUID = UUID(), enabled: Bool = false, journal: HDRMemoryJournal? = nil) {
        self.uuid = uuid
        backend = HDRFakeDisplayBackend(state: .init(displayID: 10, displayUUID: uuid, supportsHDR: true,
            prefersHDR: enabled, isBuiltin: false, configurationFingerprint: "4K:60Hz"))
        self.journal = journal ?? HDRMemoryJournal()
        controller = SystemHDRLeaseCoordinator(backend: backend, journal: self.journal)
    }
}

@MainActor private final class HDRFakeDisplayBackend: SystemHDRDisplayBackend {
    struct Write { let uuid: UUID; let enabled: Bool }
    var states: [SystemHDRDisplaySnapshot]
    var writes: [Write] = []
    var readCount = 0
    var readFails = false
    var applyWrites = true
    var failAfterApplying = false
    init(state: SystemHDRDisplaySnapshot) { states = [state] }
    func displays() throws -> [SystemHDRDisplaySnapshot] {
        readCount += 1
        if readFails { throw HDRTestFailure.expected }
        return states
    }
    func setHDR(_ enabled: Bool, displayUUID: UUID) throws {
        writes.append(.init(uuid: displayUUID, enabled: enabled))
        if applyWrites, let index = states.firstIndex(where: { $0.displayUUID == displayUUID }) {
            let old = states[index]
            states[index] = .init(displayID: old.displayID, displayUUID: old.displayUUID,
                supportsHDR: old.supportsHDR, prefersHDR: enabled, isBuiltin: old.isBuiltin,
                configurationFingerprint: old.configurationFingerprint)
        }
        if failAfterApplying { throw HDRTestFailure.expected }
    }
    func replace(enabled: Bool? = nil, supported: Bool? = nil, builtin: Bool? = nil, fingerprint: String? = nil) {
        let old = states[0]
        states[0] = .init(displayID: old.displayID, displayUUID: old.displayUUID,
            supportsHDR: supported ?? old.supportsHDR, prefersHDR: enabled ?? old.prefersHDR,
            isBuiltin: builtin ?? old.isBuiltin, configurationFingerprint: fingerprint ?? old.configurationFingerprint)
    }
}

@MainActor private final class HDRMemoryJournal: SystemHDRJournal {
    var records: [SystemHDRInterruptedChange]
    var saveFails = false
    init(records: [SystemHDRInterruptedChange] = []) { self.records = records }
    func load() throws -> [SystemHDRInterruptedChange] { records }
    func save(_ records: [SystemHDRInterruptedChange]) throws {
        if saveFails { throw HDRTestFailure.expected }
        self.records = records
    }
}

private enum HDRTestFailure: Error { case expected }
