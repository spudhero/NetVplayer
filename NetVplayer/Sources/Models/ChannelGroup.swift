// Models/ChannelGroup.swift
// 频道分组模型，对应 FongMi: bean/Group.java

import Foundation

/// 直播频道分组
public struct ChannelGroup: Codable, Identifiable, Sendable {
    public var name: String
    public var logo: String
    public var channels: [Channel]
    public var isHidden: Bool
    public var password: String

    public var id: String { name }

    public init(
        name: String = "",
        logo: String = "",
        channels: [Channel] = [],
        isHidden: Bool = false,
        password: String = ""
    ) {
        self.name = name
        self.logo = logo
        self.channels = channels
        self.isHidden = isHidden
        self.password = password
    }

    enum CodingKeys: String, CodingKey {
        case name, logo, channels, channel, isHidden, password, pass
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.logo = try container.decodeIfPresent(String.self, forKey: .logo) ?? ""
        self.channels = try container.decodeIfPresent([Channel].self, forKey: .channels)
            ?? container.decodeIfPresent([Channel].self, forKey: .channel)
            ?? []
        self.password = try container.decodeIfPresent(String.self, forKey: .password)
            ?? container.decodeIfPresent(String.self, forKey: .pass)
            ?? ""
        self.isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? !password.isEmpty
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(logo, forKey: .logo)
        try container.encode(channels, forKey: .channels)
        try container.encode(channels, forKey: .channel)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encode(password, forKey: .password)
        try container.encode(password, forKey: .pass)
    }

    public func applying(live: Live) -> ChannelGroup {
        var group = self
        group.channels = channels.enumerated().map { index, channel in
            var inherited = channel.applying(live: live)
            if inherited.number.isEmpty {
                inherited.number = String(format: "%03d", index + 1)
            }
            return inherited
        }
        return group
    }
}
