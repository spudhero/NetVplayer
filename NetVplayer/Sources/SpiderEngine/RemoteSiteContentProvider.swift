import Foundation
import DriveEngine
import Models
import ProviderRuntime
import ProviderSDK
import ProxyServer

enum RemoteProviderRequestPolicy {
    static let minimumTimeoutSeconds = 30

    static func timeoutSeconds(configured: Int) -> Int {
        max(configured, minimumTimeoutSeconds)
    }
}

public struct RemoteSiteContentProvider: SiteContentProvider, SiteContentCacheClearing, Sendable {
    public let providerID: String
    public let manager: ProviderManager
    private let driveShareExpander: DriveShareExpander
    private let detailStore = ProgressiveDetailStore()

    public init(
        providerID: String,
        manager: ProviderManager,
        driveShareExpander: DriveShareExpander = .shared
    ) {
        self.providerID = providerID
        self.manager = manager
        self.driveShareExpander = driveShareExpander
    }

    public func homeContent(site: Site) async throws -> Result {
        try await result(operation: .home, site: site, arguments: ["filter": .bool(true)])
    }

    public func homeVideoContent(site: Site) async throws -> Result? {
        try await result(operation: .homeVideo, site: site)
    }

    public func categoryContent(
        site: Site,
        tid: String,
        page: String,
        filter: Bool,
        extend: [String: String]
    ) async throws -> Result {
        try await result(
            operation: .category,
            site: site,
            arguments: [
                "tid": .string(tid),
                "page": .string(page),
                "filter": .bool(filter),
                "extend": .object(extend)
            ]
        )
    }

    public func detailContent(site: Site, id: String) async throws -> Result {
        try await detailStore.result(
            for: ProgressiveDetailKey(site: site, id: id),
            resolver: RemoteProviderDriveShareResolver(expander: driveShareExpander)
        ) {
            try await result(operation: .detail, site: site, arguments: ["id": .string(id)])
        }
    }

    public func clearContentCache() async {
        await detailStore.clear()
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        let decoded = try await result(
            operation: .player,
            site: site,
            arguments: ["flag": .string(flag), "id": .string(id), "vip_flags": .array([])]
        )
        if let interaction = decoded.interaction {
            throw PlaybackInteractionRequiredError(interaction: interaction)
        }
        return try RemoteProviderPlayerResultAdapter.localize(
            decoded,
            site: site,
            providerID: providerID
        )
    }

    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        try await result(
            operation: .search,
            site: site,
            arguments: ["keyword": .string(keyword), "quick": .bool(quick), "page": .string(page)]
        )
    }

    public func action(site: Site, action: String, value: String) async throws {
        _ = try await response(
            operation: .action,
            site: site,
            arguments: ["action": .string(action), "value": .string(value)]
        )
    }

    private func result(
        operation: ProviderOperation,
        site: Site,
        arguments: [String: ProviderJSONValue] = [:]
    ) async throws -> Result {
        let response = try await response(operation: operation, site: site, arguments: arguments)
        return try response.decodedResult(Result.self)
    }

    private func response(
        operation: ProviderOperation,
        site: Site,
        arguments: [String: ProviderJSONValue] = [:]
    ) async throws -> ProviderResponse {
        await SpiderReplacementRegistry.shared.registerRemoteProxyRoute(
            site: site,
            providerID: providerID,
            manager: manager
        )
        return try await manager.request(
            ProviderRequest(providerID: providerID, operation: operation, site: site, arguments: arguments),
            initializing: site,
            timeout: .seconds(RemoteProviderRequestPolicy.timeoutSeconds(configured: site.timeout))
        )
    }
}

public struct PlaybackInteractionRequiredError: LocalizedError, Equatable, Sendable {
    public let interaction: PlaybackInteraction

    public init(interaction: PlaybackInteraction) {
        self.interaction = interaction
    }

    public var errorDescription: String? { interaction.message }
}

enum RemoteProviderPlayerResultError: Error, Equatable {
    case invalidProxyDescriptor
    case invalidTargetURL
    case invalidHeaderJSON
    case invalidSignSecret
    case unauthorizedProvider
}

enum RemoteProviderPlayerResultAdapter {
    static let proxyScheme = "netvplayer-provider-proxy"
    private static let hmysProviderIDs: Set<String> = [
        "migration.hmys.java",
        "netvplayer.catalog.java"
    ]
    private static let hmysAPIs: Set<String> = [
        "csp_Hmys",
        "csp_HmysGuard",
        "Hmys",
        "HmysGuard"
    ]

