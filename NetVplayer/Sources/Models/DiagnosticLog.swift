// Models/DiagnosticLog.swift
// Lightweight local diagnostic logging for app-level playback investigation.

import Foundation

enum NetworkHostPrivacy {
    static func isPrivateOrLocal(_ rawHost: String) -> Bool {
        let host = rawHost
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost"
            || host.hasSuffix(".local")
            || host.hasSuffix(".lan")
            || host.hasSuffix(".internal")
            || host == "0.0.0.0"
            || host == "::"
            || host == "::1" {
            return true
        }
        if host.contains(":"), isPrivateIPv6Host(host) { return true }
        if !host.contains(".") && !host.contains(":") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10
            || parts[0] == 127
            || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
    }

    private static func isPrivateIPv6Host(_ host: String) -> Bool {
        let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        let firstHextet = address.split(separator: ":", omittingEmptySubsequences: true).first
            .flatMap { UInt16($0, radix: 16) }
        if let firstHextet,
           (0xfc00...0xfdff).contains(firstHextet) || (0xfe80...0xfebf).contains(firstHextet) {
            return true
        }
        if let mapped = address.split(separator: ":").last, mapped.contains(".") {
            return isPrivateOrLocal(String(mapped))
        }
        return false
    }
}

public enum DiagnosticLogSanitizer {
    private static let headerValueNames = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key",
    ]
    private static let sensitiveNames = [
        "authorization", "cookie", "set-cookie", "proxy-authorization", "x-api-key",
        "token", "access_token", "refresh_token", "open_token", "password", "passwd",
        "secret", "api_key", "apikey", "auth_key", "signature", "sign",
        "ossaccesskeyid", "security-token", "x-oss-access-key-id",
        "x-oss-credential", "x-oss-security-token", "x-oss-signature",
    ]
    private static let privateValueNames = [
        "keyword", "title", "file", "filename", "originalname", "savedfilename",
        "cachekey", "fid", "fileid", "pwdid", "shareid", "name", "names",
        "displayname", "episode", "site", "source", "channel",
    ]
    private static let urlExpression = try? NSRegularExpression(
        pattern: #"(?i)\bhttps?://[^\s<>\"']+"#
    )
    private static let emailExpression = try? NSRegularExpression(
        pattern: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#
    )
    private static let userPathExpression = try? NSRegularExpression(
        pattern: #"/(?:Users|home)/[^/\s]+"#
    )

    public static func sanitize(_ value: String) -> String {
        var result = replacingURLs(in: value)
        result = replacing(expression: emailExpression, in: result, with: "<redacted-email>")
        result = replacing(expression: userPathExpression, in: result, with: "~")

        for name in headerValueNames {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            result = result.replacingOccurrences(
                of: "(?im)(\\b\(escaped)\\s*[:=]\\s*)[^\\r\\n]+",
                with: "$1<redacted>",
                options: .regularExpression
            )
        }

        for name in sensitiveNames {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            result = result.replacingOccurrences(
                of: "(?i)(\"\(escaped)\"\\s*:\\s*\")[^\"]*(\")",
                with: "$1<redacted>$2",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: "(?i)(\\b\(escaped)\\s*[:=]\\s*)[^,;\\s]+",
                with: "$1<redacted>",
                options: .regularExpression
            )
        }

        for name in privateValueNames {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            result = result.replacingOccurrences(
                of: "(?im)(\\b\(escaped)\\s*=\\s*).*?(?=(?:[ \\t]+|,\\s*|;\\s*)[A-Za-z][A-Za-z0-9_-]*\\s*=|$)",
                with: "$1<redacted>",
                options: .regularExpression
            )
        }
        return result
    }

    private static func replacingURLs(in value: String) -> String {
        guard let expression = urlExpression else { return value }
        let fullRange = NSRange(value.startIndex..., in: value)
        let matches = expression.matches(in: value, range: fullRange)
        guard !matches.isEmpty else { return value }

        var result = value
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range])
            let trailingCount = token.reversed().prefix { ").,]".contains($0) }.count
            let trailing = token.suffix(trailingCount)
            let urlToken = String(token.dropLast(trailingCount))
            let replacement = sanitizedURL(urlToken) + String(trailing)
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func sanitizedURL(_ rawValue: String) -> String {
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              let parsedHost = components.host?.lowercased(),
              !parsedHost.isEmpty else {
            return "<redacted-url>"
        }
        let host = parsedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let safeHost = NetworkHostPrivacy.isPrivateOrLocal(host) ? "<private-host>" : host
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(safeHost)\(port)/<redacted>"
    }

    private static func replacing(
        expression: NSRegularExpression?,
        in value: String,
        with replacement: String
    ) -> String {
        guard let expression else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }
}

public final class DiagnosticLogStore: @unchecked Sendable {
    public static let defaultMaximumSessionBytes = 2 * 1024 * 1024
    public static let defaultMaximumLineBytes = 8 * 1024

    public let directoryURL: URL
    public let currentLogURL: URL
    public let previousLogURL: URL

