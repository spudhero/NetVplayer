// ParseEngine/ParseEngine.swift
// 解析系统调度器，对应 FongMi: ParseJob.java

import Foundation
import Models
import Networking

/// 解析引擎 — 负责二次解析播放地址
public final class ParseEngine: @unchecked Sendable {

    public static let shared = ParseEngine()

    private let httpClient: HTTPClient
    public private(set) var lastFailure: AppFailure?

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    /// 解析播放地址
    public func resolve(result: Result, parse: Parse?) async -> PlaySpec {
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
            flag: result.flag,
            siteKey: result.key
        )

        switch effectiveParse.parseType {
        case .webView:
            // Type 0: WebView 嗅探
            return baseSpec.merging(await doSniff(url: baseSpec.url, headers: baseSpec.headers, click: effectiveParse.click))
        case .json:
            // Type 1: JSON 接口解析
            return await jsonParse(parse: effectiveParse, baseSpec: baseSpec)
        case .jsonExt:
            // Type 2: JAR 自定义 JSON 解析器 — macOS 首版不支持
            lastFailure = AppFailure(category: .parse, message: "Parse type 2 JsonExt 首版无替代实现", detail: effectiveParse.name)
            return baseSpec
        case .jsonMix:
            // Type 3: 混合多解析接口 — macOS 首版不支持
            lastFailure = AppFailure(category: .parse, message: "Parse type 3 JsonMix 首版无替代实现", detail: effectiveParse.name)
            return baseSpec
        case .superParse:
            // Type 4: JSON + WebView 竞速
            return await superParse(parse: effectiveParse, baseSpec: baseSpec)
        }
    }

    // MARK: - Private

    @MainActor private var currentSniffer: WebViewSniffer?

    /// 主线程 WebView 嗅探执行
    @MainActor
    private func doSniff(url: String, headers: [String: String] = [:], click: String = "") async -> PlaySpec {
        currentSniffer?.cancel()
        
        let sniffer = WebViewSniffer()
        self.currentSniffer = sniffer
        do {
            let spec = try await sniffer.sniff(url: url, headers: headers, clickScript: click, timeout: 6)
            if self.currentSniffer === sniffer {
                self.currentSniffer = nil
            }
            return spec
        } catch {
            print("[ParseEngine] WebView 嗅探失败: \(error)")
            lastFailure = AppFailure(category: .parse, message: "WebView 嗅探失败", detail: error.localizedDescription)
            if self.currentSniffer === sniffer {
                self.currentSniffer = nil
            }
            return PlaySpec()
        }
    }

    @MainActor
    public func cancelCurrentSniff() {
        print("[ParseEngine] 主动取消当前网页嗅探")
        currentSniffer?.cancel()
        currentSniffer = nil
    }

    /// JSON 解析
    private func jsonParse(parse: Parse, baseSpec: PlaySpec) async -> PlaySpec {
        let parseUrl = parseURL(parse.url, targetURL: baseSpec.url)
        if parseUrl.isEmpty {
            lastFailure = AppFailure(category: .parse, message: "解析器 URL 为空", detail: parse.name)
            return baseSpec
        }
        do {
            var requestHeaders = parse.header
            requestHeaders.merge(parse.ext.header) { _, new in new }

            let response = try await httpClient.get(url: parseUrl, headers: requestHeaders)
            if let data = response.text.data(using: .utf8),
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return applyParsePayload(json, to: baseSpec)
            }
        } catch {
            print("[ParseEngine] JSON 解析失败: \(error)")
            lastFailure = AppFailure(category: .parse, message: "JSON 解析失败", detail: error.localizedDescription)
        }
        return baseSpec
    }

    /// 竞速解析
    private func superParse(parse: Parse, baseSpec: PlaySpec) async -> PlaySpec {
        // JSON 和 WebView 同时解析，取先返回的结果
        return await withTaskGroup(of: PlaySpec.self) { group in
            group.addTask { await self.jsonParse(parse: parse, baseSpec: baseSpec) }
            group.addTask {
                baseSpec.merging(await self.doSniff(url: baseSpec.url, headers: baseSpec.headers, click: parse.click))
            }

            for await result in group {
                if !result.url.isEmpty, result.url != baseSpec.url {
                    group.cancelAll()
                    return result
                }
            }
            return baseSpec
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
        if let danmaku = stringValue(payload["danmaku"]), !danmaku.isEmpty {
            spec.danmaku = danmaku
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
