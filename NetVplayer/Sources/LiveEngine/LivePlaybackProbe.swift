// LiveEngine/LivePlaybackProbe.swift
// Lightweight reachability probe for live playback URLs.

import Foundation
import Models
import Networking

public struct LiveProbeResult: Sendable, Equatable {
    public let isPlayable: Bool
    public let statusCode: Int
    public let contentType: String
    public let bodyPrefix: String
    public let message: String
    public let finalURL: URL?

    public var isHLS: Bool {
        let lowerContentType = contentType.lowercased()
        return lowerContentType.contains("mpegurl")
            || bodyPrefix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    public init(
        isPlayable: Bool,
        statusCode: Int,
        contentType: String,
        bodyPrefix: String,
        message: String,
        finalURL: URL? = nil
    ) {
        self.isPlayable = isPlayable
        self.statusCode = statusCode
        self.contentType = contentType
        self.bodyPrefix = bodyPrefix
        self.message = message
        self.finalURL = finalURL
    }
}

public struct LivePlaybackProbe: Sendable {
    public static let shared = LivePlaybackProbe()

    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    /// Archives may be large or unending. Keep only a bounded prefix and retire the stream at the budget.
    public func probeArchive(spec: PlaySpec, timeout: TimeInterval = 10) async -> LiveProbeResult {
        let prefix = LiveArchiveProbePrefix()
        var headers = spec.headers.filter { $0.key.caseInsensitiveCompare("Range") != .orderedSame }
        headers["Range"] = "bytes=0-4095"
        do {
            _ = try await httpClient.stream(url: spec.url, headers: headers, timeout: timeout,
                allowsProxyFallback: false, redactsURLInLogs: true, chunkSize: 1024,
                shouldStream: { response in
                    await prefix.setResponse(response)
                    return (200..<300).contains(response.statusCode)
                }, receive: { data in try await prefix.append(data) })
        } catch LiveArchiveProbePrefix.Complete.budgetReached {
            // Deliberate prefix completion, not a media failure.
        } catch {
            return LiveProbeResult(isPlayable: false, statusCode: 0, contentType: "", bodyPrefix: "", message: "probe unavailable")
        }
        let (response, data) = await prefix.snapshot()
        guard let response else {
            return LiveProbeResult(isPlayable: false, statusCode: 0, contentType: "", bodyPrefix: "", message: "probe unavailable")
        }
        return Self.evaluate(url: spec.url, statusCode: response.statusCode,
            contentType: response.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? "",
            data: data, finalURL: response.finalURL)
    }

    public func probe(spec: PlaySpec, timeout: TimeInterval = 10) async -> LiveProbeResult {
        do {
            let response = try await httpClient.get(
                url: spec.url,
                headers: spec.headers,
                timeout: timeout,
                redactsURLInLogs: true
            )
            return Self.evaluate(
                url: spec.url,
                statusCode: response.statusCode,
                contentType: response.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? "",
                data: response.data,
                finalURL: response.finalURL
            )
        } catch {
            return LiveProbeResult(
                isPlayable: false,
                statusCode: 0,
                contentType: "",
                bodyPrefix: "",
                message: "请求失败: \(error.localizedDescription)"
            )
        }
    }

    public static func evaluate(
        url: String,
        statusCode: Int,
        contentType: String,
        data: Data,
        finalURL: URL? = nil
    ) -> LiveProbeResult {
        let bodyPrefix = String(data: data.prefix(256), encoding: .utf8) ?? data.prefix(32).map { String(format: "%02x", $0) }.joined()
        guard (200..<300).contains(statusCode) else {
            return LiveProbeResult(
                isPlayable: false,
                statusCode: statusCode,
                contentType: contentType,
                bodyPrefix: bodyPrefix,
                message: "上游 HTTP \(statusCode)",
                finalURL: finalURL
            )
        }

        if looksLikeHLS(url: url, contentType: contentType) {
            let trimmed = bodyPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#EXTM3U") else {
                return LiveProbeResult(
                    isPlayable: false,
                    statusCode: statusCode,
                    contentType: contentType,
                    bodyPrefix: bodyPrefix,
                    message: data.isEmpty ? "空 M3U8 响应" : "非 M3U8 响应",
                    finalURL: finalURL
                )
            }
        } else if data.isEmpty {
            return LiveProbeResult(
                isPlayable: false,
                statusCode: statusCode,
                contentType: contentType,
                bodyPrefix: bodyPrefix,
                message: "空媒体响应",
                finalURL: finalURL
            )
        }

        return LiveProbeResult(
            isPlayable: true,
            statusCode: statusCode,
            contentType: contentType,
            bodyPrefix: bodyPrefix,
            message: "可播放",
            finalURL: finalURL
        )
    }

    private static func looksLikeHLS(url: String, contentType: String) -> Bool {
        let lowerURL = url.lowercased()
        let lowerContentType = contentType.lowercased()
        return lowerURL.contains(".m3u8")
            || lowerContentType.contains("mpegurl")
            || lowerContentType.contains("vnd.apple.mpegurl")
    }
}

private actor LiveArchiveProbePrefix {
    enum Complete: Error { case budgetReached }
    private var response: HTTPStreamResponse?
    private var data = Data()
    func setResponse(_ value: HTTPStreamResponse) { response = value }
    func append(_ value: Data) throws {
        data.append(value.prefix(max(0, 4096 - data.count)))
        if data.count >= 4096 { throw Complete.budgetReached }
    }
    func snapshot() -> (HTTPStreamResponse?, Data) { (response, data) }
}
