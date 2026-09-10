import Testing
import Foundation
import Models
import DriveEngine
import PlayerEngine
@testable import NetVplayerApp

@MainActor
@Test func testEpisodeForCurrentPlaybackMatchesMetadataURL() {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var spec = PlaySpec(url: "https://media.example.test/resolved.m3u8")
    spec.metadata["vod.episodeURL"] = "line-a-02"
    spec.metadata["vod.episodeName"] = "第02集"
    appState.playerState.currentSpec = spec

    let episodes = [
        Episode(name: "第01集", url: "line-a-01"),
        Episode(name: "第02集", url: "line-a-02"),
        Episode(name: "第03集", url: "line-a-03")
    ]

    #expect(appState.episodeForCurrentPlayback(in: episodes)?.url == "line-a-02")
    #expect(appState.playbackEpisodeContext(in: episodes).currentIndex == 1)
    #expect(appState.playbackEpisodeContext(in: episodes).hasPrevious == true)
    #expect(appState.playbackEpisodeContext(in: episodes).hasNext == true)
}

@MainActor
@Test func testPlayRelativeEpisodeReturnsNilAtBoundariesAndTargetInRange() async {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    appState.episodes = [
        Episode(name: "第01集", url: "line-a-01"),
        Episode(name: "第02集", url: "line-a-02"),
        Episode(name: "第03集", url: "line-a-03")
    ]
    var spec = PlaySpec(url: "https://media.example.test/resolved.m3u8")
    spec.metadata["vod.episodeURL"] = "line-a-02"
    spec.metadata["vod.episodeName"] = "第02集"
    appState.playerState.currentSpec = spec

    let previous = await appState.playRelativeEpisode(offset: -1)
    let next = await appState.playRelativeEpisode(offset: 1)

    #expect(previous?.url == "line-a-01")
    #expect(next?.url == "line-a-03")

    spec.metadata["vod.episodeURL"] = "line-a-01"
    spec.metadata["vod.episodeName"] = "第01集"
    appState.playerState.currentSpec = spec
    #expect(await appState.playRelativeEpisode(offset: -1) == nil)

    spec.metadata["vod.episodeURL"] = "line-a-03"
    spec.metadata["vod.episodeName"] = "第03集"
    appState.playerState.currentSpec = spec
    #expect(await appState.playRelativeEpisode(offset: 1) == nil)
}

@MainActor
@Test func testEpisodeForCurrentPlaybackFallsBackToSameNameAcrossFlags() {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var spec = PlaySpec(url: "https://media.example.test/resolved.m3u8")
    spec.metadata["vod.episodeURL"] = "line-a-02"
    spec.metadata["vod.episodeName"] = "第02集"
    appState.playerState.currentSpec = spec

    let switchedFlagEpisodes = [
        Episode(name: "第01集", url: "line-b-01"),
        Episode(name: "第02集", url: "line-b-02")
    ]
    let unrelatedEpisodes = [
        Episode(name: "第11集", url: "line-c-11"),
        Episode(name: "第12集", url: "line-c-12")
    ]

    #expect(appState.episodeForCurrentPlayback(in: switchedFlagEpisodes)?.url == "line-b-02")
    #expect(appState.episodeForCurrentPlayback(in: unrelatedEpisodes) == nil)
}

@MainActor
@Test func testRefreshSubtitleStyleIsSafeWithoutActiveMPVContext() {
    MPVPlayerEngine.vod.refreshSubtitleStyle()
}

@MainActor
@Test func testPlaybackDiagnosticsIncludeDriveFixtureSampleStatus() {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    var spec = PlaySpec(url: "https://media.example.test/movie.mp4")
    spec.metadata["drive.fixtureProvider"] = "uc"
    spec.metadata["drive.fixtureScenario"] = "high-bitrate-selection"
    spec.metadata[DrivePlaybackMetadataKey.fixtureStatus] = ExternalCaptureStatus.captured.rawValue

    let lines = appState.playbackDiagnosticLines(for: spec)

    #expect(lines.contains("Fixture：uc / high-bitrate-selection"))
    #expect(lines.contains("样本状态：captured"))
}
