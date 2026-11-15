import Foundation
import Models
import MediaServerEngine

public struct MediaServerNativeProvider: SiteContentProvider {
    public let accountID: UUID
    private let runtime: MediaServerRuntime
    public init(accountID: UUID, runtime: MediaServerRuntime = .shared) { self.accountID = accountID; self.runtime = runtime }
    public func homeContent(site: Site) async throws -> Models.Result {
        let client = try await runtime.client(for: accountID)
        let views = try await client.views()
        let types = views.compactMap { item -> VodClass? in
            guard let id = item.Id, MediaServerReference.validID(id) else { return nil }
            return VodClass(typeId: id, typeName: item.Name ?? "")
        }
        return Models.Result(types: types)
    }
    public func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Models.Result {
        guard MediaServerReference.validID(tid) else { throw MediaServerError.response }
        let client = try await runtime.client(for: accountID)
        return try listing(await client.items(parent: tid, page: Int(page) ?? 1), site: site, page: Int(page) ?? 1)
    }
    public func detailContent(site: Site, id: String) async throws -> Models.Result {
        guard let reference = MediaServerReference(locator: id), reference.accountID == accountID else { throw MediaServerError.response }
        let client = try await runtime.client(for: accountID)
        let item = try await client.item(reference.itemID)
        var vod = try vod(item, site: site)
        // Plain folders navigate one page at a time; never enumerate an entire library as episodes.
        if item.Type == "Series" || item.Type == "Season" {
            var episodes: [Episode] = [], seen = Set<String>(), page = 1
            while true {
                try Task.checkCancellation()
                let response = try await client.items(parent: item.Type == "Series" ? nil : reference.itemID, page: page,
                                                       series: item.Type == "Series" ? reference.itemID : nil, recursive: item.Type != "Series")
                let items = response.Items ?? []
                guard !items.isEmpty || episodes.isEmpty || episodes.count >= (response.TotalRecordCount ?? episodes.count) else { throw MediaServerError.response }
                var fresh = 0
                for child in items {
                    guard let childID = child.Id, seen.insert(childID).inserted else { continue }
                    fresh += 1
                    guard child.IsFolder != true else { continue }
                    let label = child.ParentIndexNumber.map { "S\($0) " } ?? ""
                    let childReference = try MediaServerReference(accountID: accountID, itemID: childID)
                    episodes.append(MediaServerDetailMapping.episode(child, reference: childReference,
                        name: label + (child.IndexNumber.map { "E\($0) " } ?? "") + (child.Name ?? "")))
                    let remaining = max(0, 512 - (vod.mediaServerDetail?.files.count ?? 0))
                    vod.mediaServerDetail?.files += MediaServerDetailMapping.detail(child, reference: childReference).files.prefix(remaining)
                }
                let total = response.TotalRecordCount ?? ((page - 1) * 50 + items.count)
                if page * 50 >= total || items.count < 50 { break }
                guard fresh > 0, page < 100 else { throw MediaServerError.response }
                page += 1
            }
            vod.episodeDetails = episodes
            let seasons = Set(episodes.compactMap(\.season)).sorted()
            if !seasons.isEmpty, episodes.allSatisfy({ $0.season != nil }) {
                vod.vodPlayFrom = seasons.map { $0 == 0 ? L10n.text("特别篇") : L10n.text("第 {0} 季", [String($0)]) }.joined(separator: "$$$")
                vod.vodPlayUrl = seasons.map { season in episodeURLs(episodes.filter { $0.season == season }) }.joined(separator: "$$$")
            } else { vod.vodPlayUrl = episodeURLs(episodes) }
        }
        return Models.Result(list: [vod])
    }
    public func playerContent(site: Site, flag: String, id: String) async throws -> Models.Result {
        guard let reference = MediaServerReference(locator: id), reference.accountID == accountID else { throw MediaServerError.response }
        var result = try await runtime.resolve(reference); result.flag = flag; return result
    }
    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Models.Result {
        let client = try await runtime.client(for: accountID)
        return try listing(await client.items(parent: nil, page: Int(page) ?? 1, search: keyword), site: site, page: Int(page) ?? 1)
    }
    private func listing(_ response: ServerItemPage, site: Site, page: Int) throws -> Models.Result {
        let items = response.Items ?? []
        return Models.Result(list: try items.map { try vod($0, site: site) }, page: page,
            pagecount: response.TotalRecordCount.map { max(1, ($0 + 49) / 50) }, total: response.TotalRecordCount ?? items.count)
    }
    private func vod(_ item: ServerItem, site: Site) throws -> Vod {
        let reference = try MediaServerReference(accountID: accountID, itemID: item.Id ?? "")
        let name = String((item.Name ?? "").prefix(1024))
        let episode = MediaServerDetailMapping.episode(item, reference: reference, name: name)
        let artwork = item.ImageTags?["Primary"].flatMap { try? MediaServerArtworkReference(item: reference, tag: $0) }
        var vod = Vod(vodId: reference.locator, vodName: name, vodPic: artwork?.locator ?? "",
            vodYear: item.ProductionYear.map(String.init) ?? "", vodContent: item.Overview ?? "",
            vodRemarks: item.isBrowsableFolder ? L10n.text("文件夹") : (item.Type ?? ""),
            vodPlayFrom: item.isBrowsableFolder ? "" : "原始文件",
            vodPlayUrl: item.isBrowsableFolder ? "" : "播放$" + reference.locator,
            siteKey: site.key, isFolder: item.isBrowsableFolder)
        vod.episodeDetails = item.isBrowsableFolder ? [] : [episode]
        if !item.isBrowsableFolder {
            let detail = MediaServerDetailMapping.detail(item, reference: reference)
            vod.mediaServerDetail = detail
            vod.vodBackground = detail.metadata.fanart ?? ""
            vod.vodActor = detail.metadata.cast?.map(\.name).joined(separator: " / ") ?? ""
            vod.vodDirector = detail.metadata.directors?.joined(separator: " / ") ?? ""
            vod.vodArea = detail.metadata.countries?.joined(separator: " / ") ?? ""
            vod.typeName = detail.metadata.genres?.joined(separator: " / ") ?? ""
        }
        return vod
    }

    private func episodeURLs(_ episodes: [Episode]) -> String {
        episodes.map { $0.name.replacingOccurrences(of: "$", with: " ").replacingOccurrences(of: "#", with: " ") + "$" + $0.url }.joined(separator: "#")
    }
}
