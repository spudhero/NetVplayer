// PlayerEngine/AliShareExtractor.swift
// Aliyun Drive share/file references to playable links.

import Foundation
import Storage
import Models
import Networking
import DriveEngine

public final class AliShareExtractor: SourceExtractorProtocol {
    public static let defaultDriveIDDefaultsKey = "aliDefaultDriveID"
    public static let authDomainDefaultsKey = "aliAuthDomain"
    public static let userIDDefaultsKey = "aliUserID"

    private let client: AliDriveClient
    private let credentialProvider: @Sendable () -> CloudCredential?
    private let credentialUpdateHandler: (@Sendable (CloudCredential) -> Void)?

    public init(
        httpClient: HTTPClient = .shared,
        credentialProvider: @escaping @Sendable () -> CloudCredential? = {
            let env = ProcessInfo.processInfo.environment
            let refreshToken = [
                env["NETVPLAYER_ALI_REFRESH_TOKEN"] ?? "",
                UserPreferences.shared.aliRefreshToken
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let accessToken = [
                env["NETVPLAYER_ALI_ACCESS_TOKEN"] ?? "",
                UserPreferences.shared.aliAccessToken
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let openToken = [
                env["NETVPLAYER_ALI_OPEN_TOKEN"] ?? "",
                UserPreferences.shared.aliOpenToken
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
        credentialUpdateHandler: (@Sendable (CloudCredential) -> Void)? = nil
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
        try await DriveRequestRecovery.withBudget {
            guard let credential = self.credentialProvider() else { throw DriveEngineError.loginRequired(.ali) }
            return try await DriveRequestRecovery.withAccountOperation(credential: credential) {
                try await self.resolveResult(url: url, credential: credential)
            }
        }
    }

    private func resolveResult(url: String, credential: CloudCredential) async throws -> SourceFetchResult {
        guard credential.provider == .ali else {
            throw DriveEngineError.loginRequired(.ali)
        }
        let refresh = credentialUpdateHandler == nil ? CloudDirectoryCredentialRefresh(original: credential) : nil

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
        var refreshedCredential: CloudCredential?
        do {
            link = try await resolveLink(credential)
        } catch {
            guard Self.isUnauthorized(error),
                  credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw error
            }
            DiagnosticLog.write("[ALI_AUTH_REFRESH] playback endpoint rejected credential; rebuilding routes once")
            let refreshed = try await client.forceRefreshCredential(credential)
            refreshedCredential = refreshed
            link = try await resolveLink(refreshed)
        }

        try await DriveTransferContext.current.check()
        if let updated = link.updatedCredential ?? refreshedCredential {
            if let credentialUpdateHandler { credentialUpdateHandler(updated) }
            else { refresh?.save(updated) }
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
        DriveServiceFailure.isCredentialExpired(error, provider: .ali)
    }
}
