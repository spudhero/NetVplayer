// Models/Channel.swift
// 直播频道模型，对应 FongMi: bean/Channel.java

import Foundation

/// 直播频道
public struct Channel: Codable, Identifiable, Sendable {
    public var name: String
    public var number: String
    public var logo: String
    public var epg: String
    public var epgName: String
    public var tvgId: String
    public var tvgName: String
    public var urls: [String]
    public var ua: String
    public var origin: String
    public var referer: String
    public var header: [String: String]
    public var catchup: Catchup?
    public var drm: Drm?
    public var parseFlag: Int
    public var clickScript: String
    public var format: String
    public var currentUrlIndex: Int

    public var id: String { "\(name)_\(number)" }

    public init(
        name: String = "",
        number: String = "",
        logo: String = "",
        epg: String = "",
        epgName: String = "",
        tvgId: String = "",
        tvgName: String = "",
        urls: [String] = [],
        ua: String = "",
        origin: String = "",
        referer: String = "",
        header: [String: String] = [:],
        catchup: Catchup? = nil,
        drm: Drm? = nil,
        parseFlag: Int = 0,
        clickScript: String = "",
        format: String = "",
        currentUrlIndex: Int = 0
    ) {
        self.name = name
        self.number = number
        self.logo = logo
        self.epg = epg
        self.epgName = epgName
        self.tvgId = tvgId
        self.tvgName = tvgName
        self.urls = urls
        self.ua = ua
        self.origin = origin
        self.referer = referer
        self.header = header
        self.catchup = catchup
        self.drm = drm
        self.parseFlag = parseFlag
        self.clickScript = clickScript
        self.format = format
        self.currentUrlIndex = currentUrlIndex
    }

    /// 当前播放 URL
    public var currentUrl: String? {
        guard currentUrlIndex >= 0 && currentUrlIndex < urls.count else { return nil }
        return urls[currentUrlIndex]
    }

    /// 组装请求头
    public var requestHeaders: [String: String] {
        var headers = header
        if !ua.isEmpty { headers["User-Agent"] = ua }
        if !origin.isEmpty { headers["Origin"] = origin }
        if !referer.isEmpty { headers["Referer"] = referer }
        return headers
    }

    enum CodingKeys: String, CodingKey {
        case name, number, logo, epg, epgName, tvgId, tvgName, urls, ua, origin, referer
        case header, catchup, drm, parse, click, format, currentUrlIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.number = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .number))?.stringValue ?? ""
        self.logo = try container.decodeIfPresent(String.self, forKey: .logo) ?? ""
        self.epg = try container.decodeIfPresent(String.self, forKey: .epg) ?? ""
        self.tvgId = try container.decodeIfPresent(String.self, forKey: .tvgId) ?? ""
        self.tvgName = try container.decodeIfPresent(String.self, forKey: .tvgName) ?? ""
        self.epgName = try container.decodeIfPresent(String.self, forKey: .epgName) ?? tvgName
        if self.epgName.isEmpty { self.epgName = self.name }

        if let urls = try? container.decode([String].self, forKey: .urls) {
            self.urls = urls
        } else if let url = try? container.decode(String.self, forKey: .urls) {
            self.urls = [url]
        } else {
            self.urls = []
        }

        self.ua = try container.decodeIfPresent(String.self, forKey: .ua) ?? ""
        self.origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? ""
        self.referer = try container.decodeIfPresent(String.self, forKey: .referer) ?? ""
        self.header = try container.decodeIfPresent([String: String].self, forKey: .header) ?? [:]
        self.catchup = try? container.decodeIfPresent(Catchup.self, forKey: .catchup)
        self.drm = try? container.decodeIfPresent(Drm.self, forKey: .drm)
        self.parseFlag = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .parse))?.intValue ?? 0
        self.clickScript = try container.decodeIfPresent(String.self, forKey: .click) ?? ""
        self.format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
        self.currentUrlIndex = (try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .currentUrlIndex))?.intValue ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(number, forKey: .number)
        try container.encode(logo, forKey: .logo)
        try container.encode(epg, forKey: .epg)
        try container.encode(epgName, forKey: .epgName)
        try container.encode(tvgId, forKey: .tvgId)
        try container.encode(tvgName, forKey: .tvgName)
        try container.encode(urls, forKey: .urls)
        try container.encode(ua, forKey: .ua)
        try container.encode(origin, forKey: .origin)
        try container.encode(referer, forKey: .referer)
        try container.encode(header, forKey: .header)
        try container.encodeIfPresent(catchup, forKey: .catchup)
        try container.encodeIfPresent(drm, forKey: .drm)
        try container.encode(parseFlag, forKey: .parse)
        try container.encode(clickScript, forKey: .click)
        try container.encode(format, forKey: .format)
        try container.encode(currentUrlIndex, forKey: .currentUrlIndex)
    }

    public func applying(live: Live) -> Channel {
        var channel = self
        if channel.ua.isEmpty { channel.ua = live.ua }
        if channel.clickScript.isEmpty { channel.clickScript = live.click }
        if channel.header.isEmpty { channel.header = live.header }
        if channel.origin.isEmpty { channel.origin = live.origin }
        if channel.referer.isEmpty { channel.referer = live.referer }
        if channel.catchup == nil { channel.catchup = live.catchup }

        let id = channel.tvgId.isEmpty ? (channel.tvgName.isEmpty ? channel.name : channel.tvgName) : channel.tvgId
        let epgName = channel.tvgName.isEmpty ? channel.name : channel.tvgName
        if live.epg.contains("{"), !channel.epg.hasPrefix("http") {
            channel.epg = live.epg
                .replacingOccurrences(of: "{id}", with: id)
                .replacingOccurrences(of: "{name}", with: epgName)
                .replacingOccurrences(of: "{epg}", with: channel.epg)
        }
        if live.logo.contains("{"), !channel.logo.hasPrefix("http") {
            channel.logo = live.logo
                .replacingOccurrences(of: "{id}", with: id)
                .replacingOccurrences(of: "{name}", with: epgName)
                .replacingOccurrences(of: "{logo}", with: channel.logo)
        } else if channel.logo.isEmpty, !live.logo.contains("{") {
            channel.logo = live.logo
        }
        return channel
    }
}
