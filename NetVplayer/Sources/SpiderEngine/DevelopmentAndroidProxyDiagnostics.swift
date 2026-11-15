import CryptoKit
import Darwin
import Foundation
import Models
import ProviderSDK

/// Safe structural summaries and explicitly enabled private response capture.
/// Summaries never print content, URLs, or header values. Their counts describe
/// the bounded sample, not necessarily the complete playlist.
enum DevelopmentAndroidProxyDiagnostics {
    private static let captureEnvironmentKey = "NETVPLAYER_ANDROID_DIAGNOSTIC_CAPTURE_ROOT"
    private static let maximumResultCaptureBytes = 1024 * 1024
    private static let maximumProxyCaptureBytes = 256 * 1024
    private static let maximumPageCaptureBytes = 2 * 1024 * 1024
    private static let capturedOperations: Set<ProviderOperation> = [
        .home, .homeVideo, .category, .search, .detail, .player, .live, .epg
    ]
    private static let maximumBytes = 1024 * 1024
    private static let maximumLines = 4096
    private static let maximumLineBytes = 16 * 1024
    private static let maximumURIs = 1024
    private static let maximumURIBytes = 8192
    private static let maximumAttributes = 64
    private static let knownPorts: Set<String> = ["9978", "9979", "9999"]
    private static let uriTags: Set<String> = [
        "#EXT-X-KEY", "#EXT-X-SESSION-KEY", "#EXT-X-MAP", "#EXT-X-MEDIA",
        "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-PART", "#EXT-X-PRELOAD-HINT",
        "#EXT-X-RENDITION-REPORT"
    ]

    /// Explicitly enabled private response artifacts, independent of the safe
    /// structural summary. Never serializes Site, request arguments, or config.
    static func captureResult(_ response: ProviderResponse, operation: ProviderOperation, site: Site) {
        captureResult(response, operation: operation, site: site, environment: ProcessInfo.processInfo.environment)
    }

    static func captureProxy(_ response: ProxyResponse, site: Site) {
        captureProxy(response, site: site, environment: ProcessInfo.processInfo.environment)
    }

    static func captureLifecycle(_ data: Data) {
        guard let root = ProcessInfo.processInfo.environment[captureEnvironmentKey], !root.isEmpty else { return }
        do {
            try writeData(data, root: root, name: "lifecycle-\(UUID().uuidString).json")
        } catch {
            reportCaptureFailure(.fileWrite)
        }
    }

    enum PageCaptureProfile: String {
        case doubaoPageHTML = "doubao-native-page"
        case doubaoSignalMetadata = "doubao-signal-metadata"
        case doubaoSignalPlay = "doubao-signal-play"

        var maximumBytes: Int { self == .doubaoPageHTML ? maximumPageCaptureBytes : maximumProxyCaptureBytes }
        var fileExtension: String { self == .doubaoPageHTML ? "html" : "json" }
    }

    /// Saves only the already received page bytes. Profiles and extensions are
    /// fixed; request URLs, page IDs, headers, and configuration are not inputs.
    static func capturePage(
        _ data: Data, profile: PageCaptureProfile,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let root = environment[captureEnvironmentKey], !root.isEmpty else { return }
        guard data.count <= profile.maximumBytes else { reportCaptureFailure(.pageTooLarge); return }
        do {
            let contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try writeData(data, root: root, name: "\(profile.rawValue)-\(contentHash).\(profile.fileExtension)")
        } catch let failure as CaptureFailure {
            reportCaptureFailure(failure)
        } catch {
            reportCaptureFailure(.fileWrite)
        }
    }

