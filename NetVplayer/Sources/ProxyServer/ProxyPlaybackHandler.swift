// ProxyServer/ProxyPlaybackHandler.swift
// Shared playback proxy handler used by app runtime and tests.

import CryptoKit
import Foundation
import Models
import Networking

private actor QuarkHLSNormalizationState {
    private var depthByContext: [String: Int] = [:]

    func depth(for context: String) -> Int? {
        depthByContext[context]
    }

    func remember(depth: Int, for context: String) {
        if depthByContext[context] == nil, depthByContext.count >= 32 {
            depthByContext.removeAll(keepingCapacity: true)
        }
        depthByContext[context] = depth
    }

    func forget(context: String) {
        depthByContext[context] = nil
    }
}

public struct ProxyPlaybackHandlers {
    public let buffered: ProxyHandler
    public let streaming: ProxyStreamingHandler

    public init(buffered: @escaping ProxyHandler, streaming: @escaping ProxyStreamingHandler) {
        self.buffered = buffered
        self.streaming = streaming
    }
}

public enum ProxyPlaybackHandler {
    public static func make(httpClient: HTTPClient = .shared) -> ProxyHandler {
        let normalizationState = QuarkHLSNormalizationState()
        return makeBuffered(httpClient: httpClient, normalizationState: normalizationState)
    }

    public static func makeHandlers(
        httpClient: HTTPClient = .shared,
        streamChunkSize: Int = 64 * 1024
    ) -> ProxyPlaybackHandlers {
        let normalizationState = QuarkHLSNormalizationState()
        return ProxyPlaybackHandlers(
            buffered: makeBuffered(httpClient: httpClient, normalizationState: normalizationState),
            streaming: makeStreaming(
                httpClient: httpClient,
                normalizationState: normalizationState,
                streamChunkSize: streamChunkSize
            )
        )
    }

    private static func makeBuffered(
        httpClient: HTTPClient,
        normalizationState: QuarkHLSNormalizationState
    ) -> ProxyHandler {
        return { params in
            guard let urlStr = targetURL(from: params), !urlStr.isEmpty else { return nil }
            let requestURLString = hmysSignedURL(urlStr, encodedSecret: params["hs64"])
            let targetURL = try ProxyAccessPolicy.validateTargetURL(requestURLString)
            let headerString = headerJSON(from: params)
            let reqHeaders = decodeHeaders(from: params)
            let response = try await fetchResponse(
                targetURL: targetURL,
                params: params,
                headers: reqHeaders,
                httpClient: httpClient,
                normalizationState: normalizationState
            )

            var contentType = response.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? "application/octet-stream"
            var responseHeaders = cleanedResponseHeaders(response.headers)

            guard (200..<300).contains(response.statusCode) else {
                let bodyPrefix = String(data: response.data.prefix(256), encoding: .utf8) ?? ""
                DiagnosticLog.write("[PROXY_UPSTREAM_ERROR] \(upstreamLogLabel(targetURL)) status=\(response.statusCode) contentType=\(contentType) bodyPrefix=\(bodyPrefix)")
                return ProxyResponse(
                    statusCode: response.statusCode,
                    contentType: contentType,
                    data: response.data,
                    headers: responseHeaders
                )
            }

            var responseData = response.data
            if params["hls"] == "1",
               let unwrapped = unwrapPNGPrefixedMPEGTS(response.data) {
                responseData = unwrapped
                contentType = "video/mp2t"
                responseHeaders.removeValue(forKey: "Content-Range")
                responseHeaders.removeValue(forKey: "content-range")
                DiagnosticLog.write("[PROXY_HLS_MEDIA_UNWRAP] \(upstreamLogLabel(targetURL)) strippedBytes=\(response.data.count - responseData.count) mediaBytes=\(responseData.count)")
            }
            if shouldRewriteM3U8(url: urlStr, contentType: contentType),
               let rewritten = rewriteM3U8(
                   data: responseData,
                   baseURL: urlStr,
                   header: headerString,
                   hmysSignSecret: params["hs64"]
               ) {
                responseData = rewritten
                contentType = "application/vnd.apple.mpegurl"
                responseHeaders.removeValue(forKey: "Content-Range")
                responseHeaders.removeValue(forKey: "content-range")
                DiagnosticLog.write("[PROXY_M3U8_REWRITE] \(upstreamLogLabel(targetURL)) originalBytes=\(response.data.count) rewrittenBytes=\(responseData.count)")
            }

            return ProxyResponse(
                statusCode: response.statusCode,
                contentType: contentType,
                data: responseData,
                headers: responseHeaders,
                closeConnection: params["hls"] == "1"
            )
        }
    }

