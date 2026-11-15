#if DEBUG
import CryptoKit
import Foundation
import Models
import Networking
import ProxyServer
import ProviderSDK

/// A loopback route for one verified catalog endpoint; never accepts an upstream URL.
enum DevelopmentAndroidSourceTransport {
    static let markerKey = "__android_source_transport"
    static let tokenKey = "__android_source_token"
    static let queryKey = "__android_source_query"
    static let maximumQueryBytes = 16 * 1024
    private static let origin = "https://api.wsyzy.net/api.php/provide/vod/"
    // DNS and both concurrent curl requests share this deadline, below the Guard's 15-second read timeout.
    private static let requestBudget: Duration = .seconds(10)
    private static let token = SymmetricKey(size: .bits256).withUnsafeBytes {
        $0.map { String(format: "%02x", $0) }.joined()
    }

    struct Request: Sendable {
        let url: URL
        let headers: [String: String]
    }
    typealias Loader = @Sendable (Request) async throws -> HTTPResponse
    typealias IPv6Loader = @Sendable (Request, TimeInterval, CMSIPv6Recovery.Observation?) async throws -> HTTPResponse?
    typealias TimedLoader = @Sendable (Request, TimeInterval) async throws -> HTTPResponse
    typealias Recorder = @Sendable (String) -> Void

    static func runtimeBaseURL() -> String? {
        guard ProxyServer.shared.isRunning else { return nil }
        return baseURL(port: ProxyServer.shared.port, token: token)
    }

    static func baseURL(port: Int, token: String) -> String? {
        guard (1...65535).contains(port), validToken(token) else { return nil }
        return "http://127.0.0.1:\(port)/proxy?\(markerKey)=1&\(tokenKey)=\(token)"
    }

    static func responseIfHandled(
        parameters: [String: String], expectedToken: String = token,
        load: Loader = loadCatalog
    ) async throws -> ProxyResponse? {
        guard let request = try request(parameters: parameters, expectedToken: expectedToken) else { return nil }
        let response = try await load(request)
        try Task.checkCancellation()
        guard response.finalURL == request.url, (100...599).contains(response.statusCode),
              response.data.count <= 4 * 1024 * 1024 else { throw URLError(.badServerResponse) }
        let mime = response.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/json"
        guard safeHeader(mime), mime.utf8.count <= 256 else { throw URLError(.badServerResponse) }
        return ProxyResponse(statusCode: response.statusCode, contentType: mime, data: response.data,
                             headers: ["Cache-Control": "no-store"])
    }

