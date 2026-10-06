import Foundation

/// Public-shell navigation actions for the in-app configuration center.
public enum ConfigurationCenterSection: String, CaseIterable, Equatable, Sendable {
    case dataSource = "data-source"
    case providers = "providers"
    case playback = "playback"
    case network = "network"
    case system = "system"
    case appearance = "appearance"
}

public enum ConfigurationCenterAction: Equatable, Sendable {
    case open(ConfigurationCenterSection)

    public var vodID: String {
        switch self {
        case .open(let section):
            return "netvplayer-config://settings/\(section.rawValue)"
        }
    }

    public static func decode(vodID: String) -> ConfigurationCenterAction? {
        guard let url = URL(string: vodID),
              url.scheme?.lowercased() == "netvplayer-config",
              url.host?.lowercased() == "settings",
              let rawSection = url.pathComponents.dropFirst().first,
              let section = ConfigurationCenterSection(rawValue: rawSection) else {
            return nil
        }
        return .open(section)
    }
}
