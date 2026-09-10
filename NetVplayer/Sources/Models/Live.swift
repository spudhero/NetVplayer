// Models/Live.swift
// 直播源模型，对应 FongMi: bean/Live.java

import Foundation

/// 直播源配置
public struct Live: Codable, Identifiable, Sendable {
    public var name: String
    public var type: Int         // 0=直接地址, 1=通过 Spider 加载
    public var url: String
    public var api: String
    public var ext: String
    public var jar: String
    public var click: String
    public var logo: String
    public var epg: String
    public var ua: String
    public var origin: String
    public var referer: String
    public var timeZone: String
    public var keep: String
    public var header: [String: String]
    public var catchup: Catchup?
    public var core: Core?
    public var timeout: Int
    public var boot: Bool
    public var pass: Bool

    // 运行时
    public var groups: [ChannelGroup]
    public var isSelected: Bool

    public var id: String { name }

    public init(
        name: String = "",
        type: Int = 0,
        url: String = "",
        api: String = "",
        ext: String = "",
        jar: String = "",
        click: String = "",
        logo: String = "",
        epg: String = "",
        ua: String = "",
        origin: String = "",
        referer: String = "",
        timeZone: String = "",
        keep: String = "",
        header: [String: String] = [:],
        catchup: Catchup? = nil,
        core: Core? = nil,
        timeout: Int = 15,
        boot: Bool = false,
        pass: Bool = false,
        groups: [ChannelGroup] = [],
        isSelected: Bool = false
    ) {
        self.name = name
        self.type = type
        self.url = url
        self.api = api
        self.ext = ext
        self.jar = jar
        self.click = click
        self.logo = logo
        self.epg = epg
        self.ua = ua
        self.origin = origin
        self.referer = referer
        self.timeZone = timeZone
        self.keep = keep
        self.header = header
        self.catchup = catchup
        self.core = core
        self.timeout = timeout
        self.boot = boot
        self.pass = pass
        self.groups = groups
        self.isSelected = isSelected
    }

    enum CodingKeys: String, CodingKey {
        case name, type, url, api, ext, jar, click, logo, epg, ua, origin, referer
        case timeZone, keep, header, catchup, core, timeout, boot, pass, groups, isSelected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.type = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .type))?.intValue ?? 0
        self.url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.api = try container.decodeIfPresent(String.self, forKey: .api) ?? ""
        self.ext = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .ext))?.stringValue ?? ""
        self.jar = try container.decodeIfPresent(String.self, forKey: .jar) ?? ""
        self.click = try container.decodeIfPresent(String.self, forKey: .click) ?? ""
        self.logo = try container.decodeIfPresent(String.self, forKey: .logo) ?? ""
        self.epg = try container.decodeIfPresent(String.self, forKey: .epg) ?? ""
        self.ua = try container.decodeIfPresent(String.self, forKey: .ua) ?? ""
        self.origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? ""
        self.referer = try container.decodeIfPresent(String.self, forKey: .referer) ?? ""
        self.timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone) ?? ""
        self.keep = try container.decodeIfPresent(String.self, forKey: .keep) ?? ""
        self.header = try container.decodeIfPresent([String: String].self, forKey: .header) ?? [:]
        self.catchup = try? container.decodeIfPresent(Catchup.self, forKey: .catchup)
        self.core = try? container.decodeIfPresent(Core.self, forKey: .core)
        self.timeout = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .timeout))?.intValue ?? 15
        self.boot = try container.decodeIfPresent(Bool.self, forKey: .boot) ?? false
        self.pass = try container.decodeIfPresent(Bool.self, forKey: .pass) ?? false
        self.groups = try container.decodeIfPresent([ChannelGroup].self, forKey: .groups) ?? []
        self.isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false

        applyInheritanceToGroups()
    }

    /// 将 Live 级默认字段继承到内嵌频道，输出 UI/播放器可直接消费的 Channel。
    public mutating func applyInheritanceToGroups() {
        var nextNumber = 1
        groups = groups.map { group in
            var group = group
            group.channels = group.channels.map { channel in
                var channel = channel.applying(live: self)
                if channel.number.isEmpty {
                    channel.number = String(format: "%03d", nextNumber)
                    nextNumber += 1
                }
                return channel
            }
            return group
        }
    }
}
