// PlayerEngine/UCShareExtractor.swift
// UC drive share and file references to playable links.

import Foundation
import Models
import Networking
import DriveEngine

public final class UCShareExtractor: SourceExtractorProtocol {
    public static let cookieDefaultsKey = "ucCookie"
    public static let deviceIDDefaultsKey = "ucTVDeviceID"
    public static let queryTokenDefaultsKey = "ucTVQueryToken"
    public static let refreshTokenDefaultsKey = "ucTVRefreshToken"
    public static let accessTokenDefaultsKey = "ucTVAccessToken"
    public static let originalPlaybackTokenDefaultsKey = "ucOriginalPlaybackToken"
    public static let fongMiPlaybackTokenDefaultsKey = "ucFongMiPlaybackToken"
    public static let fongMiPlaybackExpiresAtDefaultsKey = "ucFongMiPlaybackExpiresAt"
    public static let fongMiFixtureIDDefaultsKey = "ucFongMiFixtureID"
    public static let fongMiEvidenceStatusDefaultsKey = "ucFongMiEvidenceStatus"

    private let client: UCDriveClient
    private let httpClient: HTTPClient
    private let cookieDriver: UCCookieDriver
    private let cookieProvider: @Sendable () -> String?
    private let cookieUpdateHandler: @Sendable (String) -> Void
    private let tokenProvider: @Sendable () -> CloudCredential?
    private let tokenUpdateHandler: @Sendable (CloudCredential) -> Void
    private let fongMiPlaybackTokenProvider: @Sendable () -> CloudCredential?
    private let tvDriver: QuarkTVDriver

