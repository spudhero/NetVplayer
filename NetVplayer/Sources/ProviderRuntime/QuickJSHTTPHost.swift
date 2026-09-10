import Foundation
import ProviderSDK

struct QuickJSHostControl: Codable, Sendable {
    var type: String
    var requestID: String
    var capability: String?
    var operation: String?
    var url: String?
    var options: [String: ProviderJSONValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case requestID = "request_id"
        case capability
        case operation
        case url
        case options
    }
}

struct QuickJSHostResponse: Codable, Sendable {
    var type: String
    var requestID: String
    var ok: Bool
    var result: ProviderJSONValue?
    var error: ProviderErrorPayload?

    init(
        requestID: String,
        ok: Bool,
        result: ProviderJSONValue? = nil,
        error: ProviderErrorPayload? = nil
    ) {
        self.type = "host_response"
        self.requestID = requestID
        self.ok = ok
        self.result = result
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case type
        case requestID = "request_id"
        case ok
        case result
        case error
    }
}

struct QuickJSHTTPHost: @unchecked Sendable {
    static let defaultMaximumResponseBytes = 32 * 1024 * 1024

    private let session: URLSession
    private let maximumResponseBytes: Int

    init(
        session: URLSession? = nil,
        maximumResponseBytes: Int = QuickJSHTTPHost.defaultMaximumResponseBytes
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration)
        }
        self.maximumResponseBytes = max(1, maximumResponseBytes)
    }

    func handle(_ request: QuickJSHostControl) async -> QuickJSHostResponse {
        guard request.capability == "http", request.operation == "request" else {
            return failure(requestID: request.requestID, code: "unsupported_host_request", message: "Unsupported QuickJS host request")
        }
        do {
            let result = try await perform(request)
            return QuickJSHostResponse(requestID: request.requestID, ok: true, result: result)
        } catch let error as QuickJSHTTPHostError {
            return failure(requestID: request.requestID, code: error.code, message: error.message)
        } catch is CancellationError {
            return failure(requestID: request.requestID, code: "canceled", message: "HTTP request canceled")
        } catch {
            return failure(requestID: request.requestID, code: "request_failed", message: "HTTP request failed")
        }
    }

    private func perform(_ request: QuickJSHostControl) async throws -> ProviderJSONValue {
        guard let rawURL = request.url,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw QuickJSHTTPHostError(code: "invalid_url", message: "HTTP URL is invalid")
        }

        let options = request.options ?? [:]
        let method = httpMethod(options["method"])
        var headers = try stringMap(options["headers"], name: "headers")
        let body = try requestBody(options, headers: &headers)
        var urlRequest = URLRequest(url: url)
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpMethod = method.rawValue
        urlRequest.httpShouldHandleCookies = false
        let timeoutMilliseconds = number(options["timeout"]) ?? 10_000
        guard timeoutMilliseconds >= 0 else {
            throw QuickJSHTTPHostError(code: "invalid_timeout", message: "HTTP timeout is invalid")
        }
        // OkHttp treats a zero timeout as disabled; URLRequest uses the same sentinel.
        urlRequest.timeoutInterval = timeoutMilliseconds == 0 ? 0 : timeoutMilliseconds / 1_000
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = method == .post ? (body ?? Data()) : nil

        let followsRedirects = number(options["redirect"]).map { $0 == 1 } ?? true
        let redirectDelegate = QuickJSHTTPRedirectDelegate(followsRedirects: followsRedirects)
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: redirectDelegate)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw QuickJSHTTPHostError(code: "invalid_response", message: "HTTP response is invalid")
            }
            var data = Data()
            data.reserveCapacity(min(maximumResponseBytes, 64 * 1024))
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw QuickJSHTTPHostError(
                        code: "response_too_large",
                        message: "HTTP response exceeds the configured byte limit"
                    )
                }
                try Task.checkCancellation()
                data.append(byte)
            }
            return try responseValue(
                data: data,
                response: httpResponse,
                fallbackURL: rawURL,
                requestHeaders: headers
            )
        } catch {
            guard !Task.isCancelled,
                  !followsRedirects,
                  let rejectedResponse = redirectDelegate.rejectedResponse else {
                throw error
            }
            return try responseValue(
                data: Data(),
                response: rejectedResponse,
                fallbackURL: rawURL,
                requestHeaders: headers
            )
        }
    }

    private func responseValue(
        data: Data,
        response: HTTPURLResponse,
        fallbackURL: String,
        requestHeaders: [String: String]
    ) throws -> ProviderJSONValue {
        let responseHeaders = quickJSResponseHeaders(response.allHeaderFields)
        return .object([
            "code": .number(Double(response.statusCode)),
            "status": .number(Double(response.statusCode)),
            "headers": .object(responseHeaders),
            "content": .string(try decodeContent(data, requestHeaders: requestHeaders)),
            "content_base64": .string(data.base64EncodedString()),
            "url": .string(response.url?.absoluteString ?? fallbackURL),
        ])
    }

    private func httpMethod(_ value: ProviderJSONValue?) -> QuickJSHTTPMethod {
        let rawValue = string(value) ?? QuickJSHTTPMethod.get.rawValue
        if rawValue.caseInsensitiveCompare("post") == .orderedSame {
            return .post
        }
        if rawValue.caseInsensitiveCompare("header") == .orderedSame {
            return .head
        }
        // Android Connect.getRequest falls through to GET for every other method.
        return .get
    }

    private func stringMap(
        _ value: ProviderJSONValue?,
        name: String
    ) throws -> [String: String] {
        guard let value else { return [:] }
        guard case .object(let values) = value else {
            throw QuickJSHTTPHostError(code: "invalid_\(name)", message: "HTTP \(name) must be an object")
        }
        return values.reduce(into: [:]) { result, item in
            result[item.key] = androidString(item.value)
        }
    }

    private func objectValues(_ value: ProviderJSONValue) -> [String: ProviderJSONValue] {
        guard case .object(let values) = value else { return [:] }
        return values
    }

    private func requestBody(
        _ options: [String: ProviderJSONValue],
        headers: inout [String: String]
    ) throws -> Data? {
        if let encoded = string(options["body_base64"]) {
            guard let data = Data(base64Encoded: encoded) else {
                throw QuickJSHTTPHostError(code: "invalid_body", message: "HTTP body base64 is invalid")
            }
            return data
        }
        if let data = options["data"] {
            let postType = string(options["postType"]) ?? "json"
            switch postType {
            case "json":
                if headers.keys.first(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) == nil {
                    headers["Content-Type"] = "application/json; charset=utf-8"
                }
                return try JSONEncoder.providerCanonical.encode(data)
            case "form":
                if headers.keys.first(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) == nil {
                    headers["Content-Type"] = "application/x-www-form-urlencoded"
                }
                let values = objectValues(data)
                var components = URLComponents()
                components.queryItems = values.keys.sorted().map { key in
                    URLQueryItem(name: key, value: androidString(values[key]))
                }
                return Data((components.percentEncodedQuery ?? "").utf8)
            case "form-data":
                let boundary = "dio-boundary-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
                if headers.keys.first(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) == nil {
                    headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
                }
                return multipartFormData(values: objectValues(data), boundary: boundary)
            default:
                break
            }
        }
        if let body = string(options["body"]) {
            let hasContentType = headers.keys.contains { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }
            guard hasContentType else { return Data() }
            let charset = requestCharset(in: headers) ?? "utf-8"
            guard let encoding = ianaEncoding(named: charset) else {
                throw QuickJSHTTPHostError(code: "unsupported_charset", message: "HTTP request charset is unsupported")
            }
            return body.data(using: encoding) ?? Data(body.utf8)
        }
        return nil
    }

    private func multipartFormData(
        values: [String: ProviderJSONValue],
        boundary: String
    ) -> Data {
        var body = Data()
        for key in values.keys.sorted() {
            let value = androidString(values[key])
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private func number(_ value: ProviderJSONValue?) -> Double? {
        guard case .number(let value) = value else { return nil }
        return value.isFinite ? value : nil
    }

    private func decodeContent(_ data: Data, requestHeaders: [String: String]) throws -> String {
        let charset = requestCharset(in: requestHeaders) ?? "utf-8"

        switch charset {
        case "iso-8859-1", "latin1", "latin-1":
            return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        case "ascii", "us-ascii":
            return String(data: data, encoding: .ascii) ?? String(decoding: data, as: UTF8.self)
        case "utf-16", "utf-16le":
            return String(data: data, encoding: .utf16LittleEndian) ?? String(decoding: data, as: UTF8.self)
        case "utf-16be":
            return String(data: data, encoding: .utf16BigEndian) ?? String(decoding: data, as: UTF8.self)
        default:
            guard let encoding = ianaEncoding(named: charset) else {
                throw QuickJSHTTPHostError(code: "unsupported_charset", message: "HTTP response charset is unsupported")
            }
            return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
        }
    }

    private func ianaEncoding(named name: String?) -> String.Encoding? {
        guard let name, !name.isEmpty else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private func requestCharset(in headers: [String: String]) -> String? {
        guard let contentType = headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let parts = parameter.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0].caseInsensitiveCompare("charset") == .orderedSame else { continue }
            return parts[1]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
        }
        return nil
    }

    private func string(_ value: ProviderJSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    // Android Json.safeString stringifies primitive values and applies Java String.trim().
    private func androidString(_ value: ProviderJSONValue?) -> String {
        let raw: String
        switch value {
        case .bool(let value): raw = value ? "true" : "false"
        case .number(let value): raw = NSNumber(value: value).stringValue
        case .string(let value): raw = value
        default: return ""
        }
        let scalars = Array(raw.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, scalars[start].value <= 0x20 { start += 1 }
        while end > start, scalars[end - 1].value <= 0x20 { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    private func failure(requestID: String, code: String, message: String) -> QuickJSHostResponse {
        QuickJSHostResponse(
            requestID: requestID,
            ok: false,
            error: ProviderErrorPayload(code: code, message: message)
        )
    }
}

func quickJSResponseHeaders(_ fields: [AnyHashable: Any]) -> [String: ProviderJSONValue] {
    var values: [String: [String]] = [:]
    for (rawKey, rawValue) in fields {
        guard let key = rawKey as? String else { continue }
        let entries: [String]
        if let value = rawValue as? String {
            entries = key.caseInsensitiveCompare("Set-Cookie") == .orderedSame
                ? splitMergedSetCookie(value)
                : [value]
        } else if let value = rawValue as? [String] {
            entries = value
        } else {
            continue
        }
        values[key, default: []].append(contentsOf: entries)
    }
    return values.mapValues { entries in
        entries.count == 1
            ? .string(entries[0])
            : .array(entries.map { .string($0) })
    }
}

private func splitMergedSetCookie(_ value: String) -> [String] {
    var values: [String] = []
    var start = value.startIndex
    var index = value.startIndex
    while index < value.endIndex {
        guard value[index] == "," else {
            index = value.index(after: index)
            continue
        }
        let next = value.index(after: index)
        let remainder = value[next...].drop(while: { $0 == " " || $0 == "\t" })
        let cookiePair = remainder.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first
        guard cookiePair?.contains("=") == true else {
            index = next
            continue
        }
        values.append(String(value[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
        start = next
        index = next
    }
    let last = String(value[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    if !last.isEmpty { values.append(last) }
    return values.isEmpty ? [value] : values
}

private enum QuickJSHTTPMethod: String {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
}

private struct QuickJSHTTPHostError: Error {
    let code: String
    let message: String
}

final class QuickJSHTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let followsRedirects: Bool
    private let lock = NSLock()
    private var rejectedResponseStorage: HTTPURLResponse?

    var rejectedResponse: HTTPURLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return rejectedResponseStorage
    }

    init(followsRedirects: Bool) {
        self.followsRedirects = followsRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if followsRedirects {
            completionHandler(request)
        } else {
            lock.lock()
            rejectedResponseStorage = response
            lock.unlock()
            completionHandler(nil)
        }
    }
}
