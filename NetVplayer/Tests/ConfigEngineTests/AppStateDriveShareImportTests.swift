import Testing
import Foundation
import Models
import DriveEngine
import WebHomeEngine
@testable import NetVplayerApp

@MainActor
@Test func testDriveShareTextSearchCreatesLocalResultAndExpandsOnOpen() async throws {
    let shareText = "我用夸克网盘分享了 Demo.Movie 链接：https://v.quark.cn/s/quarkToken01 提取码：58b8"
    let expandedEpisode = Episode(
        name: "第01集",
        url: "netvplayer-drive://quark/file?share=https%3A%2F%2Fpan.quark.cn%2Fs%2FquarkToken01&pwd_id=quarkToken01&fid=fid1&fid_token=token1&file_name=Demo.E01.mp4"
    )
    let appState = AppState(
        loadDefaultConfig: false,
        startProxyServer: false,
        driveShareExpander: DriveShareExpander(expanders: [
            StaticDriveShareExpander(expectedURL: "https://pan.quark.cn/s/quarkToken01?pwd=58b8", episodes: [expandedEpisode])
        ])
    )

    await appState.search(keyword: shareText)

    let result = try #require(appState.searchResults.first)
    #expect(appState.searchResults.count == 1)
    #expect(result.siteKey == AppState.driveShareImportSiteKey)
    #expect(result.siteName == "网盘分享")
    #expect(result.vods.first?.vodId == "https://pan.quark.cn/s/quarkToken01?pwd=58b8")
    #expect(result.vods.first?.vodRemarks == "夸克网盘")
    #expect(appState.isSearching == false)

    let vod = try #require(result.vods.first)
    await appState.openImportedDriveShare(vod)

    #expect(appState.activeSite?.key == AppState.driveShareImportSiteKey)
    #expect(appState.isDetailPresented)
    #expect(appState.detailVod?.vodName == "夸克网盘分享")
    #expect(appState.detailVod?.vodPlayFrom == "网盘分享")
    #expect(appState.playFlags == ["网盘分享"])
    #expect(appState.selectedPlayFlag == "网盘分享")
    #expect(appState.episodes.count == 1)
    #expect(appState.episodes.first?.name == expandedEpisode.name)
    #expect(appState.episodes.first?.url == expandedEpisode.url)
}

@MainActor
@Test func testUnsupportedDriveShareTextCreatesDiagnosticDetailWithoutNetworkSearch() async throws {
    let shareText = "迅雷云盘：https://pan.xunlei.com/s/VOtoken01?pwd=tgr6#"
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)

    await appState.search(keyword: shareText)

    let result = try #require(appState.searchResults.first)
    #expect(appState.searchResults.count == 1)
    #expect(result.siteKey == AppState.driveShareImportSiteKey)
    #expect(result.vods.first?.vodRemarks == "待验证")
    #expect(result.vods.first?.vodContent.contains("迅雷云盘") == true)

    let vod = try #require(result.vods.first)
    await appState.openImportedDriveShare(vod)

    let rawEpisode = try #require(appState.detailVod?.parseFlags().first?.episodes.first)
    #expect(rawEpisode.name.contains("迅雷云盘"))
    #expect(rawEpisode.url.hasPrefix("netvplayer-unavailable://drive-share"))
    #expect(appState.playFlags.isEmpty)
    #expect(appState.selectedPlayFlag.isEmpty)
    #expect(appState.episodes.isEmpty)
    #expect(appState.detailVod?.vodContent.contains("迅雷云盘") == true)
}

@MainActor
@Test func testWebHomePanCheckUsesExternalDriveCandidateForCopiedText() async throws {
    let appState = AppState(loadDefaultConfig: false, startProxyServer: false)
    let dispatcher = appState.makeWebHomeBridgeDispatcher()
    let response = await dispatcher.dispatch(WebHomeBridgeMessage(
        id: "pan-check",
        method: "pan.check",
        params: [
            "shareURL": .string("链接：https://pan.baidu.com/share/init?surl=baiduToken01 提取码：abcd")
        ]
    ))

    #expect(response.ok)
    guard case .object(let result) = response.result else {
        Issue.record("pan.check should return an object result")
        return
    }
    #expect(result["canonicalURL"]?.stringValue == "https://pan.baidu.com/share/init?surl=baiduToken01&pwd=abcd")
    #expect(result["provider"]?.stringValue == "baidu")
    #expect(result["status"]?.stringValue == "supported")
    #expect(result["reason"]?.stringValue.contains("原画直链播放") == true)
    #expect(result["requiresAuth"]?.stringValue == "true")
}

private struct StaticDriveShareExpander: DriveShareExpanding {
    let expectedURL: String
    let episodes: [Episode]

    func canExpand(url: String) -> Bool {
        url == expectedURL
    }

    func expand(url: String, fallbackTitle: String) async throws -> [Episode] {
        guard url == expectedURL else {
            throw DriveEngineError.invalidShareURL(url)
        }
        return episodes
    }
}
