// LiveEngine/EpgParser.swift
// EPG 节目单解析器

import Foundation
import Models
import Networking
import zlib

/// EPG 解析器（XMLTV 格式）
public struct EpgParser: Sendable {
    private static let cacheTTL: TimeInterval = 6 * 60 * 60
    private nonisolated(unsafe) static var cache: [String: (expiresAt: Date, data: EpgData)] = [:]
    private static let cacheLock = NSLock()

    /// 从 XMLTV 文本解析 EPG 数据
    public static func parse(xml: String) -> [String: EpgData] {
        guard let data = xml.data(using: .utf8) else { return [:] }
        return parse(data: data)
    }

    /// 从 XMLTV 数据解析 EPG，支持 gzip 压缩数据
    public static func parse(data: Data) -> [String: EpgData] {
        let payload = decompressedIfNeeded(data) ?? data
        let delegate = XMLTVDelegate()
        let parser = XMLParser(data: payload)
        parser.delegate = delegate
        guard parser.parse() else {
            return [:]
        }
        return delegate.makeData()
    }

    /// 从 JSON API 拉取 EPG
    public static func fetch(
        apiTemplate: String,
        channelId: String,
        date: String,
        timeout: TimeInterval = 5,
        bypassCache: Bool = false
    ) async -> EpgData {
        await fetch(
            apiTemplate: apiTemplate,
            channelId: channelId,
            date: date,
            httpClient: .shared,
            timeout: timeout,
            bypassCache: bypassCache
        )
    }

    /// 从远端 API 拉取并缓存 EPG 数据
    public static func fetch(
        apiTemplate: String,
        channelId: String,
        date: String,
        httpClient: HTTPClient,
        timeout: TimeInterval = 5,
        bypassCache: Bool = false
    ) async -> EpgData {
        let url = buildURL(apiTemplate: apiTemplate, channelId: channelId, date: date)
        let cacheKey = "\(apiTemplate)|\(channelId)|\(date)"
        if !bypassCache, let cached = cachedValue(for: cacheKey) {
            return cached
        }

        do {
            let response = try await get(url: url, httpClient: httpClient, timeout: timeout)
            try Task.checkCancellation()
            let parsed = parse(data: response.data)
            let epg = parsed[channelId]
                ?? parsed[channelId.lowercased()]
                ?? parsed.values.first
                ?? EpgData(channelName: channelId)
            store(epg, for: cacheKey)
            return epg
        } catch is CancellationError {
            DiagnosticLog.write("[EPG_FETCH_CANCELLED] channel=\(channelId) url=\(redactedURL(url))")
            return EpgData(channelName: channelId)
        } catch {
            if isCancelled(error) {
                DiagnosticLog.write("[EPG_FETCH_CANCELLED] channel=\(channelId) url=\(redactedURL(url))")
            } else if isTimeout(error) {
                DiagnosticLog.write("[EPG_FETCH_TIMEOUT] channel=\(channelId) timeout=\(String(format: "%.1f", timeout))s url=\(redactedURL(url))")
            }
            return EpgData(channelName: channelId)
        }
    }

