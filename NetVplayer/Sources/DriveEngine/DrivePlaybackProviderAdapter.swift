import Foundation
import Models

public protocol DrivePlaybackProviderAdapter: Sendable {
    var provider: DriveProvider { get }

    func playbackPlan(
        from link: CloudDriveLink,
        primaryHeaders: [String: String],
        primaryMPVOptions: [String: String]
    ) -> DrivePlaybackPlan?

    func cleanupTemporaryFile(
        _ cleanup: DrivePlaybackCleanupDescriptor,
        credential: CloudCredential
    ) async throws -> CloudCredential?
}

public extension DrivePlaybackProviderAdapter {
    func cleanupTemporaryFile(
        _ cleanup: DrivePlaybackCleanupDescriptor,
        credential: CloudCredential
    ) async throws -> CloudCredential? {
        nil
    }

    func playbackPlan(
        from link: CloudDriveLink,
        primaryHeaders: [String: String],
        primaryMPVOptions: [String: String]
    ) -> DrivePlaybackPlan? {
        if let plan = link.playbackPlan {
            return replacingPrimaryTransportDetails(
                in: plan,
                url: link.url,
                headers: primaryHeaders,
                mpvOptions: primaryMPVOptions
            )
        }
        return playbackPlan(
            primaryURL: link.url,
            primaryHeaders: primaryHeaders,
            primaryMPVOptions: primaryMPVOptions,
            primaryMetadata: link.metadata
        )
    }

    func playbackPlan(
        primaryURL: String,
        primaryHeaders: [String: String],
        primaryMPVOptions: [String: String] = [:],
        primaryMetadata: [String: String],
        fallbackURL: String? = nil,
        fallbackHeaders: [String: String] = [:],
        fallbackMetadata: [String: String] = [:],
        reauthenticationRequired: Bool = false,
        unavailableReason: String? = nil
    ) -> DrivePlaybackPlan? {
        guard primaryMetadata[DrivePlaybackMetadataKey.provider] == provider.rawValue,
              let primaryRoute = primaryMetadata[DrivePlaybackMetadataKey.route],
              let primaryKind = candidateKind(for: primaryRoute) else {
            return nil
        }

        let size = Int64(primaryMetadata[DrivePlaybackMetadataKey.size] ?? "") ?? 0
        let sourceFileID = primaryMetadata[DrivePlaybackMetadataKey.personalFileID]
            ?? primaryMetadata[DrivePlaybackMetadataKey.fid]
            ?? ""
        guard !sourceFileID.isEmpty else { return nil }

        var candidates = [candidate(
            route: primaryRoute,
            kind: primaryKind,
            url: primaryURL,
            headers: primaryHeaders,
            mpvOptions: primaryMPVOptions,
            quality: DrivePlaybackQuality(
                value: primaryMetadata[DrivePlaybackMetadataKey.quality] ?? "",
                label: primaryMetadata[DrivePlaybackMetadataKey.qualityLabel] ?? "",
                width: Int(primaryMetadata[DrivePlaybackMetadataKey.width] ?? "") ?? 0,
                height: Int(primaryMetadata[DrivePlaybackMetadataKey.height] ?? "") ?? 0
            ),
            canUpdateProgress: primaryMetadata[DrivePlaybackMetadataKey.canUpdateProgress] == "true",
            expectedSize: size
        )]

        if let fallbackURL,
           let fallbackRoute = fallbackMetadata[DrivePlaybackMetadataKey.route],
           let fallbackKind = candidateKind(for: fallbackRoute),
           !fallbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           fallbackURL != primaryURL {
            candidates.append(candidate(
                route: fallbackRoute,
                kind: fallbackKind,
                url: fallbackURL,
                headers: fallbackHeaders,
                mpvOptions: [:],
                quality: DrivePlaybackQuality(
                    value: fallbackMetadata[DrivePlaybackMetadataKey.quality] ?? "",
                    label: fallbackMetadata[DrivePlaybackMetadataKey.qualityLabel] ?? "",
                    width: Int(fallbackMetadata[DrivePlaybackMetadataKey.width] ?? "") ?? 0,
                    height: Int(fallbackMetadata[DrivePlaybackMetadataKey.height] ?? "") ?? 0
                ),
                canUpdateProgress: fallbackMetadata[DrivePlaybackMetadataKey.canUpdateProgress]
                    .map { $0 == "true" }
                    ?? (primaryMetadata[DrivePlaybackMetadataKey.canUpdateProgress] == "true"),
                expectedSize: size
            ))
        }

        let cleanup: DrivePlaybackCleanupDescriptor?
        if primaryMetadata[DrivePlaybackMetadataKey.temporarySavedFile] == "true" {
            cleanup = DrivePlaybackCleanupDescriptor(
                provider: provider,
                driveID: primaryMetadata[DrivePlaybackMetadataKey.driveID] ?? "",
                fileID: sourceFileID,
                cacheKey: primaryMetadata[DrivePlaybackMetadataKey.cacheKey] ?? "",
                isTemporary: true
            )
        } else {
            cleanup = nil
        }

        return DrivePlaybackPlan(
            provider: provider,
            asset: DrivePlaybackAssetIdentity(
                provider: provider,
                shareID: primaryMetadata[DrivePlaybackMetadataKey.cacheKey] ?? "",
                sourceFileID: sourceFileID,
                size: size
            ),
            candidates: candidates,
            cleanup: cleanup,
            reauthenticationRequired: reauthenticationRequired,
            unavailableReason: unavailableReason
        )
    }

