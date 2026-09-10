// DriveEngine/DriveShareExpander.swift
// 将网盘分享目录展开成具体可选的剧集文件。

import Foundation
import Models
import Networking

public protocol DriveShareExpanding: Sendable {
    func canExpand(url: String) -> Bool
    func expand(url: String, fallbackTitle: String) async throws -> [Episode]
}

public enum DriveShareExpansionOutcome: Sendable {
    case expanded([Episode])
    case unavailable(reason: String)
}

public final class DriveShareExpander: @unchecked Sendable {
    public static let shared = DriveShareExpander()

    private let expanders: [any DriveShareExpanding]

    public init(expanders: [any DriveShareExpanding] = [
        QuarkDriveShareExpander(),
        UCDriveShareExpander(),
        AliDriveShareExpander(),
        P115DriveShareExpander(),
        PikPakDriveShareExpander(),
        BaiduDriveShareExpander()
    ]) {
        self.expanders = expanders
    }

    public convenience init(httpClient: HTTPClient) {
        self.init(expanders: [
            QuarkDriveShareExpander(httpClient: httpClient),
            UCDriveShareExpander(httpClient: httpClient),
            AliDriveShareExpander(httpClient: httpClient),
            P115DriveShareExpander(httpClient: httpClient),
            PikPakDriveShareExpander(httpClient: httpClient),
            BaiduDriveShareExpander(httpClient: httpClient)
        ])
    }

    public func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        guard let expander = expanders.first(where: { $0.canExpand(url: url) }) else {
            throw DriveEngineError.unsupported("该网盘分享暂未适配目录展开")
        }
        return try await expander.expand(url: url, fallbackTitle: fallbackTitle)
    }

    public func expansionOutcome(url: String, fallbackTitle: String) async -> DriveShareExpansionOutcome {
        if Self.isDirectMediaURL(url) {
            return .expanded([Episode(name: fallbackTitle, url: url)])
        }

        do {
            let episodes = try await expand(url: url, fallbackTitle: fallbackTitle)
            guard !episodes.isEmpty else {
                let reason = "未找到视频文件"
                logUnavailableExpansion(url: url, reason: reason)
                return .unavailable(reason: reason)
            }
            return .expanded(episodes)
        } catch DriveEngineError.noPlayableFile {
            let reason = "未找到视频文件"
            logUnavailableExpansion(url: url, reason: reason)
            return .unavailable(reason: reason)
        } catch {
            let reason = unavailableReason(for: error)
            let resolvedReason = reason.isEmpty ? "网盘目录展开失败" : reason
            logUnavailableExpansion(url: url, reason: resolvedReason)
            return .unavailable(reason: resolvedReason)
        }
    }

    private func unavailableReason(for error: Error) -> String {
        guard let driveError = error as? DriveEngineError else {
            return error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch driveError {
        case .unsupported(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        case .loginRequired(let provider):
            return "\(provider.displayName)需要授权"
        case .noPlayableFile:
            return "未找到视频文件"
        case .api(_, _, _, let message) where !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return driveError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func logUnavailableExpansion(url: String, reason: String) {
        let provider = DriveFileReference.provider(for: url)
        DiagnosticLog.write("[DRIVE_SHARE_EXPANSION_UNAVAILABLE] provider=\(provider.rawValue) reason=\(reason)")
    }

    private static func isDirectMediaURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }
        return [
            "mp4", "mkv", "avi", "mov", "webm", "m4v", "ts", "m2ts",
            "m3u8", "mpd", "flv", "wmv"
        ].contains(url.pathExtension.lowercased())
    }
}

public struct QuarkDriveShareExpander: DriveShareExpanding {
    private let client: QuarkDriveClient

    public init(httpClient: HTTPClient = .shared) {
        self.client = QuarkDriveClient(httpClient: httpClient)
    }

    public func canExpand(url: String) -> Bool {
        DriveFileReference.provider(for: url) == .quark
    }

    public func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        let share = try client.shareRequest(from: url)
        let files = try await client.collectPlayableFiles(share: share)
        guard !files.isEmpty else {
            throw DriveEngineError.noPlayableFile(url)
        }

        return files.enumerated().map { index, playable in
            let reference = client.fileReference(for: playable, share: share, collectionName: fallbackTitle)
            return Episode(
                name: DriveEpisodeNameFormatter.displayName(
                    for: playable.file.name,
                    fallbackTitle: fallbackTitle,
                    index: index,
                    total: files.count
                ),
                url: reference.encodedURL
            )
        }
    }

}

public struct UCDriveShareExpander: DriveShareExpanding {
    private let client: UCDriveClient

    public init(httpClient: HTTPClient = .shared) {
        self.client = UCDriveClient(httpClient: httpClient)
    }

    public func canExpand(url: String) -> Bool {
        DriveFileReference.provider(for: url) == .uc
    }

    public func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        let share = try client.shareRequest(from: url)
        let files = try await client.collectPlayableFiles(share: share)
        guard !files.isEmpty else {
            throw DriveEngineError.noPlayableFile(url)
        }

        return files.enumerated().map { index, playable in
            let reference = client.fileReference(for: playable, share: share, collectionName: fallbackTitle)
            return Episode(
                name: DriveEpisodeNameFormatter.displayName(
                    for: playable.file.name,
                    fallbackTitle: fallbackTitle,
                    index: index,
                    total: files.count
                ),
                url: reference.encodedURL
            )
        }
    }

}

public struct AliDriveShareExpander: DriveShareExpanding {
    private let client: AliDriveClient

    public init(httpClient: HTTPClient = .shared) {
        self.client = AliDriveClient(httpClient: httpClient)
    }

