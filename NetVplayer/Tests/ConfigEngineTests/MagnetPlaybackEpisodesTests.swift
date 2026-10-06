import Foundation
import Testing
@testable import SpiderEngine

@Suite("Public magnet episode expansion")
struct MagnetPlaybackEpisodesTests {
    @Test func preservesMagnetIdentityAndReplacesThePreviousFileSelection() throws {
        let magnet = "magnet:?xt=urn:btih:0123456789012345678901234567890123456789&tr=https%3A%2F%2Ftracker.example.test%2Fannounce&netvplayer_file=9"
        let files = [SixVMagnetPlaybackFile(index: 3, name: " Episode$1# ", length: 42,
                                           url: try #require(URL(string: "http://127.0.0.1:1234/3")))]
        let episodes = MagnetPlaybackEpisodes.episodes(for: magnet, files: files)
        let episode = try #require(episodes.first)
        #expect(episode.name == "Episode 1")
        let query = try #require(URLComponents(string: episode.url)?.queryItems)
        #expect(query.filter { $0.name == "netvplayer_file" }.map(\.value) == ["3"])
        #expect(query.first { $0.name == "xt" }?.value == "urn:btih:0123456789012345678901234567890123456789")
        #expect(query.first { $0.name == "tr" }?.value == "https://tracker.example.test/announce")
    }
}
