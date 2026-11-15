import Foundation
import Storage
import Testing
@testable import PlayerEngine

@Suite("Playback volume ownership")
struct PlaybackVolumeControlTests {
    @Test func actualHDMIBitstreamRequiresReceiverVolume() throws {
        for format in ["spdif-ac3", "spdif-eac3", "spdif-truehd", "spdif-dts", "spdif-dtshd"] {
            var audio = try PlaybackFormatTestFixtures.diagnostics().audio
            audio.mode = .passthrough
            audio.outputDriver = "coreaudio_exclusive"
            audio.outputFormat = format
            #expect(PlaybackVolumeControl.resolve(audio: audio) == .receiver)
        }
    }

    @Test func decodedAndNativeRenderedAudioKeepPlayerVolume() throws {
        var audio = try PlaybackFormatTestFixtures.diagnostics().audio
        #expect(PlaybackVolumeControl.resolve(audio: audio) == .player)
        audio.outputFormat = "spdif-eac3"
        audio.outputDriver = "avfoundation"
        audio.mode = .nativeCompressed
        #expect(PlaybackVolumeControl.resolve(audio: audio) == .player)
        #expect(PlaybackVolumeControl.resolve(audio: nil, hasPlayback: false) == .player)
    }

    @Test func unconfirmedOrReopeningRoutesCannotPretendToControlVolume() throws {
        var audio = try PlaybackFormatTestFixtures.diagnostics().audio
        audio.outputFormat = "spdif-eac3"
        audio.outputDriver = "avfoundation"
        audio.mode = .nativeCompressedPreparing
        #expect(PlaybackVolumeControl.resolve(audio: audio) == .checking)
        audio.mode = .passthrough
        audio.outputDriver = "null"
        #expect(PlaybackVolumeControl.resolve(audio: audio) == .checking)
        audio.outputDriver = nil
        #expect(PlaybackVolumeControl.resolve(audio: audio) == .checking)
        #expect(PlaybackVolumeControl.resolve(audio: nil) == .checking)
    }

    @MainActor
    @Test func rejectedCommandsPreserveVolumeAndMuteUntilPCMReturns() async throws {
        let suite = "PlaybackVolumeControlTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackAudioPreferenceStore(defaults: defaults)
        let engine = MPVPlayerEngine(videoSurface: .vod, audioPreferences: preferences)
        let state = PlayerState()
        engine.playerState = state
        #expect(engine.setVolume(0.37))
        let saved = preferences.snapshot
        var audio = try PlaybackFormatTestFixtures.diagnostics().audio
        audio.mode = .passthrough
        audio.outputFormat = "spdif-dtshd"
        audio.outputDriver = "coreaudio_exclusive"
        engine.updateVolumeControl(audio: audio)
        #expect(state.volumeControl == .receiver)
        #expect(!engine.setVolume(0.05))
        #expect(!engine.setMuted(true))
        #expect(!engine.toggleMute())
        #expect(preferences.snapshot == saved)
        audio.mode = nil
        engine.updateVolumeControl(audio: audio)
        #expect(state.volumeControl == .checking)
        #expect(!engine.setVolume(0.8))
        #expect(!engine.toggleMute())
        #expect(preferences.snapshot == saved)
        audio.mode = .pcm
        audio.outputFormat = "float"
        audio.outputDriver = "coreaudio"
        engine.updateVolumeControl(audio: audio)
        #expect(state.volumeControl == .player)
        #expect(preferences.snapshot == saved)
        #expect(engine.setVolume(0.21))
        #expect(preferences.snapshot.volume == 0.21)
        #expect(engine.toggleMute())
        #expect(preferences.snapshot.isMuted)
        engine.updateVolumeControl(audio: nil)
        #expect(state.volumeControl == .player)
    }

    @MainActor
    @Test func explicitPlayerVolumeRequestChangesOnlyPassthroughPolicy() throws {
        let suite = "PlaybackVolumeControlTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let output = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        var expected = PlaybackAudioOutputPreference(deviceUID: "test-hdmi", mode: .surround71,
            dolbyAudio: .passthrough, pcmSampleRate: .source)
        output.set(expected)
        let audio = PlaybackAudioPreferenceStore(defaults: defaults)
        audio.setVolume(0.37)
        audio.setMuted(true)
        let savedGain = audio.snapshot
        let engine = MPVPlayerEngine(videoSurface: .vod, audioPreferences: audio, audioOutputPreferences: output)
        engine.requestPlayerVolumeControl()
        expected.dolbyAudio = .pcm
        #expect(output.snapshot == expected)
        #expect(audio.snapshot == savedGain)
    }
}
