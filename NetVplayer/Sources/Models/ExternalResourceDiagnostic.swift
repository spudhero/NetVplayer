// Models/ExternalResourceDiagnostic.swift
// Safe inventory of remote resources referenced by TVBox configs.

import Foundation
import Darwin

public enum ExternalResourceType: String, Codable, Sendable, CaseIterable {
    case jar
    case dex
    case sharedObject = "so"
    case js
    case json
    case txt
    case unknown
}

public enum ExternalResourceDiagnosticStatus: String, Codable, Sendable, CaseIterable {
    case recorded
    case blocked
    case androidRuntimeOnly
    case unsupportedType
}

public struct ExternalResourceDiagnostic: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        [ownerType.rawValue, ownerKey, field, url, status.rawValue].joined(separator: "::")
    }

    public var ownerType: ConfigEntityType
    public var ownerKey: String
    public var ownerName: String
    public var field: String
    public var url: String
    public var resourceType: ExternalResourceType
    public var status: ExternalResourceDiagnosticStatus
    public var reason: String
    public var sizeLimitBytes: Int

    public init(
        ownerType: ConfigEntityType,
        ownerKey: String = "",
        ownerName: String = "",
        field: String,
        url: String,
        resourceType: ExternalResourceType,
        status: ExternalResourceDiagnosticStatus,
        reason: String = "",
        sizeLimitBytes: Int = 2 * 1024 * 1024
    ) {
        self.ownerType = ownerType
        self.ownerKey = ownerKey
        self.ownerName = ownerName
        self.field = field
        self.url = url
        self.resourceType = resourceType
        self.status = status
        self.reason = reason
        self.sizeLimitBytes = sizeLimitBytes
    }
}

public enum ExternalResourceDiagnosticCollector {
    public static func collect(spider: String, sites: [Site], parses: [Parse]) -> [ExternalResourceDiagnostic] {
        var diagnostics: [ExternalResourceDiagnostic] = []
        appendCandidates(
            from: spider,
            ownerType: .config,
            ownerKey: "spider",
            ownerName: "spider",
            field: "spider",
            into: &diagnostics
        )

        for site in sites {
            appendCandidates(from: site.jar, ownerType: .site, ownerKey: site.key, ownerName: site.name, field: "jar", into: &diagnostics)
            appendCandidates(from: site.api, ownerType: .site, ownerKey: site.key, ownerName: site.name, field: "api", into: &diagnostics)
            appendCandidates(from: site.ext, ownerType: .site, ownerKey: site.key, ownerName: site.name, field: "ext", into: &diagnostics)
        }

        for parse in parses {
            appendCandidates(from: parse.url, ownerType: .parse, ownerKey: parse.name, ownerName: parse.name, field: "url", into: &diagnostics)
        }

        var seen = Set<String>()
        return diagnostics.filter { seen.insert($0.id).inserted }
    }

    private static func appendCandidates(
        from value: String,
        ownerType: ConfigEntityType,
        ownerKey: String,
        ownerName: String,
        field: String,
        into diagnostics: inout [ExternalResourceDiagnostic]
    ) {
        for rawURL in extractURLs(from: value) {
            let url = redactedResourceURL(cleanResourceURL(rawURL))
            let type = resourceType(for: url)
            let statusReason = status(for: url, type: type)
            diagnostics.append(ExternalResourceDiagnostic(
                ownerType: ownerType,
                ownerKey: ownerKey,
                ownerName: ownerName,
                field: field,
                url: url,
                resourceType: type,
                status: statusReason.status,
                reason: statusReason.reason
            ))
        }
    }

    private static func extractURLs(from value: String) -> [String] {
        let pattern = #"(?:jar:)?(?:https?|file|assets)://[^\s"'<>\\|]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value) else { return nil }
            return String(value[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ","))
        }
    }

    private static func cleanResourceURL(_ rawURL: String) -> String {
        var value = rawURL
        if value.lowercased().hasPrefix("jar:") {
            value.removeFirst("jar:".count)
        }
        if let md5Range = value.range(of: ";md5;", options: [.caseInsensitive]) {
            value = String(value[..<md5Range.lowerBound])
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private static func redactedResourceURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        if components.query?.isEmpty == false {
            components.query = "<redacted>"
        }
        components.fragment = nil
        return components.string ?? value
    }

    private static func resourceType(for url: String) -> ExternalResourceType {
        let path = URL(string: url)?.path.lowercased() ?? url.lowercased()
        if path.hasSuffix(".jar") { return .jar }
        if path.hasSuffix(".dex") { return .dex }
        if path.hasSuffix(".so") { return .sharedObject }
        if path.hasSuffix(".js") { return .js }
        if path.hasSuffix(".json") { return .json }
        if path.hasSuffix(".txt") { return .txt }
        return .unknown
    }

    private static func status(for url: String, type: ExternalResourceType) -> (status: ExternalResourceDiagnosticStatus, reason: String) {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return (.blocked, "仅允许诊断公网 http/https 资源")
        }
        guard let host = parsed.host, !host.isEmpty, !isBlockedHost(host) else {
            return (.blocked, "目标地址被代理安全策略拒绝")
        }

        switch type {
        case .jar, .dex, .sharedObject:
            return (.androidRuntimeOnly, "Android Jar/Dex/so 不在 macOS 执行；仅记录资源和后续抓包线索")
        case .js, .json, .txt:
            return (.recorded, "资源地址通过安全校验，可用于可下载性诊断")
        case .unknown:
            return (.unsupportedType, "未知资源类型，仅保留引用")
        }
    }

    private static func isBlockedHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == "localhost"
            || normalized.hasSuffix(".localhost")
            || normalized.hasSuffix(".local")
            || normalized.hasSuffix(".localdomain")
            || normalized.hasSuffix(".lan") {
            return true
        }
        if normalized == "0" { return true }
        if isIPv4Literal(normalized) {
            return isBlockedIPv4(normalized)
        }
        if isBlockedIPv6(normalized) || isAmbiguousNumericHost(normalized) {
            return true
        }
        return false
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }

    private static func isBlockedIPv4(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        let first = (value >> 24) & 0xff
        let second = (value >> 16) & 0xff
        switch first {
        case 0, 10, 127:
            return true
        case 100:
            return (64...127).contains(second)
        case 169:
            return second == 254
        case 172:
            return (16...31).contains(second)
        case 192:
            return second == 168
        case 198:
            return (18...19).contains(second)
        case 224...255:
            return true
        default:
            return false
        }
    }

    private static func isBlockedIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard bytes.count >= 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
        let first = bytes[0]
        if first == 0xff { return true }
        if first == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        if (first & 0xfe) == 0xfc { return true }
        return false
    }

    private static func isAmbiguousNumericHost(_ host: String) -> Bool {
        guard host.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEFxX.")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
