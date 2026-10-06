import AppKit
import Foundation

struct PlayerWindowPreference: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var frameWidth: Double
    var frameHeight: Double
    var normalizedCenterX: Double
    var normalizedCenterY: Double
    var screenIdentifier: UInt32?
}

enum PlayerWindowPreferencePolicy {
    static let maximumStoredDimension: Double = 16_384

    static func capturedPreference(
        frame: CGRect,
        visibleFrame: CGRect,
        screenIdentifier: UInt32?
    ) -> PlayerWindowPreference? {
        guard isValid(frame: frame),
              isValid(frame: visibleFrame),
              visibleFrame.width > 0,
              visibleFrame.height > 0 else { return nil }
        return PlayerWindowPreference(
            frameWidth: min(max(1, Double(frame.width)), maximumStoredDimension),
            frameHeight: min(max(1, Double(frame.height)), maximumStoredDimension),
            normalizedCenterX: min(1, max(0, Double((frame.midX - visibleFrame.minX) / visibleFrame.width))),
            normalizedCenterY: min(1, max(0, Double((frame.midY - visibleFrame.minY) / visibleFrame.height))),
            screenIdentifier: screenIdentifier
        )
    }

    static func sanitized(_ preference: PlayerWindowPreference) -> PlayerWindowPreference? {
        guard preference.schemaVersion == PlayerWindowPreference.currentSchemaVersion,
              preference.frameWidth.isFinite,
              preference.frameHeight.isFinite,
              preference.normalizedCenterX.isFinite,
              preference.normalizedCenterY.isFinite,
              preference.frameWidth > 0,
              preference.frameHeight > 0 else { return nil }
        var value = preference
        value.frameWidth = min(value.frameWidth, maximumStoredDimension)
        value.frameHeight = min(value.frameHeight, maximumStoredDimension)
        value.normalizedCenterX = min(1, max(0, value.normalizedCenterX))
        value.normalizedCenterY = min(1, max(0, value.normalizedCenterY))
        return value
    }

    static func restoredFrame(
        preference: PlayerWindowPreference,
        visibleFrame: CGRect,
        minimumSize: CGSize
    ) -> CGRect? {
        guard let preference = sanitized(preference),
              isValid(frame: visibleFrame),
              visibleFrame.width > 0,
              visibleFrame.height > 0 else { return nil }
        let width = min(
            visibleFrame.width,
            max(minimumSize.width, CGFloat(preference.frameWidth))
        )
        let height = min(
            visibleFrame.height,
            max(minimumSize.height, CGFloat(preference.frameHeight))
        )
        let center = CGPoint(
            x: visibleFrame.minX + visibleFrame.width * CGFloat(preference.normalizedCenterX),
            y: visibleFrame.minY + visibleFrame.height * CGFloat(preference.normalizedCenterY)
        )
        let proposed = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        return PlayerWindowPresentationPolicy.frameClampedToVisibleScreen(
            proposed,
            visibleFrame: visibleFrame
        )
    }

    private static func isValid(frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }
}

@MainActor
final class PlayerWindowPreferenceStore {
    static let main = PlayerWindowPreferenceStore(storageKey: "NetVplayer.PlayerWindow.main.v1")
    static let live = PlayerWindowPreferenceStore(storageKey: "NetVplayer.PlayerWindow.live.v1")

    private(set) var preference: PlayerWindowPreference?
    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(PlayerWindowPreference.self, from: data) {
            preference = PlayerWindowPreferencePolicy.sanitized(decoded)
        }
    }

    func save(frame: CGRect, visibleFrame: CGRect, screenIdentifier: UInt32?) {
        guard let value = PlayerWindowPreferencePolicy.capturedPreference(
            frame: frame,
            visibleFrame: visibleFrame,
            screenIdentifier: screenIdentifier
        ), let data = try? JSONEncoder().encode(value) else { return }
        preference = value
        defaults.set(data, forKey: storageKey)
    }

    func reset() {
        preference = nil
        defaults.removeObject(forKey: storageKey)
    }

    static func screenIdentifier(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
