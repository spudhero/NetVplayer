// Models/Protocols.swift
// 跨模块共享协议定义

import Foundation

// MARK: - 代理响应
public struct ProxyResponse: Sendable {
    public let statusCode: Int
    public let contentType: String
    public let data: Data
    public let headers: [String: String]
    public let closeConnection: Bool

    public init(
        statusCode: Int = 200,
        contentType: String = "application/octet-stream",
        data: Data,
        headers: [String: String] = [:],
        closeConnection: Bool = false
    ) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.data = data
        self.headers = headers
        self.closeConnection = closeConnection
    }

    public static func fromSpiderValue(_ value: Any) -> ProxyResponse? {
        if let response = value as? ProxyResponse {
            return response
        }
        if let text = value as? String {
            return fromSpiderText(text)
        }
        if let array = value as? [Any] {
            return fromSpiderArray(array)
        }
        if let dict = value as? [String: Any] {
            return fromSpiderDictionary(dict)
        }
        return nil
    }

    public static func fromSpiderText(_ text: String) -> ProxyResponse? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return ProxyResponse(contentType: "text/plain; charset=utf-8", data: Data(trimmed.utf8))
        }
        return fromSpiderValue(object)
    }

    private static func fromSpiderArray(_ array: [Any]) -> ProxyResponse? {
        guard !array.isEmpty else { return nil }
        let status = intValue(array[safe: 0]) ?? 200
        let contentType = stringValue(array[safe: 1]) ?? "application/octet-stream"
        let data = dataValue(array[safe: 2]) ?? Data()
        let headers = headerMap(array[safe: 3])
        return ProxyResponse(statusCode: status, contentType: contentType, data: data, headers: headers)
    }

    private static func fromSpiderDictionary(_ dict: [String: Any]) -> ProxyResponse? {
        let status = intValue(dict["statusCode"] ?? dict["status"] ?? dict["code"]) ?? 200
        let contentType = stringValue(dict["contentType"] ?? dict["type"] ?? dict["mime"]) ?? "application/octet-stream"
        let headers = headerMap(dict["headers"] ?? dict["header"])
        let base64 = (dict["base64"] as? Bool) ?? false
        let body = dict["data"] ?? dict["body"] ?? dict["content"] ?? dict["stream"] ?? ""
        let data = dataValue(body, base64: base64) ?? Data()
        return ProxyResponse(statusCode: status, contentType: contentType, data: data, headers: headers)
    }

    private static func dataValue(_ value: Any?, base64: Bool = false) -> Data? {
        if let data = value as? Data { return data }
        if let bytes = value as? [UInt8] { return Data(bytes) }
        if let bytes = value as? [Int] { return Data(bytes.map { UInt8(clamping: $0) }) }
        if let text = stringValue(value) {
            if base64, let data = Data(base64Encoded: text) { return data }
            return Data(text.utf8)
        }
        return nil
    }

    private static func headerMap(_ value: Any?) -> [String: String] {
        if let headers = value as? [String: String] { return headers }
        if let headers = value as? [String: Any] {
            return headers.reduce(into: [:]) { result, item in
                if let value = stringValue(item.value) {
                    result[item.key] = value
                }
            }
        }
        if let text = value as? String,
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return headerMap(object)
        }
        return [:]
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Source/Extractor 协议
/// URL 提取器协议，对应 FongMi: Source.Extractor
public protocol SourceExtractorProtocol: Sendable {
    /// 判断是否匹配此提取器
    func match(url: URL) -> Bool

    /// 提取真实播放地址
    func fetch(url: String) async throws -> String

    /// 提取真实播放地址及播放层需要保留的元数据
    func fetchResult(url: String) async throws -> SourceFetchResult

}

public struct SourceFetchResult: Equatable, Sendable {
    public let url: String
    public let headers: [String: String]
    public let fallbackHeaders: [String: String]
    public let isDirectMedia: Bool
    public let mpvOptions: [String: String]
    public let metadata: [String: String]
    public let drivePlaybackPlan: DrivePlaybackPlan?

    public init(
        url: String,
        headers: [String: String] = [:],
        fallbackHeaders: [String: String] = [:],
        isDirectMedia: Bool = false,
        mpvOptions: [String: String] = [:],
        metadata: [String: String] = [:],
        drivePlaybackPlan: DrivePlaybackPlan? = nil
    ) {
        self.url = url
        self.headers = headers
        self.fallbackHeaders = fallbackHeaders
        self.isDirectMedia = isDirectMedia
        self.mpvOptions = mpvOptions
        self.metadata = metadata
        self.drivePlaybackPlan = drivePlaybackPlan
    }
}

public extension SourceExtractorProtocol {
    func fetchResult(url: String) async throws -> SourceFetchResult {
        SourceFetchResult(url: try await fetch(url: url))
    }
}