    private static func makeStreaming(
        httpClient: HTTPClient,
        normalizationState: QuarkHLSNormalizationState,
        streamChunkSize: Int
    ) -> ProxyStreamingHandler {
        return { params, sendHead, sendBody in
            guard let urlString = targetURL(from: params),
                  !urlString.isEmpty else {
                return false
            }
            let targetURL = try ProxyAccessPolicy.validateTargetURL(urlString)
            var headers = decodeHeaders(from: params)
            if let range = params["__downstream_range"], !range.isEmpty {
                headers["Range"] = range
            }
            if params["stream"] == "1" {
                headers["Accept-Encoding"] = "identity"
                _ = try await streamUpstream(
                    targetURL,
                    headers: headers,
                    httpClient: httpClient,
                    timeout: 60,
                    rejectsHTTP400ForRetry: false,
                    streamChunkSize: streamChunkSize,
                    sendHead: sendHead,
                    sendBody: sendBody
                )
                return true
            }
            guard params["hls"] == "1" else { return false }
            guard isQuarkSignedHLSChildURL(targetURL) else { return false }

            return try await streamQuarkSignedHLSChild(
                targetURL: targetURL,
                params: params,
                headers: headers,
                httpClient: httpClient,
                normalizationState: normalizationState,
                streamChunkSize: streamChunkSize,
                sendHead: sendHead,
                sendBody: sendBody
            )
        }
    }

