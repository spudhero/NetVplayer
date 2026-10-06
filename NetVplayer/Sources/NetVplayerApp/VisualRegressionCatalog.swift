// NetVplayerApp/VisualRegressionCatalog.swift
// Lightweight reproducible UI states for screenshot/visual regression work.

import Foundation
import Models
import PlayerEngine

enum VisualRegressionSurface: String, CaseIterable {
    case playerHUD
    case webHomeDebugPanel
    case danmakuOverlay
    case searchDriveGrouping
    case settingsDiagnostics
    case playbackErrorPanel
}

struct VisualRegressionScenario: Equatable, Identifiable {
    var id: String
    var surface: VisualRegressionSurface
    var title: String
    var stateSummary: String
    var viewport: String
    var capturesSensitiveData: Bool
    var fixtureAssetPath: String? = nil
    var captureStates: [String] = []
    var responsiveViewports: [String] = []
}

enum VisualRegressionScenarioCatalog {
    static let requiredScenarios: [VisualRegressionScenario] = [
        VisualRegressionScenario(
            id: "player-hud-normal",
            surface: .playerHUD,
            title: L10n.text("点播播放器 HUD"),
            stateSummary: L10n.text("OpenDesign 同源背景、标题、线路、时间和状态 badge"),
            viewport: "1480x833",
            capturesSensitiveData: false,
            fixtureAssetPath: "docs/design/player-ui/assets/w700d1q75cms.jpg",
            captureStates: [
                "normal",
                "settings-drawer",
                "subtitle-settings",
                "episode-drawer",
                "skip-dialog",
                "warning",
                "error",
                "loading",
                "buffering",
                "hud-hidden",
                "ended",
                "time-preview",
                "chapter-navigation",
                "chapter-preview",
            ],
            responsiveViewports: ["1480x833", "1200x675", "427x240", "fullscreen-16:10"]
        ),
        VisualRegressionScenario(
            id: "webhome-debug-panel",
            surface: .webHomeDebugPanel,
            title: L10n.text("WebHome 调试面板"),
            stateSummary: L10n.text("本地 demo、bridge 调用日志、URL 校验和 cache key 数量"),
            viewport: "1280x860",
            capturesSensitiveData: false
        ),
        VisualRegressionScenario(
            id: "danmaku-overlay-limited",
            surface: .danmakuOverlay,
            title: L10n.text("弹幕 overlay 限流"),
            stateSummary: L10n.text("缓存命中、最多 120 条可见 cue、字号/透明度生效"),
            viewport: "1440x900",
            capturesSensitiveData: false
        ),
        VisualRegressionScenario(
            id: "search-drive-grouping",
            surface: .searchDriveGrouping,
            title: L10n.text("搜索网盘分组"),
            stateSummary: L10n.text("Quark/UC/Ali/115/PikPak/其它分组和状态 badge"),
            viewport: "1280x860",
            capturesSensitiveData: false
        ),
        VisualRegressionScenario(
            id: "settings-diagnostics",
            surface: .settingsDiagnostics,
            title: L10n.text("设置诊断面板"),
            stateSummary: L10n.text("配置聚合、站点健康、WebHome 和样本状态诊断"),
            viewport: "1280x860",
            capturesSensitiveData: false
        ),
        VisualRegressionScenario(
            id: "playback-error-panel",
            surface: .playbackErrorPanel,
            title: L10n.text("播放错误面板"),
            stateSummary: L10n.text("provider/scenario/sampleStatus/relay mode/弹幕解析状态"),
            viewport: "1440x900",
            capturesSensitiveData: false
        )
    ]

    static func missingRequiredSurfaces(
        in scenarios: [VisualRegressionScenario] = requiredScenarios
    ) -> [VisualRegressionSurface] {
        let present = Set(scenarios.map(\.surface))
        return VisualRegressionSurface.allCases.filter { !present.contains($0) }
    }

    static func unsafeScenarios(
        in scenarios: [VisualRegressionScenario] = requiredScenarios
    ) -> [VisualRegressionScenario] {
        scenarios.filter(\.capturesSensitiveData)
    }
}

enum PlayerVisualRegressionState: String, CaseIterable {
    case normal
    case settingsDrawer = "settings-drawer"
    case subtitleSettings = "subtitle-settings"
    case episodeDrawer = "episode-drawer"
    case skipDialog = "skip-dialog"
    case warning
    case error
    case loading
    case buffering
    case hudHidden = "hud-hidden"
    case ended
    case timePreview = "time-preview"
    case chapterNavigation = "chapter-navigation"
    case chapterPreview = "chapter-preview"
}