    public init(
        httpClient: HTTPClient = .shared,
        cookieProvider: @escaping @Sendable () -> String? = {
            let envCookie = ProcessInfo.processInfo.environment["NETVPLAYER_UC_COOKIE"]
            if let envCookie, !envCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return envCookie
            }
            return UserDefaults.standard.string(forKey: UCShareExtractor.cookieDefaultsKey)
        },
        cookieUpdateHandler: @escaping @Sendable (String) -> Void = {
            UserDefaults.standard.set($0, forKey: UCShareExtractor.cookieDefaultsKey)
        },
        originalPlaybackTokenProvider: @escaping @Sendable () -> String? = {
            let envToken = ProcessInfo.processInfo.environment["NETVPLAYER_UC_ORIGINAL_UT"]
            if let envToken, !envToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return envToken
            }
            return UserDefaults.standard.string(forKey: UCShareExtractor.originalPlaybackTokenDefaultsKey)
        },
        originalPlaybackTokenUpdateHandler: @escaping @Sendable (String) -> Void = {
            UserDefaults.standard.set($0, forKey: UCShareExtractor.originalPlaybackTokenDefaultsKey)
        },
        tokenProvider: @escaping @Sendable () -> CloudCredential? = {
            let refreshToken = UserDefaults.standard.string(forKey: UCShareExtractor.refreshTokenDefaultsKey) ?? ""
            let accessToken = UserDefaults.standard.string(forKey: UCShareExtractor.accessTokenDefaultsKey) ?? ""
            let deviceID = UserDefaults.standard.string(forKey: UCShareExtractor.deviceIDDefaultsKey) ?? ""
            let queryToken = UserDefaults.standard.string(forKey: UCShareExtractor.queryTokenDefaultsKey) ?? ""
            guard !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return CloudCredential.token(
                provider: .uc,
                refreshToken: refreshToken,
                accessToken: accessToken,
                deviceID: deviceID,
                queryToken: queryToken.isEmpty ? nil : queryToken
            )
        },
        tokenUpdateHandler: @escaping @Sendable (CloudCredential) -> Void = { credential in
            UserDefaults.standard.set(credential.deviceID ?? "", forKey: UCShareExtractor.deviceIDDefaultsKey)
            UserDefaults.standard.set(credential.queryToken ?? "", forKey: UCShareExtractor.queryTokenDefaultsKey)
            UserDefaults.standard.set(credential.refreshToken ?? "", forKey: UCShareExtractor.refreshTokenDefaultsKey)
            UserDefaults.standard.set(credential.accessToken ?? "", forKey: UCShareExtractor.accessTokenDefaultsKey)
        },
        fongMiPlaybackTokenProvider: @escaping @Sendable () -> CloudCredential? = {
            let token = UserDefaults.standard.string(forKey: UCShareExtractor.fongMiPlaybackTokenDefaultsKey) ?? ""
            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToken.isEmpty else { return nil }
            let expiresAtRaw = UserDefaults.standard.string(forKey: UCShareExtractor.fongMiPlaybackExpiresAtDefaultsKey) ?? ""
            let expiresAt = TimeInterval(expiresAtRaw).map { Date(timeIntervalSince1970: $0) }
            let fixtureID = UserDefaults.standard.string(forKey: UCShareExtractor.fongMiFixtureIDDefaultsKey) ?? ""
            let evidenceRaw = UserDefaults.standard.string(forKey: UCShareExtractor.fongMiEvidenceStatusDefaultsKey) ?? ""
            let evidenceStatus = ExternalCaptureStatus(rawValue: evidenceRaw) ?? .captured
            return UCFongMiQRLoginClient.credential(
                kind: .playback,
                token: trimmedToken,
                expiresAt: expiresAt,
                fixtureID: fixtureID.isEmpty ? UCFongMiQRLoginClient.defaultFixtureID : fixtureID,
                sampleStatus: evidenceStatus
            )
        }
    ) {
        self.httpClient = httpClient
        self.client = UCDriveClient(
            httpClient: httpClient,
            originalPlaybackTokenProvider: originalPlaybackTokenProvider,
            originalPlaybackTokenUpdateHandler: originalPlaybackTokenUpdateHandler
        )
        self.cookieDriver = UCCookieDriver(
            httpClient: httpClient,
            originalPlaybackTokenProvider: originalPlaybackTokenProvider,
            originalPlaybackTokenUpdateHandler: originalPlaybackTokenUpdateHandler
        )
        self.cookieProvider = cookieProvider
        self.cookieUpdateHandler = cookieUpdateHandler
        self.tokenProvider = tokenProvider
        self.tokenUpdateHandler = tokenUpdateHandler
        self.fongMiPlaybackTokenProvider = fongMiPlaybackTokenProvider
        self.tvDriver = QuarkTVDriver(provider: .uc, httpClient: httpClient)
    }

    public func match(url: URL) -> Bool {
        if let reference = DriveFileReference.parse(url.absoluteString) {
            return reference.provider == .uc
        }
        if url.scheme?.lowercased() == "uc" { return true }
        return SourceManager.isUCWebShareURL(url)
    }

    public func fetch(url: String) async throws -> String {
        try await fetchResult(url: url).url
    }

    public func fetchResult(url: String) async throws -> SourceFetchResult {
        if let cookie = Self.normalizedCookie(cookieProvider()) {
            let link = try await cookieDriver.link(
                rawURL: url,
                credential: .cookie(provider: .uc, value: cookie)
            )
            if let updatedCookie = link.updatedCredential?.secret,
               updatedCookie != cookie,
               !updatedCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cookieUpdateHandler(updatedCookie)
            }
            let preferredLink = await preferTVOriginalLinkIfAvailable(cookieLink: link)
            let fongMiPreferredLink = await preferFongMiOriginalLinkIfAvailable(cookieLink: preferredLink)
            return streamFetchResult(for: fongMiPreferredLink)
        }

        // UC TV token can validate an account, but the TV file download endpoint
        // cannot download public share fids directly. Wogg share playback must
        // use the cookie share API until share transfer/cache is implemented.
        throw DriveEngineError.loginRequired(.uc)
    }

    private func streamFetchResult(for link: CloudDriveLink) -> SourceFetchResult {
        let headers = playbackHeaders(from: link.headers, route: link.metadata[DrivePlaybackMetadataKey.route])
        var mpvOptions: [String: String] = [:]
        if let streamLavfOptions = Self.streamLavfOptions(headers: headers) {
            mpvOptions["stream-lavf-o"] = streamLavfOptions
        }
        let adapter = UCDrivePlaybackAdapter()
        let playbackPlan = adapter.playbackPlan(
            from: link,
            primaryHeaders: headers,
            primaryMPVOptions: mpvOptions
        )

        return SourceFetchResult(
            url: link.url,
            headers: headers,
            fallbackHeaders: link.fallbackHeaders,
            isDirectMedia: true,
            mpvOptions: mpvOptions,
            metadata: adapter.sanitizedMetadata(link.metadata),
            drivePlaybackPlan: playbackPlan
        )
    }

    private func preferTVOriginalLinkIfAvailable(cookieLink: CloudDriveLink) async -> CloudDriveLink {
        let cookieRoute = cookieLink.metadata[DrivePlaybackMetadataKey.route]
        guard cookieRoute == DrivePlaybackRoute.ucSmartPlay
                || cookieRoute == DrivePlaybackRoute.personalTranscode,
              let fid = cookieLink.metadata[DrivePlaybackMetadataKey.fid],
              !fid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expectedSize = Self.int64Metadata(DrivePlaybackMetadataKey.size, in: cookieLink.metadata),
              expectedSize > 0,
              let token = tokenProvider() else {
            return cookieLink
        }

        let fileName = cookieLink.metadata[DrivePlaybackMetadataKey.fileName] ?? ""
        let reference = DriveFileReference(
            provider: .uc,
            shareURL: "https://drive.uc.cn/",
            pwdID: "",
            fid: fid,
            fidToken: "",
            fileName: fileName
        )

        var originalLink: CloudDriveLink?
        do {
            let tvLink = try await tvDriver.link(reference: reference, credential: token)
            if let updated = tvLink.updatedCredential {
                tokenUpdateHandler(updated)
            }
            if !tvLink.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let probe = try await probeTVOriginalLink(tvLink)
                if (200...399).contains(probe.statusCode),
                   let returnedSize = probe.returnedSize,
                   returnedSize > 0,
                   !Self.isSuspiciousTVOriginalSize(expected: expectedSize, returned: returnedSize) {
                    DiagnosticLog.write("[UC_LINK_SELECT] type=tv-openapi-download context=smart-play-upgrade expected=\(expectedSize) returned=\(returnedSize) url=\(Self.redactedURL(tvLink.url))")
                    originalLink = tvLink
                }
                if originalLink == nil {
                    DiagnosticLog.write(
                        "[UC_LINK_SELECT] type=tv-openapi-download context=smart-play-upgrade-rejected expected=\(expectedSize) returned=\(probe.returnedSize.map { String($0) } ?? "-") status=\(probe.statusCode) contentType=\(probe.contentType) url=\(Self.redactedURL(tvLink.url))"
                    )
                }
            }
        } catch {
            DiagnosticLog.write("[UC_LINK_SELECT] type=tv-openapi-download context=smart-play-upgrade-failed reason=\(error.localizedDescription)")
        }

        var streamingLink: CloudDriveLink?
        do {
            let link = try await tvDriver.streamingLink(
                reference: reference,
                credential: token,
                expectedSize: expectedSize
            )
            if let updated = link.updatedCredential {
                tokenUpdateHandler(updated)
            }
            if !link.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                streamingLink = link
                DiagnosticLog.write(
                    "[UC_LINK_SELECT] type=tv-openapi-streaming context=smart-play-upgrade expected=\(expectedSize) selected=\(link.metadata[DrivePlaybackMetadataKey.selectedReason] ?? "-") url=\(Self.redactedURL(link.url))"
                )
            }
        } catch {
            DiagnosticLog.write("[UC_LINK_SELECT] type=tv-openapi-streaming context=smart-play-upgrade-failed reason=\(error.localizedDescription)")
        }

        if let originalLink {
            return attachingCookieFallback(
                to: originalLink,
                additionalLinks: streamingLink.map { [$0] } ?? [],
                cookieLink: cookieLink
            )
        }
        if let streamingLink {
            return attachingCookieFallback(to: streamingLink, cookieLink: cookieLink)
        }
        return cookieLink
    }

    private func attachingCookieFallback(
        to primaryLink: CloudDriveLink,
        additionalLinks: [CloudDriveLink] = [],
        cookieLink: CloudDriveLink
    ) -> CloudDriveLink {
        var metadata = cookieLink.metadata
        primaryLink.metadata.forEach { metadata[$0.key] = $0.value }
        let adapter = UCDrivePlaybackAdapter()
        let links = [primaryLink] + additionalLinks + [cookieLink]
        let plans = links.compactMap { link in
            adapter.playbackPlan(
                from: link,
                primaryHeaders: playbackHeaders(
                    from: link.headers,
                    route: link.metadata[DrivePlaybackMetadataKey.route]
                ),
                primaryMPVOptions: [:]
            )
        }
        let base = plans.first
        let cookiePlan = plans.last
        let plan = base.map {
            DrivePlaybackPlan(
                provider: .uc,
                asset: cookiePlan?.asset ?? $0.asset,
                candidates: plans.flatMap(\.candidates),
                cleanup: cookiePlan?.cleanup ?? $0.cleanup,
                reauthenticationRequired: plans.contains { $0.reauthenticationRequired },
                unavailableReason: plans.compactMap(\.unavailableReason).first
            )
        }

        return CloudDriveLink(
            url: primaryLink.url,
            headers: primaryLink.headers,
            metadata: metadata,
            updatedCredential: primaryLink.updatedCredential,
            playbackPlan: plan
        )
    }

    private func preferFongMiOriginalLinkIfAvailable(cookieLink: CloudDriveLink) async -> CloudDriveLink {
        guard let credential = fongMiPlaybackTokenProvider(),
              UCFongMiQRLoginClient.isFongMiCredential(credential) else {
            return cookieLink
        }
        let evidenceStatus = credential.metadata[UCFongMiCredentialMetadataKey.evidenceStatus] ?? ""
        guard evidenceStatus == ExternalCaptureStatus.nativeRewriteReady.rawValue else {
            DiagnosticLog.write("[UC_FONGMI_AUTH] playback-token-present evidenceStatus=\(evidenceStatus.isEmpty ? "-" : evidenceStatus) context=keep-cookie-route")
            return cookieLink
        }

        DiagnosticLog.write("[UC_FONGMI_AUTH] playback-token-ready context=private-openapi-pending keep-cookie-route")
        return cookieLink
    }

    private func probeTVOriginalLink(_ link: CloudDriveLink) async throws -> TVOriginalProbe {
        var headers = playbackHeaders(from: link.headers)
        headers["Accept"] = "*/*"
        headers["Range"] = "bytes=0-4194303"

        let response = try await httpClient.request(
            url: link.url,
            method: .get,
            headers: headers,
            timeout: 20,
            allowsProxyFallback: false
        )

        return TVOriginalProbe(
            statusCode: response.statusCode,
            contentLength: Self.int64HeaderValue("Content-Length", in: response.headers),
            contentRangeTotal: Self.contentRangeTotal(in: response.headers),
            contentType: Self.headerValue(named: "Content-Type", in: response.headers) ?? ""
        )
    }

    private func playbackHeaders(from headers: [String: String], route: String? = nil) -> [String: String] {
        if route == DrivePlaybackRoute.ucOpenAPIStreaming
            || route == DrivePlaybackRoute.ucSmartPlay
            || route == DrivePlaybackRoute.personalTranscode {
            return headers
        }
        var playbackHeaders = headers
        if playbackHeaders["User-Agent"] == nil && playbackHeaders["user-agent"] == nil {
            playbackHeaders["User-Agent"] = UCDriveClient.accountPlaybackUserAgent
        }
        if playbackHeaders["Referer"] == nil && playbackHeaders["referer"] == nil {
            playbackHeaders["Referer"] = "https://drive.uc.cn"
        }
        return playbackHeaders
    }

    private static func normalizedCookie(_ cookie: String?) -> String? {
        guard let cookie else { return nil }
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func streamLavfOptions(headers: [String: String]) -> String? {
        guard headerValue(named: "Cookie", in: headers) != nil else {
            return nil
        }

        let orderedHeaderNames = ["Cookie", "Origin", "Referer", "User-Agent"]
        let headerBlock = orderedHeaderNames.compactMap { name -> String? in
            guard let value = headerValue(named: name, in: headers),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return "\(name): \(value)"
        }
        .joined(separator: "\r\n")

        guard !headerBlock.isEmpty else { return nil }
        return "headers=\(headerBlock)\r\n,seekable=1,initial_request_size=64,request_size=4194304"
    }

    private static func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func int64Metadata(_ key: String, in metadata: [String: String]) -> Int64? {
        guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return Int64(value)
    }

    private static func int64HeaderValue(_ name: String, in headers: [String: String]) -> Int64? {
        guard let value = headerValue(named: name, in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return Int64(value)
    }

    private static func contentRangeTotal(in headers: [String: String]) -> Int64? {
        guard let value = headerValue(named: "Content-Range", in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let slash = value.lastIndex(of: "/") else {
            return nil
        }
        let total = value[value.index(after: slash)...]
        guard total != "*" else { return nil }
        return Int64(total)
    }

    private static func isSuspiciousTVOriginalSize(expected: Int64, returned: Int64) -> Bool {
        returned < expected / 4
    }

    private static func redactedURL(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL) else { return rawURL }
        components.queryItems = components.queryItems?.map { item in
            switch item.name.lowercased() {
            case "auth_key", "token", "signature", "ossaccesskeyid", "callback", "callback-var", "access_token", "ut":
                return URLQueryItem(name: item.name, value: "<redacted>")
            default:
                return item
            }
        }
        return components.string ?? rawURL
    }
}

private struct TVOriginalProbe: Sendable {
    let statusCode: Int
    let contentLength: Int64?
    let contentRangeTotal: Int64?
    let contentType: String

    var returnedSize: Int64? {
        contentRangeTotal ?? contentLength
    }
}
