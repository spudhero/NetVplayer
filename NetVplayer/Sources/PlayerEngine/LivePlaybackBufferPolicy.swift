import Foundation
import Models

public enum LivePlaybackBufferPolicy {
    public static let defaults = ["cache": "yes", "cache-secs": "20", "demuxer-max-bytes": "67108864",
                                  "cache-pause-wait": "3", "cache-pause-initial": "yes"]
    public static let shortConnectionMetadataKey = "live.shortConnectionRetried"

    public static func indicatesConnectionReuseFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("keepalive request failed") || lower.contains("broken pipe") || lower.contains("http error 400")
            || lower.contains("http/1.1 400") || lower.contains("failed to reuse connection")
            || lower.contains("cannot reuse http connection")
            || (lower.contains("connection reuse") && (lower.contains("fail") || lower.contains("error")))
    }

    public static func shortConnectionSpec(from spec: PlaySpec) -> PlaySpec? {
        guard spec.metadata["playback.kind"] == "live",
              spec.metadata[shortConnectionMetadataKey] != "true",
              ["http", "https"].contains(URL(string: spec.url)?.scheme?.lowercased() ?? ""),
              spec.metadata[LiveHLSRelayPolicy.transportMetadataKey] != LiveHLSRelayPolicy.localRelayTransport,
              spec.metadata[LiveHLSRelayPolicy.transportMetadataKey] != LiveHLSRelayPolicy.localStreamRelayTransport else { return nil }
        var repaired = spec
        repaired.metadata[shortConnectionMetadataKey] = "true"
        // HTTP protocol and HLS demuxer options belong to different layers.
        // Putting http_persistent in stream-lavf-o leaves HLS reuse enabled.
        repaired.mpvOptions["stream-lavf-o"] = replacingOptions(
            spec.mpvOptions["stream-lavf-o"], removing: ["http_persistent", "multiple_requests", "icy"],
            appending: ["icy=0", "multiple_requests=0"])
        repaired.mpvOptions["demuxer-lavf-o"] = replacingOptions(
            spec.mpvOptions["demuxer-lavf-o"], removing: ["http_persistent"], appending: ["http_persistent=0"])
        return repaired
    }

    private static func replacingOptions(_ value: String?, removing keys: Set<String>, appending: [String]) -> String {
        let options = (value ?? "").split(separator: ",").map(String.init)
            .filter { !keys.contains($0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? "") }
        return (options + appending).joined(separator: ",")
    }
}

/// Recovered stalls matter too. Initial loading, manual pause and seeks are
/// excluded by the caller; observations are reset for each media generation.
struct LivePlaybackStallWindow {
    private var recovered: [TimeInterval] = []
    mutating func record(duration: TimeInterval, at now: TimeInterval) -> Bool {
        recovered.removeAll { now - $0 > 60 || $0 > now }
        guard duration >= 1 else { return false }
        recovered.append(now)
        if duration >= 8 || recovered.count >= 3 { recovered.removeAll(); return true }
        return false
    }
}
