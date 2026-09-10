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
}
