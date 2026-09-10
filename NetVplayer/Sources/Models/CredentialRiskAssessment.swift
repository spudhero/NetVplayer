// Models/CredentialRiskAssessment.swift
// Local credential exposure risk classification for external TVBox sites.

import Foundation

public enum CredentialRiskLevel: String, Codable, Sendable, CaseIterable {
    case safe
    case low
    case high
    case unaudited
}

public struct CredentialRiskAssessment: Codable, Sendable, Equatable, Identifiable {
    public var siteKey: String
    public var siteName: String
    public var riskLevel: CredentialRiskLevel
    public var reason: String
    public var redactedEvidence: String
    public var detectedFields: [String]
    public var thirdPartyDomains: [String]

    public var id: String {
        [siteKey, siteName, riskLevel.rawValue, reason].joined(separator: "::")
    }

    public init(
        siteKey: String,
        siteName: String = "",
        riskLevel: CredentialRiskLevel,
        reason: String = "",
        redactedEvidence: String = "",
        detectedFields: [String] = [],
        thirdPartyDomains: [String] = []
    ) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.riskLevel = riskLevel
        self.reason = reason
        self.redactedEvidence = Self.redact(redactedEvidence)
        self.detectedFields = detectedFields
        self.thirdPartyDomains = thirdPartyDomains
    }

    public static func assess(site: Site) -> CredentialRiskAssessment {
        let ext = site.ext.trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = detectedSensitiveFields(in: ext)
        let domains = thirdPartyDomains(in: ext + " " + site.api)
        let lowerExt = ext.lowercased()

        if lowerExt.contains("token.json") || lowerExt.contains("token_json") {
            let proxyMode = tokenJSONProxyMode(ext)
            if proxyMode == "proxy" || proxyMode == "1" || proxyMode == "true" {
                return CredentialRiskAssessment(
                    siteKey: site.key,
                    siteName: site.name,
                    riskLevel: .high,
                    reason: "token.json 凭据经第三方 proxy 路径转发",
                    redactedEvidence: ext,
                    detectedFields: detected.isEmpty ? ["token.json"] : detected,
                    thirdPartyDomains: domains
                )
            }
            if proxyMode == "0" || proxyMode == "false" || proxyMode == "direct" || proxyMode.isEmpty {
                return CredentialRiskAssessment(
                    siteKey: site.key,
                    siteName: site.name,
                    riskLevel: .low,
                    reason: "token.json 凭据直连或未启用 proxy，仍需用户确认来源可信",
                    redactedEvidence: ext,
                    detectedFields: detected.isEmpty ? ["token.json"] : detected,
                    thirdPartyDomains: domains
                )
            }
            return CredentialRiskAssessment(
                siteKey: site.key,
                siteName: site.name,
                riskLevel: .unaudited,
                reason: "token.json proxy 模式未识别",
                redactedEvidence: ext,
                detectedFields: detected.isEmpty ? ["token.json"] : detected,
                thirdPartyDomains: domains
            )
        }

        guard !detected.isEmpty else {
            return CredentialRiskAssessment(
                siteKey: site.key,
                siteName: site.name,
                riskLevel: .safe,
                reason: "未发现 cookie/token 字段",
                redactedEvidence: ext
            )
        }

        if domains.isEmpty {
            return CredentialRiskAssessment(
                siteKey: site.key,
                siteName: site.name,
                riskLevel: .safe,
                reason: "凭据字段只在本地配置中出现，未发现第三方域名",
                redactedEvidence: ext,
                detectedFields: detected
            )
        }

        return CredentialRiskAssessment(
            siteKey: site.key,
            siteName: site.name,
            riskLevel: .low,
            reason: "凭据字段与第三方站点 URL 同时出现，需确认是否只用于网站 session",
            redactedEvidence: ext,
            detectedFields: detected,
            thirdPartyDomains: domains
        )
    }

    public static func redact(_ value: String) -> String {
        var redacted = value
        for field in sensitiveFields {
            redacted = redacted.replacingOccurrences(
                of: "(?i)(\"\(NSRegularExpression.escapedPattern(for: field))\"\\s*:\\s*\")[^\"]+\"",
                with: "$1<redacted>\"",
                options: .regularExpression
            )
            redacted = redacted.replacingOccurrences(
                of: "(?i)(\(NSRegularExpression.escapedPattern(for: field))\\s*=\\s*)[^&\\s;\"'}]+",
                with: "$1<redacted>",
                options: .regularExpression
            )
            redacted = redacted.replacingOccurrences(
                of: "(?i)(\(NSRegularExpression.escapedPattern(for: field))=)[^&\\s]+",
                with: "$1<redacted>",
                options: .regularExpression
            )
        }
        redacted = redacted.replacingOccurrences(
            of: #"(?i)(auth_key|signature|ossaccesskeyid|access_token|refresh_token)=([^&\s]+)"#,
            with: "$1=<redacted>",
            options: .regularExpression
        )
        if redacted.count > 240 {
            return String(redacted.prefix(240)) + "..."
        }
        return redacted
    }

    private static let sensitiveFields = [
        "cookie", "cookies", "token", "refresh_token", "access_token", "open_token",
        "quark_cookie", "uccookie", "tyitoken", "dutoken", "p123token", "tuctoken",
        "bili_cookie", "ali_token"
    ]

    private static func detectedSensitiveFields(in value: String) -> [String] {
        let lower = value.lowercased()
        return sensitiveFields.filter { lower.contains($0) }
    }

    private static func tokenJSONProxyMode(_ value: String) -> String {
        let parts = value.components(separatedBy: "$$$")
        guard parts.count >= 3 else { return "" }
        return parts[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func thirdPartyDomains(in value: String) -> [String] {
        let urls = extractURLs(from: value)
        let official = [
            "quark.cn", "uc.cn", "aliyundrive.com", "alipan.com", "115.com",
            "123pan.com", "123684.com", "bilibili.com", "baidu.com",
            "mypikpak.com", "pikpak.com"
        ]
        let domains = urls.compactMap { URL(string: $0)?.host?.lowercased() }
        let thirdParty = domains.filter { host in
            !official.contains { host == $0 || host.hasSuffix(".\($0)") }
        }
        return Array(Set(thirdParty)).sorted()
    }

    private static func extractURLs(from value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"https?://[^\s"'<>\\]+"#, options: []) else {
            return []
        }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            return String(value[range]).trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        }
    }
}