    private static func streamQuarkSignedHLSChild(
        targetURL: URL,
        params: [String: String],
        headers: [String: String],
        httpClient: HTTPClient,
        normalizationState: QuarkHLSNormalizationState,
        streamChunkSize: Int,
        sendHead: @escaping @Sendable (ProxyStreamingResponseHead) async throws -> Void,
        sendBody: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> Bool {
        let context = params["qctx"]
        var attemptedURLs = Set<String>()
        var receivedResponse = false
        var lastError: Error?

        if let context,
           let learnedDepth = await normalizationState.depth(for: context),
           let learnedURL = normalizedQuarkSignedHLSChildURL(targetURL, layers: learnedDepth) {
            attemptedURLs.insert(learnedURL.absoluteString)
            do {
                let response = try await streamUpstream(
                    learnedURL,
                    headers: headers,
                    httpClient: httpClient,
                    timeout: 10,
                    streamChunkSize: streamChunkSize,
                    sendHead: sendHead,
                    sendBody: sendBody
                )
                receivedResponse = true
                DiagnosticLog.write(
                    "[PROXY_QUARK_SIGNED_CHILD_STREAM_REUSE] \(upstreamLogLabel(learnedURL)) layer=\(learnedDepth) status=\(response.statusCode)"
                )
                if response.statusCode != 400 {
                    return true
                }
            } catch {
                guard shouldRetryNormalization(after: error) else { throw error }
                lastError = error
                DiagnosticLog.write(
                    "[PROXY_QUARK_SIGNED_CHILD_STREAM_REUSE_FAILED] \(upstreamLogLabel(learnedURL)) layer=\(learnedDepth) error=\(error.localizedDescription)"
                )
            }
            await normalizationState.forget(context: context)
        }

        for normalizationLayer in 0...3 {
            let candidateURL: URL
            if normalizationLayer == 0 {
                candidateURL = targetURL
            } else if let normalizedURL = normalizedQuarkSignedHLSChildURL(
                targetURL,
                layers: normalizationLayer
            ) {
                candidateURL = normalizedURL
            } else {
                break
            }

            guard attemptedURLs.insert(candidateURL.absoluteString).inserted else { continue }
            do {
                let response = try await streamUpstream(
                    candidateURL,
                    headers: headers,
                    httpClient: httpClient,
                    timeout: 10,
                    allowsProxyFallback: normalizationLayer > 0,
                    streamChunkSize: streamChunkSize,
                    sendHead: sendHead,
                    sendBody: sendBody
                )
                receivedResponse = true
                if normalizationLayer > 0 {
                    DiagnosticLog.write(
                        "[PROXY_QUARK_SIGNED_CHILD_STREAM_RETRY] \(upstreamLogLabel(candidateURL)) layer=\(normalizationLayer) status=\(response.statusCode)"
                    )
                }
                if (200..<300).contains(response.statusCode),
                   let context,
                   normalizationLayer > 0 {
                    await normalizationState.remember(depth: normalizationLayer, for: context)
                }
                if response.statusCode != 400 {
                    return true
                }
            } catch {
                guard normalizationLayer == 0, shouldRetryNormalization(after: error) else {
                    throw error
                }
                lastError = error
                DiagnosticLog.write(
                    "[PROXY_QUARK_SIGNED_CHILD_STREAM_RAW_TIMEOUT] \(upstreamLogLabel(candidateURL)) error=\(error.localizedDescription)"
                )
            }
        }

        if receivedResponse { return false }
        throw lastError ?? HTTPError.invalidResponse
    }

    private static func streamUpstream(
        _ url: URL,
        headers: [String: String],
        httpClient: HTTPClient,
        timeout: TimeInterval,
        allowsProxyFallback: Bool = true,
        rejectsHTTP400ForRetry: Bool = true,
        streamChunkSize: Int,
        sendHead: @escaping @Sendable (ProxyStreamingResponseHead) async throws -> Void,
        sendBody: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPStreamResponse {
        let validatedURL = try ProxyAccessPolicy.validateTargetURL(url.absoluteString)
        return try await httpClient.stream(
            url: validatedURL.absoluteString,
            headers: headers,
            timeout: timeout,
            allowsProxyFallback: allowsProxyFallback,
            redactsURLInLogs: true,
            chunkSize: streamChunkSize,
            shouldStream: { response in
                try ProxyAccessPolicy.validateFinalURL(response.finalURL)
                guard !rejectsHTTP400ForRetry || response.statusCode != 400 else { return false }

                let contentType = response.headers.first {
                    $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
                }?.value ?? "application/octet-stream"
                let contentLength = response.headers.first {
                    $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame
                }.flatMap { Int($0.value) }
                if !(200..<300).contains(response.statusCode) {
                    DiagnosticLog.write(
                        "[PROXY_UPSTREAM_STREAM_ERROR] \(upstreamLogLabel(validatedURL)) status=\(response.statusCode) contentType=\(contentType)"
                    )
                }
                try await sendHead(
                    ProxyStreamingResponseHead(
                        statusCode: response.statusCode,
                        contentType: contentType,
                        contentLength: contentLength,
                        headers: cleanedResponseHeaders(response.headers),
                        closeConnection: true
                    )
                )
                return true
            },
            receive: sendBody
        )
    }

    private static func fetchResponse(
        targetURL: URL,
        params: [String: String],
        headers: [String: String],
        httpClient: HTTPClient,
        normalizationState: QuarkHLSNormalizationState
    ) async throws -> HTTPResponse {
        let isHLSChild = params["hls"] == "1" && isQuarkSignedHLSChildURL(targetURL)
        guard isHLSChild else {
            return try await requestUpstream(targetURL, headers: headers, httpClient: httpClient, timeout: 15)
        }

        let context = params["qctx"]
        var attemptedURLs = Set<String>()
        var lastResponse: HTTPResponse?
        var lastError: Error?

        if let context,
           let learnedDepth = await normalizationState.depth(for: context),
           let learnedURL = normalizedQuarkSignedHLSChildURL(targetURL, layers: learnedDepth) {
            attemptedURLs.insert(learnedURL.absoluteString)
            do {
                let response = try await requestUpstream(
                    learnedURL,
                    headers: headers,
                    httpClient: httpClient,
                    timeout: 10
                )
                DiagnosticLog.write(
                    "[PROXY_QUARK_SIGNED_CHILD_NORMALIZE_REUSE] \(upstreamLogLabel(learnedURL)) layer=\(learnedDepth) status=\(response.statusCode)"
                )
                if response.statusCode != 400 {
                    return response
                }
                lastResponse = response
            } catch {
                guard shouldRetryNormalization(after: error) else { throw error }
                lastError = error
                DiagnosticLog.write(
                    "[PROXY_QUARK_SIGNED_CHILD_NORMALIZE_REUSE_FAILED] \(upstreamLogLabel(learnedURL)) layer=\(learnedDepth) error=\(error.localizedDescription)"
                )
            }
            await normalizationState.forget(context: context)
        }

        for normalizationLayer in 0...3 {
            let candidateURL: URL
            if normalizationLayer == 0 {
                candidateURL = targetURL
            } else if let normalizedURL = normalizedQuarkSignedHLSChildURL(
                targetURL,
                layers: normalizationLayer
            ) {
                candidateURL = normalizedURL
            } else {
                break
            }

            guard attemptedURLs.insert(candidateURL.absoluteString).inserted else { continue }
            do {
                let response = try await requestUpstream(
                    candidateURL,
                    headers: headers,
                    httpClient: httpClient,
                    timeout: 10,
                    allowsProxyFallback: normalizationLayer > 0
                )
                lastResponse = response
                if normalizationLayer > 0 {
                    DiagnosticLog.write(
                        "[PROXY_QUARK_SIGNED_CHILD_NORMALIZE_RETRY] \(upstreamLogLabel(candidateURL)) layer=\(normalizationLayer) status=\(response.statusCode)"
                    )
                }
                if (200..<300).contains(response.statusCode) {
                    if let context, normalizationLayer > 0 {
                        await normalizationState.remember(depth: normalizationLayer, for: context)
                    }
                    return response
                }
                if response.statusCode != 400 {
                    return response
                }
            } catch {
                guard normalizationLayer == 0, shouldRetryNormalization(after: error) else {
                    throw error
                }
                lastError = error
                DiagnosticLog.write(
                    "[PROXY_QUARK_SIGNED_CHILD_RAW_TIMEOUT] \(upstreamLogLabel(candidateURL)) error=\(error.localizedDescription)"
                )
            }
        }

        if let lastResponse { return lastResponse }
        throw lastError ?? HTTPError.invalidResponse
    }

    private static func requestUpstream(
        _ url: URL,
        headers: [String: String],
        httpClient: HTTPClient,
        timeout: TimeInterval,
        allowsProxyFallback: Bool = true
    ) async throws -> HTTPResponse {
        let validatedURL = try ProxyAccessPolicy.validateTargetURL(url.absoluteString)
        let response = try await httpClient.request(
            url: validatedURL.absoluteString,
            method: .get,
            headers: headers,
            timeout: timeout,
            allowsProxyFallback: allowsProxyFallback,
            redactsURLInLogs: true
        )
        try ProxyAccessPolicy.validateFinalURL(response.finalURL)
        return response
    }

    private static func shouldRetryNormalization(after error: Error) -> Bool {
        guard !(error is CancellationError), let urlError = error as? URLError else {
            return false
        }
        return urlError.code == .timedOut || urlError.code == .networkConnectionLost
    }

    private static func targetURL(from params: [String: String]) -> String? {
        if let encoded = params["u64"], let decoded = ProxyURLCodec.decode(encoded), !decoded.isEmpty {
            return decoded
        }
        return params["url"]
    }

    private static func headerJSON(from params: [String: String]) -> String {
        if let encoded = params["h64"], let decoded = ProxyURLCodec.decode(encoded) {
            return decoded
        }
        return params["header"] ?? params["headers"] ?? "{}"
    }

    private static func decodeHeaders(from params: [String: String]) -> [String: String] {
        let headerStr = headerJSON(from: params)
        guard !headerStr.isEmpty,
              let headerData = headerStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: headerData) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private static func cleanedResponseHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { header in
            let lower = header.key.lowercased()
            return lower != "content-length"
                && lower != "content-type"
                && lower != "content-encoding"
                && lower != "transfer-encoding"
                && lower != "connection"
        }
    }

    private static func normalizedQuarkSignedHLSChildURL(_ url: URL) -> URL? {
        guard isQuarkSignedHLSChildURL(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var queryItems = components.queryItems else {
            return nil
        }

        var changed = false
        queryItems = queryItems.map { item in
            guard let value = item.value,
                  value.contains("%"),
                  let decodedValue = value.removingPercentEncoding,
                  decodedValue != value else {
                return item
            }
            changed = true
            return URLQueryItem(name: item.name, value: decodedValue)
        }
        guard changed else { return nil }
        components.queryItems = queryItems
        if let percentEncodedQuery = components.percentEncodedQuery {
            components.percentEncodedQuery = percentEncodedQuery.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url
    }

    private static func normalizedQuarkSignedHLSChildURL(_ url: URL, layers: Int) -> URL? {
        guard layers > 0 else { return url }
        var normalizedURL = url
        for _ in 0..<layers {
            guard let nextURL = normalizedQuarkSignedHLSChildURL(normalizedURL) else {
                return nil
            }
            normalizedURL = nextURL
        }
        return normalizedURL
    }

    private static func isQuarkSignedHLSChildURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host.hasSuffix(".drive.quark.cn"),
              url.pathExtension.caseInsensitiveCompare("m3u8") != .orderedSame,
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        return queryItems.contains(where: { $0.name.caseInsensitiveCompare("ct") == .orderedSame })
    }

    private static func isAliSignedHLSChildURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host.hasSuffix(".aliyundrive.net"),
              url.pathExtension.caseInsensitiveCompare("m3u8") != .orderedSame,
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        return queryItems.contains(where: {
            $0.name.caseInsensitiveCompare("x-oss-signature") == .orderedSame
                && !($0.value ?? "").isEmpty
        })
    }

    private static func upstreamLogLabel(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "upstream"
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? "upstream"
    }

    private static func shouldRewriteM3U8(url: String, contentType: String) -> Bool {
        let lowerURL = url.lowercased()
        let lowerContentType = contentType.lowercased()
        return lowerContentType.contains("mpegurl") || lowerURL.contains(".m3u8")
    }

    private static func rewriteM3U8(
        data: Data,
        baseURL: String,
        header: String,
        hmysSignSecret: String? = nil
    ) -> Data? {
        guard let m3u8Str = String(data: data, encoding: .utf8) else { return nil }
        let normalized = m3u8Str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("#EXTM3U") else { return nil }
        let lines = m3u8Str.components(separatedBy: .newlines)
        var newLines: [String] = []
        let normalizationContext = quarkHLSNormalizationContext(for: baseURL)
        var didLogAliRewriteStructure = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rewrittenAttributeLine = rewriteM3U8AttributeURIs(
                line: line,
                baseURL: baseURL,
                header: header,
                normalizationContext: normalizationContext,
                hmysSignSecret: hmysSignSecret
            ) {
                newLines.append(rewrittenAttributeLine)
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                newLines.append(line)
                continue
            }

            if !didLogAliRewriteStructure,
               let diagnostic = aliHLSRewriteDiagnostic(
                   baseURL: baseURL,
                   candidate: trimmed
               ) {
                DiagnosticLog.write("[ALI_HLS_REWRITE] \(diagnostic)")
                didLogAliRewriteStructure = true
            }

            newLines.append(proxiedURL(
                baseURL: baseURL,
                candidate: trimmed,
                header: header,
                fallbackExtension: "ts",
                normalizationContext: normalizationContext,
                hmysSignSecret: hmysSignSecret
            ) ?? line)
        }

        return newLines.joined(separator: "\n").data(using: .utf8)
    }

