// Models/Core.swift
// 直播内核配置模型，对应 FongMi: bean/Core.java

import Foundation

/// 直播内核配置。首版只承接配置合同，具体 TVBus/Hook 能力由 Source/Player 阶段决定。
public struct Core: Codable, Hashable, Sendable {
    public var auth: String
    public var name: String
    public var pass: String
    public var broker: String
    public var domain: String
    public var resp: String
    public var sign: String
    public var pkg: String
    public var so: String
    public var key: String
    public var option: [CoreOption]

    public init(
        auth: String = "",
        name: String = "",
        pass: String = "",
        broker: String = "",
        domain: String = "",
        resp: String = "",
        sign: String = "",
        pkg: String = "",
        so: String = "",
        key: String = "",
        option: [CoreOption] = []
    ) {
        self.auth = auth
        self.name = name
        self.pass = pass
        self.broker = broker
        self.domain = domain
        self.resp = resp
        self.sign = sign
        self.pkg = pkg
        self.so = so
        self.key = key
        self.option = option
    }

    enum CodingKeys: String, CodingKey {
        case auth, name, pass, broker, domain, resp, sign, pkg, so, key, option
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.auth = try container.decodeIfPresent(String.self, forKey: .auth) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.pass = try container.decodeIfPresent(String.self, forKey: .pass) ?? ""
        self.broker = try container.decodeIfPresent(String.self, forKey: .broker) ?? ""
        self.domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? ""
        self.resp = try container.decodeIfPresent(String.self, forKey: .resp) ?? ""
        self.sign = try container.decodeIfPresent(String.self, forKey: .sign) ?? ""
        self.pkg = try container.decodeIfPresent(String.self, forKey: .pkg) ?? ""
        self.so = try container.decodeIfPresent(String.self, forKey: .so) ?? ""
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.option = try container.decodeIfPresent([CoreOption].self, forKey: .option) ?? []
    }
}

public struct CoreOption: Codable, Hashable, Sendable {
    public var key: String
    public var values: [String]

    public init(key: String = "", values: [String] = []) {
        self.key = key
        self.values = values
    }

    enum CodingKeys: String, CodingKey {
        case key, values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.values = try container.decodeIfPresent([String].self, forKey: .values) ?? []
    }
}
