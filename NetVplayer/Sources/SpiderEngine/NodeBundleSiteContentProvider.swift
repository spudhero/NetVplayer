// SpiderEngine/NodeBundleSiteContentProvider.swift
// Adapter from OKVideoMac's Node HTTP spider contract to NetVplayer's SiteApi.

import Foundation
import DriveEngine
import Models
import NodeBundleRuntime

public struct NodeBundleSiteContentProvider: SiteContentProvider, Sendable {
    public let providerID: String
    private let driveShareExpander: DriveShareExpander

    public init(providerID: String, driveShareExpander: DriveShareExpander = .shared) {
        self.providerID = providerID
        self.driveShareExpander = driveShareExpander
    }

    public func homeContent(site: Site) async throws -> Result {
        try await result(site: site, method: "home", body: ["filter": true])
    }

    public func homeVideoContent(site: Site) async throws -> Result? {
        do {
            return try await result(site: site, method: "homeVod", body: [:])
        } catch let error as NodeBundleRuntimeError {
            // OKVideoMac registers /homeVod only for spiders that implement
            // the optional home-video capability. A missing route must not
            // invalidate the regular /home response.
            if case .requestFailed(let message) = error,
               message.contains("404") || message.localizedCaseInsensitiveContains("not found") {
                return nil
            }
            throw error
        }
    }

    public func categoryContent(
        site: Site,
        tid: String,
        page: String,
        filter: Bool,
        extend: [String: String]
    ) async throws -> Result {
        return try await result(
            site: site,
            method: "category",
            body: [
                "id": tid,
                "tid": tid,
                "page": page,
                "pg": page,
                "filter": filter,
                "extend": extend,
                "filters": extend,
            ]
        )
    }

    public func detailContent(site: Site, id: String) async throws -> Result {
        let result = try await result(
            site: site,
            method: "detail",
            body: ["id": [id], "ids": [id]]
        )
        let normalized = Self.normalizeDriveTokens(in: result)
        return await RemoteProviderDriveShareResolver(expander: driveShareExpander).resolve(normalized)
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        let normalizedID = NodeBundleDriveToken.canonicalURL(for: id) ?? id
        if DriveFileReference.parse(normalizedID) != nil {
            // Native SourceExtractors own authentication, refresh, and playback
            // route selection for cloud-drive references. Do not send these IDs
            // back to a Node bundle that may have a separate cookie store.
            return Result(url: normalizedID, parse: 0, jx: 0, flag: flag, key: site.key)
        }
        return try await result(
            site: site,
            method: "play",
            body: [
                "flag": flag,
                "id": id,
                "vipFlags": [],
                "flags": [],
            ]
        )
    }

    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        try await result(
            site: site,
            method: "search",
            body: [
                "wd": keyword,
                "key": keyword,
                "quick": quick,
                "page": page,
                "pg": page,
            ]
        )
    }

    private func result(
        site: Site,
        method: String,
        body: [String: Any]
    ) async throws -> Result {
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let response = try await NodeBundleRuntimeRegistry.shared.request(
            providerID: providerID,
            api: site.api,
            method: method,
            body: bodyData,
            headers: site.header,
            timeout: TimeInterval(max(site.timeout, 1))
        )
        guard let text = String(data: response, encoding: .utf8), !text.isEmpty else {
            throw NodeBundleRuntimeError.requestFailed("\(site.name) \(method) 返回空响应")
        }
        return Result.fromJSON(text)
    }

    private static func normalizeDriveTokens(in result: Result) -> Result {
        var normalized = result
        for index in normalized.list.indices {
            var vod = normalized.list[index]
            var flags = vod.parseFlags()
            var changed = false
            for flagIndex in flags.indices {
                for episodeIndex in flags[flagIndex].episodes.indices {
                    guard let url = NodeBundleDriveToken.canonicalURL(for: flags[flagIndex].episodes[episodeIndex].url) else {
                        continue
                    }
                    flags[flagIndex].episodes[episodeIndex].url = url
                    changed = true
                }
            }
            guard changed else { continue }
            vod.vodPlayFrom = flags.map(\.name).joined(separator: "$$$")
            vod.vodPlayUrl = flags.map { flag in
                flag.episodes.map { episode in
                    "\(safeEpisodeText(episode.name))$\(episode.url)"
                }.joined(separator: "#")
            }.joined(separator: "$$$")
            vod.episodeDetails = flags.flatMap(\.episodes)
            normalized.list[index] = vod
        }
        return normalized
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
