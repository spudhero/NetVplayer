import Foundation

public enum PlaybackAudioOutputMode: String, Codable, CaseIterable, Sendable {
    case automatic, stereo, surround51, surround71
}

public enum PlaybackDolbyAudioMode: String, Codable, CaseIterable, Sendable {
    // Keep the persisted v1 key/type compatible with existing Dolby preferences.
    case automatic, passthrough, pcm
}

public enum PlaybackPCMSampleRateMode: String, Codable, CaseIterable, Sendable {
    case device, source
}

public enum PlaybackTrueHDObjectMode: String, Codable, CaseIterable, Sendable {
    case automatic, speakers714, headphones, trackedHeadphones
}

/// Output routing is independent of the existing volume/mute preference.
/// A saved UID is a request, never evidence of a currently open device.
public struct PlaybackAudioOutputPreference: Codable, Equatable, Sendable {
    public var version = 1
    public var deviceUID: String?
    public var mode: PlaybackAudioOutputMode
    public var dolbyAudio: PlaybackDolbyAudioMode
    public var pcmSampleRate: PlaybackPCMSampleRateMode
    public var trueHDObjects: PlaybackTrueHDObjectMode

    public init(deviceUID: String? = nil, mode: PlaybackAudioOutputMode = .automatic,
                dolbyAudio: PlaybackDolbyAudioMode = .automatic,
                pcmSampleRate: PlaybackPCMSampleRateMode = .device,
                trueHDObjects: PlaybackTrueHDObjectMode = .automatic) {
        self.deviceUID = Self.validUID(deviceUID)
        self.mode = mode
        self.dolbyAudio = dolbyAudio
        self.pcmSampleRate = pcmSampleRate
        self.trueHDObjects = trueHDObjects
    }

    private enum CodingKeys: String, CodingKey { case version, deviceUID, mode, dolbyAudio, pcmSampleRate, trueHDObjects }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        deviceUID = Self.validUID(try values.decodeIfPresent(String.self, forKey: .deviceUID))
        mode = try values.decodeIfPresent(String.self, forKey: .mode)
            .flatMap(PlaybackAudioOutputMode.init(rawValue:)) ?? .automatic
        dolbyAudio = try values.decodeIfPresent(String.self, forKey: .dolbyAudio)
            .flatMap(PlaybackDolbyAudioMode.init(rawValue:)) ?? .automatic
        pcmSampleRate = try values.decodeIfPresent(String.self, forKey: .pcmSampleRate)
            .flatMap(PlaybackPCMSampleRateMode.init(rawValue:)) ?? .device
        trueHDObjects = try values.decodeIfPresent(String.self, forKey: .trueHDObjects)
            .flatMap(PlaybackTrueHDObjectMode.init(rawValue:)) ?? .automatic
    }

    private static func validUID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
}

public final class PlaybackAudioOutputPreferenceStore: NSObject, @unchecked Sendable {
    public static let shared = PlaybackAudioOutputPreferenceStore()
    public static let didChange = Notification.Name("NetVplayer.playbackAudioOutputPreferenceChanged.v1")
    public static let key = "playback.audioOutput.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var value: PlaybackAudioOutputPreference

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(PlaybackAudioOutputPreference.self, from: data), decoded.version == 1 {
            value = .init(deviceUID: decoded.deviceUID, mode: decoded.mode, dolbyAudio: decoded.dolbyAudio,
                          pcmSampleRate: decoded.pcmSampleRate, trueHDObjects: decoded.trueHDObjects)
        } else { value = .init() }
        super.init()
    }

    public var snapshot: PlaybackAudioOutputPreference {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ preference: PlaybackAudioOutputPreference) {
        lock.lock()
        let normalized = PlaybackAudioOutputPreference(deviceUID: preference.deviceUID, mode: preference.mode,
                                                       dolbyAudio: preference.dolbyAudio,
                                                       pcmSampleRate: preference.pcmSampleRate, trueHDObjects: preference.trueHDObjects)
        guard value != normalized else { lock.unlock(); return }
        value = normalized
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func reset() { set(.init()) }
}
