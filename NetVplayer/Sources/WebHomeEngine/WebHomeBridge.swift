// WebHomeEngine/WebHomeBridge.swift
// Minimal whitelist dispatcher for future WKWebView WebHome surfaces.

import Foundation
import Models
import Storage

public enum WebHomeBridgeMethod: String, Codable, Sendable, CaseIterable {
    case search
    case detail
    case play
    case panCheck = "pan.check"
    case historyQuery = "history.query"
    case cacheGet = "cache.get"
    case cacheSet = "cache.set"
    case cacheDelete = "cache.delete"
    case uiChrome = "ui.chrome"
}

public struct WebHomeBridgeMessage: Codable, Sendable, Equatable {
    public var id: String
    public var method: String
    public var params: [String: JSONDynamicValue]

    public init(id: String, method: String, params: [String: JSONDynamicValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct WebHomeBridgeResponse: Codable, Sendable, Equatable {
    public var id: String
    public var ok: Bool
    public var result: JSONDynamicValue?
    public var error: String?

    public init(id: String, ok: Bool, result: JSONDynamicValue? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.result = WebHomeBridgeSanitizer.sanitized(result)
        self.error = error
    }
}

public struct WebHomeBridgeContext: Sendable {
    public var method: WebHomeBridgeMethod
    public var params: [String: JSONDynamicValue]

    public init(method: WebHomeBridgeMethod, params: [String: JSONDynamicValue]) {
        self.method = method
        self.params = params
    }
}

public struct WebHomeBridgeHandlers: Sendable {
    public var search: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> JSONDynamicValue)?
    public var detail: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> JSONDynamicValue)?
    public var play: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> PlaySpec)?
    public var panCheck: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> JSONDynamicValue)?
    public var historyQuery: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> JSONDynamicValue)?
    public var uiChrome: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> JSONDynamicValue)?

    public init(
        search: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> JSONDynamicValue)? = nil,
        detail: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> JSONDynamicValue)? = nil,
        play: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> PlaySpec)? = nil,
        panCheck: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> JSONDynamicValue)? = nil,
        historyQuery: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> JSONDynamicValue)? = nil,
        uiChrome: (@MainActor @Sendable (WebHomeBridgeContext) async throws -> JSONDynamicValue)? = nil
    ) {
        self.search = search
        self.detail = detail
        self.play = play
        self.panCheck = panCheck
        self.historyQuery = historyQuery
        self.uiChrome = uiChrome
    }
}

public final class WebHomeBridgeDispatcher: @unchecked Sendable {
    private let handlers: WebHomeBridgeHandlers
    private let cache: WebHomeScopedCacheStore
    private let diagnosticRecorder: (@MainActor @Sendable (WebHomeBridgeInvocation) -> Void)?
    private let largeResultByteThreshold: Int
    private let largeResultsLock = NSLock()
    private var largeResults: [String: JSONDynamicValue] = [:]

    public init(
        handlers: WebHomeBridgeHandlers = WebHomeBridgeHandlers(),
        storage: StorageManager = .shared,
        largeResultByteThreshold: Int = 16_384,
        diagnosticRecorder: (@MainActor @Sendable (WebHomeBridgeInvocation) -> Void)? = nil
    ) {
        self.handlers = handlers
        self.cache = WebHomeScopedCacheStore(storage: storage)
        self.largeResultByteThreshold = max(1_024, largeResultByteThreshold)
        self.diagnosticRecorder = diagnosticRecorder
    }

    public func dispatch(_ message: WebHomeBridgeMessage) async -> WebHomeBridgeResponse {
        let startedAt = Date()
        let paramsSummary = WebHomeBridgeInvocation.summary(for: message.params)
        let response: WebHomeBridgeResponse
        guard let method = WebHomeBridgeMethod(rawValue: message.method) else {
            response = WebHomeBridgeResponse(id: message.id, ok: false, error: "WebHome bridge method not allowed: \(message.method)")
            await recordInvocation(
                message: message,
                response: response,
                startedAt: startedAt,
                paramsSummary: paramsSummary
            )
            return response
        }
        do {
            try WebHomeBridgeSanitizer.validateSafeInputs(message.params)
            let context = WebHomeBridgeContext(method: method, params: message.params)
            let result = try await dispatch(method: method, context: context)
            let pagedResult = try pageLargeResultIfNeeded(method: method, result: result)
            response = WebHomeBridgeResponse(id: message.id, ok: true, result: pagedResult)
        } catch {
            response = WebHomeBridgeResponse(id: message.id, ok: false, error: error.localizedDescription)
        }
        await recordInvocation(
            message: message,
            response: response,
            startedAt: startedAt,
            paramsSummary: paramsSummary
        )
        return response
    }

