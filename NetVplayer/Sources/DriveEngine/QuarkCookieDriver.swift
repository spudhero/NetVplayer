// DriveEngine/QuarkCookieDriver.swift
// Quark share playback driver using the same cookie-oriented strategy as AList's quark_uc driver.

import Foundation
import Models
import Networking

public final class QuarkCookieDriver: @unchecked Sendable {
    private let client: QuarkDriveClient

    public init(
        httpClient: HTTPClient = .shared,
        pendingPlayPolls: Int = 15,
        pendingPlayIntervalMilliseconds: Int = 2_000
    ) {
        self.client = QuarkDriveClient(
            httpClient: httpClient,
            pendingPlayPolls: pendingPlayPolls,
            pendingPlayIntervalMilliseconds: pendingPlayIntervalMilliseconds
        )
    }

    public func validate(_ credential: CloudCredential, reference: DriveFileReference?) async throws -> CloudCredential {
        guard credential.provider == .quark, credential.kind == .cookie else {
            throw DriveEngineError.unsupported("Wogg 夸克分享播放需要 Cookie 凭证；扫码 token 不能直接用于分享下载。")
        }

        let cookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            throw DriveEngineError.loginRequired(.quark)
        }

        if let reference {
            let link = try await link(reference: reference, credential: credential)
            guard !link.url.isEmpty else {
                throw DriveEngineError.noDownloadURL(reference.fileName)
            }
            return link.updatedCredential ?? credential
        }

        let updatedCookie = try await client.validateAccountCookie(cookie)
        var validated = credential
        validated.secret = updatedCookie
        validated.updatedAt = Date()
        return validated
    }

    public func link(reference: DriveFileReference, credential: CloudCredential) async throws -> CloudDriveLink {
        try await link(rawURL: reference.encodedURL, credential: credential)
    }

    public func link(rawURL: String, credential: CloudCredential) async throws -> CloudDriveLink {
        guard credential.provider == .quark, credential.kind == .cookie else {
            throw DriveEngineError.unsupported("Wogg 夸克分享播放需要 Cookie 凭证；扫码 token 不能直接用于分享下载。")
        }
        let cookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            throw DriveEngineError.loginRequired(.quark)
        }

        let share = try client.shareRequest(from: rawURL)
        let playableFiles = try await client.collectPlayableFiles(share: share, cookie: cookie)
        guard let selected = client.selectPlayableFile(from: playableFiles, share: share) else {
            throw DriveEngineError.noPlayableFile(share.originalURL)
        }
        guard selected.file.isPlayableVideo else {
            throw DriveEngineError.noPlayableFile(selected.file.name)
        }

        return try await savedPersonalLink(for: selected, share: share, cookie: cookie)
    }

    private func savedPersonalLink(for selected: QuarkPlayableFile, share: QuarkShareRequest, cookie: String) async throws -> CloudDriveLink {
        guard selected.file.isPlayableVideo else {
            throw DriveEngineError.noPlayableFile(selected.file.name)
        }
        let savedResult = try await client.fetchSavedDownloadURLResult(for: selected, share: share, cookie: cookie)
        guard let savedURL = savedResult.url, !savedURL.isEmpty else {
            throw DriveEngineError.noDownloadURL(selected.file.name)
        }
        return personalDownloadLink(
            url: savedURL,
            cookie: savedResult.updatedCookie,
            metadata: savedResult.savedFile?.playbackMetadata ?? [:],
            fallbackURL: savedResult.fallbackURL
        )
    }

    private func personalDownloadLink(url: String, cookie: String, metadata: [String: String], fallbackURL: String? = nil) -> CloudDriveLink {
        let playbackMetadata = Self.personalPlaybackMetadata(from: metadata, url: url)
        let headers = [
            "Referer": "https://pan.quark.cn",
            "Origin": "https://pan.quark.cn",
            "Cookie": cookie
        ]
        let fallbackMetadata: [String: String] = [
            DrivePlaybackMetadataKey.route: DrivePlaybackRoute.personalTranscode,
            DrivePlaybackMetadataKey.quality: "Transcode",
            DrivePlaybackMetadataKey.qualityLabel: "转码"
        ]
        return CloudDriveLink(
            url: url,
            headers: headers,
            metadata: playbackMetadata,
            updatedCredential: CloudCredential.cookie(provider: .quark, value: cookie),
            playbackPlan: QuarkDrivePlaybackAdapter().playbackPlan(
                primaryURL: url,
                primaryHeaders: headers,
                primaryMetadata: playbackMetadata,
                fallbackURL: fallbackURL,
                fallbackHeaders: headers,
                fallbackMetadata: fallbackMetadata
            )
        )
    }

    private static func personalPlaybackMetadata(from metadata: [String: String], url: String) -> [String: String] {
        var values = metadata
        values[DrivePlaybackMetadataKey.provider] = DriveProvider.quark.rawValue
        if values[DrivePlaybackMetadataKey.route] == nil {
            values[DrivePlaybackMetadataKey.route] = isTranscodeURL(url) ? DrivePlaybackRoute.personalTranscode : DrivePlaybackRoute.originalDownload
        }
        if values[DrivePlaybackMetadataKey.quality] == nil {
            values[DrivePlaybackMetadataKey.quality] = values[DrivePlaybackMetadataKey.route] == DrivePlaybackRoute.originalDownload ? "Origin" : "Transcode"
        }
        if values[DrivePlaybackMetadataKey.qualityLabel] == nil {
            values[DrivePlaybackMetadataKey.qualityLabel] = values[DrivePlaybackMetadataKey.route] == DrivePlaybackRoute.originalDownload ? "原画" : "转码"
        }
        return values
    }

    private static func isTranscodeURL(_ url: String) -> Bool {
        url.localizedCaseInsensitiveContains(".m3u8")
    }

    public func deleteSavedPlaybackFile(cacheKey: String, fid: String, credential: CloudCredential) async throws -> CloudCredential {
        guard credential.provider == .quark, credential.kind == .cookie else {
            throw DriveEngineError.unsupported("删除夸克转存文件需要 Cookie 凭证。")
        }
        let cookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            throw DriveEngineError.loginRequired(.quark)
        }
        let updatedCookie = try await client.deleteSavedFile(cacheKey: cacheKey, fid: fid, cookie: cookie)
        return .cookie(provider: .quark, value: updatedCookie)
    }

}
