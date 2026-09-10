// PlayerEngine/PlayerEngine.swift
// 播放引擎通用协议与策略。

import Foundation
import Models

/// 播放器状态
public enum PlayerStatus: Sendable {
    case idle
    case loading
    case playing
    case paused
    case error(String)
}

public enum PlayerVideoAspectMode: String, CaseIterable, Codable, Sendable {
    case fit
    case fill
    case wide16x9
    case classic4x3

    public var displayName: String {
        switch self {
        case .fit:
            return "原始"
        case .fill:
            return "填满"
        case .wide16x9:
            return "16:9"
        case .classic4x3:
            return "4:3"
        }
    }

    public var menuTitle: String {
        switch self {
        case .fit:
            return "原始比例（自动适应）"
        case .fill:
            return "填满窗口（裁切边缘）"
        case .wide16x9:
            return "固定比例 16:9"
        case .classic4x3:
            return "固定比例 4:3"
        }
    }

    public var mpvVideoAspectOverride: String {
        switch self {
        case .fit, .fill:
            return "no"
        case .wide16x9:
            return "16:9"
        case .classic4x3:
            return "4:3"
        }
    }

    public var mpvPanscan: Double {
        self == .fill ? 1.0 : 0.0
    }

}

/// 播放器通用 seek 归一化策略。
public enum PlayerSeekPolicy {
    public static func normalizedSeekSeconds(positionMilliseconds: Int64, durationSeconds: Double) -> Double? {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        let requestedSeconds = max(0, Double(positionMilliseconds) / 1000)
        return min(requestedSeconds, durationSeconds)
    }
}

/// mpv 字幕渲染偏好。默认覆盖片源异常样式，避免内嵌字幕被放到夸张字号。
public struct SubtitleRenderSettings: Equatable, Sendable {
    public static let defaultFontSize = 44
    public static let defaultPosition = 95
    public static let defaultOverrideSourceStyle = true
    public static let defaultFontName = "PingFang SC"

    public var fontSize: Int
    public var position: Int
    public var overrideSourceStyle: Bool
    public var fontName: String

    public init(
        fontSize: Int = Self.defaultFontSize,
        position: Int = Self.defaultPosition,
        overrideSourceStyle: Bool = Self.defaultOverrideSourceStyle,
        fontName: String = Self.defaultFontName
    ) {
        self.fontSize = min(max(fontSize, 16), 72)
        self.position = min(max(position, 0), 100)
        self.overrideSourceStyle = overrideSourceStyle
        self.fontName = fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultFontName
            : fontName
    }
}

public enum PlayerSubtitlePolicy {
    public static func mpvOptions(for settings: SubtitleRenderSettings) -> [String: String] {
        [
            "sub-ass-override": settings.overrideSourceStyle ? "strip" : "no",
            "secondary-sub-ass-override": settings.overrideSourceStyle ? "strip" : "no",
            "sub-font": settings.fontName,
            "sub-font-size": "\(settings.fontSize)",
            "sub-pos": "\(settings.position)",
            "sub-align-x": "center",
            "sub-align-y": "bottom",
            "sub-border-size": "2",
            "sub-shadow-offset": "0",
            "sub-scale": "1.0",
            "sub-scale-by-window": "yes",
            "sub-scale-with-window": "yes",
            "sub-use-margins": "no",
            "sub-ass-force-margins": "yes",
            "sub-ass-use-video-data": "none",
            "secondary-sid": "no",
            "secondary-sub-visibility": "no"
        ]
    }

    public static func mergedMPVOptions(
        sourceOptions: [String: String],
        settings: SubtitleRenderSettings
    ) -> [String: String] {
        sourceOptions.merging(mpvOptions(for: settings)) { _, userPreference in userPreference }
    }

    public static func preferredInitialSubtitleTrack(
        from tracks: [PlayerTrackInfo],
        selectedID: String?
    ) -> PlayerTrackInfo? {
        let chineseTracks = tracks
            .filter { $0.kind == .subtitle && !$0.isExternal && isChineseTrack($0) }
            .sorted { trackSortKey($0.id) < trackSortKey($1.id) }
        guard let preferred = chineseTracks.first else { return nil }
        return preferred.id == selectedID ? nil : preferred
    }

    private static func isChineseTrack(_ track: PlayerTrackInfo) -> Bool {
        let value = [
            track.id,
            track.name,
            track.language,
            track.format
        ]
        .joined(separator: " ")
        .lowercased()
        return value.contains("chi")
            || value.contains("zho")
            || value.contains("zh")
            || value.contains("cmn")
            || value.contains("chs")
            || value.contains("cht")
            || value.contains("中文")
            || value.contains("简")
            || value.contains("繁")
    }

