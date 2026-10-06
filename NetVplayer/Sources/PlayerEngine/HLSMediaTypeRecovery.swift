import Foundation
import Models
import Networking

/// Preserve native evidence separately from localized, user-facing error text.
public struct MPVPlaybackFailure: Equatable, Sendable {
    public var message: String
    public var nativeError: Int32?
    public var httpStatus: Int?
    public var playbackStarted: Bool

    public init(message: String, nativeError: Int32? = nil, httpStatus: Int? = nil, playbackStarted: Bool = false) {
        self.message = message
        self.nativeError = nativeError
        self.httpStatus = httpStatus
        self.playbackStarted = playbackStarted
    }
}

/// A single, bounded format probe for streams whose URL/MIME conceals HLS.
public enum HLSMediaTypeRecovery {
    public static let attemptedKey = "hls.typeRecoveryAttempted"
    public static let maximumBytes = 256 * 1024

    public static func eligible(_ spec: PlaySpec, failure: MPVPlaybackFailure) -> Bool {
        guard !failure.playbackStarted,
              failure.httpStatus == nil,
              let code = failure.nativeError, [-13, -17, -18].contains(code),
              spec.metadata[attemptedKey] != "true", spec.metadata[HLSRecovery.attemptedKey] != "true",
              spec.drm == nil, spec.drivePlaybackPlan == nil,
              let url = URL(string: spec.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return false }
        let format = spec.format.lowercased()
        return !format.contains("hls") && !format.contains("mpegurl") && url.pathExtension.lowercased() != "m3u8"
    }

    public static func isHLS(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes,
              var text = String(data: data, encoding: .utf8), !text.contains("\0") else { return false }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U", lines.count <= 8192 else { return false }
        let hasURI = lines.contains { !$0.isEmpty && !$0.hasPrefix("#") }
        let hasMaster = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        let hasMedia = lines.contains { $0.hasPrefix("#EXT-X-TARGETDURATION:") }
            && lines.contains { $0.hasPrefix("#EXTINF:") }
        return hasURI && (hasMaster || hasMedia)
    }

    public static func recovering(_ spec: PlaySpec) -> PlaySpec {
        var result = spec
        result.metadata[attemptedKey] = "true"
        result.format = "hls"
        result.mpvOptions["demuxer-lavf-format"] = "hls"
        return result
    }

    public static func prepare(_ spec: PlaySpec, client: HTTPClient = .shared,
                               budget: Duration = .seconds(4)) async throws -> Bool {
        let client = PlaybackProbeTransport.client(for: spec, using: client)
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                let response = try await client.getBounded(
                    url: spec.url, headers: spec.headers, maximumBytes: maximumBytes,
                    timeout: 4, allowsProxyFallback: false
                )
                try Task.checkCancellation()
                return isHLS(response.data)
            }
            group.addTask { try await Task.sleep(for: budget); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
    }
}
