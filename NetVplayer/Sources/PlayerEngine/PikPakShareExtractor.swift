// PlayerEngine/PikPakShareExtractor.swift
// PikPak file/share references to playable links.

import Foundation
import Models
import Networking
import DriveEngine

public final class PikPakShareExtractor: SourceExtractorProtocol {
    public static let accessTokenDefaultsKey = "pikpakAccessToken"
    public static let refreshTokenDefaultsKey = "pikpakRefreshToken"
    public static let deviceIDDefaultsKey = "pikpakDeviceID"

    private let client: PikPakDriveClient
    private let credentialProvider: @Sendable () -> CloudCredential?
    private let credentialUpdateHandler: @Sendable (CloudCredential) -> Void

    public init(
        httpClient: HTTPClient = .shared,
        credentialProvider: @escaping @Sendable () -> CloudCredential? = {
            let env = ProcessInfo.processInfo.environment
            let accessToken = [
                env["NETVPLAYER_PIKPAK_ACCESS_TOKEN"] ?? "",
                UserDefaults.standard.string(forKey: PikPakShareExtractor.accessTokenDefaultsKey) ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let refreshToken = [
                env["NETVPLAYER_PIKPAK_REFRESH_TOKEN"] ?? "",
                UserDefaults.standard.string(forKey: PikPakShareExtractor.refreshTokenDefaultsKey) ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let deviceID = [
                env["NETVPLAYER_PIKPAK_DEVICE_ID"] ?? "",
                UserDefaults.standard.string(forKey: PikPakShareExtractor.deviceIDDefaultsKey) ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            guard !accessToken.isEmpty || !refreshToken.isEmpty else { return nil }
            var metadata: [String: String] = [:]
            if !accessToken.isEmpty { metadata["access_token"] = accessToken }
            if !refreshToken.isEmpty { metadata["refresh_token"] = refreshToken }
            if !deviceID.isEmpty { metadata["device_id"] = deviceID }
            return CloudCredential(
                provider: .pikpak,
                kind: accessToken.isEmpty ? .refreshToken : .accessToken,
                secret: accessToken,
                refreshToken: refreshToken.isEmpty ? nil : refreshToken,
                accessToken: accessToken.isEmpty ? nil : accessToken,
                deviceID: deviceID.isEmpty ? nil : deviceID,
                metadata: metadata
            )
        },
        credentialUpdateHandler: @escaping @Sendable (CloudCredential) -> Void = { credential in
            UserDefaults.standard.set(credential.accessToken ?? "", forKey: PikPakShareExtractor.accessTokenDefaultsKey)
            UserDefaults.standard.set(credential.refreshToken ?? "", forKey: PikPakShareExtractor.refreshTokenDefaultsKey)
            UserDefaults.standard.set(credential.deviceID ?? credential.metadata["device_id"] ?? "", forKey: PikPakShareExtractor.deviceIDDefaultsKey)
        }
    ) {
        self.client = PikPakDriveClient(httpClient: httpClient)
        self.credentialProvider = credentialProvider
        self.credentialUpdateHandler = credentialUpdateHandler
    }

    public func match(url: URL) -> Bool {
        if let reference = DriveFileReference.parse(url.absoluteString) {
            return reference.provider == .pikpak
        }
        if url.scheme?.lowercased() == "pikpak" { return true }
        return (url.host ?? "").lowercased().contains("mypikpak.com")
    }

    public func fetch(url: String) async throws -> String {
        try await fetchResult(url: url).url
    }

    public func fetchResult(url: String) async throws -> SourceFetchResult {
        guard let credential = credentialProvider() else {
            throw DriveEngineError.loginRequired(.pikpak)
        }

        let link: CloudDriveLink
        if let reference = DriveFileReference.parse(url), reference.provider == .pikpak {
            link = try await client.link(reference: reference, credential: credential)
        } else {
            let share = try client.shareRequest(from: url)
            let files = try await client.collectPlayableFiles(share: share, credential: credential)
            guard let selected = client.selectPlayableFile(from: files, share: share) else {
                throw DriveEngineError.noPlayableFile(share.originalURL)
            }
            link = try await client.link(file: selected.file, credential: credential)
        }

        if let updated = link.updatedCredential {
            credentialUpdateHandler(updated)
        }
        let headers = playbackHeaders(from: link.headers)
        let adapter = PikPakDrivePlaybackAdapter()
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
            playbackHeaders["Referer"] = "https://mypikpak.com/"
        }
        return playbackHeaders
    }
}
