import Models

public enum VodCardRoutingPolicy {
    public static func mediaServerFolderCategory(site: Site, vod: Vod) -> VodClass? {
        // Legacy cached cards only recorded the server's type in remarks.
        guard vod.isFolder || ["Folder", "CollectionFolder", "BoxSet", "Playlist"].contains(vod.vodRemarks),
              let reference = MediaServerReference(locator: vod.vodId),
              site.api == "netvplayer-server://" + reference.accountID.uuidString.lowercased(),
              vod.siteKey.isEmpty || vod.siteKey == site.key else { return nil }
        return VodClass(typeId: reference.itemID, typeName: vod.vodName)
    }

    private static let globalSearchAPIs: Set<String> = [
        "csp_douban",
        "csp_doubanguard",
        "csp_doudouguard",
        "csp_piandan",
    ]

    public static func shouldRouteToGlobalSearch(site: Site, vod: Vod) -> Bool {
        let api = site.api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return globalSearchAPIs.contains(api)
            || site.key == "点我切源"
            || vod.vodId.lowercased().hasPrefix("msearch:")
            || vod.vodId.lowercased().hasSuffix("/@folder")
    }
}
