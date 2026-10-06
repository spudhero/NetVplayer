// Models/Rule.swift
// 广告规则模型

import Foundation

/// 广告规则
public struct Rule: Codable, Sendable {
    public var name: String
    public var hosts: [String]
    public var regex: [String]
    public var script: [String]

    public init(name: String = "", hosts: [String] = [], regex: [String] = [], script: [String] = []) {
        self.name = name
        self.hosts = hosts
        self.regex = regex
        self.script = script
    }
}
