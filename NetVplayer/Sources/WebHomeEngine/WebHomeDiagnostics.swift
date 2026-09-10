// WebHomeEngine/WebHomeDiagnostics.swift
// Sanitized bridge diagnostics for the default-off WebHome surface.

import Foundation
import Models

public struct WebHomeBridgeInvocation: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var method: String
    public var durationMs: Int
    public var ok: Bool
    public var error: String?
    public var paramsSummary: String
    public var responseBytes: Int
    public var cacheKeyCount: Int
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        method: String,
        durationMs: Int,
        ok: Bool,
        error: String? = nil,
        paramsSummary: String = "",
        responseBytes: Int = 0,
        cacheKeyCount: Int = 0,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.method = method
        self.durationMs = max(0, durationMs)
        self.ok = ok
        self.error = error
        self.paramsSummary = Self.clamped(paramsSummary, limit: 600)
        self.responseBytes = max(0, responseBytes)
        self.cacheKeyCount = max(0, cacheKeyCount)
        self.timestamp = timestamp
    }

    public static func summary(for params: [String: JSONDynamicValue], limit: Int = 600) -> String {
        let sanitized = WebHomeBridgeSanitizer.sanitized(.object(params))
        guard let data = try? JSONEncoder().encode(sanitized),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return clamped(text, limit: limit)
    }

    private static func clamped(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "..."
    }
}

public struct WebHomeSessionDiagnostic: Codable, Sendable, Equatable {
    public var currentURLStatus: String
    public var cacheKeyCount: Int
    public var lastError: String?
    public var invocations: [WebHomeBridgeInvocation]

    public init(
        currentURLStatus: String = "未加载",
        cacheKeyCount: Int = 0,
        lastError: String? = nil,
        invocations: [WebHomeBridgeInvocation] = []
    ) {
        self.currentURLStatus = currentURLStatus
        self.cacheKeyCount = max(0, cacheKeyCount)
        self.lastError = lastError
        self.invocations = invocations
    }

    public mutating func record(_ invocation: WebHomeBridgeInvocation, limit: Int = 30) {
        invocations.insert(invocation, at: 0)
        if invocations.count > limit {
            invocations.removeLast(invocations.count - limit)
        }
        cacheKeyCount = invocation.cacheKeyCount
        if invocation.ok {
            lastError = nil
        } else {
            lastError = invocation.error
        }
    }
}
