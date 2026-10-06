import Foundation
import Models

struct VodLineFallbackTarget {
    let flag: String
    let episode: Episode
}

enum VodLineFallbackPolicy {
    static let appliedMetadataKey = "vod.lineFallbackApplied"

    static func target(site: Site, detail: Vod, failedSpec: PlaySpec) -> VodLineFallbackTarget? {
        guard site.api.range(of: "nmyswv", options: .caseInsensitive) != nil,
              failedSpec.metadata[appliedMetadataKey] != "true" else {
            return nil
        }

        let flags = VodPlaybackAvailabilityPolicy.visibleLines(in: detail)
        guard flags.count > 1,
              let currentFlagIndex = flags.firstIndex(where: { $0.flag == failedSpec.flag }) else {
            return nil
        }

        let currentEpisodes = flags[currentFlagIndex].episodes
        let episodeURL = failedSpec.metadata["vod.episodeURL"]
        let episodeName = failedSpec.metadata["vod.episodeName"]
        let currentEpisodeIndex = currentEpisodes.firstIndex { episode in
            (episodeURL != nil && episode.url == episodeURL) ||
                (episodeName != nil && episode.name == episodeName)
        }

        for (index, flag) in flags.enumerated() where index != currentFlagIndex {
            if let episodeName {
                let sameName = flag.episodes.filter { $0.name == episodeName }
                if sameName.count == 1, let episode = sameName.first {
                    return VodLineFallbackTarget(flag: flag.flag, episode: episode)
                }
            }
            if let currentEpisodeIndex, flag.episodes.indices.contains(currentEpisodeIndex) {
                return VodLineFallbackTarget(flag: flag.flag, episode: flag.episodes[currentEpisodeIndex])
            }
        }
        return nil
    }
}
