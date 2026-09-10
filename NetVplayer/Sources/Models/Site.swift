// Models/Site.swift
// 站点数据模型，对应 FongMi: bean/Site.java

import Foundation

/// 站点类型枚举
public enum SiteType: Int, Codable, Sendable {
    case cmsXML = 0    // XML CMS (苹果CMS XML格式)
    case cmsJSON = 1   // JSON CMS (苹果CMS JSON格式)
    case spider = 3    // Spider 爬虫 (JAR/JS/Python)
    case xpath = 4     // XPath/扩展 API
}

/// 站点模型
/// 对应 FongMi: com.fongmi.android.tv.bean.Site
public struct Site: Codable, Identifiable, Hashable, Sendable {
    /// 站点唯一标识
    public var key: String
    /// 站点显示名称
    public var name: String
    /// 站点类型
    public var type: Int
    /// 爬虫 API 地址或前缀
    public var api: String
    /// 传给爬虫的扩展参数
    public var ext: String
    /// 爬虫 JAR/JS 包地址
    public var jar: String
    /// WebView 点击脚本
    public var click: String
    /// 播放 URL 前缀
    public var playUrl: String
    /// 是否隐藏
    public var hide: Int
    /// 是否显示在首页索引
    public var indexs: Int
    /// 超时时间（秒）
    public var timeout: Int
    /// 是否可搜索：0=配置禁用, 1=启用, 2=用户禁用
    public var searchable: Int
    /// 快速搜索
    public var quickSearch: Int
    /// 是否允许切换
    public var changeable: Int
    /// 限定分类列表
    public var categories: [String]
    /// 自定义 HTTP 请求头
    public var header: [String: String]
    /// UI 展示样式
    public var style: Style?

    // MARK: - 运行时状态（不参与编码）
    /// 是否被选中为当前站点
    public var isSelected: Bool = false

    public var id: String { key }

    public init(
        key: String = "",
        name: String = "",
        type: Int = 0,
        api: String = "",
        ext: String = "",
        jar: String = "",
        click: String = "",
        playUrl: String = "",
        hide: Int = 0,
        indexs: Int = 0,
        timeout: Int = 15,
        searchable: Int = 1,
        quickSearch: Int = 1,
        changeable: Int = 1,
        categories: [String] = [],
        header: [String: String] = [:],
        style: Style? = nil
    ) {
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.ext = ext
        self.jar = jar
        self.click = click
        self.playUrl = playUrl
        self.hide = hide
        self.indexs = indexs
        self.timeout = timeout
        self.searchable = searchable
        self.quickSearch = quickSearch
        self.changeable = changeable
        self.categories = categories
        self.header = header
        self.style = style
    }

    // MARK: - 业务方法

    public var siteType: SiteType {
        SiteType(rawValue: type) ?? .cmsXML
    }

    public var isSpider: Bool { type == 3 }
    public var isAndroidCrawlerSource: Bool { isSpider && api.hasPrefix("csp_") }
    public var isWoggCrawlerSource: Bool {
        key == "玩偶" || api == "csp_WoGGGuard" || api == "WoGGGuard"
    }
    public var androidCrawlerName: String {
        api.hasPrefix("csp_") ? String(api.dropFirst(4)) : api
    }
    public var androidCrawlerUnsupportedMessage: String {
        "该视频源依赖 Android 组件，当前 macOS 版本无法加载：\(name.isEmpty ? androidCrawlerName : name)。请切换其他视频源。"
    }
    public var isHidden: Bool { hide == 1 }
    public var isIndex: Bool { indexs == 1 }
    public var isSearchable: Bool { searchable == 1 }
    public var isChangeable: Bool { changeable == 1 }
    public var isQuickSearch: Bool { quickSearch == 1 }
    public var isEmpty: Bool { key.isEmpty && name.isEmpty }

    /// CMS 列表请求的 ac 参数
    public var acParam: String {
        type == 0 ? "videolist" : "detail"
    }

    // MARK: - Codable
    enum CodingKeys: String, CodingKey {
        case key, name, type, api, ext, jar, click, playUrl
        case hide, indexs, timeout, searchable, quickSearch, changeable
        case categories, header, style
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        
        if let typeVal = try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .type) {
            self.type = typeVal.intValue
        } else {
            self.type = 0
        }
        
        self.api = try container.decodeIfPresent(String.self, forKey: .api) ?? ""
        
        if let extVal = try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .ext) {
            self.ext = extVal.stringValue
        } else {
            self.ext = ""
        }
        
        self.jar = try container.decodeIfPresent(String.self, forKey: .jar) ?? ""
        self.click = try container.decodeIfPresent(String.self, forKey: .click) ?? ""
        self.playUrl = try container.decodeIfPresent(String.self, forKey: .playUrl) ?? ""
        
        self.hide = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .hide))?.intValue ?? 0
        self.indexs = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .indexs))?.intValue ?? 0
        self.timeout = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .timeout))?.intValue ?? 15
        self.searchable = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .searchable))?.intValue ?? 1
        self.quickSearch = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .quickSearch))?.intValue ?? 1
        self.changeable = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .changeable))?.intValue ?? 1
        
        self.categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        self.header = try container.decodeIfPresent([String: String].self, forKey: .header) ?? [:]
        self.style = try? container.decodeIfPresent(Style.self, forKey: .style)
        
        self.isSelected = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(api, forKey: .api)
        
        if let extData = ext.data(using: .utf8),
           let extObj = try? JSONDecoder().decode(JSONDynamicValue.self, from: extData) {
            try container.encode(extObj, forKey: .ext)
        } else {
            try container.encode(ext, forKey: .ext)
        }
        
        try container.encode(jar, forKey: .jar)
        try container.encode(click, forKey: .click)
        try container.encode(playUrl, forKey: .playUrl)
        try container.encode(hide, forKey: .hide)
        try container.encode(indexs, forKey: .indexs)
        try container.encode(timeout, forKey: .timeout)
        try container.encode(searchable, forKey: .searchable)
        try container.encode(quickSearch, forKey: .quickSearch)
        try container.encode(changeable, forKey: .changeable)
        try container.encode(categories, forKey: .categories)
        try container.encode(header, forKey: .header)
        try container.encodeIfPresent(style, forKey: .style)
    }

    // MARK: - Hashable
    public static func == (lhs: Site, rhs: Site) -> Bool {
        lhs.key == rhs.key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}

/// 动态JSON解析值类型，兼容String、Number、Bool、Object、Array以及Null
public enum JSONDynamicValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONDynamicValue])
    case array([JSONDynamicValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONDynamicValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONDynamicValue].self) {
            self = .array(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
    
    public var stringValue: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded(.towardZero) == value,
               let integer = Self.safeInt(from: value) {
                return String(integer)
            }
            return String(value)
        case .bool(let value):
            return String(value)
        case .null:
            return ""
        case .object, .array:
            if let data = try? JSONEncoder().encode(self),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return ""
        }
    }

    public var intValue: Int {
        switch self {
        case .string(let value):
            return Int(value) ?? 0
        case .number(let value):
            return Self.safeInt(from: value) ?? 0
        case .bool(let value):
            return value ? 1 : 0
        default:
            return 0
        }
    }

    private static func safeInt(from value: Double) -> Int? {
        guard value.isFinite else { return nil }

        let truncated = value.rounded(.towardZero)
        // Double(Int.max) rounds up to 2^63, which is outside Int's range.
        guard truncated >= Double(Int.min), truncated < Double(Int.max) else {
            return nil
        }
        return Int(truncated)
    }
}
