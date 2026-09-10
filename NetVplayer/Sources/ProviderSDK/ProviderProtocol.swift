import Foundation
import Models

public enum ProviderPlaybackFormat {
    /// Progressive MP4 returned by a Bili-compatible Provider.
    public static let biliProgressiveMP4 = "bili-mp4"
}

public enum ProviderOperation: String, Codable, CaseIterable, Sendable {
    case handshake
    case health
    case shutdown
    case cancel
    case initialize = "init"
    case home
    case homeVideo = "home_video"
    case category
    case search
    case detail
    case player
    case live
    case epg
    case proxy
    case action
    case manualVideoCheck = "manual_video_check"
    case isVideoFormat = "is_video_format"
    case destroy
}

public struct ProviderRequest: Codable, Sendable {
    public var protocolVersion: Int
    public var requestID: String
    public var providerID: String
    public var operation: ProviderOperation
    public var site: Site?
    public var arguments: [String: ProviderJSONValue]
    public var credentialReference: String?

    public init(
        protocolVersion: Int = 1,
        requestID: String = UUID().uuidString,
        providerID: String,
        operation: ProviderOperation,
        site: Site? = nil,
        arguments: [String: ProviderJSONValue] = [:],
        credentialReference: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.providerID = providerID
        self.operation = operation
        self.site = site
        self.arguments = arguments
        self.credentialReference = credentialReference
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case requestID = "request_id"
        case providerID = "provider_id"
        case operation, site, arguments
        case credentialReference = "credential_ref"
    }
}

public struct ProviderErrorPayload: Codable, Error, Equatable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool
    public var diagnostic: String?

    public init(code: String, message: String, retryable: Bool = false, diagnostic: String? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.diagnostic = diagnostic
    }
}

public struct ProviderProxyPayload: Codable, Equatable, Sendable {
    public var statusCode: Int
    public var contentType: String?
    public var url: String?
    public var body: String?
    public var bodyBase64: String?
    public var headers: [String: String]

    public init(
        statusCode: Int,
        contentType: String? = nil,
        url: String? = nil,
        body: String? = nil,
        bodyBase64: String? = nil,
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.url = url
        self.body = body
        self.bodyBase64 = bodyBase64
        self.headers = headers
    }

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case contentType = "content_type"
        case url, body
        case bodyBase64 = "body_base64"
        case headers
    }
}

public struct ProviderResponse: Codable, Sendable {
    public var requestID: String
    public var ok: Bool
    public var result: ProviderJSONValue?
    public var proxy: ProviderProxyPayload?
    public var error: ProviderErrorPayload?

    public init(
        requestID: String,
        ok: Bool,
        result: ProviderJSONValue? = nil,
        proxy: ProviderProxyPayload? = nil,
        error: ProviderErrorPayload? = nil
    ) {
        self.requestID = requestID
        self.ok = ok
        self.result = result
        self.proxy = proxy
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case ok, result, proxy, error
    }

    public func decodedResult<T: Decodable>(_ type: T.Type) throws -> T {
        guard ok else {
            let payload = error ?? ProviderErrorPayload(code: "provider_failed", message: "Provider request failed")
            throw payload.redacted
        }
        guard let result else {
            throw ProviderErrorPayload(code: "missing_result", message: "Provider response did not contain a result")
        }
        return try result.decode(T.self)
    }
}

public extension ProviderErrorPayload {
    var redacted: ProviderErrorPayload {
        ProviderErrorPayload(
            code: code,
            message: ProviderDiagnostics.redact(message),
            retryable: retryable,
            diagnostic: diagnostic.map(ProviderDiagnostics.redact)
        )
    }
}
