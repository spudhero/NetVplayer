import Foundation

public struct PlaybackAudioPreference: Codable, Sendable, Equatable {
    public var version = 1
    public var volume: Float = 1
    public var isMuted = false
    public var lastAudibleVolume: Float = 1

    public init(volume: Float = 1, isMuted: Bool = false, lastAudibleVolume: Float = 1) {
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 1
        self.isMuted = isMuted
        self.lastAudibleVolume = lastAudibleVolume.isFinite ? min(1, max(0.01, lastAudibleVolume)) : 1
    }
}

public final class PlaybackAudioPreferenceStore: NSObject, @unchecked Sendable {
    public static let shared = PlaybackAudioPreferenceStore()
    public static let didChange = Notification.Name("NetVplayer.playbackAudioPreferenceChanged.v1")
    public static let key = "playback.audio.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var value: PlaybackAudioPreference

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(PlaybackAudioPreference.self, from: data), decoded.version == 1 {
            value = PlaybackAudioPreference(volume: decoded.volume, isMuted: decoded.isMuted, lastAudibleVolume: decoded.lastAudibleVolume)
        } else {
            value = PlaybackAudioPreference()
        }
        super.init()
    }

    public var snapshot: PlaybackAudioPreference {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func setVolume(_ volume: Float) {
        update { preference in
            guard volume.isFinite else { return }
            preference.volume = min(1, max(0, volume))
            if preference.volume > 0 {
                preference.lastAudibleVolume = preference.volume
                preference.isMuted = false
            }
        }
    }

    public func setMuted(_ muted: Bool) {
        update { preference in
            preference.isMuted = muted
            if !muted, preference.volume == 0 { preference.volume = preference.lastAudibleVolume }
        }
    }

    public func toggleMute() {
        update { preference in
            preference.isMuted = !(preference.isMuted || preference.volume == 0)
            if !preference.isMuted, preference.volume == 0 { preference.volume = preference.lastAudibleVolume }
        }
    }

    private func update(_ transform: (inout PlaybackAudioPreference) -> Void) {
        lock.lock()
        transform(&value)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
