// Networking/HTTPClient.swift
// 基于 URLSession 的网络请求封装

import Foundation

/// HTTP 请求方法
public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case head = "HEAD"
    case options = "OPTIONS"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// HTTP 响应
public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]
    public let finalURL: URL?

    public init(data: Data, statusCode: Int, headers: [String: String] = [:], finalURL: URL? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.finalURL = finalURL
    }

    /// 获取文本内容
    public var text: String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

/// HTTP 流响应元数据。响应体由 `HTTPClient.stream` 分块交付。
public struct HTTPStreamResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let finalURL: URL?

    public init(statusCode: Int, headers: [String: String] = [:], finalURL: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.finalURL = finalURL
    }
}

final class UnsafeURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// HTTP 客户端
public final class HTTPClient: @unchecked Sendable {

    public static let shared = HTTPClient()

    private let session: URLSession
    private let allowedOrigin: URL?
    private let sessionLock = NSLock()
    private var cachedSessions: [Int: URLSession] = [:]

    private struct StreamAttemptFailure: Error {
        let underlying: Error
        let responseAccepted: Bool
    }

    public init(session: URLSession? = nil, allowedOrigin: URL? = nil) {
        self.allowedOrigin = allowedOrigin
        if let session = session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            
            let delegate = UnsafeURLSessionDelegate()
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    /// Returns a client sharing this session while rejecting cross-origin redirects.
    public func constrained(to origin: URL) -> HTTPClient {
        HTTPClient(session: session, allowedOrigin: origin)
    }

    @discardableResult
    public func setCookie(name: String, value: String, for url: String) -> Bool {
        guard let url = URL(string: url), let host = url.host,
              let storage = session.configuration.httpCookieStorage else { return false }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: host,
            .path: "/",
            .originURL: url
        ]
        if url.scheme?.lowercased() == "https" {
            properties[.secure] = "TRUE"
        }
        guard let cookie = HTTPCookie(properties: properties) else { return false }
        storage.setCookie(cookie)
        return true
    }

    public func cookieValue(name: String, for url: String) -> String? {
        guard let url = URL(string: url),
              let storage = session.configuration.httpCookieStorage else { return nil }
        return storage.cookies(for: url)?.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    public func cookieHeader(for url: String) -> String? {
        guard let url = URL(string: url),
              let storage = session.configuration.httpCookieStorage,
              let cookies = storage.cookies(for: url),
              !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    public func removeCookie(name: String, for url: String) {
        guard let url = URL(string: url),
              let storage = session.configuration.httpCookieStorage else { return }
        for cookie in storage.cookies(for: url) ?? [] where cookie.name.caseInsensitiveCompare(name) == .orderedSame {
            storage.deleteCookie(cookie)
        }
    }

    /// 清除所有已缓存的代理 Session 实例
    public func clearProxySessions() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        cachedSessions.removeAll()
        print("[HTTPClient] 已清理所有缓存的代理 Session")
    }

    private func getSession(forPort port: Int?) -> URLSession {
        guard let port = port else {
            return self.session
        }
        
        sessionLock.lock()
        defer { sessionLock.unlock() }
        
        if let cached = cachedSessions[port] {
            return cached
        }
        
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": port,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": port
        ]
        
        let delegate = UnsafeURLSessionDelegate()
        let newSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        cachedSessions[port] = newSession
        return newSession
    }

