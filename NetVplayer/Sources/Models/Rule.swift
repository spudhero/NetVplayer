// Models/Rule.swift
// 广告规则模型

import Foundation

/// 广告规则
public struct Rule: Codable, Sendable {
    public var name: String
    public var hosts: [String]
    public var regex: [String]
    public var script: [String]
    public var exclude: [String]

    public init(name: String = "", hosts: [String] = [], regex: [String] = [], script: [String] = [], exclude: [String] = []) {
        self.name = name
        self.hosts = hosts
        self.regex = regex
        self.script = script
        self.exclude = exclude
    }

    private enum CodingKeys: String, CodingKey { case name, hosts, regex, script, exclude }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        hosts = try values.decodeIfPresent([String].self, forKey: .hosts) ?? []
        regex = try values.decodeIfPresent([String].self, forKey: .regex) ?? []
        script = try values.decodeIfPresent([String].self, forKey: .script) ?? []
        exclude = try values.decodeIfPresent([String].self, forKey: .exclude) ?? []
    }
}
