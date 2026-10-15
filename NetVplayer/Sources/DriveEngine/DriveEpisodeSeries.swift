import Foundation
import Models

public struct EpisodeGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public var episodes: [Episode]
}

/// Group only by explicit provenance. File names, sizes and episode numbers
/// cannot establish that two uploads belong to the same series.
public enum DriveEpisodeSeries {
    public static func source(
        provider: DriveProvider,
        shareID: String,
        directoryID: String = "",
        directoryPath: String = ""
    ) -> EpisodeSeries {
        // Baidu uses both sharelink0-UK and sharelinkSHAREID-UK mount aliases
        // for files in the same folder. They are transport paths, not versions.
        let path = provider == .baidu
            ? directoryPath.replacingOccurrences(of: #"^/sharelink\d+-\d+(?=/|$)"#, with: "", options: .regularExpression)
            : directoryPath
        let directory = directoryID.isEmpty ? path : directoryID
        // Length-delimited components avoid ambiguous IDs without exposing them in UI.
        let id = [provider.rawValue, shareID, directory].map { "\($0.utf8.count):\($0)" }.joined()
        let name = path.isEmpty ? "" : (path as NSString).lastPathComponent
        return EpisodeSeries(id: id, name: name)
    }

    public static func source(for reference: DriveFileReference) -> EpisodeSeries {
        let directory = reference.filePath.isEmpty ? "" : (reference.filePath as NSString).deletingLastPathComponent
        return source(provider: reference.provider, shareID: reference.pwdID, directoryPath: directory)
    }

    public static func groups(in episodes: [Episode]) -> [EpisodeGroup] {
        var groups: [EpisodeGroup] = []
        var indexes: [String: Int] = [:]
        for episode in episodes {
            let series = source(for: episode)
            let id = series?.id ?? "ungrouped"
            if let index = indexes[id] {
                groups[index].episodes.append(episode)
            } else {
                indexes[id] = groups.count
                groups.append(EpisodeGroup(id: id, name: series?.name ?? "", episodes: [episode]))
            }
        }
        return groups
    }

    public static func source(for episode: Episode) -> EpisodeSeries? {
        episode.series ?? DriveFileReference.parse(episode.url).map { source(for: $0) }
    }
}
