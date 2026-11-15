// ParseEngine/ParseEngine.swift
// 解析系统调度器，对应 FongMi: ParseJob.java

import Foundation
import Models
import Networking

/// 解析引擎 — 负责二次解析播放地址
public final class ParseEngine: @unchecked Sendable {

    public static let shared = ParseEngine()

    private let httpClient: HTTPClient
    private let snifferFactory: @MainActor @Sendable () -> any WebMediaSniffing
    public private(set) var lastFailure: AppFailure?

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
        self.snifferFactory = { WebViewSniffer() }
    }

    init(httpClient: HTTPClient, snifferFactory: @escaping @MainActor @Sendable () -> any WebMediaSniffing) {
        self.httpClient = httpClient
        self.snifferFactory = snifferFactory
    }

    /// 解析播放地址
    public func resolve(result: Result, parse: Parse?, webPolicy: WebMediaPolicy? = nil) async -> PlaySpec {
        let effectiveParse = parse ?? Parse()
        lastFailure = nil
        let baseSpec = PlaySpec(
            url: result.playUrl + result.url,
            externalAudioURL: result.externalAudioURL,
            contentLength: result.contentLength,
            headers: result.header,
            format: result.format,
            drm: result.drm,
            subs: result.subs,
            providerDanmaku: result.danmaku,
            flag: result.flag,
            siteKey: result.key
        )

        let attempt: ParseAttempt
        switch effectiveParse.parseType {
        case .webView:
            // Type 0: WebView 嗅探
            attempt = await doSniff(baseSpec: baseSpec, click: effectiveParse.click, policy: webPolicy)
        case .json:
            // Type 1: JSON 接口解析
            attempt = await jsonParse(parse: effectiveParse, baseSpec: baseSpec)
        case .jsonExt:
            // Type 2: JAR 自定义 JSON 解析器 — macOS 首版不支持
            attempt = .failure(AppFailure(category: .parse, message: "Parse type 2 JsonExt 首版无替代实现", detail: effectiveParse.name))
        case .jsonMix:
            // Type 3: 混合多解析接口 — macOS 首版不支持
            attempt = .failure(AppFailure(category: .parse, message: "Parse type 3 JsonMix 首版无替代实现", detail: effectiveParse.name))
        case .superParse:
            // Type 4: JSON + WebView 竞速
            attempt = await superParse(parse: effectiveParse, baseSpec: baseSpec, policy: webPolicy)
        }
        // Retain the existing return contract: callers pair the original URL with
        // lastFailure to reject it or choose a legitimate fallback. A failed race
        // branch must never overwrite a sibling's successful result.
        if Task.isCancelled {
            lastFailure = Self.cancelledFailure
            return baseSpec
        }
        switch attempt {
        case .success(let spec):
            lastFailure = nil
            return spec
        case .failure(let failure):
            lastFailure = failure
            return baseSpec
        case .cancelled:
            lastFailure = Self.cancelledFailure
            return baseSpec
        }
    }

    // MARK: - Private

    private enum ParseAttempt: Sendable {
        case success(PlaySpec)
        case failure(AppFailure)
        case cancelled
    }

    private static var cancelledFailure: AppFailure {
        AppFailure(category: .parse, message: "解析已取消")
    }

    @MainActor private var currentSniffer: (any WebMediaSniffing)?

    /// 主线程 WebView 嗅探执行
    @MainActor
    private func doSniff(baseSpec: PlaySpec, click: String = "", policy: WebMediaPolicy? = nil) async -> ParseAttempt {
        guard !Task.isCancelled else { return .cancelled }
        currentSniffer?.cancel()
        let sniffer = snifferFactory()
        self.currentSniffer = sniffer
        defer {
            if self.currentSniffer === sniffer { self.currentSniffer = nil }
        }
        do {
            let spec = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await sniffer.sniff(url: baseSpec.url, headers: baseSpec.headers, clickScript: click, timeout: 15, policy: policy)
            } onCancel: {
                Task { @MainActor in sniffer.cancel() }
            }
            try Task.checkCancellation()
            guard !spec.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  spec.url != baseSpec.url else { throw WebViewSnifferError.noMediaFound }
            var merged = baseSpec.merging(spec)
            if spec.headerPolicy == .merge {
                merged.headers = WebViewSniffer.mergingHeaders(baseSpec.headers, spec.headers)
            }
            return .success(merged)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(AppFailure(category: .parse, message: "WebView 嗅探失败", detail: error.localizedDescription))
        }
    }

    @MainActor
    public func cancelCurrentSniff() {
        print("[ParseEngine] 主动取消当前网页嗅探")
        currentSniffer?.cancel()
        currentSniffer = nil
    }

    /// JSON 解析
    private func jsonParse(parse: Parse, baseSpec: PlaySpec) async -> ParseAttempt {
        guard !Task.isCancelled else { return .cancelled }
        let parseUrl = parseURL(parse.url, targetURL: baseSpec.url)
        if parseUrl.isEmpty {
            return .failure(AppFailure(category: .parse, message: "解析器 URL 为空", detail: parse.name))
        }
        do {
            var requestHeaders = parse.header
            requestHeaders.merge(parse.ext.header) { _, new in new }

            let response = try await httpClient.get(url: parseUrl, headers: requestHeaders)
            try Task.checkCancellation()
            if let data = response.text.data(using: .utf8),
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return .success(applyParsePayload(json, to: baseSpec))
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            if Task.isCancelled { return .cancelled }
            return .failure(AppFailure(category: .parse, message: "JSON 解析失败", detail: error.localizedDescription))
        }
        return .failure(AppFailure(category: .parse, message: "JSON 解析未返回有效对象"))
    }

    /// 竞速解析
    private func superParse(parse: Parse, baseSpec: PlaySpec, policy: WebMediaPolicy?) async -> ParseAttempt {
        // JSON 和 WebView 同时解析，取先返回的结果
        return await withTaskGroup(of: ParseAttempt.self) { group in
            group.addTask { await self.jsonParse(parse: parse, baseSpec: baseSpec) }
            group.addTask { await self.doSniff(baseSpec: baseSpec, click: parse.click, policy: policy) }

            var failure: AppFailure?
            for await attempt in group {
                if Task.isCancelled {
                    group.cancelAll()
                    return .cancelled
                }
                switch attempt {
                case .success(let spec) where !spec.url.isEmpty && spec.url != baseSpec.url:
                    group.cancelAll()
                    return .success(spec)
                case .failure(let current):
                    failure = failure ?? current
                default:
                    break
                }
            }
            return .failure(failure ?? AppFailure(category: .parse, message: "解析未返回媒体地址"))
        }
    }

    private func parseURL(_ parseURL: String, targetURL: String) -> String {
        var url = parseURL
        if url.hasPrefix("json:") || url.hasPrefix("parse:") {
            url = String(url.dropFirst(url.hasPrefix("json:") ? 5 : 6))
        }
        guard !url.isEmpty else { return "" }
        if url.contains("{url}") {
            return url.replacingOccurrences(of: "{url}", with: URLHelper.encode(targetURL))
        }
        return url + targetURL
    }

    private func applyParsePayload(_ payload: [String: Any], to baseSpec: PlaySpec) -> PlaySpec {
        var spec = baseSpec
        applyFlatPayload(payload, to: &spec)

        if let data = payload["data"] as? [String: Any] {
            applyFlatPayload(data, to: &spec)
        } else if let dataURL = stringValue(payload["data"]), !dataURL.isEmpty {
            spec.url = dataURL
        }

        return spec
    }

    private func applyFlatPayload(_ payload: [String: Any], to spec: inout PlaySpec) {
        if let url = stringValue(payload["url"]), !url.isEmpty {
            spec.url = url
        }
        if let playURL = stringValue(payload["playUrl"]), !playURL.isEmpty {
            spec.url = playURL + spec.url
        }
        if let format = stringValue(payload["format"]), !format.isEmpty {
            spec.format = format
        }
        if let flag = stringValue(payload["flag"]), !flag.isEmpty {
            spec.flag = flag
        }
        if let siteKey = stringValue(payload["key"]), !siteKey.isEmpty {
            spec.siteKey = siteKey
        }
        if let title = stringValue(payload["title"]), !title.isEmpty {
            spec.title = title
        }

        spec.headers.merge(headerMap(from: payload["header"])) { _, new in new }
        spec.headers.merge(headerMap(from: payload["headers"])) { _, new in new }
        for key in ["User-Agent", "Referer", "Cookie", "Origin", "ua"] {
            if let value = stringValue(payload[key]), !value.isEmpty {
                spec.headers[URLHelper.fixHeaderKey(key)] = value
            }
        }

        if let drm = decode(Drm.self, from: payload["drm"]) {
            spec.drm = drm
        }
        if let subs = decode([Sub].self, from: payload["subs"]) {
            spec.subs = subs
        }
        if let value = payload["danmaku"],
           let bytes = try? JSONSerialization.data(withJSONObject: ["danmaku": value]),
           let result = try? JSONDecoder().decode(Result.self, from: bytes) {
            spec.providerDanmaku = result.danmaku
        }
    }

    private func headerMap(from value: Any?) -> [String: String] {
        if let headers = value as? [String: String] {
            return headers.reduce(into: [:]) { result, item in
                result[URLHelper.fixHeaderKey(item.key)] = item.value
            }
        }
        if let headers = value as? [String: Any] {
            return headers.reduce(into: [:]) { result, item in
                if let value = stringValue(item.value), !value.isEmpty {
                    result[URLHelper.fixHeaderKey(item.key)] = value
                }
            }
        }
        if let text = value as? String,
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return headerMap(from: object)
        }
        return [:]
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
