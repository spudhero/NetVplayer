import Foundation

public enum PlaybackDialogueStrength: String, Codable, CaseIterable, Sendable {
    case off, light, medium, strong
}

/// Global listening preference, independent of routing, tracks, volume and mute.
public final class PlaybackDialoguePreferenceStore: NSObject, @unchecked Sendable {
    public static let shared = PlaybackDialoguePreferenceStore()
    public static let didChange = Notification.Name("NetVplayer.playbackDialogueChanged.v1")
    public static let key = "playback.dialogue.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var value: PlaybackDialogueStrength

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = defaults.string(forKey: Self.key).flatMap(PlaybackDialogueStrength.init(rawValue:)) ?? .off
        super.init()
    }

    public var snapshot: PlaybackDialogueStrength {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func set(_ strength: PlaybackDialogueStrength) {
        lock.lock()
        guard value != strength else { lock.unlock(); return }
        value = strength
        defaults.set(strength.rawValue, forKey: Self.key)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func reset() { set(.off) }
}
