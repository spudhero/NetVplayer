// PlayerEngine/LiveHLSRelayPolicy.swift
// Helpers for falling back from direct live HLS playback to the local playlist relay.

import Foundation
import DriveEngine
import Models
import ProxyServer

public enum LiveHLSRelayPolicy {
    public static let transportMetadataKey = "live.transport"
    public static let probePlayableMetadataKey = "live.probePlayable"
    public static let sourceByteOffsetMetadataKey = "stream.sourceByteOffset"

    public static let directTransport = "direct-live-hls"
    public static let directMediaTransport = "direct-live-media"
    public static let localRelayTransport = "local-hls-relay"
    public static let localStreamRelayTransport = "local-stream-relay"
    private static let driveSizeMetadataKey = "drive.size"

    public static func shouldRetryWithLocalRelay(spec: PlaySpec, failureMessage: String) -> Bool {
        guard spec.metadata[transportMetadataKey] == directTransport,
              PlaybackProxyPolicy.bypassReason(for: spec) == .directHLS else {
            return false
        }

        return isRecoverableNetworkReadFailure(failureMessage)
    }

    public static func shouldRetryWithLocalStreamRelay(spec: PlaySpec, failureMessage: String) -> Bool {
        guard spec.metadata[transportMetadataKey] == directMediaTransport,
              PlaybackProxyPolicy.bypassReason(for: spec) == .directMedia else {
            return false
        }

        return isRecoverableNetworkReadFailure(failureMessage)
    }

    private static func isRecoverableNetworkReadFailure(_ failureMessage: String) -> Bool {
        let lower = failureMessage.lowercased()
        return lower.contains("loading failed")
            || lower.contains("end of file")
            || lower.contains("connection reset by peer")
            || lower.contains("源站连接被中断")
            || lower.contains("连接被中断")
            || lower.contains("tls")
            || lower.contains("io error")
            || lower.contains("unexpected_eof")
            || lower.contains("failed to open")
    }