    static func localize(
        _ result: Result,
        site: Site,
        providerID: String,
        proxyServer: ProxyServer = .shared
    ) throws -> Result {
        guard let descriptor = URLComponents(string: result.url),
              descriptor.scheme?.lowercased() == proxyScheme else {
            return result
        }
        guard hmysProviderIDs.contains(providerID), hmysAPIs.contains(site.api) else {
            throw RemoteProviderPlayerResultError.unauthorizedProvider
        }
        guard descriptor.host?.lowercased() == "hmys-hls-v1" else {
            throw RemoteProviderPlayerResultError.invalidProxyDescriptor
        }
        let values = Dictionary(grouping: descriptor.queryItems ?? [], by: \URLQueryItem.name)
        guard values.values.allSatisfy({ $0.count == 1 }),
              let target = values["url"]?.first?.value,
              let targetURL = URL(string: target),
              ["http", "https"].contains(targetURL.scheme?.lowercased() ?? ""),
              targetURL.host != nil else {
            throw RemoteProviderPlayerResultError.invalidTargetURL
        }
        let headerJSON = values["headers"]?.first?.value ?? "{}"
        guard headerJSON.utf8.count <= 16 * 1024,
              let headerData = headerJSON.data(using: .utf8),
              (try? JSONDecoder().decode([String: String].self, from: headerData)) != nil else {
            throw RemoteProviderPlayerResultError.invalidHeaderJSON
        }
        guard let signSecret = values["sign_secret"]?.first?.value,
              !signSecret.isEmpty,
              signSecret.utf8.count <= 256 else {
            throw RemoteProviderPlayerResultError.invalidSignSecret
        }
        var local = URLComponents(string: proxyServer.getAddress("/proxy.m3u8"))
        local?.queryItems = [
            URLQueryItem(name: "u64", value: ProxyURLCodec.encode(target)),
            URLQueryItem(name: "h64", value: ProxyURLCodec.encode(headerJSON)),
            URLQueryItem(name: "hls", value: "1"),
            URLQueryItem(name: "hs64", value: ProxyURLCodec.encode(signSecret))
        ]
        guard let localURL = local?.url?.absoluteString else {
            throw RemoteProviderPlayerResultError.invalidProxyDescriptor
        }
        var localized = result
        localized.url = localURL
        localized.header = [:]
        if localized.format.isEmpty {
            localized.format = "m3u8"
        }
        if localized.key.isEmpty {
            localized.key = site.key
        }
        return localized
    }
}

struct RemoteProviderDriveShareResolver: Sendable {
    let expander: DriveShareExpander

    private struct Location: Hashable, Sendable {
        let vod: Int
        let flag: Int
        let episode: Int
    }

    private struct Share: Sendable {
        let location: Location
        let episode: Episode
    }

    private func shares(in result: Result) -> [Share] {
        result.list.enumerated().flatMap { vodIndex, vod in
            vod.parseFlags().enumerated().flatMap { flagIndex, flag in
                flag.episodes.enumerated().compactMap { episodeIndex, episode in
                    guard DriveFileReference.parse(episode.url) == nil,
                          DriveFileReference.provider(for: episode.url) != .unknown else { return nil }
                    return Share(location: Location(vod: vodIndex, flag: flagIndex, episode: episodeIndex), episode: episode)
                }
            }
        }
    }

    func provisional(_ result: Result) -> Result {
        render(result, shares: shares(in: result), completed: [:])
    }

    func resolve(
        _ result: Result,
        onUpdate: @escaping @Sendable (Result) async -> Void = { _ in }
    ) async -> Result {
        let work = shares(in: result)
        guard !work.isEmpty else { return result }
        return await withTaskGroup(of: (Location, [Episode]).self) { group in
            var next = 0
            func submit(_ share: Share) {
                group.addTask {
                    let episodes: [Episode]
                    switch await expander.expansionOutcome(url: share.episode.url, fallbackTitle: share.episode.name) {
                    case .expanded(let expanded): episodes = expanded
                    case .unavailable(let reason):
                        episodes = [Self.unavailableEpisode(title: share.episode.name, reason: reason)]
                    }
                    return (share.location, episodes)
                }
            }
            for share in work.prefix(8) { submit(share); next += 1 }
            var completed: [Location: [Episode]] = [:]
            for await (location, episodes) in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                completed[location] = episodes
                await onUpdate(render(result, shares: work, completed: completed))
                if next < work.count { submit(work[next]); next += 1 }
            }
            return render(result, shares: work, completed: completed)
        }
    }

    private func render(_ input: Result, shares: [Share], completed: [Location: [Episode]]) -> Result {
        guard !shares.isEmpty else { return input }
        let locations = Set(shares.map(\.location))
        var result = input
        for vodIndex in result.list.indices {
            var flags = input.list[vodIndex].parseFlags()
            for flagIndex in flags.indices {
                flags[flagIndex].episodes = flags[flagIndex].episodes.enumerated().flatMap { episodeIndex, episode in
                    let location = Location(vod: vodIndex, flag: flagIndex, episode: episodeIndex)
                    guard locations.contains(location) else { return [episode] }
                    if let expanded = completed[location] { return expanded }
                    return [Episode(name: "正在加载网盘资源", url: "netvplayer-pending://episode/\(vodIndex)/\(flagIndex)/\(episodeIndex)")]
                }
            }
            result.list[vodIndex].vodPlayFrom = flags.map(\.name).joined(separator: "$$$")
            result.list[vodIndex].vodPlayUrl = flags.map { flag in
                flag.episodes.map { "\(Self.safeEpisodeText($0.name))$\($0.url)" }.joined(separator: "#")
            }.joined(separator: "$$$")
            result.list[vodIndex].episodeDetails = flags.flatMap(\.episodes)
        }
        return result
    }

    private static func unavailableEpisode(title: String, reason: String) -> Episode {
        var components = URLComponents()
        components.scheme = "netvplayer-unavailable"
        components.host = "remote-provider-drive-share"
        components.queryItems = [URLQueryItem(name: "reason", value: safeEpisodeText(reason))]
        return Episode(
            name: safeEpisodeText(title).isEmpty ? "不可用" : safeEpisodeText(title),
            url: components.url?.absoluteString ?? "netvplayer-unavailable://remote-provider-drive-share"
        )
    }

    private static func safeEpisodeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "$", with: " ")
            .replacingOccurrences(of: "#", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
