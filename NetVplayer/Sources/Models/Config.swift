// Models/Config.swift
// 配置实体模型，对应 FongMi: bean/Config.java

import Foundation

/// 配置类型
public enum ConfigType: Int, Codable, Sendable {
    case vod = 0
    case live = 1
    case wall = 2
}

/// 用户保存的配置源
public struct Config: Codable, Identifiable, Sendable {
    public var id: Int
    public var type: ConfigType
    public var url: String
    public var name: String
    public var logo: String
    public var home: String     // 当前选中的站点 key
    public var parse: String    // 当前选中的解析器 name
    public var notice: String
    public var danmaku: String
    public var json: String     // 缓存的原始 JSON

    public init(
        id: Int = 0,
        type: ConfigType = .vod,
        url: String = "",
        name: String = "",
        logo: String = "",
        home: String = "",
        parse: String = "",
        notice: String = "",
        danmaku: String = "",
        json: String = ""
    ) {
        self.id = id
        self.type = type
        self.url = url
        self.name = name
        self.logo = logo
        self.home = home
        self.parse = parse
        self.notice = notice
        self.danmaku = danmaku
        self.json = json
    }

    public static func vod(url: String = "") -> Config {
        Config(type: .vod, url: url)
    }

}
