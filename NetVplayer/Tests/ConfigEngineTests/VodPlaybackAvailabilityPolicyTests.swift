import Testing
import Models
import DriveEngine
@testable import NetVplayerApp

@Test func playbackAvailabilityKeepsValidEpisodesAndDropsEmptyLines() {
    let quark148 = driveEpisodeURL(provider: .quark, fileName: "仙逆.148.4K.mp4", index: 148)
    let quark149 = driveEpisodeURL(provider: .quark, fileName: "仙逆.149.4K.mp4", index: 149)
    let detail = Vod(
        vodId: "xian-ni",
        vodName: "仙逆",
        vodPlayFrom: "夸克网盘$$$阿里云盘$$$百度网盘",
        vodPlayUrl: [
            "失效分享$netvplayer-unavailable://episode?reason=expired#148 4K$\(quark148)#149 4K$\(quark149)",
            "接口错误$netvplayer-unavailable://episode?reason=share_link%20is%20forbidden",
            "第01集$https://media.example.test/baidu-01.mp4"
        ].joined(separator: "$$$")
    )

    let lines = VodPlaybackAvailabilityPolicy.visibleLines(in: detail)

    #expect(lines.map(\.flag) == ["夸克网盘", "百度网盘"])
    #expect(lines[0].episodes.map(\.name) == ["148 4K", "149 4K"])
    #expect(lines[0].episodes.map(\.url) == [quark148, quark149])
    #expect(lines[1].episodes.map(\.name) == ["第01集"])
}

@MainActor
@Test func playbackAvailabilityFallsBackWhenPreferredLineIsUnavailable() {
    let quarkURL = driveEpisodeURL(provider: .quark, fileName: "仙逆.148.4K.mp4", index: 148)
    let detail = Vod(
        vodId: "xian-ni-history",
        vodName: "仙逆",
        vodPlayFrom: "阿里云盘$$$夸克网盘",
        vodPlayUrl: [
            "接口错误$netvplayer-unavailable://episode?reason=share_link%20is%20forbidden",
            "148 4K$\(quarkURL)"
        ].joined(separator: "$$$")
    )
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    appState.detailVod = detail

    appState.applyPlaybackAvailability(for: detail, preferredFlag: "阿里云盘")

    #expect(appState.playFlags == ["夸克网盘"])
    #expect(appState.selectedPlayFlag == "夸克网盘")
    #expect(appState.episodes.map(\.name) == ["148 4K"])
}

@MainActor
@Test func playbackAvailabilityClearsSelectionWhenEveryLineIsUnavailable() {
    let detail = Vod(
        vodId: "all-unavailable",
        vodName: "全部失效",
        vodPlayFrom: "UC网盘$$$阿里云盘",
        vodPlayUrl: [
            "失效$netvplayer-unavailable://episode?reason=expired",
            "失败$netvplayer-unavailable://episode?reason=forbidden"
        ].joined(separator: "$$$")
    )
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    appState.detailVod = detail

    appState.applyPlaybackAvailability(for: detail, preferredFlag: "UC网盘")

    #expect(appState.playFlags.isEmpty)
    #expect(appState.selectedPlayFlag.isEmpty)
    #expect(appState.episodes.isEmpty)
}

@Test func playbackAvailabilityKeepsExpandedDriveReferencesThatNeedAuthorization() {
    let providers: [DriveProvider] = [.quark, .uc, .baidu, .ali]

    for (index, provider) in providers.enumerated() {
        let url = driveEpisodeURL(provider: provider, fileName: "movie-\(index).mp4", index: index)
        let episode = Episode(name: "资源 \(index)", url: url)

        #expect(VodPlaybackAvailabilityPolicy.isVisibleEpisode(episode))
    }
}

private func driveEpisodeURL(provider: DriveProvider, fileName: String, index: Int) -> String {
    DriveFileReference(
        provider: provider,
        shareURL: "https://share.example.test/\(provider.rawValue)",
        pwdID: "share-\(provider.rawValue)",
        fid: "fid-\(index)",
        fidToken: "token-\(index)",
        fileName: fileName
    ).encodedURL
}
