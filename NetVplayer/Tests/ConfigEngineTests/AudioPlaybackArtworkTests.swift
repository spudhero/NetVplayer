import Foundation
import Testing
import Models
import DriveEngine
@testable import NetVplayerApp

@MainActor
@Suite struct AudioPlaybackArtworkTests {
    private let detailArtwork = "https://img.example.test/album.jpg"

    @Test(arguments: ["试音.MP3", "无损.flac", "钢琴.wav"])
    func cloudAudioUsesDetailArtworkAfterResolution(fileName: String) {
        let reference = DriveFileReference(
            provider: .quark, shareURL: "https://pan.quark.cn/s/test", pwdID: "test",
            fid: "audio", fidToken: "token", fileName: fileName
        )
        let episode = Episode(name: "第一首", url: reference.encodedURL)
        let result = Result(url: "https://media.example.test/signed-resource?token=test")
        #expect(AppState.playbackArtwork(from: result).isEmpty)
        #expect(AppState.audioFallbackArtwork(from: result, episode: episode, detailArtwork: detailArtwork) == detailArtwork)
    }

    @Test(arguments: ["https://media.example.test/song.m4a?token=test", "https://media.example.test/song.aac"])
    func directAudioUsesEpisodeArtwork(url: String) {
        let episodeArtwork = "https://img.example.test/track.jpg"
        let episode = Episode(name: "第一首", url: url, artwork: episodeArtwork)
        #expect(AppState.audioFallbackArtwork(from: Result(url: url), episode: episode, detailArtwork: detailArtwork) == episodeArtwork)
    }

    @Test(arguments: ["https://media.example.test/film.mkv", "https://media.example.test/film.m3u8", "https://media.example.test/unknown"])
    func ordinaryVideoDoesNotPrepareAPosterTrack(url: String) {
        let episode = Episode(name: "正片", url: url, artwork: detailArtwork)
        #expect(AppState.audioFallbackArtwork(from: Result(url: url), episode: episode, detailArtwork: detailArtwork).isEmpty)
    }

    @Test func explicitPlayerArtworkKeepsPriority() {
        let artwork = "https://img.example.test/player-cover.jpg"
        let result = Result(url: "https://media.example.test/song.mp3", artwork: artwork)
        let episode = Episode(name: "试音.mp3", url: result.url, artwork: detailArtwork)
        #expect(AppState.playbackArtwork(from: result) == artwork)
        #expect(AppState.audioFallbackArtwork(from: result, episode: episode, detailArtwork: detailArtwork).isEmpty)
    }

    @Test func audioMIMEAllowsAResourceWithoutAnAudioExtension() {
        let result = Result(url: "https://media.example.test/resource", format: "audio/mpeg")
        #expect(AppState.audioFallbackArtwork(from: result, episode: Episode(name: "试音", url: result.url), detailArtwork: detailArtwork) == detailArtwork)
    }

    @Test func fallbackSurvivesParsingAndProxyURLOverrides() {
        let spec = PlaySpec(url: "https://media.example.test/song.mp3", audioFallbackArtwork: detailArtwork)
        let proxied = spec.merging(PlaySpec(url: "http://127.0.0.1:9978/stream/audio"))
        #expect(proxied.artwork.isEmpty)
        #expect(proxied.audioFallbackArtwork == detailArtwork)
    }
}
