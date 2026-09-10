// Models/Parse.swift
// 解析器模型，对应 FongMi: bean/Parse.java

import Foundation

/// 解析器类型
public enum ParseType: Int, Codable, Sendable {
    case webView = 0   // WebView 嗅探
    case json = 1      // JSON 接口
    case jsonExt = 2   // JAR 自定义 JSON 解析器
    case jsonMix = 3   // 混合多解析接口
    case superParse = 4 // JSON + WebView 竞速
}

/// 解析接口配置
public struct Parse: Codable, Identifiable, Sendable {
    public var name: String
    public var type: Int
    public var url: String
    public var ext: ParseExt
    public var header: [String: String]
    public var click: String
    public var isSelected: Bool

    public var id: String { name }

    public init(
        name: String = "",
        type: Int = 0,
        url: String = "",
        ext: ParseExt = ParseExt(),
        header: [String: String] = [:],
        click: String = "",
        isSelected: Bool = false
    ) {
        self.name = name
        self.type = type
        self.url = url
        self.ext = ext
        self.header = header
        self.click = click
        self.isSelected = isSelected
    }

    public var parseType: ParseType {
        ParseType(rawValue: type) ?? .webView
    }

    public var isEmpty: Bool { name.isEmpty }

    enum CodingKeys: String, CodingKey {
        case name, type, url, ext, header, click, isSelected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.type = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .type))?.intValue ?? 0
        self.url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.ext = (try? container.decodeIfPresent(ParseExt.self, forKey: .ext)) ?? ParseExt()
        self.header = try container.decodeIfPresent([String: String].self, forKey: .header) ?? [:]
        self.click = try container.decodeIfPresent(String.self, forKey: .click) ?? ""
        self.isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(url, forKey: .url)
        try container.encode(ext, forKey: .ext)
        try container.encode(header, forKey: .header)
        try container.encode(click, forKey: .click)
        try container.encode(isSelected, forKey: .isSelected)
    }

    /// 全局超级解析器
    public static func god() -> Parse {
        Parse(name: "聚合", type: 4)
    }

}

/// 解析器扩展配置
public struct ParseExt: Codable, Sendable {
    public var flag: [String]
    public var header: [String: String]

    public init(flag: [String] = [], header: [String: String] = [:]) {
        self.flag = flag
        self.header = header
    }

    enum CodingKeys: String, CodingKey {
        case flag, header
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.flag = try container.decodeIfPresent([String].self, forKey: .flag) ?? []
        self.header = try container.decodeIfPresent([String: String].self, forKey: .header) ?? [:]
    }
}
