// PlayerEngine/PlayerState.swift
// 播放状态管理（ObservableObject）

import Foundation
import Models

public enum PlayerTrackKind: String, Codable, Sendable {
    case audio
    case subtitle
}

public enum SubtitleSlot: Hashable, Sendable { case primary, secondary }

public enum SubtitleTrackFormat: Sendable, Equatable {
    case text, styledText, bitmap
    public init(codec: String) {
        let c = codec.lowercased()
        if ["pgs", "hdmv", "dvd", "dvb", "vobsub", "xsub"].contains(where: c.contains) { self = .bitmap }
        else if c == "ass" || c == "ssa" { self = .styledText }
        else { self = .text }
    }
}

public struct PlayerTrackInfo: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var kind: PlayerTrackKind
    public var name: String
    public var language: String
    public var format: String
    public var isExternal: Bool

    public init(
        id: String,
        kind: PlayerTrackKind,
        name: String = "",
        language: String = "",
        format: String = "",
        isExternal: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.language = language
        self.format = format
        self.isExternal = isExternal
    }

    public var subtitleKind: SubtitleTrackFormat {
        SubtitleTrackFormat(codec: format)
    }

    public var displayName: String {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedName.isEmpty { return normalizedName }

        let metadata = [language, format]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.uppercased() }
        if !metadata.isEmpty { return metadata.joined(separator: " · ") }

        return kind == .audio
            ? L10n.text("音轨 {0}", ["\(id)"])
            : L10n.text("字幕 {0}", ["\(id)"])
    }
}

/// 播放状态 — 供 SwiftUI 视图绑定
@MainActor
public final class PlayerState: ObservableObject {
    @Published public var currentSpec: PlaySpec?
    @Published public var endDisposition: PlaybackEndDisposition?
    @Published public var isPlaying: Bool = false
    @Published public var position: Double = 0
    @Published public var duration: Double = 0
    @Published public var bufferedUntil: Double = 0
    @Published public var isMediaLoading: Bool = false
    @Published public var isSeeking: Bool = false
    @Published public var isBuffering: Bool = false
    @Published public var cacheSpeedBytesPerSecond: Int64?
    @Published public var cacheBufferingProgress: Double?
    @Published public var seekReceivedBytes: Int64?
    @Published public var seekTransferSpeedBytesPerSecond: Int64?
    @Published public var speed: Float = 1.0
    @Published public var volume: Float = 1.0
    @Published public var isMuted: Bool = false
    @Published public var videoAspectMode: PlayerVideoAspectMode = .fit
    @Published public var errorMessage: String?
    @Published public var mpvOptionDiagnostics: [MPVOptionDiagnostic] = []
    @Published public var chapters: [PlayerChapter] = []
    @Published public var chapterOwnerID: UUID?
    @Published public var containerEditions: [PlayerEdition] = []
    @Published public var currentContainerEditionID: Int?
    @Published public var audioTracks: [PlayerTrackInfo] = []
    @Published public var subtitleTracks: [PlayerTrackInfo] = []
    @Published public var selectedAudioTrackID: String?
    @Published public var subtitleDelaySeconds: Double = 0
    @Published public var secondarySubtitleDelaySeconds: Double = 0
    @Published public var selectedSecondarySubtitleTrackID: String?
    @Published public var selectedSubtitleTrackID: String?
    @Published public var subtitleStatus: String?
    @Published public var drivePlaybackStatus: String?
    @Published public var drmStatus: String?
    @Published public var danmakuStatus: String?

    public init() {}

    public var hasEnded: Bool {
        endDisposition == .natural || endDisposition == .userSeekBoundary || endDisposition == .premature
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return position / duration
    }

    public var bufferedPosition: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let safePosition = position.isFinite ? max(0, position) : 0
        let safeBufferedUntil = bufferedUntil.isFinite ? max(0, bufferedUntil) : 0
        return min(duration, max(safePosition, safeBufferedUntil))
    }

    public var bufferedProgress: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return bufferedPosition / duration
    }

    public var bufferedAheadDuration: Double {
        let safePosition = position.isFinite ? max(0, position) : 0
        let safeBufferedUntil = bufferedUntil.isFinite ? max(0, bufferedUntil) : 0
        return max(0, safeBufferedUntil - safePosition)
    }

}
