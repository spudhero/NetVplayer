import Foundation
import Testing
import Models
import Storage
import DriveEngine
@testable import NetVplayerApp

@MainActor
@Test(arguments: [false, true], [false, true])
func everyVisibleEntryHasItsListedNeighbours(descending: Bool, audio: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(loadDefaultConfig: false, startProxyServer: false,
        storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
    let names = audio
        ? ["试音 03.mp3", "未编号歌曲", "02.wav", "02.flac", "演唱会.mkv", "试音 03.mp3"]
        : ["[4.60GB]S01E03 4KHQHDR60FPS.mp4", "第4集.mkv", "S02E01_1080p.mp4",
           "第4集(1).mkv", "花絮.mp4", "未编号视频", "第4集.mkv"]
    let items = names.enumerated().map { Episode(name: $0.element, url: "entry-\($0.offset)") }
    state.detailVod = Vod(vodId: "collection", typeName: "电影")
    state.episodes = items
    state.episodeSortOrder = descending ? .descending : .ascending
    let displayed = descending ? Array(items.reversed()) : items
    #expect(state.displayedPlaybackEpisodes.map(\.id) == displayed.map(\.id))
    for (index, item) in displayed.enumerated() {
        state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/current",
            metadata: ["vod.episodeURL": item.url, "vod.episodeName": item.name])
        let context = state.playbackEpisodeContext()
        #expect(context.currentIndex == index)
        #expect(context.total == displayed.count)
        #expect(context.previousEpisode?.id == (index > 0 ? displayed[index - 1].id : nil))
        #expect(context.nextEpisode?.id == (index + 1 < displayed.count ? displayed[index + 1].id : nil))
        let drawer = state.playbackEpisodeContext(in: state.episodes)
        #expect(drawer.previousEpisode?.id == context.previousEpisode?.id)
        #expect(drawer.nextEpisode?.id == context.nextEpisode?.id)
    }
}

@MainActor
@Test(arguments: [false, true])
func presentationAndPlaybackKeepSourceOrderAcrossVersions(descending: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(loadDefaultConfig: false, startProxyServer: false,
        storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
    let high = (21...23).reversed().map { Episode(name: "\($0)_4K.mkv", url: "4k:\($0)") }
    let low = (21...23).map { Episode(name: "\($0)_1080p.mkv", url: "hd:\($0)") }
    state.episodes = high + low
    state.episodeSortOrder = descending ? .descending : .ascending
    state.playerState.currentSpec = PlaySpec(url: "https://example.test/22.mp4",
        metadata: ["vod.episodeURL": "4k:22", "vod.episodeName": high[1].name])
    #expect(state.displayedPlaybackEpisodes.map(\.url) == (descending
        ? ["hd:23", "hd:22", "hd:21", "4k:21", "4k:22", "4k:23"]
        : ["4k:23", "4k:22", "4k:21", "hd:21", "hd:22", "hd:23"]))
    #expect(state.episodes.map(\.id) == (high + low).map(\.id))
    let context = state.playbackEpisodeContext()
    #expect(context.nextEpisode?.url == (descending ? "4k:23" : "4k:21"))
    #expect(context.previousEpisode?.url == (descending ? "4k:21" : "4k:23"))
    #expect(context.total == 6)
    let drawerContext = state.playbackEpisodeContext(in: state.episodes)
    #expect(drawerContext.nextEpisode?.id == context.nextEpisode?.id)
    #expect(drawerContext.previousEpisode?.id == context.previousEpisode?.id)
    // This is the same context read by evaluateNextEpisodePreload and requestAutoAdvance.
    state.episodes.append(Episode(name: "NEW22_4K.mkv", url: "duplicate:22"))
    #expect(state.playbackEpisodeContext().nextEpisode?.id == context.nextEpisode?.id)
    #expect(state.playbackEpisodeContext().total == 7)
}