    private func dispatch(method: WebHomeBridgeMethod, context: WebHomeBridgeContext) async throws -> JSONDynamicValue {
        switch method {
        case .search:
            return try await handlers.search?(context) ?? .object(["items": .array([])])
        case .detail:
            return try await handlers.detail?(context) ?? .object(["status": .string("handler-unavailable")])
        case .play:
            guard let spec = try await handlers.play?(context) else {
                return .object(["status": .string("handler-unavailable")])
            }
            return .object([
                "status": .string("accepted"),
                "title": .string(spec.title),
                "siteKey": .string(spec.siteKey),
                "hasPlaySpec": .bool(true)
            ])
        case .panCheck:
            return try await handlers.panCheck?(context) ?? .object(["status": .string("unknown")])
        case .historyQuery:
            return try await handlers.historyQuery?(context) ?? .array([])
        case .cacheGet:
            let key = try requiredString("key", in: context.params)
            return largeResult(for: key) ?? cache.value(for: key) ?? .null
        case .cacheSet:
            let key = try requiredString("key", in: context.params)
            let value: JSONDynamicValue = context.params["value"] ?? .null
            try cache.set(WebHomeBridgeSanitizer.sanitized(value), for: key)
            return .object(["stored": .bool(true)])
        case .cacheDelete:
            let key = try requiredString("key", in: context.params)
            try cache.delete(key: key)
            return .object(["deleted": .bool(true)])
        case .uiChrome:
            return try await handlers.uiChrome?(context) ?? .object(["accepted": .bool(true)])
        }
    }

    private func requiredString(_ name: String, in params: [String: JSONDynamicValue]) throws -> String {
        let value = params[name]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw WebHomeBridgeError.missingParameter(name)
        }
        return value
    }

    private func pageLargeResultIfNeeded(method: WebHomeBridgeMethod, result: JSONDynamicValue) throws -> JSONDynamicValue {
        guard method == .search || method == .historyQuery,
              let data = try? JSONEncoder().encode(WebHomeBridgeSanitizer.sanitized(result)),
              data.count > largeResultByteThreshold else {
            return result
        }
        let token = "result_\(method.rawValue.replacingOccurrences(of: ".", with: "_"))_\(UUID().uuidString)"
        storeLargeResult(result, for: token)
        try cache.set(result, for: token)
        return .object([
            "resultToken": .string(token),
            "nextCursor": .string("cache.get"),
            "estimatedBytes": .number(Double(data.count))
        ])
    }

    private func storeLargeResult(_ value: JSONDynamicValue, for key: String) {
        largeResultsLock.lock()
        largeResults[key] = value
        if largeResults.count > 20 {
            largeResults.removeValue(forKey: largeResults.keys.sorted().first ?? key)
        }
        largeResultsLock.unlock()
    }

    private func largeResult(for key: String) -> JSONDynamicValue? {
        largeResultsLock.lock()
        defer { largeResultsLock.unlock() }
        return largeResults[key]
    }

    private func recordInvocation(
        message: WebHomeBridgeMessage,
        response: WebHomeBridgeResponse,
        startedAt: Date,
        paramsSummary: String
    ) async {
        guard let diagnosticRecorder else { return }
        let responseBytes = (try? JSONEncoder().encode(response).count) ?? 0
        let invocation = WebHomeBridgeInvocation(
            method: message.method,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            ok: response.ok,
            error: response.error,
            paramsSummary: paramsSummary,
            responseBytes: responseBytes,
            cacheKeyCount: cache.keyCount,
            timestamp: Date()
        )
        await diagnosticRecorder(invocation)
    }
}

public enum WebHomeBridgeError: LocalizedError, Sendable {
    case missingParameter(String)
    case unsafeURL(String)
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .missingParameter(let name):
            return "WebHome bridge 缺少参数: \(name)"
        case .unsafeURL(let value):
            return "WebHome bridge URL 不允许访问: \(value)"
        case .invalidURL(let value):
            return "WebHome bridge URL 无效: \(value)"
        }
    }
}
