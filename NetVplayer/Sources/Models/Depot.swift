// Models/Depot.swift
// 配置仓库模型，对应 FongMi: bean/Depot.java

import Foundation

/// 配置仓库中的子配置
public struct Depot: Codable, Sendable {
    public var name: String
    public var url: String

    public init(name: String = "", url: String = "") {
        self.name = name
        self.url = url
    }
}
