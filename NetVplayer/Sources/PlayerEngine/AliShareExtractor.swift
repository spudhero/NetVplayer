// PlayerEngine/AliShareExtractor.swift
// Aliyun Drive share/file references to playable links.

import Foundation
import Models
import Networking
import DriveEngine

public final class AliShareExtractor: SourceExtractorProtocol {
    public static let refreshTokenDefaultsKey = "aliRefreshToken"
    public static let accessTokenDefaultsKey = "aliAccessToken"
    public static let openTokenDefaultsKey = "aliOpenToken"
    public static let defaultDriveIDDefaultsKey = "aliDefaultDriveID"
    public static let authDomainDefaultsKey = "aliAuthDomain"
    public static let userIDDefaultsKey = "aliUserID"

    private let client: AliDriveClient
    private let credentialProvider: @Sendable () -> CloudCredential?
    private let credentialUpdateHandler: @Sendable (CloudCredential) -> Void

    public init(
        httpClient: HTTPClient = .shared,
        credentialProvider: @escaping @Sendable () -> CloudCredential? = {
            let env = ProcessInfo.processInfo.environment
            let refreshToken = [
                env["NETVPLAYER_ALI_REFRESH_TOKEN"] ?? "",
                UserDefaults.standard.string(forKey: AliShareExtractor.refreshTokenDefaultsKey) ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let accessToken = [
                env["NETVPLAYER_ALI_ACCESS_TOKEN"] ?? "",
                UserDefaults.standard.string(forKey: AliShareExtractor.accessTokenDefaultsKey) ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let openToken = [
                env["NETVPLAYER_ALI_OPEN_TOKEN"] ?? "",
                UserDefaults.standard.string(forKey: AliShareExtractor.openTokenDefaultsKey) ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let defaultDriveID = [
                env["NETVPLAYER_ALI_DEFAULT_DRIVE_ID"] ?? "",
                env["NETVPLAYER_ALI_DRIVE_ID"] ?? "",
                UserDefaults.standard.string(forKey: AliShareExtractor.defaultDriveIDDefaultsKey) ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            guard !refreshToken.isEmpty || !accessToken.isEmpty || !openToken.isEmpty else {
                return nil
            }
            var metadata: [String: String] = [:]
            if !openToken.isEmpty {
                metadata["open_token"] = openToken
            }
            if !defaultDriveID.isEmpty {
                metadata["default_drive_id"] = defaultDriveID
            }
            let authDomain = UserDefaults.standard.string(forKey: AliShareExtractor.authDomainDefaultsKey) ?? ""
            let userID = UserDefaults.standard.string(forKey: AliShareExtractor.userIDDefaultsKey) ?? ""
            if !authDomain.isEmpty { metadata["ali_auth_domain"] = authDomain }
            if !userID.isEmpty { metadata["user_id"] = userID }
            return CloudCredential(
                provider: .ali,
                kind: refreshToken.isEmpty ? .accessToken : .refreshToken,
                secret: [accessToken, openToken].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "",
                refreshToken: refreshToken.isEmpty ? nil : refreshToken,
                accessToken: accessToken.isEmpty ? nil : accessToken,
                metadata: metadata
            )
        },
        credentialUpdateHandler: @escaping @Sendable (CloudCredential) -> Void = { credential in
            UserDefaults.standard.set(credential.refreshToken ?? "", forKey: AliShareExtractor.refreshTokenDefaultsKey)
            UserDefaults.standard.set(credential.accessToken ?? "", forKey: AliShareExtractor.accessTokenDefaultsKey)
            UserDefaults.standard.set(credential.metadata["open_token"] ?? "", forKey: AliShareExtractor.openTokenDefaultsKey)
            UserDefaults.standard.set(credential.metadata["default_drive_id"] ?? "", forKey: AliShareExtractor.defaultDriveIDDefaultsKey)
            UserDefaults.standard.set(credential.metadata["ali_auth_domain"] ?? "", forKey: AliShareExtractor.authDomainDefaultsKey)
            UserDefaults.standard.set(credential.metadata["user_id"] ?? "", forKey: AliShareExtractor.userIDDefaultsKey)
        }
    ) {
        self.client = AliDriveClient(httpClient: httpClient)
        self.credentialProvider = credentialProvider
        self.credentialUpdateHandler = credentialUpdateHandler
    }

    public func match(url: URL) -> Bool {
        if let reference = DriveFileReference.parse(url.absoluteString) {
            return reference.provider == .ali
        }
        if url.scheme?.lowercased() == "ali" { return true }
        let host = (url.host ?? "").lowercased()
        return host.contains("aliyundrive.com") || host.contains("alipan.com")
    }

    public func fetch(url: String) async throws -> String {
        try await fetchResult(url: url).url
    }

    public func fetchResult(url: String) async throws -> SourceFetchResult {
        guard let credential = credentialProvider() else {
            throw DriveEngineError.loginRequired(.ali)
        }

        let resolveLink: @Sendable (CloudCredential) async throws -> CloudDriveLink = { [client] current in
            if let reference = DriveFileReference.parse(url), reference.provider == .ali {
                return try await client.link(reference: reference, credential: current)
            }
            let share = try client.shareRequest(from: url)
            let files = try await client.collectPlayableFiles(share: share)
            guard let selected = client.selectPlayableFile(from: files, share: share) else {
                throw DriveEngineError.noPlayableFile(share.originalURL)
            }
            return try await client.link(
                file: selected.file,
                share: share,
                shareToken: selected.shareToken,
                credential: current
            )
        }

        let link: CloudDriveLink
        do {
            link = try await resolveLink(credential)
        } catch {
            guard Self.isUnauthorized(error),
                  credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw error
            }
            DiagnosticLog.write("[ALI_AUTH_REFRESH] playback endpoint rejected credential; rebuilding routes once")
            let refreshed = try await client.forceRefreshCredential(credential)
            credentialUpdateHandler(refreshed)
            link = try await resolveLink(refreshed)
        }

        if let updated = link.updatedCredential {
            credentialUpdateHandler(updated)
        }
        let headers = playbackHeaders(from: link.headers)
        let adapter = AliDrivePlaybackAdapter()
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

    private func playbackHeaders(from headers: [String: String]) -> [String: String] {
        var playbackHeaders = headers
        if playbackHeaders["User-Agent"] == nil && playbackHeaders["user-agent"] == nil {
            playbackHeaders["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"
        }
        if playbackHeaders["Referer"] == nil && playbackHeaders["referer"] == nil {
            playbackHeaders["Referer"] = "https://www.aliyundrive.com/"
        }
        return playbackHeaders
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        guard case let DriveEngineError.api(provider, statusCode, _, _) = error else { return false }
        return provider == .ali && statusCode == 401
    }
}
