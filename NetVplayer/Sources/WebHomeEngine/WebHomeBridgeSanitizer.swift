// WebHomeEngine/WebHomeBridgeSanitizer.swift

import Foundation
import Models
import ProxyServer

public enum WebHomeBridgeSanitizer {
    private static let sensitiveKeys = [
        "cookie", "authorization", "token", "access_token", "refresh_token",
        "auth_key", "signature", "sign", "callback", "callback-var", "ossaccesskeyid"
    ]

    public static func validateSafeInputs(_ value: [String: JSONDynamicValue]) throws {
        try validateSafeInputs(.object(value))
    }

    public static func validateSafeInputs(_ value: JSONDynamicValue) throws {
        switch value {
        case .string(let string):
            try validateURLStringIfNeeded(string)
        case .array(let values):
            for item in values { try validateSafeInputs(item) }
        case .object(let object):
            for item in object.values { try validateSafeInputs(item) }
        case .number, .bool, .null:
            return
        }
    }

    public static func sanitized(_ value: JSONDynamicValue?) -> JSONDynamicValue? {
        guard let value else { return nil }
        return sanitized(value)
    }

    public static func sanitized(_ value: JSONDynamicValue) -> JSONDynamicValue {
        switch value {
        case .string(let string):
            return .string(redactedString(string))
        case .array(let values):
            return .array(values.map(sanitized))
        case .object(let object):
            var sanitizedObject: [String: JSONDynamicValue] = [:]
            for (key, value) in object {
                if isSensitiveKey(key) {
                    sanitizedObject[key] = .string("<redacted>")
                } else {
                    sanitizedObject[key] = sanitized(value)
                }
            }
            return .object(sanitizedObject)
        case .number, .bool, .null:
            return value
        }
    }

    private static func validateURLStringIfNeeded(_ value: String) throws {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased() else { return }
        if scheme == "http" || scheme == "https" {
            _ = try ProxyAccessPolicy.validateTargetURL(value)
            return
        }
        if ["file", "data", "about"].contains(scheme) {
            throw WebHomeBridgeError.unsafeURL(value)
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        if lower == "resulttoken" {
            return false
        }
        return sensitiveKeys.contains { lower.contains($0) }
    }

    private static func redactedString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("file://") || trimmed.hasPrefix("/") {
            return "<redacted-path>"
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return value
        }
        return redactedURLQuery(value)
    }

    private static func redactedURLQuery(_ value: String) -> String {
        guard let queryStart = value.firstIndex(of: "?") else { return value }
        let fragmentStart = value[queryStart...].firstIndex(of: "#")
        let queryEnd = fragmentStart ?? value.endIndex
        let prefix = value[..<value.index(after: queryStart)]
        let query = value[value.index(after: queryStart)..<queryEnd]
        let suffix = fragmentStart.map { value[$0...] } ?? ""
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            let separator = pair.firstIndex(of: "=")
            let encodedName = separator.map { pair[..<$0] } ?? pair[...]
            let decodedName = String(encodedName).removingPercentEncoding ?? String(encodedName)
            guard isSensitiveKey(decodedName) else { return String(pair) }
            return "\(encodedName)=<redacted>"
        }
        return String(prefix) + pairs.joined(separator: "&") + String(suffix)
    }
}
