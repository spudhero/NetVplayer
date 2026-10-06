import Foundation
import ProviderSDK
import SwiftSoup

struct QuickJSJSPHost: @unchecked Sendable {
    func handle(_ request: QuickJSHostControl) async -> QuickJSHostResponse {
        guard request.capability == "jsp", request.operation == "query" else {
            return failure(
                requestID: request.requestID,
                code: "unsupported_host_request",
                message: "Unsupported QuickJS JSP request"
            )
        }

        do {
            let options = request.options ?? [:]
            let html = string(options["html"]) ?? ""
            let rule = string(options["rule"]) ?? ""
            let baseURL = string(options["base_url"]) ?? ""
            let mode = string(options["mode"])?.lowercased() ?? "pdfh"
            let value: ProviderJSONValue
            switch mode {
            case "pdfa":
                value = .array(try QuickJSJSPParser.pdfa(html: html, rule: rule, baseURL: baseURL).map(ProviderJSONValue.string))
            case "pdfh":
                value = .string(try QuickJSJSPParser.pdfh(html: html, rule: rule, baseURL: baseURL))
            case "pd":
                value = .string(try QuickJSJSPParser.pd(html: html, rule: rule, baseURL: baseURL))
            case "pdfl":
                let texts = string(options["texts"]) ?? ""
                let urls = string(options["urls"]) ?? rule
                let urlKey = string(options["url_key"]) ?? baseURL
                value = .array(try QuickJSJSPParser.pdfl(html: html, texts: texts, urls: urls, urlKey: urlKey).map(ProviderJSONValue.string))
            default:
                throw QuickJSJSPHostError(code: "unsupported_mode", message: "QuickJS JSP mode is unsupported")
            }
            return QuickJSHostResponse(
                requestID: request.requestID,
                ok: true,
                result: .object(["value": value])
            )
        } catch {
            return failure(
                requestID: request.requestID,
                code: "jsp_parse_failed",
                message: "QuickJS JSP parsing failed"
            )
        }
    }

    private func string(_ value: ProviderJSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private func failure(requestID: String, code: String, message: String) -> QuickJSHostResponse {
        QuickJSHostResponse(
            requestID: requestID,
            ok: false,
            error: ProviderErrorPayload(code: code, message: message)
        )
    }
}

private struct QuickJSJSPHostError: Error {
    let code: String
    let message: String
}

enum QuickJSJSPParser {
    private static let noAddPattern = #":eq|:lt|:gt|:first|:last|:not|:even|:odd|:has|:contains|:matches|:empty|^body$|^#"#
    private static let joinURLPattern = #"(?i)(url|src|href|-original|-src|-play|-url|style)$|^(data-|url-|src-)"#
    private static let specialSchemes = #"(?i)^(ftp|magnet|thunder|ws):"#

    static func pdfa(html: String, rule: String, baseURL: String) throws -> [String] {
        let document = try parse(html: html, baseURL: baseURL)
        let elements = try select(document: document, rule: rule, first: false)
        return try elements.map { try elementHTML($0) }
    }

    static func pdfh(html: String, rule: String, baseURL: String) throws -> String {
        try parseDomForURL(html: html, rule: rule, baseURL: baseURL)
    }

    static func pd(html: String, rule: String, baseURL: String) throws -> String {
        try parseDomForURL(html: html, rule: rule, baseURL: baseURL)
    }

    static func pdfl(html: String, texts: String, urls: String, urlKey: String) throws -> [String] {
        let document = try parse(html: html, baseURL: urlKey)
        let (urlRule, _) = splitOption(urls)
        let elements = try select(document: document, rule: urlRule, first: false)
        return try elements.map { element in
            let fragment = try element.outerHtml()
            let text = try parseDomForURL(html: fragment, rule: texts, baseURL: "")
            let url = try parseDomForURL(html: fragment, rule: urls, baseURL: urlKey)
            return "\(text.trimmingCharacters(in: .whitespacesAndNewlines))$\(url)"
        }
    }

    private static func parse(html: String, baseURL: String) throws -> Document {
        try SwiftSoup.parse(html, baseURL)
    }

