// PlayerEngine/PlaybackProxyPolicy.swift
// 播放代理策略：标准媒体直连优先交给 libmpv，只有必要场景才走本地代理。

import Foundation
import DriveEngine
import Models

public enum PlaybackProxyBypassReason: String, Sendable {
    case localProxy = "local-proxy"
    case localStream = "local-stream"
    case localNodeProvider = "local-node-provider"
    case quarkDownloadCDN = "quark-download-cdn"
    case cloudDriveHeaders = "cloud-drive-headers"
    case directHLS = "direct-hls"
    case directMedia = "direct-media"
    case ucOpenAPIStreamingCDN = "uc-openapi-streaming-cdn"
    case ucSmartPlaySignedURL = "uc-smart-play-signed-url"
    case quarkSmartPlaySignedURL = "quark-smart-play-signed-url"
}

public enum PlaybackProxyPolicy {
    public static let defaultHTTPUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    private static let directMediaExtensions: Set<String> = [
        "m3u8", "mp4", "m4s", "m4a", "m4v", "mov", "mkv", "webm", "flv", "ts", "m2ts", "avi", "wmv"
    ]
    private static let chunkedRelayMinimumSize: Int64 = 512 * 1024 * 1024

    public static func bypassReason(for spec: PlaySpec) -> PlaybackProxyBypassReason? {
        guard let url = URL(string: spec.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return nil
        }

        if host == "127.0.0.1" || host == "localhost" {
            if url.path == "/proxy" {
                return .localProxy
            }
            if url.path == "/stream" {
                return .localStream
            }
            if url.path.lowercased().hasPrefix("/spider/") {
                return .localNodeProvider
            }
        }

        if host.contains("pds.quark.cn") {
            return .quarkDownloadCDN
        }

        let candidate = DrivePlaybackRoutePolicy.candidate(for: spec)
        let provider = spec.drivePlaybackPlan?.provider
        let legacyProvider = DriveProvider(rawValue: spec.metadata[DrivePlaybackMetadataKey.provider] ?? "")
        let legacyRoute = spec.metadata[DrivePlaybackMetadataKey.route]

        if (provider == .uc && candidate?.kind == .streaming)
            || (candidate == nil && legacyProvider == .uc && legacyRoute == DrivePlaybackRoute.ucOpenAPIStreaming) {
            return .ucOpenAPIStreamingCDN
        }

        if ((provider == .uc && candidate?.kind == .transcode)
            || (candidate == nil && legacyProvider == .uc && legacyRoute == DrivePlaybackRoute.ucSmartPlay)),
           host.contains("video-play") {
            return .ucSmartPlaySignedURL
        }

        if ((provider == .quark && candidate?.kind == .transcode)
            || (candidate == nil && legacyProvider == .quark && legacyRoute == DrivePlaybackRoute.personalTranscode)),
           (host == "drive.quark.cn" || host.hasSuffix(".drive.quark.cn")),
           URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
               $0.name.caseInsensitiveCompare("auth_key") == .orderedSame
                   && !($0.value ?? "").isEmpty
           }) == true {
            return .quarkSmartPlaySignedURL
        }

        let userAgent = headerValue(named: "User-Agent", in: spec.headers) ?? ""
        if (host.contains("quark.cn") || host.contains("uc.cn")),
           (userAgent.localizedCaseInsensitiveContains("quark-cloud-drive")
            || userAgent.localizedCaseInsensitiveContains("uc-cloud-drive")) {
            return .cloudDriveHeaders
        }

        if isDirectHLS(url: url, spec: spec) {
            return .directHLS
        }

        if directMediaExtensions.contains(url.pathExtension.lowercased()) {
            return .directMedia
        }

        return nil
    }

    public static func shouldAttemptWebSniff(
        for spec: PlaySpec,
        sourceResolvedDirectMedia: Bool
    ) -> Bool {
        guard !sourceResolvedDirectMedia,
              let url = URL(string: spec.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return bypassReason(for: spec) == nil
    }

    public static func shouldUseRemoteStreamProxy(for spec: PlaySpec) -> Bool {
        guard let url = URL(string: spec.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix(".v.anime1.me"),
           url.pathExtension.lowercased() == "mp4",
           headerValue(named: "Cookie", in: spec.headers)?.isEmpty == false,
           headerValue(named: "Referer", in: spec.headers)?.localizedCaseInsensitiveContains("anime1.me") == true {
            return true
        }
        if let candidate = DrivePlaybackRoutePolicy.candidate(for: spec) {
            return candidate.transport == .localRangeProxy
        }

        // Compatibility for persisted pre-plan specs during an in-process upgrade.
        let provider = spec.metadata[DrivePlaybackMetadataKey.provider]
        let route = spec.metadata[DrivePlaybackMetadataKey.route]
        if route == DrivePlaybackRoute.originalDownload {
            if provider == DriveProvider.quark.rawValue {
                return host.contains("pds.quark.cn")
                    || host.contains("quark.cn")
            }
            if provider == DriveProvider.ali.rawValue {
                return true
            }
        }

        guard route == DrivePlaybackRoute.ucOriginalProxy,
              provider == DriveProvider.uc.rawValue else {
            return false
        }
        return host.contains("pds.uc.cn")
            || host.contains("pds.yun.cn")
            || host.contains("cdn.yun.cn")
            || host.contains("drive.uc.cn")
            || host.contains("uc.cn")
    }

    public static func shouldUseChunkedRangeRelay(for spec: PlaySpec, enabled: Bool) -> Bool {
        guard enabled,
              let url = URL(string: spec.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              !isDirectHLS(url: url, spec: spec),
              isCloudOriginalRoute(spec),
              declaredSize(for: spec) >= chunkedRelayMinimumSize else {
            return false
        }
        return true
    }

    public static func shouldUseLocalHLSProxy(for spec: PlaySpec) -> Bool {
        guard let url = URL(string: spec.url),
              let host = url.host?.lowercased() else {
            return false
        }
        if let candidate = DrivePlaybackRoutePolicy.candidate(for: spec),
           candidate.transport == .hlsRelay {
            return isDirectHLS(url: url, spec: spec)
        }
        let needsCompatibilityRelay = host == "vip.123pan.cn"
            || host == "vd.wmvbo.com"
            || host == "zijieapi.douyinbyte.com"
            || host == "vip.dytt-cinema.com"
            || host == "vip.dytt-cine.com"
            || host == "play.phimgood.com"
            || host == "hhjx.hhplayer.com"
            || bypassReason(for: spec) == .quarkSmartPlaySignedURL
            || isNBYWrappedHLS(url)
        return needsCompatibilityRelay && isDirectHLS(url: url, spec: spec)
    }

    private static func isNBYWrappedHLS(_ url: URL) -> Bool {
        url.port == 9090 && url.path.lowercased().contains("/nby/m3u8/")
    }

    public static func shouldProxyDriveTranscodeHLS(for spec: PlaySpec) -> Bool {
        if let candidate = DrivePlaybackRoutePolicy.candidate(for: spec),
           candidate.transport == .hlsRelay,
           let url = URL(string: spec.url),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return isDirectHLS(url: url, spec: spec)
        }
        guard spec.metadata[DrivePlaybackMetadataKey.route] == DrivePlaybackRoute.personalTranscode,
              spec.metadata[DrivePlaybackRoutePolicy.transportMetadataKey] != DrivePlaybackRoutePolicy.directPlayerTransport,
              let provider = spec.metadata[DrivePlaybackMetadataKey.provider],
              !provider.isEmpty,
              let url = URL(string: spec.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return isDirectHLS(url: url, spec: spec)
    }

    public static func headersForDirectPlayback(_ headers: [String: String]) -> [String: String] {
        guard headerValue(named: "User-Agent", in: headers)?.isEmpty != false else {
            return headers
        }
        var normalized = headers
        normalized["User-Agent"] = defaultHTTPUserAgent
        return normalized
    }

    public static func headersForDirectPlayback(
        _ headers: [String: String],
        reason: PlaybackProxyBypassReason
    ) -> [String: String] {
        switch reason {
        case .ucOpenAPIStreamingCDN, .ucSmartPlaySignedURL, .quarkSmartPlaySignedURL:
            return headers
        default:
            return headersForDirectPlayback(headers)
        }
    }

    public static func mpvOptionsForDirectPlayback(
        reason: PlaybackProxyBypassReason,
        activeProxyPort: Int?
    ) -> [String: String] {
        guard shouldAttachNetworkProxy(for: reason),
              let activeProxyPort,
              activeProxyPort > 0 else {
            return [:]
        }
        return ["http-proxy": "http://127.0.0.1:\(activeProxyPort)"]
    }

    public static func mpvOptionsForLivePlayback(
        reason: PlaybackProxyBypassReason,
        proxyMode: Int,
        customProxyPort: Int,
        existingStreamLavfOptions: String? = nil
    ) -> [String: String] {
        var options = [
            "stream-lavf-o": liveStreamLavfOptions(from: existingStreamLavfOptions)
        ]
        if shouldAttachNetworkProxy(for: reason),
           proxyMode == 2,
           customProxyPort > 0 {
            options["http-proxy"] = "http://127.0.0.1:\(customProxyPort)"
        }
        return options
    }

    public static func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func shouldAttachNetworkProxy(for reason: PlaybackProxyBypassReason) -> Bool {
        switch reason {
        case .directHLS, .directMedia:
            return true
        case .localProxy, .localStream, .localNodeProvider, .quarkDownloadCDN, .cloudDriveHeaders, .ucOpenAPIStreamingCDN, .ucSmartPlaySignedURL, .quarkSmartPlaySignedURL:
            return false
        }
    }

    private static func liveStreamLavfOptions(from existing: String?) -> String {
        let options = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !options.isEmpty else { return "icy=0" }

        let icyOptionPattern = #"(^|,)\s*icy\s*=\s*[^,]*"#
        if options.range(
            of: icyOptionPattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return options.replacingOccurrences(
                of: icyOptionPattern,
                with: "$1icy=0",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return "\(options),icy=0"
    }

    private static func isCloudOriginalRoute(_ spec: PlaySpec) -> Bool {
        if let candidate = DrivePlaybackRoutePolicy.candidate(for: spec) {
            return candidate.kind == .original
        }
        let originalProviders: Set<String> = [
            DriveProvider.quark.rawValue,
            DriveProvider.uc.rawValue,
            DriveProvider.ali.rawValue,
            DriveProvider.p115.rawValue,
            DriveProvider.pikpak.rawValue
        ]
        guard let provider = spec.metadata[DrivePlaybackMetadataKey.provider],
              originalProviders.contains(provider) else {
            return false
        }
        let route = spec.metadata[DrivePlaybackMetadataKey.route]
        return route == DrivePlaybackRoute.originalDownload
            || route == DrivePlaybackRoute.ucOriginalProxy
    }

    private static func declaredSize(for spec: PlaySpec) -> Int64 {
        if let candidate = DrivePlaybackRoutePolicy.candidate(for: spec), candidate.expectedSize > 0 {
            return candidate.expectedSize
        }
        guard let raw = spec.metadata[DrivePlaybackMetadataKey.size]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let size = Int64(raw) else {
            return 0
        }
        return max(0, size)
    }

    private static func isDirectHLS(url: URL, spec: PlaySpec) -> Bool {
        let lowerRawURL = spec.url.lowercased()
        let lowerFormat = spec.format.lowercased()
        return url.pathExtension.lowercased() == "m3u8"
            || lowerRawURL.contains(".m3u8")
            || lowerFormat.contains("hls")
            || lowerFormat.contains("mpegurl")
    }
}
