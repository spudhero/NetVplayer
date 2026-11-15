import Foundation
import Models
import PlayerEngine

/// Opt-in actions on the real AppState/MPV session. A seek jump never satisfies
/// the progress gate; each action needs fresh continuous playback afterwards.
@MainActor
enum DevelopmentAndroidPlaybackContractAudit {
    struct Plan: Decodable {
        var seekSeconds: [Double]?
        var pauseResume: Bool?
        var reopen: Bool?
        var nextEpisodes: Int?
        var audioTracks: Bool?
    }

    static func run(_ plan: Plan, state: AppState, episode: Episode,
                    fullObservationSeconds: Double? = nil, observationTimeoutSeconds: Double = 80,
                    requiredOutput: DevelopmentAndroidAuditContract.RequiredOutput = .audioAndVideo) async -> [[String: Any]] {
        var records: [[String: Any]] = []
        let initial = state.playerState.currentSpec
        func finish() async -> [[String: Any]] {
            await state.cancelLoading()
            await MPVPlayerEngine.vod.stopAndWaitForRetirement()
            records.append(["action": "stop", "passed": !state.playerState.isPlaying && !state.playerState.isMediaLoading])
            return records
        }
        func observeAction(_ action: String, expected: PlaySpec?, target: Double? = nil) async -> [String: Any] {
            await observe(action, state: state, expected: expected, target: target,
                requiredSeconds: fullObservationSeconds, timeoutSeconds: observationTimeoutSeconds,
                requiredOutput: requiredOutput)
        }
        let consumer = UUID()
        state.playerState.setPlaybackInformationVisible(true, consumer: consumer)
        defer { state.playerState.setPlaybackInformationVisible(false, consumer: consumer) }
        if plan.pauseResume == true {
            MPVPlayerEngine.vod.pause()
            try? await Task.sleep(for: .seconds(1))
            let start = state.playerState.position
            try? await Task.sleep(for: .seconds(2))
            records.append(["action": "pause", "passed": !state.playerState.isPlaying && abs(state.playerState.position - start) < 0.2])
            MPVPlayerEngine.vod.resume()
            records.append(await observeAction("resume", expected: initial))
            guard records.last?["passed"] as? Bool == true, !Task.isCancelled else { return await finish() }
        }
        for target in (plan.seekSeconds ?? []).prefix(8) where target.isFinite && target >= 0 {
            guard target < state.playerState.duration - 6 else {
                records.append(["action": "seek", "target": target, "passed": false, "reason": "target_outside_duration"]); continue
            }
            MPVPlayerEngine.vod.seek(to: Int64(target * 1000))
            records.append(await observeAction("seek", expected: initial, target: target))
            guard records.last?["passed"] as? Bool == true, !Task.isCancelled else { return await finish() }
        }
        if plan.audioTracks == true {
            let tracks = state.playerState.audioTracks
            if tracks.count < 2 { records.append(["action": "audio_tracks", "passed": false, "reason": "fewer_than_two_tracks", "available": tracks.count]) }
            else {
                for track in tracks.prefix(3) {
                    MPVPlayerEngine.vod.selectAudioTrack(id: track.id)
                    var record = await observeAction("audio_track", expected: initial)
                    record["requested_id"] = track.id
                    record["selected_id"] = state.playerState.selectedAudioTrackID
                    record["passed"] = (record["passed"] as? Bool == true) && state.playerState.selectedAudioTrackID == track.id
                    records.append(record)
                    guard record["passed"] as? Bool == true, !Task.isCancelled else { return await finish() }
                }
            }
        }
        if plan.reopen == true {
            state.saveCurrentPlaybackProgress()
            await state.cancelLoading()
            await MPVPlayerEngine.vod.stopAndWaitForRetirement()
            let saved: History?
            if initial?.hostMagnet != nil {
                saved = state.historyItems.first {
                    $0.siteKey == initial?.siteKey && $0.vodId == initial?.metadata["vod.id"]
                }
            } else if let initial, let vodID = initial.metadata["vod.id"],
               let rawEpisode = initial.metadata["vod.episodeURL"] {
                saved = DevelopmentAndroidHistoryAudit.matchingHistory(state.historyItems,
                    siteKey: initial.siteKey, vodID: vodID,
                    detailRequestID: initial.metadata["vod.originalDetailRequestID"] ?? vodID,
                    flag: initial.flag, episodeURL: rawEpisode,
                    sourceFingerprint: initial.metadata["library.sourceFingerprint"] ?? "")
            } else { saved = nil }
            if let expectedFile = initial?.hostMagnet?.selectedFile?.identity {
                records.append(["action": "history_magnet_file", "passed": saved?.magnet == expectedFile,
                    "expected_file_index": expectedFile.fileIndex, "expected_file_length": expectedFile.length,
                    "saved_file_index": saved?.magnet?.fileIndex ?? -1,
                    "saved_file_length": saved?.magnet?.length ?? -1])
            }
            guard let saved else {
                records.append(["action": "history_record", "passed": false,
                    "failure_stage": "saved_history_missing_or_ambiguous"])
                return await finish()
            }
            await state.playHistory(saved)
            if let selection = state.pendingPlaybackSelection, let candidate = selection.candidates.first(where: \.isPlayable) {
                await state.selectPlaybackCandidate(candidate)
            }
            var resume = await observeAction("history_resume", expected: initial,
                target: Double(saved.position) / 1000)
            resume["playback_entry"] = "production_saved_history"
            resume["saved_history_position_ms"] = saved.position
            resume["saved_history_source_fingerprint"] = saved.sourceFingerprint
            records.append(resume)
            guard records.last?["passed"] as? Bool == true, !Task.isCancelled else { return await finish() }
        }
        for _ in 0..<min(3, max(0, plan.nextEpisodes ?? 0)) {
            guard let current = state.playerState.currentSpec?.metadata["vod.episodeURL"],
                  let index = state.episodes.firstIndex(where: { $0.url == current }), state.episodes.indices.contains(index + 1) else {
                records.append(["action": "next_episode", "passed": false, "reason": "no_next_episode"]); break
            }
            let next = state.episodes[index + 1]
            await state.playEpisode(next, resumePosition: 0, restartFromBeginning: true)
            if let selection = state.pendingPlaybackSelection, let candidate = selection.candidates.first(where: \.isPlayable) {
                await state.selectPlaybackCandidate(candidate)
            }
            var expected = initial
            expected?.metadata["vod.episodeURL"] = next.url
            expected?.hostMagnet = nil
            records.append(await observeAction("next_episode", expected: expected))
            guard records.last?["passed"] as? Bool == true, !Task.isCancelled else { return await finish() }
        }
        return await finish()
    }