    private static func parseDomForURL(html: String, rule: String, baseURL: String) throws -> String {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerRule = trimmedRule.lowercased()
        if lowerRule == "text" || lowerRule == "body&&text" {
            return try parse(html: html, baseURL: baseURL).text()
        }
        if lowerRule == "html" || lowerRule == "body&&html" {
            return try parse(html: html, baseURL: baseURL).html()
        }

        let (selectorRule, option) = splitOption(trimmedRule)
        let document = try parse(html: html, baseURL: baseURL)
        let elements = try select(document: document, rule: selectorRule, first: true)
        guard let element = elements.first else { return "" }
        let output = try value(for: element, option: option ?? "")
        guard !output.isEmpty else { return "" }
        guard shouldJoinURL(option: option ?? "", value: output) else { return output }
        return resolveURL(output, baseURL: baseURL)
    }

    private static func splitOption(_ rule: String) -> (String, String?) {
        let parts = rule.components(separatedBy: "&&")
        guard parts.count > 1 else { return (rule, nil) }
        return (parts.dropLast().joined(separator: "&&"), parts.last)
    }

    private static func value(for element: Element, option: String) throws -> String {
        let normalized = option.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return try element.outerHtml() }
        if normalized.caseInsensitiveCompare("text") == .orderedSame {
            return try element.text()
        }
        if normalized.caseInsensitiveCompare("html") == .orderedSame {
            return try element.html()
        }
        for attribute in normalized.split(separator: "|").map(String.init) {
            let value = try element.attr(attribute)
            if !value.isEmpty {
                if attribute.lowercased().contains("style"), let url = styleURL(value) {
                    return url
                }
                return value
            }
        }
        return ""
    }

    private static func shouldJoinURL(option: String, value: String) -> Bool {
        guard option.range(of: joinURLPattern, options: .regularExpression) != nil else { return false }
        return value.range(of: specialSchemes, options: .regularExpression) == nil
    }

    private static func resolveURL(_ value: String, baseURL: String) -> String {
        let lower = value.lowercased()
        if let index = lower.range(of: "http") {
            return String(value[index.lowerBound...])
        }
        guard !baseURL.isEmpty,
              let base = URL(string: baseURL),
              let resolved = URL(string: value, relativeTo: base)?.absoluteURL else {
            return value
        }
        return resolved.absoluteString
    }

    private static func styleURL(_ value: String) -> String? {
        guard let match = value.range(of: #"(?i)url\((.*?)\)"#, options: .regularExpression) else { return nil }
        let matched = String(value[match])
        guard let open = matched.firstIndex(of: "("), let close = matched.lastIndex(of: ")") else { return nil }
        return matched[matched.index(after: open)..<close]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
    }

    private static func select(document: Document, rule: String, first: Bool) throws -> Elements {
        let transformed = parseHikerToJQ(rule, first: first)
        guard !transformed.isEmpty else { return Elements() }
        var current: Elements?
        for token in transformed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            let info = selectorInfo(String(token))
            guard !info.selector.isEmpty else { continue }
            let selected: Elements
            if let current {
                selected = try current.select(info.selector)
            } else {
                selected = try document.select(info.selector)
            }
            let adjusted = try apply(info: info, to: selected)
            current = adjusted
            if adjusted.isEmpty { break }
        }
        return current ?? Elements()
    }

