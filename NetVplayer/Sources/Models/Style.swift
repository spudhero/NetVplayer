// Models/Style.swift
// UI 样式模型，对应 FongMi: bean/Style.java

import Foundation

/// 卡片展示样式
public struct Style: Codable, Sendable {
    public var type: String   // rect / oval / list
    public var ratio: Float   // 宽高比

    public init(type: String = "rect", ratio: Float = 0.75) {
        self.type = type
        self.ratio = ratio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "rect"
        
        if let ratioVal = try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .ratio) {
            self.ratio = Float(ratioVal.stringValue) ?? 0.75
        } else {
            self.ratio = 0.75
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(ratio, forKey: .ratio)
    }

    enum CodingKeys: String, CodingKey {
        case type, ratio
    }
}
