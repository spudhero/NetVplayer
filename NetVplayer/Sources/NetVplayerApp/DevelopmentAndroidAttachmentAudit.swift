import Foundation
import CryptoKit
import Models
import PlayerEngine

@MainActor
enum DevelopmentAndroidAttachmentAudit {
    struct Plan: Decodable {
        var seekSeconds: [Double]?
        var nextEpisode: Bool?
        var requireSubtitles: Bool?
        var danmaku: Bool?
        var visualHoldSeconds: Int?
    }

    static func run(_ plan: Plan, state: AppState) async -> [[String: Any]] {
        var records: [[String: Any]] = []
        let engine = MPVPlayerEngine.vod
        let player = state.playerState
        let initial = player.currentSpec
        for _ in 0..<30 {
            if !player.subtitleTracks.isEmpty && player.selectedSubtitleTrackID != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        records.append(["action": "attachment_inventory", "passed": !player.subtitleTracks.isEmpty || (plan.danmaku == true && plan.requireSubtitles == false && !(initial?.providerDanmaku.isEmpty ?? true)),
            "applicable": !player.subtitleTracks.isEmpty || (plan.danmaku == true && !(initial?.providerDanmaku.isEmpty ?? true)),
            "sources": initial?.subs.map { ["url_sha256": hash($0.url), "name_sha256": hash($0.name), "language": $0.lang, "format": $0.format, "flag": $0.flag] } ?? [],
            "tracks": player.subtitleTracks.map { ["id": $0.id, "name_sha256": hash($0.name), "language": $0.language, "format": $0.format, "external": $0.isExternal] },
            "default_selected_id": player.selectedSubtitleTrackID ?? "",
            "provider_danmaku_count": initial?.providerDanmaku.count ?? 0])
        if !player.subtitleTracks.isEmpty {
            records.append(await observeCue("default_timing", state: state, seconds: 4))
            let tracks = Array(player.subtitleTracks.prefix(3))
            for track in tracks {
                engine.selectSubtitleTrack(id: track.id)
                try? await Task.sleep(for: .milliseconds(500))
                records.append(["action": "subtitle_select", "requested_id": track.id,
                    "passed": engine.subtitleTimingObservation().selectedID == track.id])
            }
            if let first = tracks.first { engine.selectSubtitleTrack(id: first.id) }
            for target in (plan.seekSeconds ?? [30]).prefix(3) where target >= 0 && target < player.duration - 5 {
                engine.seek(to: Int64(target * 1000))
                try? await Task.sleep(for: .seconds(1))
                var record = await observeCue("subtitle_seek_timing", state: state, seconds: 5)
                record["target_seconds"] = target
                records.append(record)
            }
            let visualHold = min(60, max(0, plan.visualHoldSeconds ?? 0))
            if visualHold > 0 {
                engine.pause()
                await visualPause("subtitle_selected", seconds: visualHold, state: state)
            }
            engine.disableSubtitle()
            try? await Task.sleep(for: .seconds(2))
            records.append(["action": "subtitle_disable", "passed": engine.subtitleTimingObservation().selectedID == nil
                && player.selectedSubtitleTrackID == nil])
            if visualHold > 0 {
                await visualPause("subtitle_disabled", seconds: visualHold, state: state)
                engine.resume()
            }
            if plan.nextEpisode == true, let raw = initial?.metadata["vod.episodeURL"],
               let index = state.episodes.firstIndex(where: { $0.url == raw }), state.episodes.indices.contains(index + 1) {
                let next = state.episodes[index + 1]
                await state.playEpisode(next, resumePosition: 0, restartFromBeginning: true)
                if let selection = state.pendingPlaybackSelection, let candidate = selection.candidates.first(where: \.isPlayable) {
                    await state.selectPlaybackCandidate(candidate)
                }
                var progress = DevelopmentAndroidSampling.PlaybackProgress()
                var advanced = false
                for _ in 0..<35 {
                    if player.currentSpec?.metadata["vod.episodeURL"] == next.url,
                       progress.observe(position: player.position, playing: player.isPlaying,
                        loading: player.isMediaLoading, buffering: player.isBuffering) { advanced = true; break }
                    if !player.isMediaLoading, player.errorMessage != nil { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                records.append(["action": "next_episode_disabled", "passed": advanced && player.currentSpec?.metadata["vod.episodeURL"] == next.url
                    && engine.subtitleTimingObservation().selectedID == nil,
                    "progress": advanced, "episode_sha256": hash(next.url), "tracks": player.subtitleTracks.count,
                    "expected_episode_active": player.currentSpec?.metadata["vod.episodeURL"] == next.url,
                    "player_error_present": player.errorMessage != nil,
                    "actual_episode_sha256": hash(player.currentSpec?.metadata["vod.episodeURL"] ?? ""),
                    "native_selected_id": engine.subtitleTimingObservation().selectedID ?? "",
                    "state_selected_id": player.selectedSubtitleTrackID ?? "",
                    "initial_scope_sha256": hash(initial?.metadata["vod.id"] ?? ""),
                    "next_scope_sha256": hash(player.currentSpec?.metadata["vod.id"] ?? "")])
                if advanced, player.currentSpec?.metadata["vod.episodeURL"] == next.url, let track = player.subtitleTracks.first {
                    engine.selectSubtitleTrack(id: track.id)
                    engine.seek(to: 30_000)
                    try? await Task.sleep(for: .seconds(1))
                    records.append(await observeCue("next_episode_timing", state: state, seconds: 5))
                }
            }
        }
        if plan.danmaku == true {
            state.setDanmakuRenderingEnabled(true)
            for _ in 0..<150 {
                if !state.currentDanmakuCues.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            records.append(["action": "provider_danmaku", "passed": !state.currentDanmakuCues.isEmpty && state.selectedProviderDanmakuIndex == 0,
                "cues": state.currentDanmakuCues.count, "selected_index": state.selectedProviderDanmakuIndex ?? -1])
            for index in Array((player.currentSpec?.providerDanmaku.indices ?? 0..<0).prefix(3)) {
                await state.selectProviderDanmakuTrack(at: index)
                records.append(["action": "provider_danmaku_select", "requested_index": index,
                    "passed": state.selectedProviderDanmakuIndex == index && !state.currentDanmakuCues.isEmpty,
                    "cues": state.currentDanmakuCues.count,
                    "first_cue_ms": state.currentDanmakuCues.first?.timeMs ?? -1])
            }
            state.setDanmakuRenderingEnabled(false)
            try? await Task.sleep(for: .seconds(1))
            records.append(["action": "danmaku_disable", "passed": state.currentDanmakuCues.isEmpty])
        }
        return records
    }

    private static func visualPause(_ phase: String, seconds: Int, state: AppState) async {
        if let output = DevelopmentAndroidAppAudit.current?.output {
            let value: [String: Any] = ["phase": phase, "position": state.playerState.position,
                                       "selected_id": state.playerState.selectedSubtitleTrackID ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: value) {
                try? data.write(to: URL(fileURLWithPath: output).appendingPathComponent("attachment-visual-phase.json"), options: .atomic)
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func observeCue(_ action: String, state: AppState, seconds: Int) async -> [String: Any] {
        if let selected = state.playerState.subtitleTracks.first(where: { $0.id == state.playerState.selectedSubtitleTrackID }), selected.subtitleKind == .bitmap {
            return ["action": action, "passed": false, "status": "bitmap_requires_visual_observation",
                    "measurement": "sub_text_is_not_a_bitmap_rendering_or_sync_assertion", "samples": []]
        }
        var samples: [[String: Any]] = []
        var valid = 0
        for _ in 0..<(seconds * 4) {
            let observation = MPVPlayerEngine.vod.subtitleTimingObservation()
            let position = state.playerState.position - state.playerState.subtitleDelaySeconds
            if !observation.text.isEmpty, let start = observation.start, let end = observation.end,
               start.isFinite, end.isFinite, position.isFinite {
                let aligned = observation.selectedID != nil && position >= start - 0.75 && position <= end + 0.75
                if aligned { valid += 1 }
                samples.append(["position": position, "cue_start": start, "cue_end": end,
                    "text_sha256": hash(observation.text), "aligned": aligned])
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return ["action": action, "passed": valid >= 2 && valid == samples.count, "samples": samples,
            "status": samples.isEmpty ? "no_cue_in_observation_window" : valid == samples.count ? "aligned" : "misaligned",
            "measurement": "active_mpv_sub_text_and_time_bounds_not_visual_assertion"]
    }

    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}
