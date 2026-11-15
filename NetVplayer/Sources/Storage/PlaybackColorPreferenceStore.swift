import Foundation

public enum PlaybackToneMapping: String, Codable, CaseIterable, Sendable {
    case bt2390 = "bt.2390", mobius, reinhard
}

/// A preference never establishes that the current renderer/display supports HDR.
public enum PlaybackVideoOutputMode: String, Codable, CaseIterable, Sendable {
    // Keep the persisted raw values: automatic now follows the user's system
    // setting; hdrIfAvailable is the explicit temporary system HDR opt-in.
    case automatic, sdr, hdrIfAvailable
}

/// nil means automatic (a valid source suggestion, then the application default).
/// These are SDR signal reference values, not a measurement of the monitor.
public struct PlaybackColorPreference: Codable, Equatable, Sendable {
    public var version = 1
    public var toneMapping: PlaybackToneMapping?
    public var peakNits: Int?
    public var videoOutput: PlaybackVideoOutputMode
    public var systemDolbyVision: Bool
    public var sourceDolbyVisionMetadata: Bool

    public init(toneMapping: PlaybackToneMapping? = nil, peakNits: Int? = nil,
                videoOutput: PlaybackVideoOutputMode = .automatic, systemDolbyVision: Bool = false,
                sourceDolbyVisionMetadata: Bool = false) {
        self.toneMapping = toneMapping
        self.peakNits = peakNits.map { min(203, max(80, $0)) }
        self.videoOutput = videoOutput
        self.systemDolbyVision = systemDolbyVision
        self.sourceDolbyVisionMetadata = sourceDolbyVisionMetadata
    }

    private enum CodingKeys: String, CodingKey { case version, toneMapping, peakNits, videoOutput, systemDolbyVision, sourceDolbyVisionMetadata }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        toneMapping = try values.decodeIfPresent(PlaybackToneMapping.self, forKey: .toneMapping)
        peakNits = try values.decodeIfPresent(Int.self, forKey: .peakNits).map { min(203, max(80, $0)) }
        // Preserve AV-02 preferences and safely ignore future/unknown modes.
        videoOutput = try values.decodeIfPresent(String.self, forKey: .videoOutput)
            .flatMap(PlaybackVideoOutputMode.init(rawValue:)) ?? .automatic
        systemDolbyVision = try values.decodeIfPresent(Bool.self, forKey: .systemDolbyVision) ?? false
        sourceDolbyVisionMetadata = try values.decodeIfPresent(Bool.self, forKey: .sourceDolbyVisionMetadata) ?? false
    }
}

public final class PlaybackColorPreferenceStore: NSObject, @unchecked Sendable {
    public static let shared = PlaybackColorPreferenceStore()
    public static let didChange = Notification.Name("NetVplayer.playbackColorPreferenceChanged.v1")
    public static let key = "playback.color.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var value: PlaybackColorPreference

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(PlaybackColorPreference.self, from: data), decoded.version == 1 {
            value = .init(toneMapping: decoded.toneMapping, peakNits: decoded.peakNits, videoOutput: decoded.videoOutput,
                          systemDolbyVision: decoded.systemDolbyVision,
                          sourceDolbyVisionMetadata: decoded.sourceDolbyVisionMetadata)
        } else {
            value = .init()
        }
        super.init()
    }

    public var snapshot: PlaybackColorPreference {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ preference: PlaybackColorPreference) {
        lock.lock()
        value = .init(toneMapping: preference.toneMapping, peakNits: preference.peakNits, videoOutput: preference.videoOutput,
                      systemDolbyVision: preference.systemDolbyVision,
                      sourceDolbyVisionMetadata: preference.sourceDolbyVisionMetadata)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func reset() { set(.init()) }
}
