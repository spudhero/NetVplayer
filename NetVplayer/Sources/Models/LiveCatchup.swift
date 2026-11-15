import Foundation

/// Runtime-only ownership. No URLs, headers or credentials are exported as metadata.
public struct LiveCatchupContext: Sendable, Equatable {
    public let sourceFingerprint: String
    public let sourceRevision: UUID
    public let channelFingerprint: String
    public let channelName: String
    public let programme: EpgItem
    public let requestID: UUID
    public let mediaStartOffset: Double
    public let supportsRequestSeek: Bool

    public init(sourceFingerprint: String, sourceRevision: UUID, channelFingerprint: String,
                channelName: String, programme: EpgItem, requestID: UUID = UUID(),
                mediaStartOffset: Double = 0, supportsRequestSeek: Bool) {
        self.sourceFingerprint = sourceFingerprint
        self.sourceRevision = sourceRevision
        self.channelFingerprint = channelFingerprint
        self.channelName = channelName
        self.programme = programme
        self.requestID = requestID
        self.mediaStartOffset = mediaStartOffset
        self.supportsRequestSeek = supportsRequestSeek
    }

    public var duration: Double { programme.end.timeIntervalSince(programme.start) }

    public func programmePosition(mediaPosition: Double) -> Double {
        guard mediaPosition.isFinite else { return mediaStartOffset }
        return min(duration, max(0, mediaStartOffset + mediaPosition))
    }
}

public enum LiveCatchupPhase: Sendable { case idle, loading, playing, failed, ended }

public enum LiveCatchupUnavailableReason: String, Sendable, Error {
    case missingProgramme, invalidProgramme, future, onAir, expired, unsupported
    case invalidTemplate, unknownPlaceholder, unsupportedType, missingTimeZone, staleSource
    case noArchive, archiveUnconfirmed, serverTimeZoneUnknown, ambiguousArchiveTime

    public var message: String {
        switch self {
        case .missingProgramme: L10n.text("没有此时段的节目单，无法选择回放。")
        case .invalidProgramme: L10n.text("节目起止时间无效，无法回放。")
        case .future: L10n.text("节目尚未播出。")
        case .onAir: L10n.text("节目正在播出，请观看直播。")
        case .expired: L10n.text("节目已超出此来源配置的回放保留期。")
        case .unsupported: L10n.text("此频道未配置回放。")
        case .invalidTemplate: L10n.text("回放地址模板无效，请检查来源配置。")
        case .unknownPlaceholder: L10n.text("回放模板含不支持的占位符。")
        case .unsupportedType: L10n.text("此来源的回放类型暂不支持。")
        case .missingTimeZone: L10n.text("此回放模板需要明确的来源时区。")
        case .staleSource: L10n.text("来源已刷新，请重新选择回放节目。")
          case .noArchive: L10n.text("服务端未保留此节目的归档。")
          case .archiveUnconfirmed: L10n.text("尚未取得此节目的历史归档信息。")
          case .serverTimeZoneUnknown: L10n.text("Xtream 服务端未提供有效时区，无法定位归档。")
          case .ambiguousArchiveTime: L10n.text("归档时间存在夏令时歧义，无法准确定位节目。")
        }
    }
}

public struct LiveCatchupRequest: Sendable, Equatable {
    public let url: String
    public let mediaStartOffset: Double
    public let initialPosition: Double?
    public let supportsRequestSeek: Bool

    public init(url: String, mediaStartOffset: Double, initialPosition: Double?, supportsRequestSeek: Bool) {
        self.url = url
        self.mediaStartOffset = mediaStartOffset
        self.initialPosition = initialPosition
        self.supportsRequestSeek = supportsRequestSeek
    }
}

public enum LiveCatchupAvailability: Sendable, Equatable {
    /// A valid request configuration; actual media availability still requires playback.
    case available(LiveCatchupRequest)
    case unavailable(LiveCatchupUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .available: L10n.text("回放")
        case .unavailable(let reason): reason.message
        }
    }
}

public enum LiveCatchupSeekAction: Sendable, Equatable {
    case native(mediaPosition: Double), request(programmePosition: Double), finish, unsupported
}
