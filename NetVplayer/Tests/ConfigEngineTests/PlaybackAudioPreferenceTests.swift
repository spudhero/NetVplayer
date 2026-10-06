import Foundation
import Testing
import Storage
@testable import PlayerEngine

@Suite(.serialized)
struct PlaybackAudioPreferenceTests {
    @Test func preferencesSurviveRecreationAndMutePreservesAudibleVolume() throws {
        let suite = "PlaybackAudioPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackAudioPreferenceStore(defaults: defaults)
        store.setVolume(0.37)
        store.setMuted(true)
        let restored = PlaybackAudioPreferenceStore(defaults: defaults)
        #expect(restored.snapshot.volume == 0.37)
        #expect(restored.snapshot.isMuted)
        restored.toggleMute()
        #expect(!restored.snapshot.isMuted)
        #expect(restored.snapshot.volume == 0.37)
        restored.setVolume(0)
        restored.toggleMute()
        #expect(restored.snapshot.volume == 0.37)
        restored.setVolume(.nan)
        #expect(restored.snapshot.volume == 0.37)
        restored.setVolume(100)
        #expect(restored.snapshot.volume == 1)
    }

    @Test func invalidOrFutureStoredValuesUseSafeDefaults() throws {
        let suite = "PlaybackAudioPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"version":100,"volume":0,"isMuted":true,"lastAudibleVolume":0}"#.utf8), forKey: PlaybackAudioPreferenceStore.key)
        #expect(PlaybackAudioPreferenceStore(defaults: defaults).snapshot == PlaybackAudioPreference())
    }

    @MainActor
    @Test func vodAndLiveSharePreferenceAndNewBindingsRestoreIt() async throws {
        let suite = "PlaybackAudioPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackAudioPreferenceStore(defaults: defaults)
        let vod = MPVPlayerEngine(videoSurface: .vod, audioPreferences: store)
        let live = MPVPlayerEngine(videoSurface: .live, audioPreferences: store)
        let vodState = PlayerState()
        let liveState = PlayerState()
        vod.playerState = vodState
        live.playerState = liveState
        vod.setVolume(0.42)
        vod.setMuted(true)
        for _ in 0..<20 { await Task.yield() }
        #expect(vodState.volume == 0.42)
        #expect(liveState.volume == 0.42)
        #expect(liveState.isMuted)
        live.toggleMute()
        for _ in 0..<20 { await Task.yield() }
        #expect(!vodState.isMuted)
        let replacement = PlayerState()
        vod.playerState = replacement
        for _ in 0..<20 { await Task.yield() }
        #expect(replacement.volume == 0.42)
    }
}