@MainActor
@Test func quarkHiddenExtensionsAndAlternateSharesFollowVisibleNeighbours() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(loadDefaultConfig: false, startProxyServer: false,
        storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
    func episode(_ name: String, fileName: String) throws -> Episode {
        let shareID = fileName.hasSuffix(".mp3") ? "alternate" : "primary"
        let reference = DriveFileReference(provider: .quark, shareURL: "https://pan.quark.cn/s/\(shareID)",
            pwdID: shareID, fid: fileName, fidToken: "fixture", fileName: fileName, formatType: "video/mp4")
        #expect(try #require(DriveFileReference.parse(reference.encodedURL)).formatType == "video/mp4")
        return Episode(name: name, url: reference.encodedURL)
    }
    let primary = try (1...33).map { try episode(String(format: "%02d", $0), fileName: String(format: "%02d.mkv", $0)) }
    let alternate = try (7...40).map { try episode("E\($0).mp3", fileName: "E\($0).mp3") }
    state.detailVod = Vod(vodId: "film", typeName: "玩偶电影")
    state.selectedPlayFlag = "夸克网盘"
    state.episodes = primary + [try episode("04(1)", fileName: "04(1).mkv")] + alternate
    state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/33.mp4",
        metadata: ["vod.episodeURL": primary[32].url, "vod.episodeName": "33"])
    let context = state.playbackEpisodeContext()
    #expect(context.previousEpisode?.id == primary[31].id)
    #expect(context.nextEpisode?.name == "04(1)")
    #expect(state.playbackEpisodeContext(in: state.episodes).nextEpisode?.id == context.nextEpisode?.id)
    state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/copy.mp4",
        metadata: ["vod.episodeURL": state.episodes[33].url, "vod.episodeName": "04(1)"])
    #expect(state.playbackEpisodeContext().previousEpisode?.id == primary.last?.id)
    #expect(state.playbackEpisodeContext().nextEpisode?.id == alternate.first?.id)
    state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/34.mp4",
        metadata: ["vod.episodeURL": alternate[27].url, "vod.episodeName": "E34.mp3"])
    #expect(state.playbackEpisodeContext().nextEpisode?.name == "E35.mp3")
}

@MainActor
@Test(arguments: [false, true])
func baiduDirectoryVersionsAndLegacyReferencesFollowOneVisibleList(legacyReference: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(loadDefaultConfig: false, startProxyServer: false,
        storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
    func episode(_ name: String, folder: String, size: String) throws -> Episode {
        let file = BaiduShareFile(fileID: folder + name, name: name, path: folder + "/" + name,
            size: 4_848_798_194, category: 1, isDirectory: false)
        let share = BaiduShareRequest(originalURL: "https://pan.baidu.com/s/1fixture", shareToken: "1fixture",
            shortURLToken: "fixture", passcode: "")
        var reference = BaiduDriveClient().fileReference(for: file, share: share,
            shareID: "share", shareUK: "fixture", collectionName: "无可替代（臻彩）")
        #expect(try #require(DriveFileReference.parse(reference.encodedURL)).filePath == file.path)
        if legacyReference {
            reference = DriveFileReference(provider: .baidu, shareURL: share.originalURL,
                pwdID: "share", fid: file.fileID, fidToken: "fixture", fileName: name)
            #expect(try #require(DriveFileReference.parse(reference.encodedURL)).filePath.isEmpty)
        }
        return Episode(name: "[\(size)]\(name)", url: reference.encodedURL)
    }
    let base = try (1...9).map { try episode(String(format: "E%02d", $0) + ((7...8).contains($0) ? ".mkv" : ".mp4"),
        folder: "/series", size: "4.00GB") }
    var selected = try (1...8).map { try episode("第\($0)集.mkv", folder: "/series/DV", size: $0 == 2 ? "4.52GB" : "4.28GB") }
    let final = try episode("2026.S01E09.第9集.2160p.WEB-DL.DoVi HQ.H.265.DTS 5.1.mkv",
        folder: "/series/DV", size: "4.76GB")
    if !legacyReference { selected.append(final) }
    state.detailVod = Vod(vodId: "film", typeName: "玩偶电影")
    state.selectedPlayFlag = "百度网盘"
    state.episodes = base + selected + (legacyReference ? [final] : [])
    func play(_ item: Episode) {
        state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/current",
            metadata: ["vod.episodeURL": item.url, "vod.episodeName": item.name])
    }
    play(selected[1])
    let context = state.playbackEpisodeContext()
    #expect(context.previousEpisode?.id == selected[0].id)
    #expect(context.nextEpisode?.id == selected[2].id)
    #expect(context.total == 18)
    #expect(state.playbackEpisodeContext(in: state.episodes).nextEpisode?.id == context.nextEpisode?.id)
    #expect(state.displayedPlaybackEpisodes.count == 18)
    play(selected[7])
    #expect(state.playbackEpisodeContext().nextEpisode?.id == final.id)
    play(base[5])
    #expect(state.playbackEpisodeContext().nextEpisode?.id == base[6].id)
    play(base[8])
    #expect(state.playbackEpisodeContext().nextEpisode?.id == selected[0].id)
    play(selected[0])
    #expect(state.playbackEpisodeContext().previousEpisode?.id == base[8].id)
    play(final)
    #expect(state.playbackEpisodeContext().previousEpisode?.id == selected[7].id)
    #expect(!state.playbackEpisodeContext().hasNext)
}

