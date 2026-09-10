import Foundation
import Models
import PlayerEngine

struct VodPlaybackLine {
    let flag: String
    let episodes: [Episode]
}

enum VodPlaybackAvailabilityPolicy {
    static func visibleLines(in detail: Vod) -> [VodPlaybackLine] {
        let flags = detail.vodPlayFrom.components(separatedBy: "$$$")
        let playLists = detail.vodPlayUrl.components(separatedBy: "$$$")

        return flags.enumerated().compactMap { index, rawFlag in
            let flag = rawFlag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !flag.isEmpty, index < playLists.count else { return nil }

            let episodes = Episode.parse(from: playLists[index]).filter(isVisibleEpisode)
            guard !episodes.isEmpty else { return nil }
            return VodPlaybackLine(flag: flag, episodes: episodes)
        }
    }

    static func isVisibleEpisode(_ episode: Episode) -> Bool {
        let support = SourceManager.shared.support(for: episode.url)
        return support.kind != "unavailable" && support.kind != "empty"
    }
}
