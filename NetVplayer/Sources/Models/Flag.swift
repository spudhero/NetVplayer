// Models/Flag.swift
// 播放线路模型，对应 FongMi: bean/Flag.java

import Foundation

/// 播放线路（如"极速专线"、"高清官源"）
public struct Flag: Codable, Identifiable, Sendable {
    public var name: String
    public var episodes: [Episode]
    public var isSelected: Bool

    public var id: String { name }

    public init(name: String = "", episodes: [Episode] = [], isSelected: Bool = false) {
        self.name = name
        self.episodes = episodes
        self.isSelected = isSelected
    }
}
