import Foundation
import Models
import ProviderSDK

public enum ProviderProxyResponseError: LocalizedError, Equatable, Sendable {
    case invalidStatusCode(Int)
    case invalidBase64Body
    case bodyTooLarge(limit: Int)
    case invalidHeader(String)

    public var errorDescription: String? {
        switch self {
        case .invalidStatusCode(let statusCode):
            return "Provider proxy status code is invalid: \(statusCode)"
        case .invalidBase64Body:
            return "Provider proxy body base64 is invalid"
        case .bodyTooLarge(let limit):
            return "Provider proxy body exceeds the configured byte limit: \(limit)"
        case .invalidHeader(let name):
            return "Provider proxy response header is invalid: \(name)"
        }
    }
}

public enum ProviderProxyResponseAdapter {
    public static let defaultMaximumBodyBytes = 32 * 1024 * 1024

    public static func response(
        from payload: ProviderProxyPayload,
        maximumBodyBytes: Int = defaultMaximumBodyBytes
    ) throws -> ProxyResponse {
        guard (100...599).contains(payload.statusCode) else {
            throw ProviderProxyResponseError.invalidStatusCode(payload.statusCode)
        }

        let limit = max(1, maximumBodyBytes)
        let data: Data
        if let encoded = payload.bodyBase64 {
            let maximumEncodedBytes = ((limit + 2) / 3) * 4
            guard encoded.utf8.count <= maximumEncodedBytes,
                  let decoded = Data(base64Encoded: encoded) else {
                throw ProviderProxyResponseError.invalidBase64Body
            }
            data = decoded
        } else if let body = payload.body {
            data = Data(body.utf8)
        } else {
            data = Data()
        }
        guard data.count <= limit else {
            throw ProviderProxyResponseError.bodyTooLarge(limit: limit)
        }

        let declaredContentType = payload.contentType?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let declaredContentType, containsLineBreak(declaredContentType) {
            throw ProviderProxyResponseError.invalidHeader("Content-Type")
        }
        let headerContentType = payload.headers.first {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentType = [declaredContentType, headerContentType]
            .compactMap { $0 }
            .first { !$0.isEmpty }
            ?? "application/octet-stream"

        var headers: [String: String] = [:]
        for (name, value) in payload.headers {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidHeaderName(trimmedName),
                  !containsLineBreak(value) else {
                throw ProviderProxyResponseError.invalidHeader(trimmedName.isEmpty ? "<empty>" : trimmedName)
            }
            switch trimmedName.lowercased() {
            case "content-length", "content-type", "transfer-encoding", "connection",
                 "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "upgrade":
                continue
            default:
                headers[trimmedName] = value
            }
        }

        return ProxyResponse(
            statusCode: payload.statusCode,
            contentType: contentType,
            data: data,
            headers: headers
        )
    }

    private static func containsLineBreak(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 0x0A || $0.value == 0x0D }
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122,
                 33, 35...39, 42, 43, 45, 46, 94...96, 124, 126:
                return true
            default:
                return false
            }
        }
    }
}
