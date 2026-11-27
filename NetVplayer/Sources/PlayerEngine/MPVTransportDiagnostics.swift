import Foundation

/// Keep numeric HTTP evidence in the current load. Raw log text may contain
/// signed URLs, headers, or bytes from a malformed response.
struct MPVTransportDiagnostics {
    private struct Observation {
        let kind: String
        let offset: Int64?
        let expected: Int64?
    }

    let loadedAt: TimeInterval
    private(set) var lastRequestedPositionMs: Int64
    private var latest: (observation: Observation, time: TimeInterval)?
    private var failures = 0

    init(loadedAt: TimeInterval, positionMs: Int64) {
        self.loadedAt = loadedAt
        lastRequestedPositionMs = max(0, positionMs)
    }

    mutating func seek(to positionMs: Int64) {
        lastRequestedPositionMs = max(0, positionMs)
    }

    mutating func observe(prefix: String?, text: String, now: TimeInterval) {
        guard prefix == "ffmpeg", let separator = text.firstIndex(of: ":"),
              ["http", "https", "httpproxy", "tls", "tcp"].contains(text[..<separator]) else { return }
        let message = text[text.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let observation: Observation
        if let match = message.wholeMatch(of: #/Stream ends prematurely at ([0-9]+), should be ([0-9]+)/#) {
            observation = .init(kind: "short-response", offset: Int64(match.1), expected: Int64(match.2))
        } else if let match = message.wholeMatch(of: #/Unexpected offset: expected ([0-9]+), got ([0-9]+)/#) {
            observation = .init(kind: "offset-mismatch", offset: Int64(match.2), expected: Int64(match.1))
        } else if let match = message.wholeMatch(of: #/Will reconnect at ([0-9]+) in [0-9]+ second\(s\)(?:, error=(.+))?\./#) {
            let reason = match.2.flatMap { Self.readFailureKind($0.lowercased()) }
            observation = .init(kind: reason ?? "reconnect", offset: Int64(match.1), expected: nil)
        } else if let reason = Self.readFailureKind(message.lowercased()) {
            observation = .init(kind: reason, offset: nil, expected: nil)
        } else {
            return
        }
        failures += 1
        latest = (observation, now)
    }

    func summary(positionMs: Int64, now: TimeInterval) -> String {
        let elapsedMs = Int64(max(0, now - loadedAt) * 1_000)
        let advanceMs = max(lastRequestedPositionMs, positionMs) - lastRequestedPositionMs
        var fields = "loadAgeMs=\(elapsedMs) requestedPositionMs=\(lastRequestedPositionMs) "
            + "advanceMs=\(advanceMs) transportEvents=\(failures)"
        if let latest {
            fields += " lastTransportEvent=\(latest.observation.kind) eventAgeMs=\(Int64(max(0, now - latest.time) * 1_000))"
            if let offset = latest.observation.offset { fields += " offset=\(offset)" }
            if let expected = latest.observation.expected { fields += " expectedOffset=\(expected)" }
        }
        return fields
    }

    private static func readFailureKind(_ message: String) -> String? {
        switch message {
        case "connection timed out", "operation timed out",
             "error reading http response: connection timed out", "io error: operation timed out":
            return "timeout"
        case "connection reset by peer", "error reading http response: connection reset by peer",
             "io error: connection reset by peer":
            return "connection-reset"
        case "end of file", "error reading http response: end of file", "io error: end of file":
            return "connection-eof"
        default:
            return nil
        }
    }
}