    public static func shouldSkipDirectPlaybackForProbe(isPlayable: Bool, statusCode: Int, bodyPrefix: String) -> Bool {
        let deterministicFailure = switch statusCode {
        case 401, 403, 404, 410, 419, 440, 502, 605: true
        default: false
        }
        guard !isPlayable, deterministicFailure else { return false }
        return !bodyPrefix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    public static func localRelaySpec(from spec: PlaySpec, proxyPort: Int) -> PlaySpec? {
        guard let relayURL = localRelayURL(for: spec.url, headers: spec.headers, proxyPort: proxyPort) else {
            return nil
        }

        var relaySpec = spec
        relaySpec.url = relayURL
        relaySpec.metadata[transportMetadataKey] = localRelayTransport
        relaySpec.mpvOptions.removeValue(forKey: "http-proxy")
        return relaySpec
    }

    public static func localStreamRelaySpec(
        from spec: PlaySpec,
        proxyServer: ProxyServer = .shared,
        relayMode: RemoteStreamRelayMode = .buffered
    ) -> PlaySpec? {
        let contentLength = spec.metadata[driveSizeMetadataKey].flatMap(Int64.init)
        let sourceByteOffset = sourceByteOffset(for: spec)
        let bufferConfiguration = remoteStreamBufferConfiguration(for: spec)
        let parallelUpstream = parallelSegmentedOpenEndedUpstreamConfiguration(for: spec)
        let relayURL = proxyServer.registerRemoteStream(
            url: spec.url,
            headers: spec.headers,
            contentType: contentType(for: spec),
            contentLength: contentLength,
            sourceByteOffset: sourceByteOffset,
            continuousOpenEndedResponses: relayMode == .buffered,
            parallelSegmentedOpenEndedUpstream: parallelUpstream != nil,
            parallelUpstreamUsesCurl: parallelUpstream?.usesCurl ?? false,
            parallelUpstreamSegmentSize: parallelUpstream?.segmentSize ?? 5 * 1024 * 1024,
            parallelUpstreamConcurrency: parallelUpstream?.concurrency ?? 3,
            bufferConfiguration: bufferConfiguration,
            relayMode: relayMode
        )
        guard !relayURL.isEmpty else { return nil }

        var relaySpec = spec
        relaySpec.url = relayURL
        relaySpec.metadata[transportMetadataKey] = localStreamRelayTransport
        relaySpec.metadata["stream.relayMode"] = relayMode.rawValue
        relaySpec.mpvOptions.removeValue(forKey: "http-proxy")
        relaySpec.mpvOptions.removeValue(forKey: "stream-lavf-o")
        if sourceByteOffset > 0 {
            relaySpec.metadata[sourceByteOffsetMetadataKey] = String(sourceByteOffset)
            if let remainingOptions = demuxerOptionsWithoutInitialByteSkip(
                spec.mpvOptions["demuxer-lavf-o"]
            ) {
                relaySpec.mpvOptions["demuxer-lavf-o"] = remainingOptions
            } else {
                relaySpec.mpvOptions.removeValue(forKey: "demuxer-lavf-o")
            }
        }
        return relaySpec
    }

    static func parallelSegmentedOpenEndedUpstreamConfiguration(
        for spec: PlaySpec
    ) -> (usesCurl: Bool, segmentSize: Int64, concurrency: Int)? {
        let provider = spec.metadata[DrivePlaybackMetadataKey.provider]
        let route = spec.metadata[DrivePlaybackMetadataKey.route]
        if provider == DriveProvider.uc.rawValue && route == DrivePlaybackRoute.ucOriginalProxy {
            return (usesCurl: true, segmentSize: 512 * 1024, concurrency: 16)
        }
        if provider == DriveProvider.p115.rawValue && route == DrivePlaybackRoute.originalDownload {
            return (usesCurl: false, segmentSize: 512 * 1024, concurrency: 2)
        }
        return nil
    }

    static func remoteStreamBufferConfiguration(for spec: PlaySpec) -> RemoteStreamBufferConfiguration {
        let provider = spec.metadata[DrivePlaybackMetadataKey.provider]
        let route = spec.metadata[DrivePlaybackMetadataKey.route]
        let isOriginal = route == DrivePlaybackRoute.originalDownload
            || route == DrivePlaybackRoute.ucOriginalProxy
        guard isOriginal else {
            return .default
        }

        if provider == DriveProvider.ali.rawValue {
            return RemoteStreamBufferConfiguration(
                initialChunkSize: 1 * 1024 * 1024,
                chunkSize: 1 * 1024 * 1024,
                prefetchWindowSize: 16 * 1024 * 1024,
                maxBytes: 32 * 1024 * 1024,
                maxConcurrentPrefetches: 2
            )
        }

        if provider == DriveProvider.p115.rawValue {
            return RemoteStreamBufferConfiguration(
                initialChunkSize: 512 * 1024,
                chunkSize: 512 * 1024,
                prefetchWindowSize: 8 * 1024 * 1024,
                maxBytes: 32 * 1024 * 1024,
                maxConcurrentPrefetches: 1
            )
        }

        let cloudOriginalProviders: Set<String> = [
            DriveProvider.quark.rawValue,
            DriveProvider.uc.rawValue,
            DriveProvider.pikpak.rawValue
        ]
        guard let provider, cloudOriginalProviders.contains(provider) else {
            return .default
        }

        return RemoteStreamBufferConfiguration(
            initialChunkSize: 4 * 1024 * 1024,
            chunkSize: 4 * 1024 * 1024,
            prefetchWindowSize: 32 * 1024 * 1024,
            maxBytes: 64 * 1024 * 1024,
            maxConcurrentPrefetches: 2
        )
    }

    private static func sourceByteOffset(for spec: PlaySpec) -> Int64 {
        guard spec.mpvOptions["demuxer-lavf-format"]?.lowercased() == "mov",
              let options = spec.mpvOptions["demuxer-lavf-o"] else {
            return 0
        }

        return options
            .split(separator: ",")
            .compactMap { option -> Int64? in
                let parts = option.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "skip_initial_bytes",
                      let value = Int64(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                      value > 0 else {
                    return nil
                }
                return value
            }
            .first ?? 0
    }

    private static func demuxerOptionsWithoutInitialByteSkip(_ options: String?) -> String? {
        guard let options else { return nil }
        let remaining = options
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.hasPrefix("skip_initial_bytes=") && !$0.isEmpty }
            .joined(separator: ",")
        return remaining.isEmpty ? nil : remaining
    }

    public static func localRelayURL(
        for url: String,
        headers: [String: String],
        proxyPort: Int,
        streaming: Bool = false
    ) -> String? {
        let headersData = try? JSONSerialization.data(withJSONObject: headers)
        let headersString = headersData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = proxyPort
        components.path = "/proxy"
        components.queryItems = [
            URLQueryItem(name: "u64", value: ProxyURLCodec.encode(url)),
            URLQueryItem(name: "h64", value: ProxyURLCodec.encode(headersString))
        ]
        if streaming {
            components.queryItems?.append(URLQueryItem(name: "stream", value: "1"))
        }
        return components.url?.absoluteString
    }

    private static func contentType(for spec: PlaySpec) -> String {
        let lowerFormat = spec.format.lowercased()
        if lowerFormat.contains("flv") { return "video/x-flv" }
        if lowerFormat.contains("mp2t") || lowerFormat.contains("mpegts") { return "video/mp2t" }
        if lowerFormat.contains("mp4") { return "video/mp4" }

        let pathExtension = URL(string: spec.url)?.pathExtension.lowercased() ?? ""
        switch pathExtension {
        case "flv": return "video/x-flv"
        case "ts", "m2ts": return "video/mp2t"
        case "mp4", "m4v", "mov": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
}
