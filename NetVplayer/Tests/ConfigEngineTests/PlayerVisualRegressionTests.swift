import Foundation
import Testing
@testable import NetVplayerApp

@Suite("Player visual regression")
struct PlayerVisualRegressionTests {
    @Test
    func parsesSeparatedAndInlineArguments() {
        let configuration = PlayerVisualRegressionConfiguration.parse(arguments: [
            "NetVplayerApp",
            "--visual-regression-player=settings-drawer",
            "--visual-regression-fixture", "/tmp/player.jpg",
            "--visual-regression-viewport", "1200x675",
            "--visual-regression-output=/tmp/player.png",
        ])

        #expect(configuration?.state == .settingsDrawer)
        #expect(configuration?.fixtureURL?.path == "/tmp/player.jpg")
        #expect(configuration?.viewport == CGSize(width: 1200, height: 675))
        #expect(configuration?.outputURL?.path == "/tmp/player.png")
    }

    @Test
    func rejectsUnknownStateAndFallsBackForInvalidViewport() {
        #expect(PlayerVisualRegressionConfiguration.parse(arguments: [
            "NetVplayerApp",
            "--visual-regression-player", "unknown",
        ]) == nil)

        let configuration = PlayerVisualRegressionConfiguration.parse(arguments: [
            "NetVplayerApp",
            "--visual-regression-player", "normal",
            "--visual-regression-viewport", "0x0",
        ])
        #expect(configuration?.viewport == PlayerVisualRegressionConfiguration.defaultViewport)
    }

    @Test @MainActor
    func appliesDeterministicPlayerStateWithoutStartingServices() {
        let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
        let configuration = PlayerVisualRegressionConfiguration(
            state: .buffering,
            fixtureURL: URL(fileURLWithPath: "/tmp/player.jpg"),
            viewport: CGSize(width: 1480, height: 833),
            outputURL: nil
        )

        configuration.apply(to: appState)

        #expect(appState.playerState.currentSpec?.title == "南部档案 - 第02集")
        #expect(appState.playerState.currentSpec?.flag == "极速源")
        #expect(appState.playerState.position == 1_185)
        #expect(appState.playerState.duration == 8_538)
        #expect(appState.playerState.speed == 1.25)
        #expect(appState.playerState.volume == 0.64)
        #expect(appState.playerState.isBuffering)
        #expect(appState.playerState.cacheBufferingProgress == 0.68)
        #expect(appState.playerState.subtitleStatus == "外挂字幕 2 条")
        #expect(appState.playerState.audioTracks.first?.displayName == "中文 AAC")
        #expect(appState.playerState.danmakuStatus == "弹幕 已缓存 120 条")
        #expect(appState.episodes.count == 24)
        #expect(appState.episodes[1].isSelected)
    }
}
