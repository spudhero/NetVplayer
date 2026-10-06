// Models/IBoxVideoSourceReference.swift
// Sanitized behavior notes for iBox 2.4.6 video-source compatibility work.

import Foundation

public struct IBoxParseDiagnostic: Sendable, Equatable {
    public var parseURL: String
    public var headers: [String: String]
    public var requiresParse: Bool
    public var preferredParseType: ParseType
    public var reason: String

    public init(
        parseURL: String,
        headers: [String: String],
        requiresParse: Bool,
        preferredParseType: ParseType,
        reason: String
    ) {
        self.parseURL = parseURL
        self.headers = headers
        self.requiresParse = requiresParse
        self.preferredParseType = preferredParseType
        self.reason = reason
    }

    public var compatibleWithBuiltInParseRoutes: Bool {
        switch preferredParseType {
        case .webView, .json, .superParse:
            return true
        case .jsonExt, .jsonMix:
            return false
        }
    }

    public static func analyze(_ payload: [String: Any]) -> IBoxParseDiagnostic {
        let payload = firstObject(in: payload, matching: hasParseMarkers) ?? payload
        let parseURL = firstString(in: payload, keys: ["parse_api", "parser_api", "parse-url", "parseUrl", "parseApi", "parse"])
        var headers = videoParseHeaders(from: payload)
        let ua = firstString(in: payload, keys: ["ua", "user-agent", "User-Agent"])
        if !ua.isEmpty {
            headers["User-Agent"] = ua
        }
        let referer = firstString(in: payload, keys: ["referer", "referrer", "Referer"])
        if !referer.isEmpty {
            headers["Referer"] = referer
        }

        let rawType = int(in: payload, keys: ["parseType", "type"])
            ?? (parseURL.isEmpty ? ParseType.webView.rawValue : ParseType.json.rawValue)
        let preferredType = ParseType(rawValue: rawType) ?? (parseURL.isEmpty ? .webView : .json)
        let requiresParse = bool(in: payload, keys: ["needParse", "isParse", "jx"])
            || !parseURL.isEmpty

        return IBoxParseDiagnostic(
            parseURL: parseURL,
            headers: headers,
            requiresParse: requiresParse,
            preferredParseType: preferredType,
            reason: requiresParse
                ? "iBox parse 形态可进入现有 JSON/WebView/SuperParse 路线"
                : "未观察到 iBox parse 标记"
        )
    }

    private static func firstString(in payload: [String: Any], keys: [String]) -> String {
        for key in keys {
            let value = firstString(in: payload, key: key)
            if !value.isEmpty { return value }
        }
        return ""
    }

    private static func videoParseHeaders(from payload: [String: Any]) -> [String: String] {
        payload.reduce(into: [:]) { result, entry in
            if entry.key.lowercased().hasPrefix("video-parse-") {
                let value = string(entry.value)
                guard !value.isEmpty else { return }
                result[entry.key] = value
            } else if let object = entry.value as? [String: Any] {
                result.merge(videoParseHeaders(from: object)) { _, new in new }
            } else if let array = entry.value as? [[String: Any]] {
                for object in array {
                    result.merge(videoParseHeaders(from: object)) { _, new in new }
                }
            }
        }
    }

    private static func hasParseMarkers(_ payload: [String: Any]) -> Bool {
        !firstString(in: payload, keys: ["parse_api", "parser_api", "parse-url", "parseUrl", "parseApi", "parse"]).isEmpty
            || !firstString(in: payload, keys: ["needParse", "isParse", "parseType"]).isEmpty
            || !videoParseHeaders(from: payload).isEmpty
    }

    private static func firstObject(
        in value: Any,
        matching predicate: ([String: Any]) -> Bool
    ) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if predicate(object) { return object }
            for child in object.values {
                if let match = firstObject(in: child, matching: predicate) {
                    return match
                }
            }
        } else if let array = value as? [[String: Any]] {
            for object in array {
                if let match = firstObject(in: object, matching: predicate) {
                    return match
                }
            }
        }
        return nil
    }

    private static func firstString(in value: Any, key targetKey: String) -> String {
        if let object = value as? [String: Any] {
            if let match = object.first(where: { $0.key.caseInsensitiveCompare(targetKey) == .orderedSame }) {
                let value = string(match.value)
                if !value.isEmpty { return value }
            }
            for child in object.values {
                let result = firstString(in: child, key: targetKey)
                if !result.isEmpty { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                let result = firstString(in: child, key: targetKey)
                if !result.isEmpty { return result }
            }
        }
        return ""
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let value as String:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case let value as NSNumber:
            return value.stringValue
        case let value as Bool:
            return value ? "1" : "0"
        default:
            return ""
        }
    }

    private static func int(in payload: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            let value = firstString(in: payload, key: key)
            if let number = Int(value) { return number }
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.intValue != 0
        case let value as String:
            let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lower == "1" || lower == "true" || lower == "yes"
        default:
            return false
        }
    }

    private static func bool(in payload: [String: Any], keys: [String]) -> Bool {
        keys.contains { key in
            bool(firstString(in: payload, key: key))
        }
    }
}
