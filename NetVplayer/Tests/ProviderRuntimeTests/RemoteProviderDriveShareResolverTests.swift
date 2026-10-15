import Foundation
import DriveEngine
import Models
import Testing
@testable import SpiderEngine

@Test(arguments: [
    "bilibili://play?aid=12345&cid=67890",
    "https://www.bilibili.com/video/BV1fixture?p=2"
])
func remoteProviderDriveShareResolverPreservesBilibiliEpisodes(playbackURL: String) async throws {
    let resolver = RemoteProviderDriveShareResolver(expander: DriveShareExpander(expanders: []))
    let input = Result(list: [Vod(
        vodId: "classroom",
        vodName: "Classroom",
        vodPlayFrom: "Bilibili",
        vodPlayUrl: "Lesson$\(playbackURL)"
    )])

    let provisional = resolver.provisional(input)
    #expect(provisional.list[0].vodPlayUrl == input.list[0].vodPlayUrl)

    let resolved = await resolver.resolve(input)
    let episode = try #require(resolved.list[0].parseFlags().first?.episodes.first)
    #expect(episode.name == "Lesson")
    #expect(episode.url == playbackURL)
    #expect(resolved.list[0].vodPlayFrom == "Bilibili")
}

@Test func remoteProviderDriveShareResolverPreservesBilibiliWhileExpandingDriveShares() async throws {
    let playbackURL = "bilibili://play?aid=12345&cid=67890"
    let shareURL = "https://pan.quark.cn/s/classroom-fixture"
    let mediaURL = "https://media.example.test/lesson.mp4"
    let resolver = RemoteProviderDriveShareResolver(expander: DriveShareExpander(expanders: [
        RemoteProviderFixtureExpander(expectedURL: shareURL, episodes: [Episode(name: "File", url: mediaURL)])
    ]))
    let input = Result(list: [Vod(
        vodId: "mixed",
        vodPlayFrom: "Bilibili$$$Quark",
        vodPlayUrl: "Lesson$\(playbackURL)$$$Share$\(shareURL)"
    )])

    let provisional = resolver.provisional(input).list[0].parseFlags()
    #expect(provisional[0].episodes.first?.url == playbackURL)
    #expect(provisional[1].episodes.first?.url.hasPrefix("netvplayer-pending:") == true)

    let resolved = await resolver.resolve(input)
    let flags = resolved.list[0].parseFlags()
    #expect(flags.map(\.name) == ["Bilibili", "Quark"])
    #expect(flags[0].episodes.first?.name == "Lesson")
    #expect(flags[0].episodes.first?.url == playbackURL)
    #expect(flags[1].episodes.first?.url == mediaURL)
    #expect(resolved.list[0].episodeDetails.map(\.url) == [playbackURL, mediaURL])
}

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

@Test func remoteProviderDriveShareResolverPreservesDistinctShareGroupsWithIdenticalTitles() async throws {
    let shares = ["https://pan.quark.cn/s/a", "https://pan.quark.cn/s/b"]
    let resolver = RemoteProviderDriveShareResolver(expander: DriveShareExpander(expanders: shares.enumerated().map { index, share in
        RemoteProviderFixtureExpander(expectedURL: share, episodes: [
            Episode(name: "01", url: "https://media.example.test/\(index)/01.mp4"),
            Episode(name: "02", url: "https://media.example.test/\(index)/02.mp4")
        ])
    }))
    let input = Result(list: [Vod(vodId: "fixture", vodPlayFrom: "Quark",
        vodPlayUrl: shares.map { "Series$\($0)" }.joined(separator: "#"))])
    let resolved = await resolver.resolve(input)
    let episodes = try #require(resolved.list.first?.parseFlags().first?.episodes)
    let groups = DriveEpisodeSeries.groups(in: episodes)
    #expect(groups.count == 2)
    #expect(groups.map { $0.episodes.count } == [2, 2])
    #expect(episodes[0].series?.id != episodes[2].series?.id)
    let decoded = try JSONDecoder().decode(Result.self, from: JSONEncoder().encode(resolved))
    #expect(decoded.list[0].parseFlags()[0].episodes.map(\.series) == episodes.map(\.series))
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