    static func request(parameters: [String: String], expectedToken: String) throws -> Request? {
        guard parameters[markerKey] != nil else { return nil }
        guard parameters[markerKey] == "1", validToken(expectedToken),
              let received = parameters[tokenKey], sameToken(received, expectedToken),
              let encoded = parameters[queryKey], parameters["url"] == nil, parameters["u64"] == nil else {
            throw invalidRequest()
        }
        let query: String?
        if encoded == "n" { query = nil }
        else {
            guard encoded.first == "q" else { throw invalidRequest() }
            let payload = String(encoded.dropFirst())
            guard payload.utf8.count <= ((maximumQueryBytes + 2) / 3) * 4,
                  payload.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw invalidRequest() }
            let padded = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                + String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: padded), data.count <= maximumQueryBytes,
                  data.allSatisfy({ $0 >= 0x21 && $0 < 0x7f }),
                  encodeQuery(data) == payload, let text = String(data: data, encoding: .ascii) else { throw invalidRequest() }
            query = text
        }
        let rawURL = origin + (query.map { "?" + $0 } ?? "")
        guard let components = URLComponents(string: rawURL), components.scheme == "https",
              components.host == "api.wsyzy.net", components.port == nil,
              components.percentEncodedPath == "/api.php/provide/vod/", components.user == nil,
              components.password == nil, components.fragment == nil,
              components.percentEncodedQuery == query, let url = components.url,
              url.absoluteString == rawURL else { throw invalidRequest() }
        var headers: [String: String] = [:]
        for (name, canonical) in [("user-agent", "User-Agent"), ("referer", "Referer"),
                                  ("origin", "Origin"), ("accept", "Accept")] {
            if let value = parameters[name] {
                guard value.utf8.count <= 4096, safeHeader(value) else { throw invalidRequest() }
                headers[canonical] = value
            }
        }
        return Request(url: url, headers: headers)
    }

    private static func encodeQuery(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func validToken(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sameToken(_ lhs: String, _ rhs: String) -> Bool {
        guard validToken(lhs) else { return false }
        return zip(lhs.utf8, rhs.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func safeHeader(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
    }

    private static func invalidRequest() -> ProviderErrorPayload {
        ProviderErrorPayload(code: "invalid_android_source_transport", message: "Invalid Android development catalog transport request")
    }

    private static let verifiedHTTPClient: HTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // A supplied standard session retains platform TLS validation. Do not use
        // HTTPClient.shared or withExplicitProxy, which install another delegate.
        return HTTPClient(session: URLSession(configuration: configuration))
    }()

    private static func loadCatalog(_ request: Request) async throws -> HTTPResponse {
        try await loadCatalog(request, budget: requestBudget, ipv6: { request, timeout, observation in
            try await CMSIPv6Recovery.verifiedIPv6Response(
                for: request.url.absoluteString, headers: request.headers, httpClient: verifiedHTTPClient,
                timeout: timeout, allowsProxyFallback: false, observation: observation
            )
        }, http1: { request, timeout in
            try await SourceResourceTransport.response(for: request.url, headers: request.headers, timeout: timeout)
        })
    }

    /// One deadline covers DNS, both IPv6 addresses and any HTTP/1.1 fallback.
    /// The original Guard gives a loopback response only 15 seconds to arrive.
    static func loadCatalog(_ request: Request, budget: Duration, record: @escaping Recorder = recordProduction,
                            ipv6: @escaping IPv6Loader, http1: @escaping TimedLoader) async throws -> HTTPResponse {
        let trace = Trace(budget: budget, record: record)
        trace.note("request.begin")
        do {
            try Task.checkCancellation()
            let response = try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
                group.addTask {
                    guard trace.remaining > 0 else { throw URLError(.timedOut) }
                    trace.note("ipv6.begin")
                    if let response = try await ipv6(request, trace.remaining, { stage, status, error, curl in
                        trace.note(stage, status: status, error: error, curl: curl)
                    }) {
                        try Task.checkCancellation()
                        trace.note("ipv6.success", status: response.statusCode)
                        return response
                    }
                    try Task.checkCancellation()
                    trace.note("ipv6.unavailable")
                    guard trace.remaining > 0 else { throw URLError(.timedOut) }
                    trace.note("http1.begin")
                    do {
                        let response = try await http1(request, min(4, trace.remaining))
                        try Task.checkCancellation()
                        trace.note("http1.complete", status: response.statusCode)
                        return response
                    } catch {
                        trace.note("http1.error", error: (error as NSError).code)
                        throw error
                    }
                }
                group.addTask {
                    try await ContinuousClock().sleep(until: trace.start.advanced(by: budget))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let response = try await group.next() else { throw URLError(.badServerResponse) }
                return response
            }
            trace.note("request.complete", status: response.statusCode)
            return response
        } catch {
            let stage = error is CancellationError || (error as? URLError)?.code == .cancelled
                ? "request.cancelled" : (error as? URLError)?.code == .timedOut ? "request.timeout" : "request.failed"
            trace.note(stage, error: (error as NSError).code)
            throw error
        }
    }

    private static func recordProduction(_ message: String) {
        DiagnosticLog.write(message)
        print(message)
    }

    private struct Trace: Sendable {
        let id = UUID().uuidString.lowercased()
        let start = ContinuousClock.now
        let budget: Duration
        let record: Recorder

        var remaining: TimeInterval { max(0, seconds(budget - start.duration(to: .now))) }

        func note(_ stage: String, status: Int? = nil, error: Int? = nil, curl: Int? = nil) {
            var message = "[ANDROID_SOURCE_TRANSPORT] requestID=\(id) stage=\(stage) elapsedMs=\(Int(seconds(start.duration(to: .now)) * 1000))"
            if let status { message += " status=\(status)" }
            if let error { message += " errorCode=\(error)" }
            if let curl { message += " curlCode=\(curl)" }
            record(message)
        }

        private func seconds(_ value: Duration) -> TimeInterval {
            let components = value.components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
    }
}
#endif
