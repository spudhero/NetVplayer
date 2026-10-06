import Foundation
import Models

public enum MediaLibraryPresentation {
    public static func vod(record: MediaRecord, group: [MediaRecord]? = nil, site: Site) -> Vod {
        let metadata = record.metadata
        let television = metadata.kind == .television
        let title = television ? metadata.showTitle ?? metadata.title ?? record.entry.name : metadata.title ?? record.entry.name
        var remarks: [String] = []
        if let value = metadata.tmdbRating { remarks.append(String(format: "TMDB %.1f", value)) }
        if let value = metadata.doubanRating { remarks.append(String(format: "豆瓣 %.1f", value)) }
        if !record.candidates.isEmpty { remarks.append("待确认") }
        var vod = Vod(vodId: record.reference.locator, vodName: title, vodPic: metadata.poster ?? "",
            vodYear: metadata.year.map(String.init) ?? "", vodContent: metadata.plot ?? "",
            vodRemarks: remarks.joined(separator: " · "), typeName: television ? "剧集" : "电影",
            vodBackground: metadata.fanart ?? "", siteKey: site.key)
        let records = (group ?? [record]).sorted { lhs, rhs in
            if lhs.metadata.season != rhs.metadata.season { return (lhs.metadata.season ?? 0) < (rhs.metadata.season ?? 0) }
            if lhs.metadata.episode != rhs.metadata.episode { return (lhs.metadata.episode ?? 0) < (rhs.metadata.episode ?? 0) }
            return lhs.entry.name.localizedStandardCompare(rhs.entry.name) == .orderedAscending
        }
        if television {
            let seasons = Dictionary(grouping: records) { $0.metadata.season ?? 1 }
            let keys = seasons.keys.sorted()
            vod.vodPlayFrom = keys.map { "第 \($0) 季" }.joined(separator: "$$$")
            vod.vodPlayUrl = keys.map { season in (seasons[season] ?? []).map { item in
                let number = item.metadata.episode.map { "第 \($0) 集" } ?? item.entry.name
                return safeEpisodeName(number) + "$" + item.reference.locator
            }.joined(separator: "#") }.joined(separator: "$$$")
        } else {
            vod.vodPlayFrom = "播放文件"
            vod.vodPlayUrl = records.map { safeEpisodeName($0.entry.name) + "$" + $0.reference.locator }.joined(separator: "#")
        }
        return vod
    }
    private static func safeEpisodeName(_ name: String) -> String { name.replacingOccurrences(of: "$", with: "＄").replacingOccurrences(of: "#", with: "＃") }
}