    public func canExpand(url: String) -> Bool {
        DriveFileReference.provider(for: url) == .ali
    }

    public func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        let share = try client.shareRequest(from: url)
        let files = try await client.collectPlayableFiles(share: share)
        guard !files.isEmpty else {
            throw DriveEngineError.noPlayableFile(url)
        }

        return files.enumerated().map { index, playable in
            let reference = client.fileReference(for: playable, share: share, collectionName: fallbackTitle)
            return Episode(
                name: DriveEpisodeNameFormatter.displayName(
                    for: playable.file.name,
                    fallbackTitle: fallbackTitle,
                    index: index,
                    total: files.count
                ),
                url: reference.encodedURL
            )
        }
    }
}

public struct P115DriveShareExpander: DriveShareExpanding {
    private let client: P115DriveClient

    public init(httpClient: HTTPClient = .shared) {
        self.client = P115DriveClient(httpClient: httpClient)
    }

    public func canExpand(url: String) -> Bool {
        DriveFileReference.provider(for: url) == .p115
    }

    public func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        let share = try client.shareRequest(from: url)
        let files = try await client.collectPlayableFiles(share: share)
        guard !files.isEmpty else {
            throw DriveEngineError.noPlayableFile(url)
        }

        return files.enumerated().map { index, playable in
            let reference = client.fileReference(for: playable, share: share, collectionName: fallbackTitle)
            return Episode(
                name: DriveEpisodeNameFormatter.displayName(
                    for: playable.file.name,
                    fallbackTitle: fallbackTitle,
                    index: index,
                    total: files.count
                ),
                url: reference.encodedURL
            )
        }
    }
}

public struct PikPakDriveShareExpander: DriveShareExpanding {
    private let client: PikPakDriveClient
    private let credentialProvider: @Sendable () -> CloudCredential?

    public init(
        httpClient: HTTPClient = .shared,
        credentialProvider: @escaping @Sendable () -> CloudCredential? = {
            let env = ProcessInfo.processInfo.environment
            let accessToken = [
                env["NETVPLAYER_PIKPAK_ACCESS_TOKEN"] ?? "",
                UserDefaults.standard.string(forKey: "pikpakAccessToken") ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let refreshToken = [
                env["NETVPLAYER_PIKPAK_REFRESH_TOKEN"] ?? "",
                UserDefaults.standard.string(forKey: "pikpakRefreshToken") ?? ""
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let deviceID = [
                env["NETVPLAYER_PIKPAK_DEVICE_ID"] ?? "",
                UserDefaults.standard.string(forKey: "pikpakDeviceID") ?? ""
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
        }
    ) {
        self.client = PikPakDriveClient(httpClient: httpClient)
        self.credentialProvider = credentialProvider
    }

    public func canExpand(url: String) -> Bool {
        DriveFileReference.provider(for: url) == .pikpak
    }

    public func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        let share = try client.shareRequest(from: url)
        let files = try await client.collectPlayableFiles(share: share, credential: credentialProvider())
        guard !files.isEmpty else {
            throw DriveEngineError.noPlayableFile(url)
        }

        return files.enumerated().map { index, playable in
            let reference = client.fileReference(for: playable, share: share, collectionName: fallbackTitle)
            return Episode(
                name: DriveEpisodeNameFormatter.displayName(
                    for: playable.file.name,
                    fallbackTitle: fallbackTitle,
                    index: index,
                    total: files.count
                ),
                url: reference.encodedURL
            )
        }
    }
}

public struct BaiduDriveShareExpander: DriveShareExpanding {
    private let client: BaiduDriveClient

    public init(httpClient: HTTPClient = .shared) {
        self.client = BaiduDriveClient(httpClient: httpClient)
    }

    public func canExpand(url: String) -> Bool {
        DriveFileReference.provider(for: url) == .baidu
    }

    public func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        let share = try client.shareRequest(from: url)
        let expanded = try await client.expandedFiles(share: share)
        guard !expanded.files.isEmpty else {
            throw DriveEngineError.noPlayableFile(url)
        }

        return expanded.files.map { file in
            let reference = client.fileReference(
                for: file,
                share: share,
                shareID: expanded.shareID,
                shareUK: expanded.shareUK,
                collectionName: fallbackTitle
            )
            return Episode(name: "[\(Self.sizeLabel(file.size))]\(file.name)", url: reference.encodedURL)
        }
    }

    private static func sizeLabel(_ bytes: Int64) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let value = Double(max(bytes, 0))
        if bytes >= 1_073_741_824 {
            return String(format: "%.2fGB", locale: locale, value / 1_073_741_824)
        }
        if bytes >= 1_048_576 {
            return String(format: "%.2fMB", locale: locale, value / 1_048_576)
        }
        if bytes >= 1_024 {
            return String(format: "%.2fKB", locale: locale, value / 1_024)
        }
        return "\(max(bytes, 0))B"
    }
}

private enum DriveEpisodeNameFormatter {
    static func displayName(for fileName: String, fallbackTitle: String, index: Int, total: Int) -> String {
        let cleaned = fileName
            .replacingOccurrences(of: #"\.(mp4|m4v|mov|m3u8|mkv|ts|flv|webm)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "$", with: " ")
            .replacingOccurrences(of: "#", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if total == 1 {
            let fallback = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || (!fallback.isEmpty && (cleaned.localizedCaseInsensitiveContains(fallback) || fallback.localizedCaseInsensitiveContains(cleaned))) {
                return "正片"
            }
        }

        return cleaned.isEmpty ? String(format: "第%02d集", index + 1) : cleaned
    }
}
