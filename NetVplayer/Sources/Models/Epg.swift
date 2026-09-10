// Models/Epg.swift
// EPG 节目单模型

import Foundation

/// EPG 节目条目
public struct EpgItem: Codable, Identifiable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date

    public var id: String { "\(title)_\(start.timeIntervalSince1970)" }

    public init(title: String = "", start: Date = Date(), end: Date = Date()) {
        self.title = title
        self.start = start
        self.end = end
    }

    /// 是否正在播出
    public var isLive: Bool {
        let now = Date()
        return now >= start && now <= end
    }
}

/// EPG 数据
public struct EpgData: Codable, Sendable {
    public var channelName: String
    public var items: [EpgItem]

    public init(channelName: String = "", items: [EpgItem] = []) {
        self.channelName = channelName
        self.items = items
    }
}
