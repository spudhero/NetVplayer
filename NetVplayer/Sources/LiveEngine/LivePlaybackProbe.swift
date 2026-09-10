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

    public init(
        isPlayable: Bool,
        statusCode: Int,
        contentType: String,
        bodyPrefix: String,
        message: String
    ) {
        self.isPlayable = isPlayable
        self.statusCode = statusCode
        self.contentType = contentType
        self.bodyPrefix = bodyPrefix
        self.message = message
    }
}

public struct LivePlaybackProbe: Sendable {
    public static let shared = LivePlaybackProbe()

    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    public func probe(spec: PlaySpec, timeout: TimeInterval = 10) async -> LiveProbeResult {
        do {
            let response = try await httpClient.get(url: spec.url, headers: spec.headers, timeout: timeout)
            return Self.evaluate(
                url: spec.url,
                statusCode: response.statusCode,
                contentType: response.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? "",
                data: response.data
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

    public static func evaluate(url: String, statusCode: Int, contentType: String, data: Data) -> LiveProbeResult {
        let bodyPrefix = String(data: data.prefix(256), encoding: .utf8) ?? data.prefix(32).map { String(format: "%02x", $0) }.joined()
        guard (200..<300).contains(statusCode) else {
            return LiveProbeResult(
                isPlayable: false,
                statusCode: statusCode,
                contentType: contentType,
                bodyPrefix: bodyPrefix,
                message: "上游 HTTP \(statusCode)"
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
                    message: data.isEmpty ? "空 M3U8 响应" : "非 M3U8 响应"
                )
            }
        } else if data.isEmpty {
            return LiveProbeResult(
                isPlayable: false,
                statusCode: statusCode,
                contentType: contentType,
                bodyPrefix: bodyPrefix,
                message: "空媒体响应"
            )
        }

        return LiveProbeResult(
            isPlayable: true,
            statusCode: statusCode,
            contentType: contentType,
            bodyPrefix: bodyPrefix,
            message: "可播放"
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
