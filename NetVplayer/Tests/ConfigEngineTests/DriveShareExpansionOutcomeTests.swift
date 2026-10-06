import Testing
import Models
import DriveEngine

@Test func driveShareExpansionOutcomePreservesSuccessfulEpisodesInOrder() async throws {
    let expected = [
        Episode(name: "第01集 4K", url: "https://media.example.test/01.mp4"),
        Episode(name: "第02集 1080P", url: "https://media.example.test/02.mp4")
    ]
    let url = "https://pan.quark.cn/s/success"
    let expander = DriveShareExpander(expanders: [
        OutcomeDriveShareExpander(url: url, behavior: .episodes(expected))
    ])

    switch await expander.expansionOutcome(url: url, fallbackTitle: "测试影片") {
    case .expanded(let episodes):
        #expect(episodes.map(\.name) == expected.map(\.name))
        #expect(episodes.map(\.url) == expected.map(\.url))
    case .unavailable(let reason):
        Issue.record("Expected expanded episodes, got unavailable: \(reason)")
    }
}

@Test func driveShareExpansionOutcomePreservesDirectMediaWithoutDirectoryExpansion() async throws {
    let url = "https://media.example.test/movie.mp4?token=signed"
    let expander = DriveShareExpander(expanders: [])

    switch await expander.expansionOutcome(url: url, fallbackTitle: "直链影片") {
    case .expanded(let episodes):
        #expect(episodes.map(\.name) == ["直链影片"])
        #expect(episodes.map(\.url) == [url])
    case .unavailable(let reason):
        Issue.record("Expected a direct media episode, got unavailable: \(reason)")
    }
}

@Test func driveShareExpansionOutcomeTreatsEmptyDirectoryAsUnavailable() async throws {
    let url = "https://drive.uc.cn/s/empty"
    let expander = DriveShareExpander(expanders: [
        OutcomeDriveShareExpander(url: url, behavior: .episodes([]))
    ])

    switch await expander.expansionOutcome(url: url, fallbackTitle: "空目录") {
    case .expanded:
        Issue.record("Expected an unavailable outcome for an empty directory")
    case .unavailable(let reason):
        #expect(reason == "未找到视频文件")
    }
}

@Test func driveShareExpansionOutcomeNormalizesProviderFailures() async throws {
    let cases: [(provider: DriveProvider, url: String)] = [
        (.quark, "https://pan.quark.cn/s/failed"),
        (.uc, "https://drive.uc.cn/s/failed"),
        (.baidu, "https://pan.baidu.com/s/failed"),
        (.ali, "https://www.alipan.com/s/failed")
    ]

    for item in cases {
        let error = DriveEngineError.api(
            provider: item.provider,
            statusCode: 400,
            code: nil,
            message: "share_link is forbidden"
        )
        let expander = DriveShareExpander(expanders: [
            OutcomeDriveShareExpander(url: item.url, behavior: .failure(error))
        ])

        switch await expander.expansionOutcome(url: item.url, fallbackTitle: "失效目录") {
        case .expanded:
            Issue.record("Expected \(item.provider.rawValue) failure to be unavailable")
        case .unavailable(let reason):
            #expect(reason.contains("share_link is forbidden"))
        }
    }
}

private struct OutcomeDriveShareExpander: DriveShareExpanding {
    enum Behavior: Sendable {
        case episodes([Episode])
        case failure(DriveEngineError)
    }

    let url: String
    let behavior: Behavior

    func canExpand(url: String) -> Bool {
        url == self.url
    }

    func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        switch behavior {
        case .episodes(let episodes):
            return episodes
        case .failure(let error):
            throw error
        }
    }
}
