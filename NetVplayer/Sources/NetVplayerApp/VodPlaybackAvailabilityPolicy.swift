import Foundation
import Models
import PlayerEngine

struct VodPlaybackLine {
    let flag: String
    let episodes: [Episode]
}

enum VodPlaybackAvailabilityPolicy {
    static func needsMagnetExpansion(_ episode: Episode, site: Site?) -> Bool {
        let support = episodeSupport(for: episode, site: site)
        return support.kind == "magnet" && support.status == .supported
            && URLComponents(string: episode.url)?.queryItems?.contains(where: {
                $0.name == "netvplayer_file"
            }) != true
    }

    static func expanding(_ episode: Episode, with files: [Episode], flag: String, in detail: Vod) -> Vod? {
        let flags = detail.vodPlayFrom.components(separatedBy: "$$$")
        var lists = detail.vodPlayUrl.components(separatedBy: "$$$")
        guard !files.isEmpty, let lineIndex = flags.firstIndex(of: flag), lineIndex < lists.count else { return nil }
        var episodes = Episode.parse(from: lists[lineIndex])
        guard let episodeIndex = episodes.firstIndex(where: { $0.url == episode.url }) else { return nil }
        episodes.replaceSubrange(episodeIndex...episodeIndex, with: files)
        lists[lineIndex] = episodes.map { "\($0.name)$\($0.url)" }.joined(separator: "#")
        var expanded = detail
        expanded.vodPlayUrl = lists.joined(separator: "$$$")
        return expanded
    }

    static func episodeSupport(for episode: Episode, site: Site?) -> SourceSupport {
        let support = SourceManager.shared.support(for: episode.url)
        // SixV resolves magnets before the generic media extractor receives the result.
        if support.kind == "magnet", let site, site.type == 3,
           ["csp_SixVGuard", "SixVGuard", "csp_Xb6v", "Xb6v"].contains(site.api) {
            return SourceSupport(kind: "magnet", status: .supported,
                                 reason: L10n.text("磁力资源将边下载边播放"))
        }
        return support
    }

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
