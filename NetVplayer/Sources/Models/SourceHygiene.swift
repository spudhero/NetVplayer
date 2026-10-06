// Models/SourceHygiene.swift
// Local-only source governance rules and diagnostics.

import Foundation

public enum SourceHygieneRuleKind: String, Codable, Sendable, CaseIterable {
    case siteFingerprint
    case siteNameRegex
    case parseURL
    case liveURL
}

public struct SourceHygieneRule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: SourceHygieneRuleKind
    public var pattern: String
    public var name: String
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: SourceHygieneRuleKind,
        pattern: String,
        name: String = "",
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.name = name
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

public struct SourceHygieneDecision: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var ruleID: UUID
    public var ruleName: String
    public var kind: SourceHygieneRuleKind
    public var entityType: ConfigEntityType
    public var entityKey: String
    public var entityName: String
    public var value: String
    public var reason: String

    public init(
        id: UUID = UUID(),
        ruleID: UUID,
        ruleName: String = "",
        kind: SourceHygieneRuleKind,
        entityType: ConfigEntityType,
        entityKey: String = "",
        entityName: String = "",
        value: String = "",
        reason: String = ""
    ) {
        self.id = id
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.kind = kind
        self.entityType = entityType
        self.entityKey = entityKey
        self.entityName = entityName
        self.value = value
        self.reason = reason
    }
}

public enum SourceHygienePolicy {
    public static func siteFingerprint(_ site: Site) -> String {
        fingerprint([site.api, site.ext, site.jar].joined(separator: "|"))
    }

    public static func filterSites(_ sites: [Site], rules: [SourceHygieneRule]) -> (items: [Site], decisions: [SourceHygieneDecision]) {
        var decisions: [SourceHygieneDecision] = []
        let items = sites.filter { site in
            if let decision = decision(for: site, rules: rules) {
                decisions.append(decision)
                return false
            }
            return true
        }
        return (items, decisions)
    }

    public static func filterParses(_ parses: [Parse], rules: [SourceHygieneRule]) -> (items: [Parse], decisions: [SourceHygieneDecision]) {
        var decisions: [SourceHygieneDecision] = []
        let items = parses.filter { parse in
            if let decision = decision(for: parse, rules: rules) {
                decisions.append(decision)
                return false
            }
            return true
        }
        return (items, decisions)
    }

    public static func filterLives(_ lives: [Live], rules: [SourceHygieneRule]) -> (items: [Live], decisions: [SourceHygieneDecision]) {
        var decisions: [SourceHygieneDecision] = []
        let items = lives.filter { live in
            if let decision = decision(for: live, rules: rules) {
                decisions.append(decision)
                return false
            }
            return true
        }
        return (items, decisions)
    }

    public static func decision(for site: Site, rules: [SourceHygieneRule]) -> SourceHygieneDecision? {
        for rule in rules where rule.isEnabled {
            switch rule.kind {
            case .siteFingerprint:
                guard equals(rule.pattern, siteFingerprint(site)) else { continue }
                return decision(rule: rule, entityType: .site, key: site.key, name: site.name, value: siteFingerprint(site))
            case .siteNameRegex:
                guard regex(rule.pattern, matches: site.name) else { continue }
                return decision(rule: rule, entityType: .site, key: site.key, name: site.name, value: site.name)
            case .parseURL, .liveURL:
                continue
            }
        }
        return nil
    }

    public static func decision(for parse: Parse, rules: [SourceHygieneRule]) -> SourceHygieneDecision? {
        for rule in rules where rule.isEnabled && rule.kind == .parseURL {
            guard contains(rule.pattern, in: parse.url) else { continue }
            return decision(rule: rule, entityType: .parse, key: parse.name, name: parse.name, value: parse.url)
        }
        return nil
    }

    public static func decision(for live: Live, rules: [SourceHygieneRule]) -> SourceHygieneDecision? {
        for rule in rules where rule.isEnabled && rule.kind == .liveURL {
            let values = [live.url, live.api, live.ext, live.jar] + live.groups.flatMap { $0.channels.flatMap(\.urls) }
            guard let match = values.first(where: { contains(rule.pattern, in: $0) }) else { continue }
            return decision(rule: rule, entityType: .live, key: live.name, name: live.name, value: match)
        }
        return nil
    }

    private static func decision(
        rule: SourceHygieneRule,
        entityType: ConfigEntityType,
        key: String,
        name: String,
        value: String
    ) -> SourceHygieneDecision {
        SourceHygieneDecision(
            ruleID: rule.id,
            ruleName: rule.name,
            kind: rule.kind,
            entityType: entityType,
            entityKey: key,
            entityName: name,
            value: value,
            reason: "命中本地源治理规则：\(rule.name.isEmpty ? rule.pattern : rule.name)"
        )
    }

    private static func contains(_ needle: String, in haystack: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func equals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func regex(_ pattern: String, matches value: String) -> Bool {
        guard !pattern.isEmpty,
              let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
