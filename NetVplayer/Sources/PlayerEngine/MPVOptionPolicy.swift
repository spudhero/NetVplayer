import Foundation
import Models

public enum MPVOptionOrigin: String, Sendable { case source, user, session, transport }

public struct MPVEffectiveOption: Equatable, Sendable {
    public let value: String
    public let origin: MPVOptionOrigin
}

public struct MPVOptionDiagnostic: Identifiable, Equatable, Sendable {
    public enum Status: Sendable { case applied, rejected }
    public let name: String
    public let origin: MPVOptionOrigin
    public let status: Status
    public var id: String { name }
}

/// Values stay in the runtime plan. Diagnostics carry only names, origins and outcomes.
public enum MPVOptionPolicy {
    public static func resolve(spec: PlaySpec, user: [String: String], session: [String: String]) -> [String: MPVEffectiveOption] {
        let defaults = spec.metadata["playback.kind"] == "live" ? LivePlaybackBufferPolicy.defaults : [:]
        var result = defaults.mapValues { MPVEffectiveOption(value: $0, origin: .transport) }
        for (key, value) in spec.mpvOptions { result[key] = .init(value: value, origin: .source) }
        for (key, value) in user { result[key] = .init(value: value, origin: .user) }
        for (key, value) in session { result[key] = .init(value: value, origin: .session) }
        if let key = cencKey(spec.drm) {
            let existing = result["demuxer-lavf-o"]?.value ?? ""
            var fields = existing.split(separator: ",").map(String.init).filter {
                $0.split(separator: "=", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces).lowercased() != "decryption_key"
            }
            fields.append("decryption_key=\(key)")
            result["demuxer-lavf-o"] = .init(value: fields.joined(separator: ","), origin: .transport)
        }
        let transport = PlaybackTransportOptions.resolved(result.mapValues(\.value), url: spec.url,
                                                        direct: spec.metadata["network.explicitDirect"] == "true")
        for (key, value) in transport where value != result[key]?.value || key == "http-proxy" {
            result[key] = .init(value: value, origin: .transport)
        }
        // The engine clears this list with change-list/clr and appends structured
        // headers afterwards. Setting an empty string creates an empty list entry;
        // FFmpeg then sends a blank line before the appended headers.
        result.removeValue(forKey: "http-header-fields")
        result["user-agent"] = .init(value: header("User-Agent", in: spec.headers) ?? PlaybackProxyPolicy.defaultHTTPUserAgent, origin: .transport)
        result["referrer"] = .init(value: header("Referer", in: spec.headers) ?? "", origin: .transport)
        return result
    }

    public static func accepts(name: String, value: String) -> Bool {
        guard name.utf8.count <= 80, value.utf8.count <= 64 * 1_024, !value.contains("\0") else { return false }
        return name.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil
    }

    private static func cencKey(_ drm: Drm?) -> String? {
        guard let drm,
              ["cenc", "cenc-aes-ctr"].contains(drm.type.lowercased()),
              drm.key.utf8.count == 32,
              drm.key.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return drm.key.lowercased()
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
