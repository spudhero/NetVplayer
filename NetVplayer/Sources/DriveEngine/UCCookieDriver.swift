// DriveEngine/UCCookieDriver.swift
// UC share playback driver using cookie-oriented public share APIs.

import Foundation
import Models
import Networking

public final class UCCookieDriver: @unchecked Sendable {
    private let client: UCDriveClient

    public init(
        httpClient: HTTPClient = .shared,
        pendingPlayPolls: Int = 15,
        pendingPlayIntervalMilliseconds: Int = 2_000,
        originalPlaybackTokenProvider: @escaping @Sendable () -> String? = { nil },
        originalPlaybackTokenUpdateHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.client = UCDriveClient(
            httpClient: httpClient,
            pendingPlayPolls: pendingPlayPolls,
            pendingPlayIntervalMilliseconds: pendingPlayIntervalMilliseconds,
            originalPlaybackTokenProvider: originalPlaybackTokenProvider,
            originalPlaybackTokenUpdateHandler: originalPlaybackTokenUpdateHandler
        )
    }

    public func validate(_ credential: CloudCredential, reference _: DriveFileReference?) async throws -> CloudCredential {
        guard credential.provider == .uc, credential.kind == .cookie else {
            throw DriveEngineError.unsupported("UC 分享播放需要 UC Cookie 凭证。")
        }

        let cookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            throw DriveEngineError.loginRequired(.uc)
        }

        let accountCookie = try await validatedAccountCookie(cookie)

