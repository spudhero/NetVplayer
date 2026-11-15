import Foundation
import Models
import ProviderSDK

/// Bind Android endpoints and optionally remote HLS references to this playback.
/// URI roles come from HLS tags; signatures, qualities and tracks are preserved.
enum DevelopmentAndroidProxyManifest {
    static func map(_ response: ProxyResponse, originalURL: String,
                    hlsLocalize: ((String, DevelopmentAndroidHLS.Role) throws -> String?)? = nil,
                    localize: (String) throws -> String?) throws -> ProxyResponse {
        var headers = response.headers
        if let key = headers.keys.first(where: { $0.lowercased() == "location" }), let value = headers[key] {
            headers[key] = try reference(value, base: originalURL, localize: localize)
        }
        let type = response.contentType.lowercased()
        let text = String(data: response.data, encoding: .utf8)
        let hls = text?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))).hasPrefix("#EXTM3U") == true
        let dash = type.contains("dash+xml") || text?.contains("<MPD") == true
        guard hls || dash else {
            return ProxyResponse(statusCode: response.statusCode, contentType: response.contentType,
                data: response.data, headers: headers, closeConnection: response.closeConnection)
        }
        guard response.data.count <= 2 * 1024 * 1024, let text,
              !headers.contains(where: { $0.key.lowercased() == "content-encoding" && $0.value.lowercased() != "identity" }) else { throw unsupported() }
        let mapped: String
        if hls {
            let attributes = try NSRegularExpression(pattern: #"(?:^|[, :])URI=(?:"([^"]*)"|([^,\s]*))"#)
            var nextPlaylist = false
            var encrypted = false
            var byteRange = false
            var hasInitialization = false
            func resolve(_ value: String, role: DevelopmentAndroidHLS.Role) throws -> String {
                try reference(value, base: originalURL) { candidate in
                    if let mapped = try hlsLocalize?(candidate, role) { return mapped }
                    return try localize(candidate)
                }
            }
            mapped = try text.components(separatedBy: "\n").map { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return line }
                if !trimmed.hasPrefix("#") && !trimmed.hasPrefix("\u{feff}#") {
                    let role: DevelopmentAndroidHLS.Role = nextPlaylist ? .playlist
                        : (encrypted || byteRange || hasInitialization ? .opaque : .segment)
                    let resolved = try resolve(trimmed, role: role)
                    nextPlaylist = false; byteRange = false
                    return line.replacingOccurrences(of: trimmed, with: resolved)
                }
                let tag = String(trimmed.split(separator: ":", maxSplits: 1).first ?? "")
                if tag == "#EXT-X-STREAM-INF" { nextPlaylist = true }
                if tag == "#EXT-X-BYTERANGE" { byteRange = true }
                if tag == "#EXT-X-MAP" { hasInitialization = true }
                if tag == "#EXT-X-KEY" || tag == "#EXT-X-SESSION-KEY" {
                    encrypted = trimmed.range(of: #"(?:^|[:,])METHOD=NONE(?:,|$)"#, options: .regularExpression) == nil
                }
                let role: DevelopmentAndroidHLS.Role = ["#EXT-X-MEDIA", "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-RENDITION-REPORT"].contains(tag) ? .playlist : .opaque
                var output = line
                for match in attributes.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                    let capture = match.range(at: match.range(at: 1).location != NSNotFound ? 1 : 2)
                    guard let range = Range(capture, in: line) else { continue }
                    let resolved = try resolve(String(line[range]), role: role)
                    guard let outputRange = Range(capture, in: output) else { throw unsupported() }
                    output.replaceSubrange(outputRange, with: resolved)
                }
                return output
            }.joined(separator: "\n")
        } else {
            guard !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw unsupported() }
            let document = try XMLDocument(xmlString: text, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
            guard document.rootElement()?.localName == "MPD" else { throw unsupported() }
            // Remote BaseURL/SegmentTemplate hierarchies remain in the original
            // manifest and are resolved by the DASH demuxer, including languages,
            // representations, timelines and periods.
            let nodes = try document.nodes(forXPath: "//*[local-name()='BaseURL'] | //@media | //@initialization | //@sourceURL | //@href")
            guard nodes.count <= 8192 else { throw unsupported() }
            let localBase = nodes.contains { $0.localName == "BaseURL" && isAndroidReference($0.stringValue ?? "") }
            if localBase && nodes.contains(where: {
                guard $0.localName != "BaseURL", let value = $0.stringValue else { return false }
                return URLComponents(string: value)?.scheme == nil && !isAndroidReference(value)
            }) { throw unsupported() }
            var changed = false
            for node in nodes {
                guard let value = node.stringValue else { continue }
                // A relative segment underneath a remote BaseURL belongs to that
                // hierarchy. Only explicit Android endpoints require rebinding.
                guard isAndroidReference(value) else { continue }
                guard !value.contains("$") else { throw unsupported() }
                let resolved = try reference(value, base: originalURL, localize: localize)
                if resolved != value { node.stringValue = resolved; changed = true }
            }
            mapped = changed ? document.xmlString(options: [.nodePreserveAll]) : text
        }
        let data = Data(mapped.utf8)
        if data != response.data {
            headers = headers.filter { !["content-length", "etag", "content-md5", "digest"].contains($0.key.lowercased()) }
        }
        return ProxyResponse(statusCode: response.statusCode, contentType: response.contentType,
            data: data, headers: headers, closeConnection: response.closeConnection)
    }

    static func reference(_ value: String, base: String, localize: (String) throws -> String?) throws -> String {
        if value.hasPrefix("//"), let scheme = URLComponents(string: base.replacingOccurrences(of: ":-1/", with: ":9978/"))?.scheme {
            return try reference(scheme + ":" + value, base: base, localize: localize)
        }
        if URLComponents(string: value)?.scheme != nil { return try localize(value) ?? value }
        if !isAndroidReference(base), let origin = URL(string: base),
           let absolute = URL(string: value, relativeTo: origin)?.absoluteURL.absoluteString {
            return try localize(absolute) ?? absolute
        }
        // CatVod's -1 sentinel is not accepted by Foundation's URL parser.
        guard let separator = base.range(of: "://"),
              let start = base[separator.upperBound...].firstIndex(of: "/"),
              let origin = URL(string: "http://127.0.0.1:9978" + base[start...]),
              let absolute = URL(string: value, relativeTo: origin)?.absoluteURL.absoluteString,
              let mapped = try localize(absolute) else { throw unsupported() }
        return mapped
    }

    private static func isAndroidReference(_ value: String) -> Bool {
        if value.hasPrefix("/proxy?") || value.hasPrefix("?do=") || value.hasPrefix("proxy?") { return true }
        let absolute = value.hasPrefix("//") ? "http:" + value : value
        guard let parts = URLComponents(string: absolute.replacingOccurrences(of: ":-1/", with: ":9978/")) else { return false }
        return parts.path == "/proxy" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(parts.host?.lowercased() ?? "")
    }

    static func unsupported() -> ProviderErrorPayload {
        ProviderErrorPayload(code: "unsupported_android_proxy_reference",
            message: "原版代理返回了无法绑定的本地清单引用", retryable: false)
    }
}
