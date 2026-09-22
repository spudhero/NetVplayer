import Foundation

/// The remote channel is a projection of local diagnostics, never a copy of a log line.
/// In particular, free-form error text, URLs, headers, titles and response bodies stay local.
public struct RemoteDiagnosticRecord: Equatable, Sendable {
    public let code: String
    public let isError: Bool
    public let measurements: [String: Int]

    private static let errorCodes: Set<String> = [
        "SENTRY_VERIFICATION",
        "CONFIG_LOAD_FAILED", "CATALOG_LOAD_FAILED", "PLAYBACK_PREPARE_FAILED",
        "CLOUD_AUTH_FAILED", "PROVIDER_INSTALL_FAILED",
        "MPV_SEEK_ERROR", "MPV_SUBTITLE_ERROR", "MPV_AUDIO_ERROR",
        "PROXY_SERVER_ERROR", "PROXY_UPSTREAM_ERROR", "PROXY_UPSTREAM_STREAM_ERROR",
        "REMOTE_STREAM_UPSTREAM_ERROR", "PLAYBACK_RECOVERY_FAILED",
        "LIVE_CONTENT_RECOVERY_FAILED",
        "DRIVE_PLAYBACK_ROUTE_REFRESH_FAILED",
    ]
    private static let breadcrumbCodes: Set<String> = [
        "CONFIG_LOAD_STARTED", "CONFIG_LOAD_SUCCEEDED", "CONFIG_LOAD_CANCELLED",
        "MPV_INIT", "MPV_PLAY", "MPV_STARTED", "MPV_DESTROY", "MPV_SEEK",
        "MPV_CACHE_STALL", "MPV_TRACK", "MPV_TRACK_DETECTED", "MPV_ERROR",
        "REMOTE_STREAM_ERROR",
        "VOD_PLAYER_EXIT", "LIVE_CONTENT_REFRESH", "LIVE_CONTENT_REFRESHED",
        "LIVE_CONTENT_REFRESH_FAILED",
        "LIVE_RESUME_SELECTED", "LIVE_TRANSPORT", "DRIVE_PLAYBACK_WARNING",
    ]
    private static let measurementExpression = try! NSRegularExpression(
        pattern: #"(?:^|[\s,])(status|code|errorCode|errorKind|expected|provider|route|attempt|bytes|elapsedMs|durationMs)=(-?[0-9]{1,9})(?=[\s,;]|$)"#
    )

    public init?(localMessage: String) {
        guard localMessage.first == "[", let end = localMessage.firstIndex(of: "]") else { return nil }
        let code = String(localMessage[localMessage.index(after: localMessage.startIndex)..<end])
        guard Self.errorCodes.contains(code) || Self.breadcrumbCodes.contains(code) else { return nil }
        self.code = code
        // Bound work even if a caller accidentally passes a response body as a diagnostic.
        let suffix = String(localMessage[localMessage.index(after: end)...].prefix(512))
        var measurements: [String: Int] = [:]
        for match in Self.measurementExpression.matches(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)) {
            guard let key = Range(match.range(at: 1), in: suffix),
                  let value = Range(match.range(at: 2), in: suffix),
                  let number = Int(suffix[value]) else { continue }
            measurements[String(suffix[key])] = number
        }
        self.measurements = measurements
        self.isError = Self.errorCodes.contains(code) && measurements["expected"] != 1
    }
}

/// A process-wide sink that can be disconnected without holding a lock while invoking it.
public final class DiagnosticRecordRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (RemoteDiagnosticRecord) -> Void)?

    public init() {}

    public func setSink(_ sink: (@Sendable (RemoteDiagnosticRecord) -> Void)?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    public func receive(_ message: String) {
        lock.lock()
        let callback = sink
        lock.unlock()
        guard let callback, let record = RemoteDiagnosticRecord(localMessage: message) else { return }
        callback(record)
    }
}
