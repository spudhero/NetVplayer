// ConfigEngine/URLNormalizer.swift
// URL 归一化，对应 FongMi: UrlUtil.convert

import Foundation
import Networking

/// URL 归一化处理
public enum URLNormalizer {

    /// 按配置文件地址转换资源 URL，兼容 TVBox/FongMi 中常见的 ./js、assets:// 与 file:// 写法。
    public static func convert(_ url: String, baseURL: String, bundle: Bundle = .main) -> String {
        let result = url.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // 空 URL
        guard !result.isEmpty else { return result }

        // 已经是 http/https
        if result.hasPrefix("http://") || result.hasPrefix("https://") {
            return result
        }

        // file://
        if result.hasPrefix("file://") {
            return result
        }

        // assets:// — 映射到 Bundle 资源
        if result.hasPrefix("assets://") {
            return resolveAssetURL(result, bundle: bundle) ?? result
        }

        // 相对路径
        if result.hasPrefix("./") || result.hasPrefix("../") || result.hasPrefix("/") {
            return resolveRelativeURL(result, baseURL: baseURL)
        }

        if !baseURL.isEmpty,
           !result.contains("://"),
           (result.contains("/") || !URL(fileURLWithPath: result).pathExtension.isEmpty) {
            return resolveRelativeURL(result, baseURL: baseURL)
        }

        return result
    }

    /// 递归转换 JSON 字符串中的资源路径。非 JSON 文本按单个 URL 处理。
    public static func convertEmbeddedResources(_ text: String, baseURL: String, bundle: Bundle = .main) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return isResourceReference(trimmed) ? convert(trimmed, baseURL: baseURL, bundle: bundle) : text
        }

        let converted = convertEmbeddedObject(object, baseURL: baseURL, bundle: bundle)
        guard JSONSerialization.isValidJSONObject(converted),
              let output = try? JSONSerialization.data(withJSONObject: converted),
              let string = String(data: output, encoding: .utf8) else {
            return text
        }
        return string
    }

    private static func resolveAssetURL(_ url: String, bundle: Bundle) -> String? {
        let path = String(url.dropFirst("assets://".count))
        let fileURL = URL(fileURLWithPath: path)
        let candidates = [
            bundle.url(
                forResource: fileURL.deletingPathExtension().lastPathComponent,
                withExtension: fileURL.pathExtension.isEmpty ? nil : fileURL.pathExtension
            ),
            bundle.resourceURL?.appendingPathComponent(path)
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })?.absoluteString
    }

    private static func resolveRelativeURL(_ value: String, baseURL: String) -> String {
        guard !baseURL.isEmpty else { return value }
        if let base = URL(string: baseURL), base.isFileURL {
            let directory = base.hasDirectoryPath ? base : base.deletingLastPathComponent()
            return URL(string: value, relativeTo: directory)?.absoluteURL.absoluteString
                ?? directory.appendingPathComponent(value).absoluteString
        }
        return URLHelper.resolve(base: baseURL, relative: value)
    }

    private static func convertEmbeddedObject(_ object: Any, baseURL: String, bundle: Bundle) -> Any {
        if let dict = object as? [String: Any] {
            return dict.mapValues { convertEmbeddedObject($0, baseURL: baseURL, bundle: bundle) }
        }
        if let array = object as? [Any] {
            return array.map { convertEmbeddedObject($0, baseURL: baseURL, bundle: bundle) }
        }
        if let string = object as? String, isResourceReference(string) {
            return convert(string, baseURL: baseURL, bundle: bundle)
        }
        return object
    }

    private static func isResourceReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("./") || trimmed.hasPrefix("../") || trimmed.hasPrefix("assets://") || trimmed.hasPrefix("file://") {
            return true
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return true
        }
        if trimmed.contains("://") {
            return false
        }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let ext = URL(fileURLWithPath: trimmed).pathExtension.lowercased()
        if ["js", "json", "txt", "m3u", "m3u8", "cookie"].contains(ext) {
            return true
        }
        // Encrypted ext values can contain a Base64 slash without being paths.
        if let decoded = Data(base64Encoded: trimmed), decoded.count >= 16,
           trimmed.hasSuffix("=") || String(data: decoded, encoding: .utf8) == nil {
            return false
        }
        return trimmed.contains("/") && !trimmed.contains("|") && !trimmed.contains(";")
    }
}
