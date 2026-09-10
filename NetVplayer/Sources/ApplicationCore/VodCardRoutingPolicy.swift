import Models

public enum VodCardRoutingPolicy {
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
    }
}
