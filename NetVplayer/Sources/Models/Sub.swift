// Models/Sub.swift
// 字幕模型，对应 FongMi: bean/Sub.java

import Foundation

/// 外挂字幕
public struct Sub: Codable, Identifiable, Sendable {
    public var name: String
    public var url: String
    public var lang: String
    public var format: String
    public var flag: Int

    public var id: String { "\(name)_\(url)" }

    public init(name: String = "", url: String = "", lang: String = "", format: String = "", flag: Int = 0) {
        self.name = name
        self.url = url
        self.lang = lang
        self.format = format
        self.flag = flag
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, lang, format, flag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        lang = try container.decodeIfPresent(String.self, forKey: .lang) ?? ""
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
        flag = try container.decodeIfPresent(Int.self, forKey: .flag) ?? 0
    }
}