    // Environment injection keeps local contracts independent of process-wide
    // environment mutations and does not enable capture in ordinary App runs.
    static func captureResult(
        _ response: ProviderResponse, operation: ProviderOperation, site: Site, environment: [String: String]
    ) {
        guard let root = environment[captureEnvironmentKey], !root.isEmpty,
              response.ok, capturedOperations.contains(operation), let result = response.result else { return }
        do {
            let data = try JSONEncoder.providerCanonical.encode(result)
            guard data.count <= maximumResultCaptureBytes else { reportCaptureFailure(.resultTooLarge); return }
            try writeCapture(data, root: root, site: site, operation: operation, fileExtension: "result.json")
        } catch let failure as CaptureFailure {
            reportCaptureFailure(failure)
        } catch {
            reportCaptureFailure(.resultEncoding)
        }
    }

    static func captureProxy(_ response: ProxyResponse, site: Site, environment: [String: String]) {
        guard let root = environment[captureEnvironmentKey], !root.isEmpty else { return }
        let fileExtension: String
        switch mimeKind(response.contentType) {
        case "hls": fileExtension = "m3u8"
        case "dash": fileExtension = "mpd"
        default: return
        }
        guard response.data.count <= maximumProxyCaptureBytes else { reportCaptureFailure(.proxyTooLarge); return }
        do {
            try writeCapture(response.data, root: root, site: site, operation: .proxy, fileExtension: fileExtension)
        } catch let failure as CaptureFailure {
            reportCaptureFailure(failure)
        } catch {
            reportCaptureFailure(.fileWrite)
        }
    }

    struct MediaContext: Codable, Sendable {
        var requestID = UUID().uuidString
        var routeID: String
        var parentRouteID: String?
        var playerInputSHA256: String?
        var proxyInputSHA256: String?
        var originalURLSHA256: String
        var role: String
    }

    /// Each request gets its own envelope, even when two responses share bytes.
    /// Hashes join it to the actual player invocation without saving credentials
    /// or signed URLs in this envelope. Original bodies stay in opt-in storage.
    static func captureExchange(_ response: ProxyResponse, context: MediaContext,
                                environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let root = environment[captureEnvironmentKey], !root.isEmpty else { return }
        do {
            let hash = DevelopmentAndroidLifecycleDiagnostics.sha256(response.data)
            let filename = "exchange-body-\(hash).bin"
            let captured = response.data.count <= 2 * 1024 * 1024
            if captured { try writeData(response.data, root: root, name: filename) }
            var envelope: [String: ProviderJSONValue] = [
                "schema": .number(1), "context": try JSONDecoder().decode(ProviderJSONValue.self, from: JSONEncoder().encode(context)),
                "status": .number(Double(response.statusCode)), "bodySHA256": .string(hash),
                "bodyBytes": .number(Double(response.data.count)), "bodyCaptured": .bool(captured)
            ]
            if captured { envelope["bodyFile"] = .string(filename) }
            try writeData(try JSONEncoder.providerCanonical.encode(envelope), root: root,
                name: "exchange-\(context.requestID).json")
        } catch { reportCaptureFailure(.fileWrite) }
    }

    static func captureStream(_ observation: DevelopmentAndroidHLSStream.Observation, context: MediaContext) {
        let prefix = observation.prefix
        let bytes = observation.bytes
        let offset = observation.offset
        let complete = observation.complete
        guard let root = ProcessInfo.processInfo.environment[captureEnvironmentKey], !root.isEmpty else { return }
        do {
            var envelope: [String: ProviderJSONValue] = [
                "schema": .number(1), "context": try JSONDecoder().decode(ProviderJSONValue.self, from: JSONEncoder().encode(context)),
                "rawBytes": .number(Double(bytes)), "complete": .bool(complete),
                "entireResponse": .bool(observation.entireResponse),
                "prefixSHA256": .string(DevelopmentAndroidLifecycleDiagnostics.sha256(prefix)),
                "prefixBytes": .number(Double(prefix.count))
            ]
            if let length = observation.declaredBodyBytes { envelope["declaredBodyBytes"] = .number(Double(length)) }
            if let status = observation.status { envelope["status"] = .number(Double(status)) }
            if let hash = observation.bodySHA256 { envelope["bodySHA256"] = .string(hash) }
            if context.role == DevelopmentAndroidHLS.Role.segment.rawValue {
                let name = "segment-prefix-\(DevelopmentAndroidLifecycleDiagnostics.sha256(prefix)).bin"
                try writeData(prefix, root: root, name: name)
                envelope["prefixFile"] = .string(name)
            }
            if let offset { envelope["TSInputAdvance"] = .number(Double(offset)) }
            try writeData(try JSONEncoder.providerCanonical.encode(envelope), root: root,
                name: "stream-\(context.requestID).json")
        } catch { reportCaptureFailure(.fileWrite) }
    }

