import DriveEngine
import Models
import Testing
@testable import SpiderEngine

@Test func remoteProviderDriveShareResolverExpandsSharesInsideTheShell() async {
    let shareURL = "https://pan.quark.cn/s/remote-provider-fixture?pwd=58b8"
    let expander = DriveShareExpander(expanders: [
        RemoteProviderFixtureExpander(
            expectedURL: shareURL,
            episodes: [
                Episode(name: "Episode 1", url: "https://media.example.test/01.mp4"),
                Episode(name: "Episode 2", url: "https://media.example.test/02.mp4")
            ]
        )
    ])
    let resolver = RemoteProviderDriveShareResolver(expander: expander)
    let input = Result(list: [
        Vod(
            vodId: "fixture",
            vodName: "Fixture",
            vodPlayFrom: "Quark$$$Direct",
            vodPlayUrl: "Share$\(shareURL)$$$Trailer$https://media.example.test/trailer.m3u8"
        )
    ])

    let output = await resolver.resolve(input)
    let flags = output.list[0].parseFlags()

    #expect(flags.map(\.name) == ["Quark", "Direct"])
    #expect(flags[0].episodes.map(\.name) == ["Episode 1", "Episode 2"])
    #expect(flags[0].episodes.map(\.url) == [
        "https://media.example.test/01.mp4",
        "https://media.example.test/02.mp4"
    ])
    #expect(flags[1].episodes.map(\.url) == ["https://media.example.test/trailer.m3u8"])
    #expect(output.list[0].episodeDetails.count == 3)
}

@Test func remoteProviderDriveShareResolverKeepsFailureExplicitAndRedacted() async throws {
    let shareURL = "https://drive.uc.cn/s/expired"
    let expander = DriveShareExpander(expanders: [
        RemoteProviderFixtureExpander(
            expectedURL: shareURL,
            error: .api(provider: .uc, statusCode: 403, code: nil, message: "share #expired$now")
        )
    ])
    let resolver = RemoteProviderDriveShareResolver(expander: expander)
    let input = Result(list: [
        Vod(
            vodId: "fixture",
            vodName: "Fixture",
            vodPlayFrom: "UC",
            vodPlayUrl: "Expired$\(shareURL)"
        )
    ])

    let output = await resolver.resolve(input)
    let episode = try #require(output.list[0].parseFlags().first?.episodes.first)

    #expect(episode.name == "Expired")
    #expect(episode.url.hasPrefix("netvplayer-unavailable://remote-provider-drive-share"))
    #expect(!output.list[0].vodPlayUrl.contains("#expired$now"))
    #expect(output.list[0].vodPlayUrl.contains("share%20expired%20now"))
}

@Test func remoteProviderDriveShareResolverKeepsFileReferencesWithoutReexpanding() async throws {
    let reference = DriveFileReference(
        provider: .quark,
        shareURL: "quark://share/share-1",
        pwdID: "share-1",
        fid: "file-1",
        fidToken: "token-1",
        fileName: "episode.mp4"
    ).encodedURL
    let resolver = RemoteProviderDriveShareResolver(expander: DriveShareExpander(expanders: []))
    let input = Result(
        list: [
            Vod(
                vodId: "fixture",
                vodName: "Fixture",
                vodPlayFrom: "Quark",
                vodPlayUrl: "Episode$\(reference)"
            )
        ]
    )

    let output = await resolver.resolve(input)
    let episode = try #require(output.list[0].parseFlags().first?.episodes.first)
    #expect(episode.url == reference)
    #expect(episode.name == "Episode")
}

private struct RemoteProviderFixtureExpander: DriveShareExpanding {
    let expectedURL: String
    let episodes: [Episode]
    let error: DriveEngineError?

    init(expectedURL: String, episodes: [Episode]) {
        self.expectedURL = expectedURL
        self.episodes = episodes
        self.error = nil
    }

    init(expectedURL: String, error: DriveEngineError) {
        self.expectedURL = expectedURL
        self.episodes = []
        self.error = error
    }

    func canExpand(url: String) -> Bool {
        url == expectedURL
    }

    func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        if let error { throw error }
        return episodes
    }
}
