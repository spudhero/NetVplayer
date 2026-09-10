import Foundation
import DriveEngine
import Models
import ProviderRuntime
import ProviderSDK
import ProxyServer

public struct RemoteSiteContentProvider: SiteContentProvider, Sendable {
    public let providerID: String
    public let manager: ProviderManager
    private let driveShareExpander: DriveShareExpander

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
        let decoded = try await result(operation: .detail, site: site, arguments: ["id": .string(id)])
        return await RemoteProviderDriveShareResolver(expander: driveShareExpander).resolve(decoded)
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        let decoded = try await result(
            operation: .player,
            site: site,
            arguments: ["flag": .string(flag), "id": .string(id), "vip_flags": .array([])]
        )
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

    private func result(
        operation: ProviderOperation,
        site: Site,
        arguments: [String: ProviderJSONValue] = [:]
    ) async throws -> Result {
        await SpiderReplacementRegistry.shared.registerRemoteProxyRoute(
            site: site,
            providerID: providerID,
            manager: manager
        )
        try await manager.initialize(providerID: providerID, site: site)
        let response = try await manager.request(
            ProviderRequest(providerID: providerID, operation: operation, site: site, arguments: arguments),
            timeout: .seconds(max(site.timeout, 1))
        )
        return try response.decodedResult(Result.self)
    }
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
        guard providerID == "migration.hmys.java" else {
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

    func resolve(_ result: Result) async -> Result {
        var resolved = result
        for index in resolved.list.indices {
            resolved.list[index] = await resolve(resolved.list[index])
        }
        return resolved
    }

    private func resolve(_ vod: Vod) async -> Vod {
        var resolved = vod
        var flags = vod.parseFlags()
        var changed = false

        for flagIndex in flags.indices {
            var episodes: [Episode] = []
            for episode in flags[flagIndex].episodes {
                // A file-level reference already contains the selected fid and
                // must go straight to SourceManager; expanding it again turns
                // a playable item into an auth-dependent directory request.
                if DriveFileReference.parse(episode.url) != nil {
                    episodes.append(episode)
                    continue
                }
                guard DriveFileReference.provider(for: episode.url) != .unknown else {
                    episodes.append(episode)
                    continue
                }

                changed = true
                switch await expander.expansionOutcome(url: episode.url, fallbackTitle: episode.name) {
                case .expanded(let expanded):
                    episodes.append(contentsOf: expanded)
                case .unavailable(let reason):
                    episodes.append(Self.unavailableEpisode(title: episode.name, reason: reason))
                }
            }
            flags[flagIndex].episodes = episodes
        }

        guard changed else { return vod }
        resolved.vodPlayFrom = flags.map(\.name).joined(separator: "$$$")
        resolved.vodPlayUrl = flags.map { flag in
            flag.episodes.map { episode in
                "\(Self.safeEpisodeText(episode.name))$\(episode.url)"
            }.joined(separator: "#")
        }.joined(separator: "$$$")
        resolved.episodeDetails = flags.flatMap(\.episodes)
        return resolved
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