        var validated = credential
        validated.secret = accountCookie
        validated.updatedAt = Date()
        return validated
    }

    public func link(reference: DriveFileReference, credential: CloudCredential) async throws -> CloudDriveLink {
        try await link(rawURL: reference.encodedURL, credential: credential)
    }

    public func link(rawURL: String, credential: CloudCredential) async throws -> CloudDriveLink {
        guard credential.provider == .uc, credential.kind == .cookie else {
            throw DriveEngineError.unsupported("UC 分享播放需要 UC Cookie 凭证。")
        }
        let cookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            throw DriveEngineError.loginRequired(.uc)
        }

        let accountCookie = try await validatedAccountCookie(cookie)
        let share = try client.shareRequest(from: rawURL)
        let playableFiles = try await client.collectPlayableFiles(share: share, cookie: accountCookie)
        guard let selected = client.selectPlayableFile(from: playableFiles, share: share) else {
            throw DriveEngineError.noPlayableFile(share.originalURL)
        }
        guard selected.file.isPlayableVideo else {
            throw DriveEngineError.noPlayableFile(selected.file.name)
        }

        let personalLink = try await savedPersonalLink(
            for: selected,
            share: share,
            cookie: accountCookie
        )
        return await attachingPersonalTranscodeFallback(
            to: personalLink,
            selected: selected,
            share: share,
            cookie: personalLink.updatedCredential?.secret ?? accountCookie
        )
    }

    public func deleteSavedPlaybackFile(
        cacheKey: String,
        fid: String,
        credential: CloudCredential
    ) async throws -> CloudCredential {
        guard credential.provider == .uc, credential.kind == .cookie else {
            throw DriveEngineError.unsupported("UC 自动清理需要 UC Cookie 凭证。")
        }
        let cookie = credential.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            throw DriveEngineError.loginRequired(.uc)
        }
        let updatedCookie = try await client.deleteSavedFile(cacheKey: cacheKey, fid: fid, cookie: cookie)
        return .cookie(provider: .uc, value: updatedCookie)
    }

    private func savedPersonalLink(for selected: UCPlayableFile, share: UCShareRequest, cookie: String) async throws -> CloudDriveLink {
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
            metadata: savedResult.savedFile?.playbackMetadata(provider: .uc) ?? [:],
            userAgent: savedResult.playbackUserAgent,
            route: savedResult.playbackRoute == DrivePlaybackRoute.ucSmartPlay
                ? DrivePlaybackRoute.personalTranscode
                : savedResult.playbackRoute,
            selectedReason: savedResult.selectedReason,
            candidateSummary: savedResult.candidateSummary
        )
    }

    private func attachingPersonalTranscodeFallback(
        to originalLink: CloudDriveLink,
        selected: UCPlayableFile,
        share: UCShareRequest,
        cookie: String
    ) async -> CloudDriveLink {
        guard originalLink.metadata[DrivePlaybackMetadataKey.route] == DrivePlaybackRoute.ucOriginalProxy else {
            return originalLink
        }

        do {
            let fallbackLink = try await savedPersonalTranscodeLink(
                for: selected,
                share: share,
                cookie: cookie
            )
            return attachingFallbackLink(fallbackLink, to: originalLink)
        } catch {
            log("个人网盘转码预取失败，继续使用个人盘原文件: \(error.localizedDescription)")
            let basePlan = originalLink.playbackPlan
                ?? UCDrivePlaybackAdapter().playbackPlan(
                    from: originalLink,
                    primaryHeaders: originalLink.headers,
                    primaryMPVOptions: [:]
                )
            let plan = basePlan.map {
                DrivePlaybackPlan(
                    provider: $0.provider,
                    asset: $0.asset,
                    candidates: $0.candidates,
                    cleanup: $0.cleanup,
                    reauthenticationRequired: Self.requiresPersonalAccountLogin(error),
                    unavailableReason: "personal-transfer-failed"
                )
            }
            return CloudDriveLink(
                url: originalLink.url,
                headers: originalLink.headers,
                metadata: originalLink.metadata,
                updatedCredential: originalLink.updatedCredential,
                playbackPlan: plan
            )
        }
    }

    private func log(_ message: String) {
        let line = "[UCCookieDriver] \(message)"
        print(line)
        DiagnosticLog.write(line)
    }

    private func validatedAccountCookie(_ cookie: String) async throws -> String {
        do {
            return try await client.validateAccountCookie(cookie)
        } catch {
            if Self.requiresPersonalAccountLogin(error) {
                throw DriveEngineError.loginRequired(.uc)
            }
            throw error
        }
    }

    private func savedPersonalTranscodeLink(
        for selected: UCPlayableFile,
        share: UCShareRequest,
        cookie: String
    ) async throws -> CloudDriveLink {
        let savedResult = try await client.fetchSavedPersonalPlayURLResult(
            for: selected,
            share: share,
            cookie: cookie
        )
        guard let savedURL = savedResult.url, !savedURL.isEmpty else {
            throw DriveEngineError.noDownloadURL(selected.file.name)
        }
        return personalDownloadLink(
            url: savedURL,
            cookie: savedResult.updatedCookie,
            metadata: savedResult.savedFile?.playbackMetadata(provider: .uc) ?? [:],
            userAgent: savedResult.playbackUserAgent,
            route: DrivePlaybackRoute.personalTranscode,
            selectedReason: savedResult.selectedReason,
            candidateSummary: savedResult.candidateSummary
        )
    }

    private func attachingFallbackLink(_ fallbackLink: CloudDriveLink, to originalLink: CloudDriveLink) -> CloudDriveLink {
        var fallbackMetadata = fallbackLink.metadata
        let selectedReason = fallbackMetadata[DrivePlaybackMetadataKey.selectedReason]
        if fallbackMetadata[DrivePlaybackMetadataKey.quality] == nil,
           let quality = Self.playbackQuality(from: selectedReason),
           !quality.isEmpty {
            fallbackMetadata[DrivePlaybackMetadataKey.quality] = quality
            fallbackMetadata[DrivePlaybackMetadataKey.qualityLabel] = Self.playbackQualityLabel(for: quality)
        }
        let adapter = UCDrivePlaybackAdapter()
        let originalPlan = originalLink.playbackPlan
            ?? adapter.playbackPlan(from: originalLink, primaryHeaders: originalLink.headers, primaryMPVOptions: [:])
        let fallbackPlan = adapter.playbackPlan(
            primaryURL: fallbackLink.url,
            primaryHeaders: fallbackLink.headers,
            primaryMetadata: fallbackMetadata
        )
        let plan = Self.combinedPlan(primary: originalPlan, appending: fallbackPlan)

        return CloudDriveLink(
            url: originalLink.url,
            headers: originalLink.headers,
            metadata: originalLink.metadata,
            updatedCredential: fallbackLink.updatedCredential ?? originalLink.updatedCredential,
            playbackPlan: plan
        )
    }

    private static func combinedPlan(
        primary: DrivePlaybackPlan?,
        appending fallback: DrivePlaybackPlan?
    ) -> DrivePlaybackPlan? {
        guard let base = primary ?? fallback else { return nil }
        return DrivePlaybackPlan(
            provider: base.provider,
            asset: primary?.asset ?? base.asset,
            candidates: (primary?.candidates ?? []) + (fallback?.candidates ?? []),
            cleanup: primary?.cleanup ?? fallback?.cleanup,
            reauthenticationRequired: (primary?.reauthenticationRequired ?? false)
                || (fallback?.reauthenticationRequired ?? false),
            unavailableReason: primary?.unavailableReason ?? fallback?.unavailableReason
        )
    }

    private static func playbackQuality(from selectedReason: String?) -> String? {
        guard let selectedReason else { return nil }
        let components = selectedReason.split(separator: ":").map(String.init)
        guard components.count >= 2,
              components[0] == "resolution" || components[0] == "fallback-video-list" else {
            return nil
        }
        return components[1]
    }

    private static func playbackQualityLabel(for quality: String) -> String {
        switch quality.lowercased() {
        case "4k": return "4K"
        case "2k": return "2K"
        case "super": return "超清"
        case "high": return "高清"
        case "normal": return "标清"
        case "low": return "流畅"
        default: return quality
        }
    }

    private func personalDownloadLink(
        url: String,
        cookie: String,
        metadata: [String: String],
        userAgent: String?,
        route: String?,
        selectedReason: String? = nil,
        candidateSummary: String? = nil
    ) -> CloudDriveLink {
        var playbackMetadata = metadata
        if let route {
            playbackMetadata[DrivePlaybackMetadataKey.route] = route
        }
        if let selectedReason, !selectedReason.isEmpty {
            playbackMetadata[DrivePlaybackMetadataKey.selectedReason] = selectedReason
        }
        if let candidateSummary, !candidateSummary.isEmpty {
            playbackMetadata[DrivePlaybackMetadataKey.candidateSummary] = candidateSummary
        }
        let headers = personalPlaybackHeaders(cookie: cookie, userAgent: userAgent, route: route)
        let plan = UCDrivePlaybackAdapter().playbackPlan(
            primaryURL: url,
            primaryHeaders: headers,
            primaryMetadata: playbackMetadata
        )
        return CloudDriveLink(
            url: url,
            headers: headers,
            metadata: playbackMetadata,
            updatedCredential: .cookie(provider: .uc, value: cookie),
            playbackPlan: plan
        )
    }

    private func personalPlaybackHeaders(cookie: String, userAgent: String?, route: String?) -> [String: String] {
        guard route != DrivePlaybackRoute.ucSmartPlay,
              route != DrivePlaybackRoute.personalTranscode else {
            return [:]
        }
        return [
            "Referer": "https://drive.uc.cn/",
            "Origin": "https://drive.uc.cn",
            "Cookie": cookie,
            "User-Agent": userAgent ?? UCDriveClient.accountPlaybackUserAgent
        ]
    }

    private static func requiresPersonalAccountLogin(_ error: Error) -> Bool {
        guard let driveError = error as? DriveEngineError else {
            return false
        }
        switch driveError {
        case .loginRequired(.uc):
            return true
        case .api(.uc, let statusCode, let code, let message):
            return statusCode == 401
                || code == 31001
                || message.localizedCaseInsensitiveContains("require login")
                || message.localizedCaseInsensitiveContains("guest")
        default:
            return false
        }
    }

}