@MainActor
@Test(arguments: [DriveProvider.quark, .uc, .baidu])
func audioEntriesAcrossSharesAndFoldersStayInTheVisibleQueue(provider: DriveProvider) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(loadDefaultConfig: false, startProxyServer: false,
        storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
    let names = ["歌曲 03.mp3", "未知文件名", "歌曲 01.wav", "歌曲 01.wav"]
    let items = names.enumerated().map { index, name in
        let reference = DriveFileReference(provider: provider, shareURL: "https://example.test/share-\(index)",
            pwdID: "share-\(index)", fid: "file-\(index)", fidToken: "fixture", fileName: name,
            formatType: index.isMultiple(of: 2) ? "audio/mpeg" : "", filePath: "/folder-\(index)/\(name)")
        return Episode(name: name, url: reference.encodedURL)
    }
    state.episodes = items
    state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/current",
        metadata: ["vod.episodeURL": items[2].url, "vod.episodeName": items[2].name])
    #expect(state.displayedPlaybackEpisodes.map(\.id) == items.map(\.id))
    #expect(state.playbackEpisodeContext().previousEpisode?.id == items[1].id)
    #expect(state.playbackEpisodeContext().nextEpisode?.id == items[3].id)
    #expect(state.playbackEpisodeContext().total == 4)
}

@MainActor
@Test func largeAndRefreshedListsKeepNavigationAtTheVisibleBoundary() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = AppState(loadDefaultConfig: false, startProxyServer: false,
        storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
    state.episodes = (0..<5_001).map { Episode(name: "文件\($0).mkv", url: "entry-\($0)") }
    let last = try #require(state.episodes.last)
    state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/current",
        metadata: ["vod.episodeURL": last.url, "vod.episodeName": last.name])
    #expect(state.playbackEpisodeContext().previousEpisode?.id == state.episodes[4_999].id)
    #expect(!state.playbackEpisodeContext().hasNext)
    let appended = Episode(name: "未编号歌曲", url: "appended")
    state.episodes.append(appended)
    #expect(state.playbackEpisodeContext().nextEpisode?.id == appended.id)
    #expect(state.playbackEpisodeContext().total == state.displayedPlaybackEpisodes.count)
    state.episodes = [last]
    #expect(!state.playbackEpisodeContext().hasNext)
    #expect(!state.playbackEpisodeContext().hasPrevious)
    state.episodes = []
    #expect(state.playbackEpisodeContext().currentIndex == nil)
    #expect(!state.playbackEpisodeContext().hasNext)
}