    func sanitizedMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata
    }

    private func candidate(
        route: String,
        kind: DrivePlaybackCandidateKind,
        url: String,
        headers: [String: String],
        mpvOptions: [String: String],
        quality: DrivePlaybackQuality,
        canUpdateProgress: Bool,
        expectedSize: Int64
    ) -> DrivePlaybackCandidate {
        DrivePlaybackCandidate(
            id: "\(provider.rawValue):\(route)",
            providerRoute: route,
            kind: kind,
            transport: transport(for: kind, route: route, url: url),
            url: url,
            headers: headers,
            mpvOptions: mpvOptions,
            quality: quality,
            refreshPolicy: refreshPolicy(for: kind),
            canUpdateProgress: canUpdateProgress,
            expectedSize: expectedSize
        )
    }

    private func replacingPrimaryTransportDetails(
        in plan: DrivePlaybackPlan,
        url: String,
        headers: [String: String],
        mpvOptions: [String: String]
    ) -> DrivePlaybackPlan {
        var replaced = false
        let candidates = plan.candidates.map { value -> DrivePlaybackCandidate in
            guard !replaced, value.url == url else { return value }
            replaced = true
            return DrivePlaybackCandidate(
                id: value.id,
                providerRoute: value.providerRoute,
                kind: value.kind,
                transport: value.transport,
                url: value.url,
                headers: headers,
                mpvOptions: mpvOptions,
                quality: value.quality,
                refreshPolicy: value.refreshPolicy,
                canUpdateProgress: value.canUpdateProgress,
                expectedSize: value.expectedSize
            )
        }
        return DrivePlaybackPlan(
            provider: plan.provider,
            asset: plan.asset,
            candidates: candidates,
            cleanup: plan.cleanup,
            reauthenticationRequired: plan.reauthenticationRequired,
            unavailableReason: plan.unavailableReason
        )
    }

    private func candidateKind(for route: String) -> DrivePlaybackCandidateKind? {
        switch route {
        case DrivePlaybackRoute.originalDownload, DrivePlaybackRoute.ucOriginalProxy:
            return .original
        case DrivePlaybackRoute.ucOpenAPIStreaming, DrivePlaybackRoute.streamVariant:
            return .streaming
        case DrivePlaybackRoute.personalTranscode, DrivePlaybackRoute.ucSmartPlay:
            return .transcode
        case DrivePlaybackRoute.shareFallback:
            return .shareFallback
        default:
            return nil
        }
    }

    private func transport(
        for kind: DrivePlaybackCandidateKind,
        route _: String,
        url: String
    ) -> DrivePlaybackTransport {
        switch kind {
        case .original, .shareFallback:
            return .localRangeProxy
        case .streaming:
            if provider == .pikpak {
                let path = URL(string: url)?.path.lowercased() ?? url.lowercased()
                return path.contains(".m3u8") ? .hlsRelay : .direct
            }
            return .direct
        case .transcode:
            if provider == .uc { return .direct }
            let path = URL(string: url)?.path.lowercased() ?? url.lowercased()
            return path.contains(".m3u8") ? .hlsRelay : .direct
        }
    }

    private func refreshPolicy(for kind: DrivePlaybackCandidateKind) -> DrivePlaybackRefreshPolicy {
        if provider == .ali || provider == .pikpak {
            return .refreshCredentialAndURLOnce
        }
        return kind == .shareFallback ? .none : .refreshURLOnce
    }
}

