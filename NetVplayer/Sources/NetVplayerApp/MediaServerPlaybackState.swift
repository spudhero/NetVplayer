import Models
import PlayerEngine
import MediaServerEngine

extension AppState {
    func mediaServerSnapshot() -> MediaServerPlaybackSnapshot {
        let audio = playerState.audioTracks.first { $0.id == playerState.selectedAudioTrackID }
        let subtitle = playerState.subtitleTracks.first { $0.id == playerState.selectedSubtitleTrackID }
        // mpv track IDs are not FFmpeg/Emby stream indices. Unknown mappings stay absent.
        return .init(seconds: playerState.position, paused: !playerState.isPlaying, muted: playerState.isMuted,
            volume: Int(playerState.volume * 100), rate: Double(playerState.speed),
            audioIndex: audio?.sourceIndex,
            subtitleIndex: playerState.selectedSubtitleTrackID == nil ? -1 : subtitle?.sourceIndex)
    }
    func reportMediaServerPlayback(spec: PlaySpec?, started: Bool = false) {
        guard let spec, let server = spec.mediaServer,
              playerState.currentSpec?.mediaServer?.leaseID == server.leaseID,
              spec.metadata["playback.sessionGeneration"] == String(playbackSessionState.generation) else { return }
        let snapshot = mediaServerSnapshot()
        Task { await MediaServerRuntime.shared.report(server.leaseID, snapshot: snapshot, started: started) }
    }
}