    private let fileManager: FileManager
    private let maximumSessionBytes: Int
    private let maximumLineBytes: Int
    private let lock = NSLock()

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        maximumSessionBytes: Int = defaultMaximumSessionBytes,
        maximumLineBytes: Int = defaultMaximumLineBytes
    ) {
        self.directoryURL = directoryURL
        self.currentLogURL = directoryURL.appendingPathComponent("current.log")
        self.previousLogURL = directoryURL.appendingPathComponent("previous.log")
        self.fileManager = fileManager
        self.maximumSessionBytes = max(1_024, maximumSessionBytes)
        self.maximumLineBytes = max(256, maximumLineBytes)
    }

    public convenience init(fileManager: FileManager = .default) {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        self.init(
            directoryURL: library
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("NetVplayer", isDirectory: true),
            fileManager: fileManager
        )
    }

    public func beginSession() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try ensureDirectory()
            if fileManager.fileExists(atPath: previousLogURL.path) {
                try fileManager.removeItem(at: previousLogURL)
            }
            if fileManager.fileExists(atPath: currentLogURL.path) {
                try fileManager.moveItem(at: currentLogURL, to: previousLogURL)
            }
            let marker = "\(Self.timestamp()) [SESSION_START]\n"
            try Data(marker.utf8).write(to: currentLogURL, options: .atomic)
        } catch {
            // Diagnostics must never prevent application startup.
        }
    }

    public func write(_ message: String) {
        let sanitized = DiagnosticLogSanitizer.sanitize(message)
        let prefix = "\(Self.timestamp()) "
        let messageBudget = max(0, maximumLineBytes - Data(prefix.utf8).count - 1)
        let bounded = Self.utf8Prefix(sanitized, maximumBytes: messageBudget)
        let data = Data("\(prefix)\(bounded)\n".utf8)

        lock.lock()
        defer { lock.unlock() }
        do {
            try ensureDirectory()
            try compactIfNeeded(incomingByteCount: data.count)
            if !fileManager.fileExists(atPath: currentLogURL.path) {
                try Data().write(to: currentLogURL, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: currentLogURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging is best effort by design.
        }
    }

    public func reportText(maximumCombinedBytes: Int = 2 * 1024 * 1024) -> String {
        lock.lock()
        defer { lock.unlock() }

        let budget = max(1_024, maximumCombinedBytes)
        let previousHeader = "===== Previous session =====\n"
        let currentHeader = "===== Current session =====\n"
        let separator = "\n"
        let contentBudget = max(
            0,
            budget - previousHeader.utf8.count - currentHeader.utf8.count - separator.utf8.count
        )
        let previousRaw = sessionReportText(at: previousLogURL, label: "previous")
        let currentRaw = sessionReportText(at: currentLogURL, label: "current")
        let previous = Self.utf8SuffixString(
            DiagnosticLogSanitizer.sanitize(previousRaw),
            maximumBytes: contentBudget / 2
        )
        let current = Self.utf8SuffixString(
            DiagnosticLogSanitizer.sanitize(currentRaw),
            maximumBytes: contentBudget - previous.utf8.count
        )
        return previousHeader + previous + separator + currentHeader + current
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func compactIfNeeded(incomingByteCount: Int) throws {
        let existingSize = (try? currentLogURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard existingSize + incomingByteCount > maximumSessionBytes else { return }

        let retained = tailData(at: currentLogURL, maximumBytes: maximumSessionBytes / 2)
        var replacement = Data("\(Self.timestamp()) [LOG_TRUNCATED] oldest entries removed\n".utf8)
        replacement.append(retained)
        if replacement.count + incomingByteCount > maximumSessionBytes {
            replacement = Self.utf8SuffixData(
                replacement,
                maximumBytes: max(0, maximumSessionBytes - incomingByteCount)
            )
        }
        try replacement.write(to: currentLogURL, options: .atomic)
    }

    private func sessionReportText(at url: URL, label: String) -> String {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return "[LOG_UNAVAILABLE] \(label) session log not found\n"
        }
        guard !isDirectory.boolValue else {
            return "[LOG_UNAVAILABLE] \(label) session log is not a readable file\n"
        }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                return "[LOG_UNAVAILABLE] \(label) session log is not valid UTF-8\n"
            }
            return text.isEmpty ? "[LOG_EMPTY] \(label) session log is empty\n" : text
        } catch {
            return "[LOG_UNAVAILABLE] \(label) session log could not be read\n"
        }
    }

    private func tailData(at url: URL, maximumBytes: Int) -> Data {
        guard maximumBytes > 0, let data = try? Data(contentsOf: url) else { return Data() }
        return Self.utf8SuffixData(data, maximumBytes: maximumBytes)
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        let data = Data(value.utf8)
        guard data.count > maximumBytes else { return value }
        let ellipsis = Data("...".utf8)
        var prefix = data.prefix(max(0, maximumBytes - ellipsis.count))
        while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
            prefix = prefix.dropLast()
        }
        let marker = maximumBytes >= ellipsis.count ? "..." : ""
        return (String(data: prefix, encoding: .utf8) ?? "") + marker
    }

    private static func utf8SuffixData(_ data: Data, maximumBytes: Int) -> Data {
        guard maximumBytes > 0 else { return Data() }
        guard data.count > maximumBytes else { return data }
        var suffix = data.suffix(maximumBytes)
        while !suffix.isEmpty, String(data: suffix, encoding: .utf8) == nil {
            suffix = suffix.dropFirst()
        }
        if let newline = suffix.firstIndex(of: 0x0A), newline < suffix.endIndex {
            suffix = suffix.suffix(from: suffix.index(after: newline))
        }
        return Data(suffix)
    }

    private static func utf8SuffixString(_ value: String, maximumBytes: Int) -> String {
        String(
            data: utf8SuffixData(Data(value.utf8), maximumBytes: maximumBytes),
            encoding: .utf8
        ) ?? ""
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

public enum DiagnosticLog {
    private static let store = DiagnosticLogStore()

    public static var currentLogURL: URL { store.currentLogURL }
    public static var previousLogURL: URL { store.previousLogURL }
    public static var path: String { currentLogURL.path }

    public static func beginSession() {
        store.beginSession()
    }

    public static func write(_ message: String) {
        store.write(message)
    }

    public static func reportText(maximumCombinedBytes: Int = 2 * 1024 * 1024) -> String {
        store.reportText(maximumCombinedBytes: maximumCombinedBytes)
    }
}