    private enum CaptureFailure: String, Error {
        case invalidRoot = "invalid_root"
        case rootCreate = "root_create"
        case rootOpen = "root_open"
        case rootNotPrivate = "root_not_private"
        case fileOpen = "file_open"
        case filePermissions = "file_permissions"
        case fileWrite = "file_write"
        case resultEncoding = "result_encoding"
        case resultTooLarge = "result_too_large"
        case proxyTooLarge = "proxy_too_large"
        case pageTooLarge = "page_too_large"
    }

    private static func reportCaptureFailure(_ failure: CaptureFailure) {
        // No Error description, path, site, headers, URL, or provider content.
        FileHandle.standardError.write(Data("[ANDROID_PROVIDER_DIAGNOSTIC_CAPTURE] code=\(failure.rawValue)\n".utf8))
    }

    private static func writeCapture(
        _ data: Data, root: String, site: Site, operation: ProviderOperation, fileExtension: String
    ) throws {
        let siteHash = SHA256.hash(data: Data(site.key.utf8)).map { String(format: "%02x", $0) }.joined()
        let contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "\(siteHash)-\(operation.rawValue)-\(contentHash).\(fileExtension)"
        try writeData(data, root: root, name: name)
    }

    private static func writeData(_ data: Data, root: String, name: String) throws {
        let directory = try openCaptureDirectory(root)
        defer { _ = Darwin.close(directory) }
        let descriptor = Darwin.openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            if errno == EEXIST { return }
            throw CaptureFailure.fileOpen
        }
        var complete = false
        defer {
            _ = Darwin.close(descriptor)
            if !complete { _ = Darwin.unlinkat(directory, name, 0) }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw CaptureFailure.filePermissions }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { throw CaptureFailure.fileWrite }
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CaptureFailure.fileWrite }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw CaptureFailure.fileWrite }
        complete = true
    }

    private static func openCaptureDirectory(_ root: String) throws -> Int32 {
        guard root.hasPrefix("/"), root.utf8.count <= 4096, !root.utf8.contains(0) else {
            throw CaptureFailure.invalidRoot
        }
        let components = root.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw CaptureFailure.invalidRoot
        }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw CaptureFailure.rootOpen }
        defer { if directory >= 0 { _ = Darwin.close(directory) } }
        for (index, component) in components.enumerated() {
            if Darwin.mkdirat(directory, component, mode_t(0o700)) != 0 && errno != EEXIST {
                throw CaptureFailure.rootCreate
            }
            let isRoot = index == components.count - 1
            let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (isRoot ? O_NOFOLLOW : 0)
            let next = Darwin.openat(directory, component, flags)
            guard next >= 0 else { throw CaptureFailure.rootOpen }
            _ = Darwin.close(directory)
            directory = next
        }
        var status = stat()
        guard Darwin.fstat(directory, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), status.st_uid == geteuid(),
              status.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw CaptureFailure.rootNotPrivate
        }
        let result = directory
        directory = -1
        return result
    }

    static func summary(response: ProxyResponse, payload: ProviderProxyPayload) -> String {
        let sample = Data(response.data.prefix(maximumBytes))
        let strictText = String(data: sample, encoding: .utf8)
        let text = strictText ?? String(decoding: sample, as: UTF8.self)
        let byteTruncated = response.data.count > sample.count
        let utf8 = strictText == nil ? (byteTruncated ? "invalid_prefix" : "invalid")
            : (byteTruncated ? "valid_prefix" : "valid")
        let gzip = sample.starts(with: [0x1f, 0x8b])
        let leading = text.drop(while: { $0 == "\u{feff}" || $0.isWhitespace })
        let magicEnd = leading.firstIndex(where: { $0.isNewline }) ?? leading.endIndex
        let hls = leading[..<magicEnd].trimmingCharacters(in: .whitespaces) == "#EXTM3U"
        var counts = Counts(truncated: byteTruncated)

        if hls {
            let lines = leading.split(maxSplits: maximumLines, omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            if lines.count > maximumLines { counts.truncated = true }
            for rawLine in lines.prefix(maximumLines) {
                guard rawLine.utf8.count <= maximumLineBytes else {
                    counts.oversizeLines += 1
                    counts.truncated = true
                    continue
                }
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                guard line.hasPrefix("#") else {
                    guard counts.uris < maximumURIs else { counts.truncated = true; break }
                    counts.uriLines += 1
                    countURI(line, counts: &counts)
                    continue
                }
                let separator = line.firstIndex(of: ":") ?? line.endIndex
                let tag = String(line[..<separator])
                switch tag {
                case "#EXT-X-STREAM-INF", "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-MEDIA": counts.master += 1
                case "#EXTINF", "#EXT-X-PART": counts.media += 1
                default: break
                }
                guard uriTags.contains(tag), separator != line.endIndex else { continue }
                let attributes = line[line.index(after: separator)...]
                countAttributes(attributes, tag: tag, counts: &counts)
                if counts.uris >= maximumURIs { counts.truncated = true; break }
            }
        }

        let bodyKind: String
        if payload.bodyBase64 != nil { bodyKind = payload.body == nil ? "base64" : "both" }
        else { bodyKind = payload.body == nil ? "absent" : "text" }
        let fields = [
            "[ANDROID_PROVIDER_PROXY_SHAPE]", "status=\(response.statusCode)",
            "mime=\(mimeKind(response.contentType))", "body_kind=\(bodyKind)",
            "bytes=\(response.data.count)", "empty=\(bit(response.data.isEmpty))", "sampled=\(sample.count)",
            "utf8=\(utf8)", "hls=\(bit(hls))", "gzip=\(bit(gzip))",
            "encoding=\(bit(hasHeader("Content-Encoding", response: response, payload: payload)))",
            "location=\(bit(hasHeader("Location", response: response, payload: payload)))",
            "master=\(counts.master)", "media=\(counts.media)", "uris=\(counts.uris)",
            "uri_lines=\(counts.uriLines)", "uri_attributes=\(counts.uriAttributes)",
            "key_uri=\(counts.keyURI)", "map_uri=\(counts.mapURI)",
            "relative=\(counts.relative)", "absolute=\(counts.absolute)", "http=\(counts.http)",
            "other_scheme=\(counts.otherScheme)", "loopback=\(counts.loopback)",
            "knownloopback=\(counts.knownLoopback)", "negativeport=\(counts.negativePort)",
            "oversize_lines=\(counts.oversizeLines)", "oversize_uris=\(counts.oversizeURIs)",
            "truncated=\(bit(counts.truncated))"
        ]
        // Every field contains only constants, a fixed enum value, or integers.
        return String(fields.joined(separator: " ").prefix(1024))
    }

    private struct Counts {
        var truncated = false
        var master = 0
        var media = 0
        var uris = 0
        var uriLines = 0
        var uriAttributes = 0
        var keyURI = 0
        var mapURI = 0
        var relative = 0
        var absolute = 0
        var http = 0
        var otherScheme = 0
        var loopback = 0
        var knownLoopback = 0
        var negativePort = 0
        var oversizeLines = 0
        var oversizeURIs = 0
    }

    /// Split HLS attributes at commas outside quotes. In particular, commas in
    /// a signed URI must not create invented URI references.
    private static func countAttributes(_ text: Substring, tag: String, counts: inout Counts) {
        var start = text.startIndex
        var quoted = false
        var attributes = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted {
                countAttribute(text[start..<index], tag: tag, counts: &counts)
                attributes += 1
                guard attributes < maximumAttributes, counts.uris < maximumURIs else {
                    counts.truncated = true
                    return
                }
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        countAttribute(text[start..<text.endIndex], tag: tag, counts: &counts)
    }

    private static func countAttribute(_ attribute: Substring, tag: String, counts: inout Counts) {
        guard let separator = attribute.firstIndex(of: "="),
              attribute[..<separator].trimmingCharacters(in: .whitespaces) == "URI" else { return }
        guard counts.uris < maximumURIs else { counts.truncated = true; return }
        var value = attribute[attribute.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        guard !value.isEmpty else { return }
        counts.uriAttributes += 1
        if tag == "#EXT-X-KEY" || tag == "#EXT-X-SESSION-KEY" { counts.keyURI += 1 }
        if tag == "#EXT-X-MAP" { counts.mapURI += 1 }
        countURI(value, counts: &counts)
    }

    private static func countURI(_ uri: String, counts: inout Counts) {
        counts.uris += 1
        guard uri.utf8.count <= maximumURIBytes else {
            counts.oversizeURIs += 1
            counts.truncated = true
            return
        }
        let authorityTail: Substring
        if uri.hasPrefix("//") {
            counts.absolute += 1
            counts.http += 1
            authorityTail = uri.dropFirst(2)
        } else if let colon = uri.firstIndex(of: ":"), isScheme(uri[..<colon]) {
            counts.absolute += 1
            let scheme = uri[..<colon].lowercased()
            let suffix = uri[uri.index(after: colon)...]
            guard (scheme == "http" || scheme == "https"), suffix.hasPrefix("//") else {
                counts.otherScheme += 1
                return
            }
            counts.http += 1
            authorityTail = suffix.dropFirst(2)
        } else {
            counts.relative += 1
            return
        }
        let end = authorityTail.firstIndex(where: { "/?#".contains($0) }) ?? authorityTail.endIndex
        let authority = authorityTail[..<end].lowercased()
        guard !authority.contains("@") else { return }
        let host: String
        let port: String?
        if authority.hasPrefix("["), let closing = authority.firstIndex(of: "]") {
            host = String(authority[...closing])
            let tail = authority[authority.index(after: closing)...]
            guard tail.isEmpty || tail.hasPrefix(":") else { return }
            port = tail.isEmpty ? nil : String(tail.dropFirst())
        } else {
            let parts = authority.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return }
            host = parts.first.map(String.init) ?? ""
            port = parts.count == 2 ? String(parts[1]) : nil
        }
        guard host == "127.0.0.1" || host == "localhost" || host == "[::1]" else { return }
        counts.loopback += 1
        if let port, knownPorts.contains(port) { counts.knownLoopback += 1 }
        if let port, let number = Int(port), number < 0 { counts.negativePort += 1 }
    }

    private static func isScheme(_ value: Substring) -> Bool {
        let bytes = value.utf8
        guard let first = bytes.first, isLetter(first) else { return false }
        return bytes.dropFirst().allSatisfy { isLetter($0) || (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46 }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func hasHeader(_ name: String, response: ProxyResponse, payload: ProviderProxyPayload) -> Bool {
        response.headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            || payload.headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func mimeKind(_ value: String) -> String {
        let bounded = String(decoding: value.utf8.prefix(128), as: UTF8.self)
        let mime = bounded.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch mime {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl": return "hls"
        case "application/dash+xml": return "dash"
        case "application/octet-stream": return "binary"
        case "application/json": return "json"
        case "text/plain", "text/html": return "text"
        default:
            if mime.hasPrefix("video/") { return "video" }
            if mime.hasPrefix("audio/") { return "audio" }
            return "other"
        }
    }

    private static func bit(_ value: Bool) -> Int { value ? 1 : 0 }
}