    private static func parseHikerToJQ(_ rule: String, first: Bool) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let sections = trimmed.components(separatedBy: "&&")
        if sections.count == 1 {
            return appendFirst(to: trimmed, enabled: first)
        }
        return sections.enumerated().map { index, section in
            let shouldAppend = first || index < sections.count - 1
            return appendFirst(to: section, enabled: shouldAppend)
        }.joined(separator: " ")
    }

    private static func appendFirst(to section: String, enabled: Bool) -> String {
        let tokens = section.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard let last = tokens.last, enabled,
              String(last).range(of: noAddPattern, options: .regularExpression) == nil else {
            return section.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefix = tokens.dropLast().joined(separator: " ")
        let suffix = String(last) + ":eq(0)"
        return prefix.isEmpty ? suffix : "\(prefix) \(suffix)"
    }

    private struct SelectorInfo {
        var selector: String
        var positional: PositionalFilter?
        var textMatch: TextMatch?
        var exclusions: [String]
    }

    private enum PositionalFilter {
        case index(Int)
        case lessThan(Int)
        case greaterThan(Int)
        case parity(even: Bool)
    }

    private struct TextMatch {
        var ownText: Bool
        var pattern: String
    }

    private static func selectorInfo(_ raw: String) -> SelectorInfo {
        let parts = raw.components(separatedBy: "--")
        var selector = parts.first ?? raw
        var positional: PositionalFilter?
        var textMatch: TextMatch?
        if let open = selector.range(of: ":eq("), let close = selector[open.upperBound...].firstIndex(of: ")") {
            let number = String(selector[open.upperBound..<close])
            if let value = Int(number) { positional = .index(value) }
            selector.removeSubrange(open.lowerBound...close)
        }
        if selector.hasSuffix(":first") {
            selector.removeLast(":first".count)
            positional = .index(0)
        } else if selector.hasSuffix(":last") {
            selector.removeLast(":last".count)
            positional = .index(-1)
        } else if selector.hasSuffix(":even") {
            selector.removeLast(":even".count)
            positional = .parity(even: true)
        } else if selector.hasSuffix(":odd") {
            selector.removeLast(":odd".count)
            positional = .parity(even: false)
        } else if let match = selector.range(of: #":(lt|gt)\((-?\d+)\)$"#, options: .regularExpression) {
            let expression = String(selector[match])
            let operatorName = expression.hasPrefix(":lt") ? "lt" : "gt"
            let number = expression.drop { $0 != "(" }.dropFirst().dropLast()
            if let value = Int(number) {
                positional = operatorName == "lt" ? .lessThan(value) : .greaterThan(value)
            }
            selector.removeSubrange(match)
        }
        if let match = selector.range(of: #":(matchesOwn|matches)\(.*\)$"#, options: .regularExpression),
           let open = selector[match].firstIndex(of: "("),
           let close = selector[match].lastIndex(of: ")") {
            let expression = selector[match]
            textMatch = TextMatch(
                ownText: expression.hasPrefix(":matchesOwn"),
                pattern: String(expression[expression.index(after: open)..<close])
            )
            selector.removeSubrange(match)
        }
        return SelectorInfo(
            selector: selector,
            positional: positional,
            textMatch: textMatch,
            exclusions: Array(parts.dropFirst()).filter { !$0.isEmpty }
        )
    }

    private static func apply(info: SelectorInfo, to elements: Elements) throws -> Elements {
        var selected = Array(elements)
        if let positional = info.positional {
            switch positional {
            case .index(let index):
                let resolved = index >= 0 ? index : selected.count + index
                selected = selected.indices.contains(resolved) ? [selected[resolved]] : []
            case .lessThan(let value):
                let limit = value >= 0 ? value : selected.count + value
                selected = selected.enumerated().filter { $0.offset < limit }.map(\.element)
            case .greaterThan(let value):
                let limit = value >= 0 ? value : selected.count + value
                selected = selected.enumerated().filter { $0.offset > limit }.map(\.element)
            case .parity(let even):
                selected = selected.enumerated().filter { ($0.offset % 2 == 0) == even }.map(\.element)
            }
        }
        if let textMatch = info.textMatch {
            let regex = try NSRegularExpression(pattern: textMatch.pattern)
            selected = try selected.filter { element in
                let value = try textMatch.ownText ? element.ownText() : element.text()
                return regex.firstMatch(
                    in: value,
                    range: NSRange(value.startIndex..<value.endIndex, in: value)
                ) != nil
            }
        }
        guard !info.exclusions.isEmpty else { return Elements(selected) }
        let copy = Elements(selected).copy() as! Elements
        for exclusion in info.exclusions {
            try copy.select(exclusion).remove()
        }
        return copy
    }

    private static func elementHTML(_ element: Element) throws -> String {
        try element.outerHtml()
    }
}