    /// 判定一个错误是否属于需要由代理进行重试的网络或 TLS/SSL 阻断错误
    private func isNetworkFailureWarrantingProxy(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return true
            default:
                return false
            }
        }
        
        let desc = error.localizedDescription.lowercased()
        if desc.contains("ssl") || desc.contains("tls") || desc.contains("connection reset") || desc.contains("timeout") || desc.contains("handshake") {
            return true
        }
        return false
    }

    /// 发起 GET 请求
    public func get(
        url: String,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15,
        allowsProxyFallback: Bool = true,
        redactsURLInLogs: Bool = false
    ) async throws -> HTTPResponse {
        return try await request(
            url: url,
            method: .get,
            headers: headers,
            timeout: timeout,
            allowsProxyFallback: allowsProxyFallback,
            redactsURLInLogs: redactsURLInLogs
        )
    }

    /// 发起 POST 请求
    public func post(
        url: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 15,
        handlesCookies: Bool = true
    ) async throws -> HTTPResponse {
        return try await request(
            url: url,
            method: .post,
            headers: headers,
            body: body,
            timeout: timeout,
            handlesCookies: handlesCookies
        )
    }

    /// 下载二进制数据
    public func download(url: String, headers: [String: String] = [:]) async throws -> Data {
        let response = try await get(url: url, headers: headers)
        return response.data
    }

    /// 将响应体直接下载到文件，避免大型媒体先完整驻留内存。
    @discardableResult
    public func downloadFile(
        url: String,
        headers: [String: String] = [:],
        to destinationURL: URL,
        timeout: TimeInterval = 300,
        allowsProxyFallback: Bool = true,
        redactsURLInLogs: Bool = false
    ) async throws -> HTTPStreamResponse {
        guard let requestURL = URL(string: url), !requestURL.isFileURL else {
            throw HTTPError.invalidURL(url)
        }

        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = HTTPMethod.get.rawValue
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let parentDirectory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        do {
            return try await downloadFileAttempt(
                session: session,
                request: request,
                destinationURL: destinationURL
            )
        } catch {
            let loggedURL = redactsURLInLogs ? Self.redactedURLForLog(url) : url
            let loggedError = redactsURLInLogs
                ? Self.redactedErrorForLog(error)
                : "\(error.localizedDescription) (\(error))"
            guard allowsProxyFallback, isNetworkFailureWarrantingProxy(error) else {
                throw error
            }

            print("[HTTPClient] 直连文件下载失败：\(loggedURL)，错误：\(loggedError)。准备检测本地代理并重试。")
            guard let activePort = await ProxyDetector.shared.detectActiveProxy() else {
                print("[HTTPClient] 未检测到可用的本地代理端口，无法重试文件下载。")
                throw error
            }

            let proxySession = getSession(forPort: activePort)
            do {
                let response = try await downloadFileAttempt(
                    session: proxySession,
                    request: request,
                    destinationURL: destinationURL
                )
                print("[HTTPClient] 代理文件下载已收到响应：HTTP \(response.statusCode)，原始 URL：\(loggedURL)")
                return response
            } catch {
                let proxyLoggedError = redactsURLInLogs
                    ? Self.redactedErrorForLog(error)
                    : "\(error.localizedDescription) (\(error))"
                ProxyDetector.shared.clearCache()
                print("[HTTPClient] 代理文件下载失败：\(proxyLoggedError)")
                throw error
            }
        }
    }

    /// 通用请求方法（支持代理自动回落）
    public func request(
        url: String,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 15,
        allowsProxyFallback: Bool = true,
        redactsURLInLogs: Bool = false,
        handlesCookies: Bool = true
    ) async throws -> HTTPResponse {
        guard let requestURL = URL(string: url) else {
            throw HTTPError.invalidURL(url)
        }

        if requestURL.isFileURL {
            let data = try Data(contentsOf: requestURL)
            return HTTPResponse(data: data, statusCode: 200, finalURL: requestURL)
        }

        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method.rawValue
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = handlesCookies

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body = body {
            request.httpBody = body
        }

        // 1. 尝试使用默认 Session 进行直连访问
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HTTPError.invalidResponse
            }
            try validateFinalURL(httpResponse.url)

            var responseHeaders: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                if let keyString = key as? String, let valueString = value as? String {
                    responseHeaders[keyString] = valueString
                }
            }

            return HTTPResponse(
                data: data,
                statusCode: httpResponse.statusCode,
                headers: responseHeaders,
                finalURL: httpResponse.url
            )
        } catch {
            let loggedURL = redactsURLInLogs ? Self.redactedURLForLog(url) : url
            let loggedError = redactsURLInLogs ? Self.redactedErrorForLog(error) : "\(error.localizedDescription) (\(error))"
            if allowsProxyFallback {
                print("[HTTPClient] 直连请求失败：\(loggedURL)，错误：\(loggedError)。准备检测本地代理并重试。")
            } else {
                print("[HTTPClient] 直连请求失败：\(loggedURL)，错误：\(loggedError)。本次请求未启用代理重试。")
            }
            
            // 2. 判断该错误是否为网络阻断，若是则通过代理重试
            guard allowsProxyFallback, isNetworkFailureWarrantingProxy(error) else {
                throw error
            }
            
            // 获取当前可用的本地代理端口
            guard let activePort = await ProxyDetector.shared.detectActiveProxy() else {
                print("[HTTPClient] 未检测到可用的本地代理端口，无法重试该请求。")
                throw error
            }
            
            print("[HTTPClient] 检测到本地代理端口 \(activePort)，正在重试请求...")
            let proxySession = getSession(forPort: activePort)
            
            do {
                let (data, response) = try await proxySession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw HTTPError.invalidResponse
                }
                try validateFinalURL(httpResponse.url)

                var responseHeaders: [String: String] = [:]
                for (key, value) in httpResponse.allHeaderFields {
                    if let keyString = key as? String, let valueString = value as? String {
                        responseHeaders[keyString] = valueString
                    }
                }

                print("[HTTPClient] 代理请求已收到响应：HTTP \(httpResponse.statusCode)，原始 URL：\(loggedURL)")
                return HTTPResponse(
                    data: data,
                    statusCode: httpResponse.statusCode,
                    headers: responseHeaders,
                    finalURL: httpResponse.url
                )
            } catch {
                let loggedError = redactsURLInLogs ? Self.redactedErrorForLog(error) : "\(error.localizedDescription) (\(error))"
                ProxyDetector.shared.clearCache()
                print("[HTTPClient] 代理请求失败：\(loggedError)")
                throw error
            }
        }
    }

    /// 分块读取响应体。只有 `shouldStream` 接受响应后才会交付 body，便于调用方先处理重试状态码。
    public func stream(
        url: String,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15,
        allowsProxyFallback: Bool = true,
        redactsURLInLogs: Bool = false,
        chunkSize: Int = 64 * 1024,
        shouldStream: @escaping @Sendable (HTTPStreamResponse) async throws -> Bool,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPStreamResponse {
        guard let requestURL = URL(string: url) else {
            throw HTTPError.invalidURL(url)
        }
        guard !requestURL.isFileURL else {
            throw HTTPError.invalidURL(url)
        }

        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = HTTPMethod.get.rawValue
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let normalizedChunkSize = max(1, chunkSize)
        do {
            return try await streamAttempt(
                session: session,
                request: request,
                chunkSize: normalizedChunkSize,
                shouldStream: shouldStream,
                receive: receive
            )
        } catch let failure as StreamAttemptFailure {
            let error = failure.underlying
            let loggedURL = redactsURLInLogs ? Self.redactedURLForLog(url) : url
            let loggedError = redactsURLInLogs
                ? Self.redactedErrorForLog(error)
                : "\(error.localizedDescription) (\(error))"
            guard !failure.responseAccepted,
                  allowsProxyFallback,
                  isNetworkFailureWarrantingProxy(error) else {
                throw error
            }

            print("[HTTPClient] 直连流请求失败：\(loggedURL)，错误：\(loggedError)。准备检测本地代理并重试。")
            guard let activePort = await ProxyDetector.shared.detectActiveProxy() else {
                print("[HTTPClient] 未检测到可用的本地代理端口，无法重试流请求。")
                throw error
            }

            let proxySession = getSession(forPort: activePort)
            do {
                let response = try await streamAttempt(
                    session: proxySession,
                    request: request,
                    chunkSize: normalizedChunkSize,
                    shouldStream: shouldStream,
                    receive: receive
                )
                print("[HTTPClient] 代理流请求已收到响应：HTTP \(response.statusCode)，原始 URL：\(loggedURL)")
                return response
            } catch let proxyFailure as StreamAttemptFailure {
                let proxyError = proxyFailure.underlying
                let proxyLoggedError = redactsURLInLogs
                    ? Self.redactedErrorForLog(proxyError)
                    : "\(proxyError.localizedDescription) (\(proxyError))"
                ProxyDetector.shared.clearCache()
                print("[HTTPClient] 代理流请求失败：\(proxyLoggedError)")
                throw proxyError
            }
        }
    }

    private func streamAttempt(
        session: URLSession,
        request: URLRequest,
        chunkSize: Int,
        shouldStream: @escaping @Sendable (HTTPStreamResponse) async throws -> Bool,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPStreamResponse {
        var responseAccepted = false
        var chunk = Data()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HTTPError.invalidResponse
            }

            var responseHeaders: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                if let keyString = key as? String, let valueString = value as? String {
                    responseHeaders[keyString] = valueString
                }
            }
            let metadata = HTTPStreamResponse(
                statusCode: httpResponse.statusCode,
                headers: responseHeaders,
                finalURL: httpResponse.url
            )
            responseAccepted = try await shouldStream(metadata)
            guard responseAccepted else { return metadata }

            chunk.reserveCapacity(chunkSize)
            for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                if chunk.count >= chunkSize {
                    let delivery = chunk
                    chunk.removeAll(keepingCapacity: true)
                    try await receive(delivery)
                }
            }
            if !chunk.isEmpty {
                let delivery = chunk
                chunk.removeAll(keepingCapacity: true)
                try await receive(delivery)
            }
            return metadata
        } catch {
            if responseAccepted, !chunk.isEmpty, !Task.isCancelled {
                let delivery = chunk
                chunk.removeAll(keepingCapacity: true)
                do {
                    try await receive(delivery)
                } catch {
                    throw StreamAttemptFailure(underlying: error, responseAccepted: true)
                }
            }
            throw StreamAttemptFailure(underlying: error, responseAccepted: responseAccepted)
        }
    }

    private func downloadFileAttempt(
        session: URLSession,
        request: URLRequest,
        destinationURL: URL
    ) async throws -> HTTPStreamResponse {
        let (temporaryURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HTTPError.httpError(
                httpResponse.statusCode,
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        var responseHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let keyString = key as? String, let valueString = value as? String {
                responseHeaders[keyString] = valueString
            }
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return HTTPStreamResponse(
            statusCode: httpResponse.statusCode,
            headers: responseHeaders,
            finalURL: httpResponse.url
        )
    }

    static func redactedURLForLog(_ rawValue: String) -> String {
        guard var components = URLComponents(string: rawValue) else { return "redacted-url" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        let lastComponent = components.path.split(separator: "/").last.map(String.init) ?? ""
        components.path = lastComponent.isEmpty ? "" : "/.../\(lastComponent)"
        return components.string ?? "redacted-url"
    }

    private static func redactedErrorForLog(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.localizedDescription) [\(value.domain):\(value.code)]"
    }

    private func validateFinalURL(_ finalURL: URL?) throws {
        guard let allowedOrigin else { return }
        guard let finalURL,
              Self.sameOrigin(finalURL, allowedOrigin) else {
            throw HTTPError.originMismatch
        }
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased() else {
            return false
        }
        return effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

/// HTTP 错误
public enum HTTPError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case invalidResponse
    case originMismatch
    case httpError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "无效的 URL: \(url)"
        case .invalidResponse: return "无效的 HTTP 响应"
        case .originMismatch: return "响应重定向到未授权的来源"
        case .httpError(let code, let msg): return "HTTP 错误 \(code): \(msg)"
        }
    }
}
