// Models/Epg.swift
// EPG 节目单模型

import Foundation

/// EPG 节目条目
public struct EpgItem: Codable, Identifiable, Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var xtreamArchive: XtreamProgrammeArchive?

    // Archive evidence belongs to the current provider/source session, never a disk EPG.
    enum CodingKeys: String, CodingKey { case title, start, end }

    public var id: String { "\(title)_\(start.timeIntervalSince1970)" }

    public init(title: String = "", start: Date = Date(), end: Date = Date(), xtreamArchive: XtreamProgrammeArchive? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.xtreamArchive = xtreamArchive
    }

    /// 是否正在播出
    public var isLive: Bool {
        let now = Date()
        return now >= start && now < end
    }
}

/// EPG 数据
public struct EpgData: Codable, Sendable, Equatable {
    public var channelName: String
    public var items: [EpgItem]

    public init(channelName: String = "", items: [EpgItem] = []) {
        self.channelName = channelName
        self.items = items
    }
}

public enum EpgAvailability: String, Sendable { case available, empty, stale, unavailable, unconfigured }
public enum EpgCoverage: Sendable { case unspecified, xtreamHistory, xtreamShort }

public struct EpgLoadResult: Sendable {
    public var data: EpgData
    public var availability: EpgAvailability
    public var message: String?
    public var coverage: EpgCoverage
    public var discardsPreviousData: Bool
    public init(data: EpgData, availability: EpgAvailability, message: String? = nil,
                coverage: EpgCoverage = .unspecified, discardsPreviousData: Bool = false) {
        self.data = data
        self.availability = availability
        self.message = message
        self.coverage = coverage
        self.discardsPreviousData = discardsPreviousData
    }
}