    public static func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeAll()
    }

    private static func cachedValue(for key: String) -> EpgData? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[key], entry.expiresAt > Date() else {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.data
    }

    private static func store(_ data: EpgData, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = (Date().addingTimeInterval(cacheTTL), data)
    }

    private static func buildURL(apiTemplate: String, channelId: String, date: String) -> String {
        apiTemplate
            .replacingOccurrences(of: "{date}", with: encode(date))
            .replacingOccurrences(of: "{id}", with: encode(channelId))
            .replacingOccurrences(of: "{name}", with: encode(channelId))
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private static func get(url: String, httpClient: HTTPClient, timeout: TimeInterval) async throws -> HTTPResponse {
        try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            group.addTask {
                try await httpClient.get(url: url, timeout: timeout, allowsProxyFallback: false)
            }
            group.addTask {
                let clampedTimeout = max(timeout, 0.1)
                try await Task.sleep(nanoseconds: UInt64(clampedTimeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }

            guard let response = try await group.next() else {
                throw URLError(.unknown)
            }
            return response
        }
    }

    private static func isCancelled(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        return error is CancellationError
    }

    private static func isTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        return error.localizedDescription.lowercased().contains("timed out")
    }

    private static func redactedURL(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL) else { return rawURL }
        components.queryItems = components.queryItems?.map { URLQueryItem(name: $0.name, value: "<redacted>") }
        return components.url?.absoluteString ?? rawURL
    }

    private static func decompressedIfNeeded(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        if data[0] == 0x1f && data[1] == 0x8b {
            return gunzip(data)
        }
        return nil
    }

    private static func gunzip(_ data: Data) -> Data? {
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data()
        let finalStatus = data.withUnsafeBytes { inputBytes -> Int32 in
            guard let inputBase = inputBytes.bindMemory(to: Bytef.self).baseAddress else {
                return Z_DATA_ERROR
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(data.count)

            let chunkSize = 16 * 1024
            var status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                status = buffer.withUnsafeMutableBytes { outputBytes -> Int32 in
                    stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let decodedCount = chunkSize - Int(stream.avail_out)
                if decodedCount > 0 {
                    output.append(buffer, count: decodedCount)
                }
                if status == Z_STREAM_END {
                    return status
                }
                if status != Z_OK {
                    return status
                }
            } while stream.avail_out == 0
            return status
        }

        return finalStatus == Z_STREAM_END ? output : nil
    }
}

private final class XMLTVDelegate: NSObject, XMLParserDelegate {
    private struct Programme {
        var channel: String
        var title: String = ""
        var start: Date = Date()
        var end: Date = Date()
    }

    private var channelNames: [String: String] = [:]
    private var programmes: [Programme] = []
    private var currentChannelId: String?
    private var currentProgramme: Programme?
    private var currentElement = ""
    private var buffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        buffer = ""
        switch elementName {
        case "channel":
            currentChannelId = attributeDict["id"]
        case "programme":
            guard let channel = attributeDict["channel"] else { return }
            currentProgramme = Programme(
                channel: channel,
                start: Self.parseDate(attributeDict["start"]),
                end: Self.parseDate(attributeDict["stop"])
            )
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "display-name":
            if let channelId = currentChannelId, !value.isEmpty, channelNames[channelId] == nil {
                channelNames[channelId] = value
            }
        case "title":
            if currentProgramme != nil, !value.isEmpty {
                currentProgramme?.title = value
            }
        case "channel":
            currentChannelId = nil
        case "programme":
            if let programme = currentProgramme, !programme.title.isEmpty {
                programmes.append(programme)
            }
            currentProgramme = nil
        default:
            break
        }
        currentElement = ""
        buffer = ""
    }

    func makeData() -> [String: EpgData] {
        var grouped: [String: [EpgItem]] = [:]
        for programme in programmes {
            grouped[programme.channel, default: []].append(EpgItem(
                title: programme.title,
                start: programme.start,
                end: programme.end
            ))
        }
        return grouped.mapValues { items in
            items.sorted { $0.start < $1.start }
        }.map { key, items in
            (
                key,
                EpgData(channelName: channelNames[key] ?? key, items: items)
            )
        }.reduce(into: [:]) { partial, item in
            partial[item.0] = item.1
        }
    }

    private static func parseDate(_ raw: String?) -> Date {
        guard let raw, !raw.isEmpty else { return Date(timeIntervalSince1970: 0) }
        let formats = [
            "yyyyMMddHHmmss Z",
            "yyyyMMddHHmmssZ",
            "yyyyMMddHHmmss",
            "yyyyMMddHHmm"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return Date(timeIntervalSince1970: 0)
    }
}
