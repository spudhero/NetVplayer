import Foundation

public enum ProviderDiagnosticLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

public enum ProviderDiagnosticCategory: String, Codable, Sendable {
    case lifecycle
    case request
    case process
    case protocolViolation = "protocol"
    case standardError = "stderr"
}

public enum ProviderDiagnosticCode: String, Codable, Sendable {
    case processStarting = "process.starting"
    case processStarted = "process.started"
    case processLaunchFailed = "process.launch_failed"
    case processStopping = "process.stopping"
    case processStopped = "process.stopped"
    case processTerminated = "process.terminated"
    case requestStarted = "request.started"
    case requestCompleted = "request.completed"
    case requestFailed = "request.failed"
    case requestTimedOut = "request.timed_out"
    case requestCanceled = "request.canceled"
    case invalidResponse = "protocol.invalid_response"
    case standardErrorOutput = "process.stderr"
}

public struct ProviderDiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let level: ProviderDiagnosticLevel
    public let category: ProviderDiagnosticCategory
    public let code: ProviderDiagnosticCode
    public let providerID: String
    public let requestID: String?
    public let processID: Int32?
    public let terminationStatus: Int32?
    public let statusCode: Int?
    public let contentType: String?
    public var message: String?

    public init(
        timestamp: Date = Date(),
        level: ProviderDiagnosticLevel,
        category: ProviderDiagnosticCategory,
        code: ProviderDiagnosticCode,
        providerID: String,
        requestID: String? = nil,
        processID: Int32? = nil,
        terminationStatus: Int32? = nil,
        statusCode: Int? = nil,
        contentType: String? = nil,
        message: String? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.code = code
        self.providerID = providerID
        self.requestID = requestID
        self.processID = processID
        self.terminationStatus = terminationStatus
        self.statusCode = statusCode
        self.contentType = contentType
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case level
        case category
        case code
        case providerID = "provider_id"
        case requestID = "request_id"
        case processID = "process_id"
        case terminationStatus = "termination_status"
        case statusCode = "status_code"
        case contentType = "content_type"
        case message
    }
}

public enum ProviderDiagnostics {
    private static let urlPattern = try? NSRegularExpression(pattern: #"https?://[^\s\"'<>]+"#)
    private static let headerPattern = try? NSRegularExpression(
        pattern: #"(?i)(cookie|authorization|proxy-authorization|x-api-key)\s*:\s*[^\r\n]+"#
    )

    public static func redact(_ value: String) -> String {
        var result = value
        if let pattern = urlPattern {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "<redacted-url>"
            )
        }
        if let pattern = headerPattern {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1: <redacted>"
            )
        }
        return result
    }

    public static func jsonLine(for event: ProviderDiagnosticEvent) throws -> Data {
        var redactedEvent = event
        if let message = redactedEvent.message {
            redactedEvent.message = redact(message)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(redactedEvent) + Data([0x0A])
    }
}
