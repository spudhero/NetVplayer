// PlayerEngine/P115ShareExtractor.swift
// 115 share/file references to playable links.

import Foundation
import Models
import Networking
import DriveEngine

public final class P115ShareExtractor: SourceExtractorProtocol {
    public static let cookieDefaultsKey = "p115Cookie"
    public static let accessTokenDefaultsKey = "p115AccessToken"

    private let client: P115DriveClient
    private let cookieProvider: @Sendable () -> String?
    private let accessTokenProvider: @Sendable () -> String?
    private let cookieUpdateHandler: @Sendable (String) -> Void

    public init(
        httpClient: HTTPClient = .shared,
        cookieProvider: @escaping @Sendable () -> String? = {
            let env = ProcessInfo.processInfo.environment
            let cookie = [
                env["NETVPLAYER_115_COOKIE"] ?? "",
                env["NETVPLAYER_P115_COOKIE"] ?? "",
                UserDefaults.standard.string(forKey: P115ShareExtractor.cookieDefaultsKey) ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            return cookie.isEmpty ? nil : cookie
        },
        accessTokenProvider: @escaping @Sendable () -> String? = {
            let env = ProcessInfo.processInfo.environment
            let accessToken = [
                env["NETVPLAYER_115_ACCESS_TOKEN"] ?? "",
                env["NETVPLAYER_P115_ACCESS_TOKEN"] ?? "",
                UserDefaults.standard.string(forKey: P115ShareExtractor.accessTokenDefaultsKey) ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            return accessToken.isEmpty ? nil : accessToken
        },
        cookieUpdateHandler: @escaping @Sendable (String) -> Void = {
            UserDefaults.standard.set($0, forKey: P115ShareExtractor.cookieDefaultsKey)
        }
    ) {
        self.client = P115DriveClient(httpClient: httpClient)
        self.cookieProvider = cookieProvider
        self.accessTokenProvider = accessTokenProvider
        self.cookieUpdateHandler = cookieUpdateHandler
    }

    public func match(url: URL) -> Bool {
        if let reference = DriveFileReference.parse(url.absoluteString) {
            return reference.provider == .p115
        }
        let scheme = url.scheme?.lowercased()
        if scheme == "115" || scheme == "p115" { return true }
        let host = (url.host ?? "").lowercased()
        return host.contains("115.com") || host.contains("115cdn.com")
    }

    public func fetch(url: String) async throws -> String {
        try await fetchResult(url: url).url
    }

    public func fetchResult(url: String) async throws -> SourceFetchResult {
        guard let cookie = normalizedCookie(cookieProvider()) else {
            throw DriveEngineError.loginRequired(.p115)
        }
        cookieUpdateHandler(cookie)
        let accessToken = normalizedAccessToken(accessTokenProvider())

        let link: CloudDriveLink
        if let reference = DriveFileReference.parse(url), reference.provider == .p115 {
            link = try await client.link(reference: reference, cookie: cookie, accessToken: accessToken)
        } else {
            let share = try client.shareRequest(from: url)
            let files = try await client.collectPlayableFiles(share: share, cookie: cookie)
            guard let selected = client.selectPlayableFile(from: files, share: share) else {
                throw DriveEngineError.noPlayableFile(share.originalURL)
            }
            link = try await client.link(file: selected.file, share: share, cookie: cookie, accessToken: accessToken)
        }

        let headers = playbackHeaders(from: link.headers, cookie: cookie)
        let adapter = P115DrivePlaybackAdapter()
        return SourceFetchResult(
            url: link.url,
            headers: headers,
            isDirectMedia: true,
            metadata: adapter.sanitizedMetadata(link.metadata),
            drivePlaybackPlan: adapter.playbackPlan(
                from: link,
                primaryHeaders: headers,
                primaryMPVOptions: [:]
            )
        )
    }

    private func normalizedCookie(_ cookie: String?) -> String? {
        guard let cookie else { return nil }
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedAccessToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func playbackHeaders(from headers: [String: String], cookie: String) -> [String: String] {
        var playbackHeaders = headers
        if playbackHeaders["User-Agent"] == nil && playbackHeaders["user-agent"] == nil {
            playbackHeaders["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"
        }
        if playbackHeaders["Referer"] == nil && playbackHeaders["referer"] == nil {
            playbackHeaders["Referer"] = "https://115.com/"
        }
        if playbackHeaders["Cookie"] == nil && playbackHeaders["cookie"] == nil {
            playbackHeaders["Cookie"] = cookie
        }
        return playbackHeaders
    }
}