    private static func trackSortKey(_ id: String) -> Int {
        Int(id.filter(\.isNumber)) ?? Int.max
    }
}

public struct MPVParsedTrackLog: Equatable, Sendable {
    public var track: PlayerTrackInfo
    public var isSelected: Bool

    public init(track: PlayerTrackInfo, isSelected: Bool) {
        self.track = track
        self.isSelected = isSelected
    }
}

public enum MPVTrackLogParser {
    public static func parsedTrack(from text: String) -> MPVParsedTrackLog? {
        let kind: PlayerTrackKind
        let idPattern: String
        let languagePattern: String
        if text.contains("--sid="), text.contains("Subs") {
            kind = .subtitle
            idPattern = #"--sid=([^\s]+)"#
            languagePattern = #"--slang=([^\s]+)"#
        } else if text.contains("--aid="), text.contains("Audio") {
            kind = .audio
            idPattern = #"--aid=([^\s]+)"#
            languagePattern = #"--alang=([^\s]+)"#
        } else {
            return nil
        }

        guard let id = firstCapture(pattern: idPattern, in: text), id != "no" else {
            return nil
        }
        let language = firstCapture(pattern: languagePattern, in: text) ?? ""
        let format = firstCapture(pattern: #"\(([^)]*)\)"#, in: text) ?? ""
        let track = PlayerTrackInfo(
            id: id,
            kind: kind,
            language: language,
            format: format,
            isExternal: false
        )
        return MPVParsedTrackLog(track: track, isSelected: text.contains("●"))
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}

public enum PlaybackResumePolicy {
    public static func episodeURL(for spec: PlaySpec) -> String {
        spec.metadata["vod.episodeURL"] ?? spec.url
    }

    public static func canRestoreHistoryPosition(position: Int64, episodeURL historyEpisodeURL: String, spec: PlaySpec) -> Bool {
        guard position > 0, spec.metadata["playback.kind"] != "live" else { return false }
        return historyEpisodeURL == episodeURL(for: spec)
    }

    public static func isSeekReady(durationSeconds: Double) -> Bool {
        durationSeconds.isFinite && durationSeconds > 0
    }

    public static func normalizedRestorePositionMilliseconds(position: Int64, durationSeconds: Double) -> Int64? {
        guard isSeekReady(durationSeconds: durationSeconds), position > 0 else { return nil }
        let requestedSeconds = Double(position) / 1000
        guard requestedSeconds.isFinite else { return nil }
        let endBoundary = durationSeconds - resumeEndGuardSeconds(durationSeconds: durationSeconds)
        guard requestedSeconds < endBoundary else { return nil }
        return position
    }

    private static func resumeEndGuardSeconds(durationSeconds: Double) -> Double {
        min(30, max(5, durationSeconds * 0.02))
    }
}

public enum PlaybackStartPolicy {
    public static func canApply(episodeURL: String, spec: PlaySpec) -> Bool {
        guard !episodeURL.isEmpty, spec.metadata["playback.kind"] != "live" else { return false }
        return episodeURL == PlaybackResumePolicy.episodeURL(for: spec)
    }

    public static func normalizedStartPositionMilliseconds(
        resumePosition: Int64?,
        openingSkipSeconds: Int,
        durationSeconds: Double
    ) -> Int64? {
        let normalizedResume = resumePosition.flatMap {
            PlaybackResumePolicy.normalizedRestorePositionMilliseconds(
                position: $0,
                durationSeconds: durationSeconds
            )
        }
        let openingPosition = Int64(max(0, openingSkipSeconds)) * 1_000
        let normalizedOpening = PlaybackResumePolicy.normalizedRestorePositionMilliseconds(
            position: openingPosition,
            durationSeconds: durationSeconds
        )
        let target = max(normalizedResume ?? 0, normalizedOpening ?? 0)
        return target > 0 ? target : nil
    }
}

public enum PlaybackEndDisposition: Equatable, Sendable {
    case natural
    case userSeekBoundary
    case premature
    case stopped
    case failed
    case ignored
}

struct PlaybackPostSeekEndGuard: Equatable, Sendable {
    static let requiredForwardProgressSeconds: Double = 3
    static let maximumContinuousDeltaSeconds: Double = 5

    private(set) var targetSeconds: Double?
    private var didRestartPlayback = false
    private var lastPositionSeconds: Double?
    private var continuousForwardProgressSeconds: Double = 0

    var isProtecting: Bool { targetSeconds != nil }

    mutating func begin(targetSeconds: Double) {
        guard targetSeconds.isFinite, targetSeconds >= 0 else {
            reset()
            return
        }
        self.targetSeconds = targetSeconds
        didRestartPlayback = false
        lastPositionSeconds = nil
        continuousForwardProgressSeconds = 0
    }

    mutating func markPlaybackRestarted() {
        guard isProtecting else { return }
        didRestartPlayback = true
        lastPositionSeconds = nil
        continuousForwardProgressSeconds = 0
    }

    mutating func observePosition(_ positionSeconds: Double) {
        guard positionSeconds.isFinite, isProtecting else { return }
        if !didRestartPlayback {
            didRestartPlayback = true
            lastPositionSeconds = positionSeconds
            return
        }
        guard let previous = lastPositionSeconds else {
            lastPositionSeconds = positionSeconds
            return
        }

        let delta = positionSeconds - previous
        if delta > 0, delta <= Self.maximumContinuousDeltaSeconds {
            continuousForwardProgressSeconds += delta
        } else if delta < 0 || delta > Self.maximumContinuousDeltaSeconds {
            continuousForwardProgressSeconds = 0
        }
        lastPositionSeconds = positionSeconds
        if continuousForwardProgressSeconds >= Self.requiredForwardProgressSeconds {
            reset()
        }
    }

    func isBoundarySeek(
        positionSeconds: Double,
        durationSeconds: Double,
        completionToleranceSeconds: Double = 3
    ) -> Bool {
        guard let targetSeconds,
              positionSeconds.isFinite,
              durationSeconds.isFinite,
              durationSeconds > 0 else { return false }
        let boundary = max(0, durationSeconds - max(0, completionToleranceSeconds))
        return targetSeconds >= boundary || positionSeconds >= boundary
    }

    mutating func reset() {
        targetSeconds = nil
        didRestartPlayback = false
        lastPositionSeconds = nil
        continuousForwardProgressSeconds = 0
    }
}

public enum PlaybackAutoAdvancePolicy {
    public static let naturalEndReason: Int32 = 0
    public static let stoppedEndReason: Int32 = 2

    public static func isNaturalEnd(reason: Int32, error: Int32) -> Bool {
        reason == naturalEndReason && error >= 0
    }

    public static func shouldAdvanceAfterNaturalEnd(
        reason: Int32,
        error: Int32,
        playbackStarted: Bool
    ) -> Bool {
        playbackStarted && isNaturalEnd(reason: reason, error: error)
    }

    public static func endDisposition(
        reason: Int32,
        error: Int32,
        isReplacingMedia: Bool,
        playbackStarted: Bool,
        isPausedForCache: Bool,
        positionSeconds: Double,
        durationSeconds: Double,
        isProtectedByUserSeek: Bool,
        isUserSeekToBoundary: Bool = false,
        completionToleranceSeconds: Double = 3
    ) -> PlaybackEndDisposition {
        guard !isReplacingMedia else { return .ignored }
        if reason == stoppedEndReason { return .stopped }
        if error < 0 { return .failed }
        guard reason == naturalEndReason else { return .premature }
        if isProtectedByUserSeek {
            return isUserSeekToBoundary ? .userSeekBoundary : .premature
        }
        guard playbackStarted,
              !isPausedForCache,
              positionSeconds.isFinite,
              durationSeconds.isFinite else {
            return .premature
        }
        guard durationSeconds > 0 else { return .natural }
        let tolerance = max(0, completionToleranceSeconds)
        return positionSeconds >= max(0, durationSeconds - tolerance)
            ? .natural
            : .premature
    }

    public static func shouldAdvance(
        positionSeconds: Double,
        durationSeconds: Double,
        endingSkipSeconds: Int,
        hasNextEpisode: Bool
    ) -> Bool {
        guard hasNextEpisode,
              endingSkipSeconds > 0,
              positionSeconds.isFinite,
              durationSeconds.isFinite,
              positionSeconds > 0,
              durationSeconds > Double(endingSkipSeconds) else {
            return false
        }
        let remaining = durationSeconds - positionSeconds
        return remaining > 0 && remaining <= Double(endingSkipSeconds)
    }

    public static func canRequestAdvance(
        episodeURL: String,
        currentEpisodeURL: String,
        inFlightEpisodeURL: String?,
        hasNextEpisode: Bool,
        isLoading: Bool
    ) -> Bool {
        !episodeURL.isEmpty
            && episodeURL == currentEpisodeURL
            && inFlightEpisodeURL != episodeURL
            && hasNextEpisode
            && !isLoading
    }
}