    private static func sameEpisode(_ current: String?, _ expected: String?) -> Bool {
        guard let current, let expected else { return false }
        if current == expected { return true }
        guard let lhs = DevelopmentAndroidReplayAudit.Selection.stableIdentitySHA256(for: current),
              let rhs = DevelopmentAndroidReplayAudit.Selection.stableIdentitySHA256(for: expected) else { return false }
        return lhs == rhs
    }

    private static func observe(_ action: String, state: AppState, expected: PlaySpec?, target: Double? = nil,
                                requiredSeconds: Double?, timeoutSeconds: Double,
                                requiredOutput: DevelopmentAndroidAuditContract.RequiredOutput) async -> [String: Any] {
        let start = ProcessInfo.processInfo.systemUptime
        var progress = DevelopmentAndroidSampling.PlaybackProgress()
        var continuous = DevelopmentAndroidSampling.ContinuousPlaybackWindow(requiredSeconds: requiredSeconds ?? 5)
        var advanced = false
        var positions: [Double] = []
        var samples = [[String: Any]]()
        let deadline = start + (requiredSeconds.map { max($0, min(1200, timeoutSeconds)) } ?? 35)
        var landing = target.map { DevelopmentAndroidSampling.PlaybackTargetLanding(targetSeconds: $0) }
        var identityChanged = false
        func identityMatches() -> Bool {
            let spec = state.playerState.currentSpec
            return spec?.siteKey == expected?.siteKey && spec?.flag == expected?.flag
                && spec?.metadata["vod.id"] == expected?.metadata["vod.id"]
                && sameEpisode(spec?.metadata["vod.episodeURL"], expected?.metadata["vod.episodeURL"])
        }
        func sameMagnetFile() -> Bool {
            guard let file = expected?.hostMagnet?.selectedFile?.identity else { return true }
            let spec = state.playerState.currentSpec
            return spec?.hostMagnet?.selectedFile?.identity == file && spec?.mediaIdentity == file.mediaIdentity
        }
        func decoderReady() -> Bool {
            let p = state.playerState
            let d = p.playbackDiagnostics
            let video = (d?.video.width ?? 0) > 0 && (d?.video.height ?? 0) > 0 && !(d?.video.codec ?? "").isEmpty
            let audio = (d?.audio.outputSampleRate ?? 0) > 0 && (d?.audio.outputChannelCount ?? 0) > 0
                && !(d?.audio.codec ?? "").isEmpty && !(d?.audio.outputDriver ?? "").isEmpty
            return requiredOutput.accepts(audioDecoded: audio, videoDecoded: video,
                separateAudio: !(p.currentSpec?.externalAudioURL ?? "").isEmpty)
        }
        while ProcessInfo.processInfo.systemUptime < deadline && !Task.isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            let p = state.playerState
            positions.append(p.position.isFinite ? p.position : 0)
            let identity = identityMatches() && sameMagnetFile()
            let decoded = decoderReady()
            samples.append(["monotonic_seconds": now, "position": p.position.isFinite ? p.position : 0,
                "playing": p.isPlaying, "loading": p.isMediaLoading, "buffering": p.isBuffering,
                "seeking": p.isSeeking, "speed": p.speed, "decoder_ready": decoded, "identity_matches": identity])
            if p.currentSpec != nil && !identity { identityChanged = true; break }
            if landing != nil {
                _ = landing?.observe(position: p.position, settled: decoded && identity && p.isPlaying
                    && !p.isSeeking && !p.isMediaLoading && !p.isBuffering && p.speed == 1)
                if landing?.failed == true { break }
            }
            let targetReached = landing?.reached ?? true
            if requiredSeconds != nil {
                advanced = continuous.observe(time: now, position: p.position, playing: p.isPlaying,
                    loading: p.isMediaLoading, buffering: p.isBuffering, seeking: p.isSeeking,
                    speed: Double(p.speed), decoded: decoded, identityMatches: identity && targetReached)
                if advanced { break }
            } else if targetReached && !p.isSeeking && progress.observe(position: p.position,
                playing: p.isPlaying, loading: p.isMediaLoading, buffering: p.isBuffering) { advanced = true; break }
            if p.errorMessage != nil || state.isPlaybackErrorPresented
                || state.cloudAuthRequest != nil || state.playbackVerificationRequest != nil { break }
            try? await Task.sleep(for: .seconds(1))
        }
        let p = state.playerState
        let identity = identityMatches()
        let sameFile = sameMagnetFile()
        let decoded = decoderReady()
        var record: [String: Any] = ["action": action, "passed": advanced && identity && decoded && sameFile,
            "timeline_advanced": advanced, "identity_matches": identity, "decoder_confirmed": decoded,
            "positions_seconds": positions, "samples": samples,
            "full_observation_required": requiredSeconds != nil,
            "elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000]
        let authenticationRequired = state.cloudAuthRequest != nil
        let verificationRequired = state.playbackVerificationRequest != nil
        record["authentication_required"] = authenticationRequired
        record["verification_required"] = verificationRequired
        record["playback_error_presented"] = state.isPlaybackErrorPresented
        if let error = p.errorMessage { record["error"] = error }
        if verificationRequired {
            record["failure_stage"] = "playback_contract_verification_required"
        } else if authenticationRequired {
            record["failure_stage"] = "playback_contract_authentication_required"
        } else if p.errorMessage != nil || state.isPlaybackErrorPresented {
            record["failure_stage"] = "playback_contract_backend_error"
        }
        if let requiredSeconds {
            record["required_continuous_seconds"] = requiredSeconds
            record["continuous_playback_seconds"] = continuous.elapsedSeconds
            record["continuous_media_advanced_seconds"] = continuous.advancedSeconds
            record["continuous_sample_count"] = continuous.sampleCount
            record["observation_window_complete"] = continuous.complete
            if !advanced && !identityChanged && !Task.isCancelled && p.errorMessage == nil
                && !state.isPlaybackErrorPresented && state.cloudAuthRequest == nil
                && state.playbackVerificationRequest == nil && ProcessInfo.processInfo.systemUptime >= deadline {
                record["failure_stage"] = "playback_contract_observation_timeout"
            }
        }
        if identityChanged { record["failure_stage"] = "playback_context_changed" }
        if let file = expected?.hostMagnet?.selectedFile?.identity {
            record["magnet_file_identity_matches"] = sameFile
            record["expected_file_index"] = file.fileIndex
            record["selected_file_index"] = p.currentSpec?.hostMagnet?.selectedFile?.identity.fileIndex ?? -1
        }
        if let landing {
            record["target_seconds"] = landing.targetSeconds
            record["target_tolerance_seconds"] = landing.toleranceSeconds
            record["target_reached"] = landing.reached
            record["target_first_settled_position"] = landing.firstSettledPosition
            record["target_landing_method"] = "first_settled_decoded_position"
            if landing.failed { record["failure_stage"] = "playback_target_not_restored" }
        }
        return record
    }
}
