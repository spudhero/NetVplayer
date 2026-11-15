import Foundation

/// A bounded sequence of ordinary initial/history pairs in one frozen original source session.
@MainActor
enum DevelopmentAndroidReplayBatchAudit {
    enum Failure: String, Error { case invalidBatch, incompatiblePlan, duplicateIdentity }

    static func plans(from plan: DevelopmentAndroidAppAudit.Plan) throws -> [DevelopmentAndroidAppAudit.Plan] {
        guard let selections = plan.exactPlaybackBatch else { return [plan] }
        guard (1...8).contains(selections.count), selections.allSatisfy({ $0.isValid && $0.episodeURLSHA256 != nil }) else {
            throw Failure.invalidBatch
        }
        guard plan.only?.count == 1, plan.providerExecutionPreference == .androidPreferred,
              plan.exactPlayback == nil, plan.performanceReplayCount == 0,
              plan.resumeFromSavedHistory != true, plan.expectedHistorySHA256 == nil,
              plan.playbackContract == nil, plan.attachmentContract == nil,
              plan.categoryID == nil, plan.searchKeyword == nil, plan.sampleVodID == nil,
              plan.categoryProbeID == nil, plan.detailProbeID == nil, plan.categoryProbeWarmup != true,
              plan.homeRevisits?.isEmpty != false,
              plan.requestedPlayFlag == nil, plan.requestedQuality == nil, plan.requestedMagnetFileIndex == nil,
              plan.inventoryOnly != true, plan.singlePlaybackAttempt != false,
              plan.observeFullPlaybackWindow == true, plan.playbackSeconds == 45 else {
            throw Failure.incompatiblePlan
        }
        let identities = selections.map { [$0.vodID, $0.flag, $0.episodeURLSHA256!].joined(separator: "\u{0}") }
        guard Set(identities).count == identities.count else { throw Failure.duplicateIdentity }
        return selections.map { selection in
            var member = plan
            member.exactPlaybackBatch = nil
            member.exactPlayback = selection
            member.singlePlaybackAttempt = true
            member.sampleCount = 1
            member.allSelectedSamples = true
            member.homeOnly = true
            member.playbackContract = .init(reopen: true)
            return member
        }
    }

    static func completed(_ result: [String: Any]) -> Bool {
        guard let attempts = result["attempts"] as? [[String: Any]], attempts.count == 1 else { return false }
        let attempt = attempts[0]
        guard attempt["status"] as? String == "playback_progress",
              attempt["playback_contract_passed"] as? Bool == true,
              let actions = attempt["playback_contract"] as? [[String: Any]] else { return false }
        return actions.contains { $0["action"] as? String == "history_resume"
            && $0["playback_entry"] as? String == "production_saved_history"
            && $0["passed"] as? Bool == true }
    }
}
