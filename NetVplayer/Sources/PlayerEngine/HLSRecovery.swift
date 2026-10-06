import Foundation
import Models
import Networking

public struct HLSRecoverySlots: Sendable {
    private var active: [Bool: UUID] = [:]
    public init() {}
    public mutating func claim(live: Bool) -> UUID? {
        guard active[live] == nil else { return nil }
        let id = UUID()
        active[live] = id
        return id
    }
    public func isCurrent(_ id: UUID, live: Bool) -> Bool { active[live] == id }
    @discardableResult
    public mutating func complete(_ id: UUID, live: Bool) -> Bool {
        guard active[live] == id else { return false }
        active.removeValue(forKey: live)
        return true
    }
    public mutating func invalidate(live: Bool) { active.removeValue(forKey: live) }
}

/// A recovery-only reduction of a master playlist. Unknown HLS semantics stay with libmpv.
public enum HLSRecovery {
    public static let maximumBytes = 256 * 1024
    public static let attemptedKey = "hls.recoveryAttempted"

    public static func eligible(_ spec: PlaySpec) -> Bool {
        guard spec.metadata[attemptedKey] != "true", spec.drm == nil,
              spec.drivePlaybackPlan == nil, let url = URL(string: spec.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return spec.format.lowercased().contains("hls") || url.pathExtension.lowercased() == "m3u8"
    }

    public static func reducedMaster(_ data: Data, baseURL: URL) -> String? {
        guard data.count < maximumBytes, let source = String(data: data, encoding: .utf8),
              !source.contains("\0") else { return nil }
        let lines = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U", lines.count < 4096 else { return nil }
        var variants: [(attributes: [String: String], url: URL)] = []
        var groups: [[String: String]] = []
        var prelude = ["#EXTM3U"]
        var cursor = 1
        while cursor < lines.count {
            let line = lines[cursor]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                guard let attributes = parseAttributes(line), cursor + 1 < lines.count,
                      let url = absoluteURL(lines[cursor + 1], baseURL),
                      let bandwidth = Int(attributes["BANDWIDTH"] ?? ""), bandwidth > 0 else { return nil }
                variants.append((attributes, url)); cursor += 2
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:") {
                guard let attributes = parseAttributes(line) else { return nil }
                groups.append(attributes)
            } else if line.hasPrefix("#EXT-X-VERSION:") || line == "#EXT-X-INDEPENDENT-SEGMENTS" {
                prelude.append(line)
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                // Optional trick-play entries do not participate in normal playback.
            } else if line.hasPrefix("#EXT") || !line.hasPrefix("#") { return nil }
            cursor += 1
        }
        guard variants.count >= 12 else { return nil }
        let candidates = variants.filter { variant in
            let fields = variant.attributes
            let codecs = (fields["CODECS"] ?? "").split(separator: ",").map(String.init)
            let size = (fields["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
            let fps = fields["FRAME-RATE"].flatMap(Double.init) ?? (fields["FRAME-RATE"] == nil ? 30 : .infinity)
            return size.count == 2 && (1...1920).contains(size[0]) && (1...1080).contains(size[1])
                && fps.isFinite && fps > 0 && fps <= 60 && fields["VIDEO"] == nil
                && codecs.contains(where: { $0.hasPrefix("avc1.") || $0.hasPrefix("avc3.") })
                && codecs.contains(where: { $0.hasPrefix("mp4a.40.") })
                && codecs.allSatisfy { $0.hasPrefix("avc1.") || $0.hasPrefix("avc3.") || $0.hasPrefix("mp4a.40.") }
                && Set(fields.keys).isSubset(of: ["BANDWIDTH", "AVERAGE-BANDWIDTH", "CODECS", "RESOLUTION", "FRAME-RATE", "AUDIO", "SUBTITLES", "CLOSED-CAPTIONS"])
        }
        guard let chosen = candidates.max(by: { Int($0.attributes["BANDWIDTH"]!)! < Int($1.attributes["BANDWIDTH"]!)! }) else { return nil }
        for kind in ["AUDIO", "SUBTITLES", "CLOSED-CAPTIONS"] {
            guard let groupID = chosen.attributes[kind], groupID != "NONE" else { continue }
            let matches = groups.filter { $0["TYPE"] == kind && $0["GROUP-ID"] == groupID }
            guard !matches.isEmpty else { return nil }
            for var group in matches {
                guard Set(group.keys).isSubset(of: ["TYPE", "GROUP-ID", "NAME", "LANGUAGE", "ASSOC-LANGUAGE", "DEFAULT", "AUTOSELECT", "FORCED", "INSTREAM-ID", "CHARACTERISTICS", "CHANNELS", "URI"]) else { return nil }
                if let uri = group["URI"] {
                    guard let url = absoluteURL(uri, baseURL) else { return nil }
                    group["URI"] = url.absoluteString
                } else if kind == "SUBTITLES" { return nil }
                prelude.append("#EXT-X-MEDIA:" + serialize(group))
            }
        }
        prelude.append("#EXT-X-STREAM-INF:" + serialize(chosen.attributes))
        prelude.append(chosen.url.absoluteString)
        return prelude.joined(separator: "\n") + "\n"
    }

    private static func absoluteURL(_ raw: String, _ base: URL) -> URL? {
        guard !raw.hasPrefix("#"), !raw.contains("{$"), !raw.contains("\""),
              let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    private static func parseAttributes(_ line: String) -> [String: String]? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var quoted = false
        var fields = [String](), field = ""
        for char in line[line.index(after: colon)...] {
            if char == "\"" { quoted.toggle() }
            if char == "," && !quoted { fields.append(field); field = "" } else { field.append(char) }
        }
        guard !quoted else { return nil }
        fields.append(field)
        var result: [String: String] = [:]
        for field in fields {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = String(pair[0]), raw = String(pair[1])
            guard !key.isEmpty, !raw.isEmpty, result[key] == nil else { return nil }
            let value = raw.hasPrefix("\"") && raw.hasSuffix("\"") ? String(raw.dropFirst().dropLast()) : raw
            guard !value.contains("\"") else { return nil }
            result[key] = value
        }
        return result
    }

    private static func serialize(_ attributes: [String: String]) -> String {
        let unquoted: Set<String> = ["TYPE", "BANDWIDTH", "AVERAGE-BANDWIDTH", "RESOLUTION", "FRAME-RATE", "DEFAULT", "AUTOSELECT", "FORCED"]
        return attributes.keys.sorted().map { key in
            let value = attributes[key]!
            return key + "=" + (unquoted.contains(key) || (key == "CLOSED-CAPTIONS" && value == "NONE") ? value : "\"" + value + "\"")
        }.joined(separator: ",")
    }

    public static func prepare(_ spec: PlaySpec, client: HTTPClient = .shared, budget: Duration = .seconds(8)) async throws -> String? {
        guard eligible(spec) else { return nil }
        let client = PlaybackProbeTransport.client(for: spec, using: client)
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                let buffer = HLSRecoveryBuffer()
                let response = try await client.stream(url: spec.url, headers: spec.headers, timeout: 8,
                    allowsProxyFallback: false, redactsURLInLogs: true, chunkSize: 16 * 1024,
                    shouldStream: { response in
                        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
                        return true
                    }, receive: { try await buffer.append($0) })
                try Task.checkCancellation()
                guard let base = response.finalURL ?? URL(string: spec.url) else { return nil }
                return await reducedMaster(buffer.data, baseURL: base)
            }
            group.addTask { try await Task.sleep(for: budget); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}

private actor HLSRecoveryBuffer {
    var data = Data()
    func append(_ chunk: Data) throws {
        guard data.count + chunk.count < HLSRecovery.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        data.append(chunk)
    }
}