public struct QuarkDrivePlaybackAdapter: DrivePlaybackProviderAdapter {
    public let provider: DriveProvider = .quark
    public init() {}

    public func cleanupTemporaryFile(
        _ cleanup: DrivePlaybackCleanupDescriptor,
        credential: CloudCredential
    ) async throws -> CloudCredential? {
        guard !cleanup.cacheKey.isEmpty else {
            throw DriveEngineError.unsupported("夸克临时文件缺少缓存标识。")
        }
        return try await QuarkCookieDriver().deleteSavedPlaybackFile(
            cacheKey: cleanup.cacheKey,
            fid: cleanup.fileID,
            credential: credential
        )
    }
}

public struct UCDrivePlaybackAdapter: DrivePlaybackProviderAdapter {
    public let provider: DriveProvider = .uc
    public init() {}

    public func cleanupTemporaryFile(
        _ cleanup: DrivePlaybackCleanupDescriptor,
        credential: CloudCredential
    ) async throws -> CloudCredential? {
        guard !cleanup.cacheKey.isEmpty else {
            throw DriveEngineError.unsupported("UC 临时文件缺少缓存标识。")
        }
        return try await UCCookieDriver().deleteSavedPlaybackFile(
            cacheKey: cleanup.cacheKey,
            fid: cleanup.fileID,
            credential: credential
        )
    }
}

public struct AliDrivePlaybackAdapter: DrivePlaybackProviderAdapter {
    public let provider: DriveProvider = .ali
    public init() {}

    public func cleanupTemporaryFile(
        _ cleanup: DrivePlaybackCleanupDescriptor,
        credential: CloudCredential
    ) async throws -> CloudCredential? {
        guard !cleanup.driveID.isEmpty else {
            throw DriveEngineError.unsupported("阿里云盘临时文件缺少 drive ID。")
        }
        return try await AliDriveClient().deleteTemporaryPlaybackFile(
            driveID: cleanup.driveID,
            fileID: cleanup.fileID,
            cacheKey: cleanup.cacheKey,
            credential: credential
        )
    }
}

public struct P115DrivePlaybackAdapter: DrivePlaybackProviderAdapter {
    public let provider: DriveProvider = .p115
    public init() {}

    public func cleanupTemporaryFile(
        _ cleanup: DrivePlaybackCleanupDescriptor,
        credential: CloudCredential
    ) async throws -> CloudCredential? {
        try await P115DriveClient().deleteTemporaryPlaybackFile(
            fileID: cleanup.fileID,
            credential: credential
        )
        return nil
    }
}

public struct PikPakDrivePlaybackAdapter: DrivePlaybackProviderAdapter {
    public let provider: DriveProvider = .pikpak
    public init() {}
}

public struct BaiduDrivePlaybackAdapter: DrivePlaybackProviderAdapter {
    public let provider: DriveProvider = .baidu
    public init() {}

    public func cleanupTemporaryFile(
        _ cleanup: DrivePlaybackCleanupDescriptor,
        credential: CloudCredential
    ) async throws -> CloudCredential? {
        guard !cleanup.cacheKey.isEmpty else {
            throw DriveEngineError.unsupported("百度网盘临时文件缺少缓存标识。")
        }
        return try await BaiduDriveClient().deleteTemporaryPlaybackFile(
            cacheKey: cleanup.cacheKey,
            fileID: cleanup.fileID,
            credential: credential
        )
    }
}

public enum DrivePlaybackProviderAdapters {
    public static func adapter(for provider: DriveProvider) -> any DrivePlaybackProviderAdapter {
        switch provider {
        case .quark: return QuarkDrivePlaybackAdapter()
        case .uc: return UCDrivePlaybackAdapter()
        case .ali: return AliDrivePlaybackAdapter()
        case .p115: return P115DrivePlaybackAdapter()
        case .pikpak: return PikPakDrivePlaybackAdapter()
        case .baidu: return BaiduDrivePlaybackAdapter()
        default: return UnsupportedDrivePlaybackAdapter(provider: provider)
        }
    }
}

private struct UnsupportedDrivePlaybackAdapter: DrivePlaybackProviderAdapter {
    let provider: DriveProvider

    func playbackPlan(
        from link: CloudDriveLink,
        primaryHeaders: [String: String],
        primaryMPVOptions: [String: String]
    ) -> DrivePlaybackPlan? {
        nil
    }
}
