#if DEBUG
import Foundation
import Testing
@testable import NetVplayerApp

@MainActor
private func replayBatchPlan(_ changes: [String: Any] = [:], count: Int = 3) throws -> DevelopmentAndroidAppAudit.Plan {
    var value: [String: Any] = ["config": "/fixture/config", "output": "/fixture/out", "only": ["original"],
        "providerExecutionPreference": "androidPreferred", "observeFullPlaybackWindow": true, "playbackSeconds": 45,
        "exactPlaybackBatch": (0..<count).map { ["vodID": "original-vod", "flag": "original-line",
            "episodeURLSHA256": String(format: "%064x", $0 + 1)] }]
    value.merge(changes) { _, new in new }
    return try JSONDecoder().decode(DevelopmentAndroidAppAudit.Plan.self, from: JSONSerialization.data(withJSONObject: value))
}

@MainActor
@Test func replayBatchPreservesOrderAndRequiresOneInitialAndOneRealHistoryPerIdentity() throws {
    let plan = try replayBatchPlan(count: 8)
    #expect(plan.usesSinglePlaybackAttempt)
    let members = try DevelopmentAndroidReplayBatchAudit.plans(from: plan)
    #expect(members.count == 8)
    for (index, member) in members.enumerated() {
        #expect(member.exactPlayback?.vodID == "original-vod")
        #expect(member.exactPlayback?.episodeURLSHA256 == String(format: "%064x", index + 1))
        #expect(member.exactPlaybackBatch == nil)
        #expect(member.singlePlaybackAttempt == true)
        #expect(member.sampleCount == 1 && member.allSelectedSamples == true && member.homeOnly == true)
        #expect(member.playbackContract?.reopen == true)
        #expect(member.playbackContract?.seekSeconds == nil && member.playbackContract?.nextEpisodes == nil)
    }
}

@MainActor
@Test func replayBatchIsExplicitAndRejectsEmptyOversizeOrUnboundFiles() throws {
    let plain = try replayBatchPlan(["exactPlaybackBatch": NSNull()])
    #expect(!plain.usesSinglePlaybackAttempt)
    #expect(try DevelopmentAndroidReplayBatchAudit.plans(from: plain).count == 1)
    for count in [0, 9] {
        let invalid = try replayBatchPlan(count: count)
        #expect(throws: DevelopmentAndroidReplayBatchAudit.Failure.invalidBatch) {
            try DevelopmentAndroidReplayBatchAudit.plans(from: invalid)
        }
    }
    let invalid = try replayBatchPlan(["exactPlaybackBatch": [["vodID": "vod", "flag": "line", "fileID": "unbound"]]])
    #expect(throws: DevelopmentAndroidReplayBatchAudit.Failure.invalidBatch) {
        try DevelopmentAndroidReplayBatchAudit.plans(from: invalid)
    }
}

@MainActor
@Test func replayBatchRejectsMixedScopesAndUnreservedActions() throws {
    let incompatible: [[String: Any]] = [
        ["only": ["one", "two"]], ["providerExecutionPreference": "macPreferred"],
        ["performanceReplays": 1], ["resumeFromSavedHistory": true],
        ["playbackContract": ["seekSeconds": [10]]], ["singlePlaybackAttempt": false],
        ["observeFullPlaybackWindow": false], ["playbackSeconds": 5],
        ["categoryID": "unplanned"], ["searchKeyword": "unplanned"],
        ["requestedQuality": "unplanned"], ["requestedMagnetFileIndex": 0],
        ["inventoryOnly": true], ["detailProbeID": "unplanned"],
        ["homeRevisits": ["refresh"]], ["categoryProbeWarmup": true]
    ]
    for changes in incompatible {
        let invalid = try replayBatchPlan(changes)
        #expect(throws: DevelopmentAndroidReplayBatchAudit.Failure.incompatiblePlan) {
            try DevelopmentAndroidReplayBatchAudit.plans(from: invalid)
        }
    }
}

@MainActor
@Test func replayBatchRejectsDuplicateIdentityAndPreservesFrozenVODAndLineChanges() throws {
    let hash = String(repeating: "a", count: 64)
    let original = ["vodID": "vod", "flag": "line", "episodeURLSHA256": hash]
    let duplicate = try replayBatchPlan(["exactPlaybackBatch": [original, original]])
    #expect(throws: DevelopmentAndroidReplayBatchAudit.Failure.duplicateIdentity) {
        try DevelopmentAndroidReplayBatchAudit.plans(from: duplicate)
    }
    var other = original; other["vodID"] = "other"
    let different = try replayBatchPlan(["exactPlaybackBatch": [original, other]])
    let members = try DevelopmentAndroidReplayBatchAudit.plans(from: different)
    #expect(members.map { $0.exactPlayback?.vodID } == ["vod", "other"])
    other = original; other["flag"] = "other-line"
    let separate = try replayBatchPlan(["exactPlaybackBatch": [original, other]])
    #expect(try DevelopmentAndroidReplayBatchAudit.plans(from: separate).count == 2)
}

@MainActor
@Test func replayBatchCannotContinueAfterOnlyInitialPlaybackOrAnUnverifiedHistoryEntry() {
    let action: [String: Any] = ["action": "history_resume", "playback_entry": "production_saved_history", "passed": true]
    var attempt: [String: Any] = ["status": "playback_progress", "playback_contract_passed": true, "playback_contract": [action]]
    #expect(DevelopmentAndroidReplayBatchAudit.completed(["attempts": [attempt]]))
    attempt.removeValue(forKey: "playback_contract")
    #expect(!DevelopmentAndroidReplayBatchAudit.completed(["attempts": [attempt]]))
    var wrong = action; wrong["playback_entry"] = "direct_reopen"
    attempt["playback_contract"] = [wrong]
    #expect(!DevelopmentAndroidReplayBatchAudit.completed(["attempts": [attempt]]))
    wrong = action; wrong["passed"] = false
    attempt["playback_contract"] = [wrong]
    #expect(!DevelopmentAndroidReplayBatchAudit.completed(["attempts": [attempt]]))
    #expect(!DevelopmentAndroidReplayBatchAudit.completed(["attempts": []]))
}
#endif