    private static func aliHLSRewriteDiagnostic(baseURL: String, candidate: String) -> String? {
        guard let base = URLComponents(string: baseURL),
              base.host?.lowercased().hasSuffix(".aliyundrive.net") == true else {
            return nil
        }

        let candidateQuery = candidate
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .first?
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let resolvedURL = absoluteURL(baseURL: baseURL, candidate: candidate)
        let resolved = URLComponents(string: resolvedURL)
        let resolvedQuery = resolved?.percentEncodedQuery ?? ""
        let querySource = candidateQuery.isEmpty ? "parent" : "candidate"
        let queryPreserved = candidateQuery.isEmpty || candidateQuery == resolvedQuery
        let keys = (resolved?.queryItems ?? []).map(\.name).sorted().joined(separator: ",")
        let encodedScalars = Dictionary(grouping: candidateQuery.unicodeScalars.filter {
            !CharacterSet.urlQueryAllowed.contains($0)
        }, by: { String(format: "U+%04X", $0.value) })
            .map { "\($0.key):\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        let characters = Array(candidateQuery)
        var percentPatterns: [String] = []
        for index in characters.indices where characters[index] == "%" {
            let next = characters.index(after: index)
            let end = characters.index(next, offsetBy: 2, limitedBy: characters.endIndex) ?? characters.endIndex
            percentPatterns.append("%" + String(characters[next..<end]))
        }
        let patternSummary = Dictionary(grouping: percentPatterns, by: { $0 })
            .map { "\($0.key):\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        return "source=\(querySource) candidateQueryBytes=\(candidateQuery.utf8.count) resolvedQueryBytes=\(resolvedQuery.utf8.count) queryPreserved=\(queryPreserved) encodedScalars=\(encodedScalars.isEmpty ? "none" : encodedScalars) percentPatterns=\(patternSummary.isEmpty ? "none" : patternSummary) keys=\(keys)"
    }

    private static func rewriteM3U8AttributeURIs(
        line: String,
        baseURL: String,
        header: String,
        normalizationContext: String?,
        hmysSignSecret: String?
    ) -> String? {
        guard line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#"),
              line.localizedCaseInsensitiveContains("URI=\"") else {
            return nil
        }

        var rewritten = line
        var searchRange = rewritten.startIndex..<rewritten.endIndex
        var changed = false
        while let marker = rewritten.range(of: #"URI=""#, options: [.caseInsensitive], range: searchRange) {
            let valueStart = marker.upperBound
            guard let valueEnd = rewritten[valueStart...].firstIndex(of: "\"") else {
                break
            }
            let candidate = String(rewritten[valueStart..<valueEnd])
            if let proxyURL = proxiedURL(
                baseURL: baseURL,
                candidate: candidate,
                header: header,
                fallbackExtension: "bin",
                normalizationContext: normalizationContext,
                hmysSignSecret: hmysSignSecret
            ) {
                rewritten.replaceSubrange(valueStart..<valueEnd, with: proxyURL)
                changed = true
                searchRange = rewritten.index(marker.lowerBound, offsetBy: #"URI=""#.count + proxyURL.count)..<rewritten.endIndex
            } else {
                searchRange = valueEnd..<rewritten.endIndex
            }
        }
        return changed ? rewritten : nil
    }

    private static func proxiedURL(
        baseURL: String,
        candidate: String,
        header: String,
        fallbackExtension: String,
        normalizationContext: String?,
        hmysSignSecret: String?
    ) -> String? {
        let resolvedURL = absoluteURL(baseURL: baseURL, candidate: candidate)
        let targetURL = hmysSignSecret == nil
            ? resolvedURL
            : hmysURLByInheritingQuery(baseURL: baseURL, targetURL: resolvedURL)
        let relayHeader: String
        if let url = URL(string: targetURL), isQuarkSignedHLSChildURL(url) {
            relayHeader = "{}"
        } else {
            relayHeader = hlsChildRelayHeader(for: targetURL, inheritedHeader: header)
        }
        var proxyComponents = URLComponents()
        proxyComponents.scheme = "http"
        proxyComponents.host = "127.0.0.1"
        proxyComponents.port = ProxyServer.shared.port
        proxyComponents.path = proxyPath(for: targetURL, fallbackExtension: fallbackExtension)
        var queryItems = [
            URLQueryItem(name: "u64", value: ProxyURLCodec.encode(targetURL)),
            URLQueryItem(name: "h64", value: ProxyURLCodec.encode(relayHeader)),
            URLQueryItem(name: "hls", value: "1")
        ]
        if let normalizationContext,
           let url = URL(string: targetURL),
           isQuarkSignedHLSChildURL(url) {
            queryItems.append(URLQueryItem(name: "qctx", value: normalizationContext))
        }
        if let url = URL(string: targetURL), isAliSignedHLSChildURL(url) {
            queryItems.append(URLQueryItem(name: "stream", value: "1"))
        }
        if let hmysSignSecret {
            queryItems.append(URLQueryItem(name: "hs64", value: hmysSignSecret))
        }
        proxyComponents.queryItems = queryItems
        return proxyComponents.url?.absoluteString
    }

    static func hmysSignedURL(
        _ urlString: String,
        encodedSecret: String?,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> String {
        guard let encodedSecret,
              let secret = ProxyURLCodec.decode(encodedSecret),
              !secret.isEmpty,
              var components = URLComponents(string: urlString) else { return urlString }
        let wsTime = String(timestamp, radix: 16)
        let digest = Insecure.MD5.hash(data: Data("\(secret)\(components.path)\(wsTime)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        var queryItems = (components.queryItems ?? []).filter {
            $0.name.caseInsensitiveCompare("wsTime") != .orderedSame
                && $0.name.caseInsensitiveCompare("wsSecret") != .orderedSame
        }
        queryItems.append(URLQueryItem(name: "wsSecret", value: digest))
        queryItems.append(URLQueryItem(name: "wsTime", value: wsTime))
        components.queryItems = queryItems
        return components.url?.absoluteString ?? urlString
    }

    private static func hmysURLByInheritingQuery(baseURL: String, targetURL: String) -> String {
        guard let base = URLComponents(string: baseURL),
              var target = URLComponents(string: targetURL) else { return targetURL }
        var queryItems = (target.queryItems ?? []).filter {
            $0.name.caseInsensitiveCompare("wsTime") != .orderedSame
                && $0.name.caseInsensitiveCompare("wsSecret") != .orderedSame
        }
        let existingNames = Set(queryItems.map { $0.name.lowercased() })
        queryItems.append(contentsOf: (base.queryItems ?? []).filter {
            let name = $0.name.lowercased()
            return name != "wstime" && name != "wssecret" && !existingNames.contains(name)
        })
        target.queryItems = queryItems.isEmpty ? nil : queryItems
        return target.url?.absoluteString ?? targetURL
    }

    private static func hlsChildRelayHeader(for targetURL: String, inheritedHeader: String) -> String {
        guard let host = URL(string: targetURL)?.host?.lowercased(),
              host == "xhscdn.com" || host.hasSuffix(".xhscdn.com"),
              let data = inheritedHeader.data(using: .utf8),
              var headers = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return inheritedHeader
        }
        headers = headers.filter { key, _ in
            key.caseInsensitiveCompare("Referer") != .orderedSame
        }
        guard let sanitizedData = try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys]),
              let sanitized = String(data: sanitizedData, encoding: .utf8) else {
            return inheritedHeader
        }
        return sanitized
    }

    private static func quarkHLSNormalizationContext(for baseURL: String) -> String? {
        guard let url = URL(string: baseURL),
              let host = url.host?.lowercased(),
              host.hasSuffix(".drive.quark.cn"),
              url.pathExtension.caseInsensitiveCompare("m3u8") == .orderedSame else {
            return nil
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in baseURL.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func proxyPath(for targetURL: String, fallbackExtension: String) -> String {
        let supportedExtensions: Set<String> = [
            "m3u8", "m3u", "ts", "m4s", "mp4", "m4a", "aac", "ac3", "ec3", "vtt", "webvtt"
        ]
        let pathExtension = URL(string: targetURL)?.pathExtension.lowercased() ?? ""
        let relayExtension = supportedExtensions.contains(pathExtension) ? pathExtension : fallbackExtension
        return "/proxy.\(relayExtension)"
    }

    private static func unwrapPNGPrefixedMPEGTS(_ data: Data) -> Data? {
        let prefixEnd = data.withUnsafeBytes { bytes -> Int? in
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            guard bytes.count >= pngSignature.count + 12,
                  pngSignature.indices.allSatisfy({ bytes[$0] == pngSignature[$0] }) else {
                return nil
            }

            var offset = pngSignature.count
            while offset + 12 <= bytes.count {
                let length = Int(bytes[offset]) << 24
                    | Int(bytes[offset + 1]) << 16
                    | Int(bytes[offset + 2]) << 8
                    | Int(bytes[offset + 3])
                guard length <= bytes.count - offset - 12 else { return nil }
                let chunkEnd = offset + 12 + length
                let isIEND = bytes[offset + 4] == 0x49
                    && bytes[offset + 5] == 0x45
                    && bytes[offset + 6] == 0x4E
                    && bytes[offset + 7] == 0x44
                if isIEND {
                    guard chunkEnd + 188 < bytes.count,
                          bytes[chunkEnd] == 0x47,
                          bytes[chunkEnd + 188] == 0x47 else {
                        return nil
                    }
                    return chunkEnd
                }
                offset = chunkEnd
            }
            return nil
        }

        guard let prefixEnd else { return nil }
        return data.subdata(in: prefixEnd..<data.count)
    }

    private static func absoluteURL(baseURL: String, candidate: String) -> String {
        guard let base = URL(string: baseURL) else { return candidate }
        let resolved: String
        if candidate.hasPrefix("http") {
            resolved = candidate
        } else if candidate.hasPrefix("/"), let scheme = base.scheme, let host = base.host {
            let port = base.port.flatMap { ":\($0)" } ?? ""
            resolved = "\(scheme)://\(host)\(port)\(candidate)"
        } else {
            resolved = resolveRelativeURLPreservingQuery(base: base, candidate: candidate)
        }
        let normalized = normalizedURLQueryPreservingEscapes(resolved)
        return aliSignedHLSChildURL(baseURL: baseURL, resolvedURL: normalized) ?? normalized
    }

    private static func resolveRelativeURLPreservingQuery(base: URL, candidate: String) -> String {
        let suffixStart = candidate.firstIndex { $0 == "?" || $0 == "#" }
        let relativePath = suffixStart.map { String(candidate[..<$0]) } ?? candidate
        let rawSuffix = suffixStart.map { String(candidate[$0...]) } ?? ""
        let directory = base.deletingLastPathComponent()
        guard let resolvedPath = URL(string: relativePath, relativeTo: directory)?.absoluteURL else {
            return candidate
        }
        var components = URLComponents(url: resolvedPath, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return (components?.string ?? resolvedPath.absoluteString) + rawSuffix
    }

    private static func normalizedURLQueryPreservingEscapes(_ rawURL: String) -> String {
        guard let queryStart = rawURL.firstIndex(of: "?") else { return rawURL }
        let fragmentStart = rawURL[queryStart...].firstIndex(of: "#")
        let queryEnd = fragmentStart ?? rawURL.endIndex
        let rawQuery = String(rawURL[rawURL.index(after: queryStart)..<queryEnd])
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "%")
        guard let encodedQuery = rawQuery.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return rawURL
        }
        let prefix = String(rawURL[...queryStart])
        let fragment = fragmentStart.map { String(rawURL[$0...]) } ?? ""
        return prefix + encodedQuery + fragment
    }

    private static func aliSignedHLSChildURL(baseURL: String, resolvedURL: String) -> String? {
        guard let base = URLComponents(string: baseURL),
              let baseHost = base.host?.lowercased(),
              baseHost.hasSuffix(".aliyundrive.net"),
              let resolved = URLComponents(string: resolvedURL),
              resolved.host?.caseInsensitiveCompare(baseHost) == .orderedSame,
              resolved.percentEncodedQuery?.isEmpty != false,
              let baseQuery = base.percentEncodedQuery,
              !baseQuery.isEmpty else {
            return nil
        }

        let queryItems = base.queryItems ?? []
        guard queryItems.contains(where: {
            $0.name.caseInsensitiveCompare("x-oss-signature") == .orderedSame
                && !($0.value ?? "").isEmpty
        }), queryItems.contains(where: {
            $0.name.caseInsensitiveCompare("x-oss-process") == .orderedSame
                && ($0.value ?? "").localizedCaseInsensitiveContains("hls/sign")
        }) else {
            return nil
        }

        var signed = resolved
        signed.percentEncodedQuery = baseQuery
        return signed.string
    }
}