struct PlayerVisualRegressionConfiguration: Equatable {
    static let stateArgument = "--visual-regression-player"
    static let fixtureArgument = "--visual-regression-fixture"
    static let viewportArgument = "--visual-regression-viewport"
    static let outputArgument = "--visual-regression-output"
    static let defaultViewport = CGSize(width: 1480, height: 833)

    var state: PlayerVisualRegressionState
    var fixtureURL: URL?
    var viewport: CGSize
    var outputURL: URL?

    static var current: PlayerVisualRegressionConfiguration? {
        parse(arguments: ProcessInfo.processInfo.arguments)
    }

    static func parse(arguments: [String]) -> PlayerVisualRegressionConfiguration? {
        guard let rawState = value(for: stateArgument, in: arguments),
              let state = PlayerVisualRegressionState(rawValue: rawState) else {
            return nil
        }

        let fixtureURL = value(for: fixtureArgument, in: arguments)
            .map { URL(fileURLWithPath: $0) }
        let outputURL = value(for: outputArgument, in: arguments)
            .map { URL(fileURLWithPath: $0) }
        let viewport = value(for: viewportArgument, in: arguments)
            .flatMap(parseViewport) ?? defaultViewport

        return PlayerVisualRegressionConfiguration(
            state: state,
            fixtureURL: fixtureURL,
            viewport: viewport,
            outputURL: outputURL
        )
    }

    @MainActor
    func apply(to appState: AppState) {
        let playerState = appState.playerState
        playerState.currentSpec = PlaySpec(
            title: L10n.text("南部档案 - 第02集"),
            flag: L10n.text("极速源"),
            siteKey: "visual-regression"
        )
        playerState.currentSpec?.metadata["vod.pic"] = fixtureURL?.absoluteString ?? ""
        playerState.currentSpec?.metadata["vod.name"] = L10n.text("南部档案")
        playerState.isPlaying = false
        playerState.endDisposition = state == .ended ? .natural : nil
        playerState.position = 1_185
        playerState.duration = 8_538
        if state == .chapterNavigation || state == .chapterPreview {
            playerState.position = 42
            playerState.duration = 6_913
            playerState.chapters = [0.0, 287, 645, 952, 1_217, 1_406, 1_886, 2_202, 2_397,
                2_922, 3_329, 3_608, 4_305, 4_684, 5_330, 6_033, 6_327].enumerated().map { index, seconds in
                PlayerChapter(id: index, title: "Chapter \(index + 1)", seconds: seconds)
            }
            playerState.chapterOwnerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        }
        playerState.bufferedUntil = 4_800
        playerState.speed = 1.25
        playerState.volume = 0.64
        playerState.subtitleStatus = L10n.text("外挂字幕 2 条")
        playerState.drivePlaybackStatus = nil
        playerState.danmakuStatus = L10n.text("弹幕 已缓存 120 条")
        playerState.audioTracks = [
            PlayerTrackInfo(id: "audio-1", kind: .audio, name: L10n.text("中文 AAC")),
        ]
        playerState.selectedAudioTrackID = "audio-1"
        appState.selectedPlayFlag = L10n.text("极速源")
        appState.episodes = (1...24).map { number in
            Episode(
                name: L10n.text("第 {0} 集", ["\(number)"]),
                url: "visual-regression://episode/\(number)",
                isSelected: number == 2,
                season: 2,
                number: number
            )
        }

        appState.isPlayerLoading = state == .loading
        appState.playerLoadingMessage = L10n.text("正在解析高清播放地址...")
        playerState.isBuffering = state == .buffering
        playerState.cacheBufferingProgress = state == .buffering ? 0.68 : nil
        playerState.cacheSpeedBytesPerSecond = state == .buffering ? 3_600_000 : nil
        appState.playbackWarningMessage = state == .warning
            ? L10n.text("当前线路响应较慢，播放器已自动切换到兼容模式。")
            : nil
        playerState.errorMessage = state == .error
            ? L10n.text("播放地址暂时不可用，请重试或切换线路。")
            : nil
    }

    private static func value(for argument: String, in arguments: [String]) -> String? {
        if let inline = arguments.first(where: { $0.hasPrefix("\(argument)=") }) {
            return String(inline.dropFirst(argument.count + 1))
        }
        guard let index = arguments.firstIndex(of: argument),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func parseViewport(_ rawValue: String) -> CGSize? {
        let parts = rawValue.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width >= 320,
              height >= 180,
              width <= 8_192,
              height <= 8_192 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}
