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
@Test(arguments: [DriveProvider.quark, .uc, .baidu])
func testCloudSongPlaybackContextEnablesRelativeNavigation(provider: DriveProvider) {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    let names = ["阿里郎-再次爱上你.mp3", "阿密特m-我们站着 就是理由.wav", "歌曲三"]
    let songs = names.enumerated().map { index, name in
        let reference = DriveFileReference(provider: provider, shareURL: "https://share.example.test/album",
            pwdID: "album", fid: "track-\(index)", fidToken: "", fileName: name, formatType: "audio/mpeg")
        return Episode(name: (name as NSString).deletingPathExtension, url: reference.encodedURL)
    }
    var spec = PlaySpec(url: "http://127.0.0.1:9978/stream/resolved")
    spec.metadata["vod.episodeURL"] = songs[0].url
    appState.playerState.currentSpec = spec
    let first = appState.playbackEpisodeContext(in: songs)
    #expect(first.total == 3)
    #expect(!first.hasPrevious)
    #expect(first.nextEpisode?.id == songs[1].id)

    spec.metadata["vod.episodeURL"] = songs[1].url
    appState.playerState.currentSpec = spec
    let middle = appState.playbackEpisodeContext(in: songs)
    #expect(middle.previousEpisode?.id == songs[0].id)
    #expect(middle.nextEpisode?.id == songs[2].id)

    spec.metadata["vod.episodeURL"] = songs[2].url
    appState.playerState.currentSpec = spec
    #expect(!appState.playbackEpisodeContext(in: songs).hasNext)
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
