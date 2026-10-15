import Foundation
import Testing
import Models
import Storage
import DriveEngine
import ApplicationCore
@testable import NetVplayerApp

@Suite @MainActor
struct EpisodeSeriesGroupingTests {
    @Test(arguments: [false, true])
    func everyGroupUsesItsVisibleNeighboursAndStopsAtBothEnds(descending: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
        let sources = [
            DriveEpisodeSeries.source(provider: .quark, shareID: "share-a", directoryID: "sdr", directoryPath: "/Series/4K SDR"),
            DriveEpisodeSeries.source(provider: .quark, shareID: "share-a", directoryID: "root", directoryPath: "/Series"),
            DriveEpisodeSeries.source(provider: .quark, shareID: "share-b", directoryID: "root", directoryPath: "/Series")
        ]
        let names = [["01", "02", "03"], ["S01E11", "S01E12"], ["E01", "E02", "E03"]]
        state.episodes = names.enumerated().flatMap { group, names in
            names.enumerated().map { index, name in
                Episode(name: name, url: "file-\(group)-\(index)", series: sources[group])
            }
        }
        state.episodeSortOrder = descending ? .descending : .ascending
        #expect(state.displayedEpisodeGroups.map(\.id) == sources.map(\.id))
        #expect(state.displayedPlaybackEpisodes.count == 8)
        for group in state.displayedEpisodeGroups {
            for (index, item) in group.episodes.enumerated() {
                state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/current.mp4",
                    metadata: ["vod.episodeURL": item.url, "vod.episodeName": item.name])
                let context = state.playbackEpisodeContext()
                #expect(context.currentIndex == index)
                #expect(context.total == group.episodes.count)
                #expect(context.previousEpisode?.id == (index > 0 ? group.episodes[index - 1].id : nil))
                #expect(context.nextEpisode?.id == (index + 1 < group.episodes.count ? group.episodes[index + 1].id : nil))
                #expect(state.playbackEpisodeContext(in: state.episodes).nextEpisode?.id == context.nextEpisode?.id)
                let transition = PlaybackSessionCore.requestAutoAdvance(
                    PlaybackSessionState(), episodeURL: item.url, context: context, isLoading: false
                )
                #expect(transition.targetEpisode?.id == context.nextEpisode?.id)
            }
        }
    }

    @Test func progressiveReplacementRebuildsGroupsWithoutUsingNamesAsIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
        let source = DriveEpisodeSeries.source(provider: .baidu, shareID: "a", directoryPath: "/Series")
        let other = DriveEpisodeSeries.source(provider: .baidu, shareID: "b", directoryPath: "/Series")
        let first = Episode(name: "第01集.mkv", url: "one", series: source)
        let next = Episode(name: "S01E02 4K60FPS.mp4", url: "two", series: source)
        let duplicate = Episode(name: first.name, url: "another-one", series: other)
        state.episodes = [first, duplicate]
        state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/current",
            metadata: ["vod.episodeURL": first.url, "vod.episodeName": first.name, "vod.episodeSeriesID": source.id])
        #expect(!state.playbackEpisodeContext().hasNext)
        state.episodes = [first, duplicate, next]
        #expect(state.displayedPlaybackEpisodes.map(\.url) == [first.url, next.url, duplicate.url])
        #expect(state.playbackEpisodeContext().nextEpisode?.url == next.url)
        state.episodes = [duplicate]
        #expect(state.playbackEpisodeContext().currentIndex == nil)
        #expect(!state.playbackEpisodeContext().hasNext)
        var moved = first
        moved.series = other
        state.episodes = [moved, duplicate]
        #expect(state.playbackEpisodeContext().currentIndex == nil)
        #expect(!state.playbackEpisodeContext().hasNext)
        state.episodes = []
        #expect(state.episodeGroups.isEmpty)
    }

    @Test func seriesMetadataRoundTripsThroughDetailAndCacheWithoutChangingPlaybackIdentity() throws {
        let url = DriveFileReference(provider: .quark, shareURL: "https://pan.quark.cn/s/fixture",
            pwdID: "fixture", fid: "file", fidToken: "fixture", fileName: "01.mkv").encodedURL
        let series = DriveEpisodeSeries.source(provider: .quark, shareID: "fixture", directoryID: "sdr", directoryPath: "/Series/4K SDR")
        let episode = Episode(name: "01", url: url, series: series)
        let vod = Vod(vodId: "fixture", episodeDetails: [episode], vodPlayFrom: "Quark", vodPlayUrl: "01$\(url)")
        let decoded = try JSONDecoder().decode(Vod.self, from: JSONEncoder().encode(vod))
        let parsed = try #require(decoded.parseFlags().first?.episodes.first)
        #expect(parsed.series == series)
        #expect(parsed.id == Episode(name: "01", url: url).id)
        #expect(parsed.url == url)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
        state.applyPlaybackAvailability(for: decoded)
        #expect(state.episodes.first?.series == series)
        #expect(state.episodeGroups.first?.id == series.id)
        let legacy = try JSONDecoder().decode(Episode.self, from: Data(#"{"name":"01","url":"file","isSelected":false}"#.utf8))
        #expect(legacy.series == nil)
    }

    @Test func refreshedShareTokenKeepsTheCurrentFileEvenWhenNamesRepeat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
        func reference(_ fid: String, token: String) -> DriveFileReference {
            DriveFileReference(provider: .baidu, shareURL: "https://pan.baidu.com/s/fixture",
                pwdID: "fixture", fid: fid, fidToken: token, fileName: "01.mkv", filePath: "/Series/01.mkv")
        }
        let previous = reference("first", token: "expired")
        let refreshed = reference("first", token: "fresh")
        let next = reference("second", token: "fresh")
        state.episodes = [Episode(name: "01", url: refreshed.encodedURL), Episode(name: "01", url: next.encodedURL)]
        state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/current.mp4",
            metadata: ["vod.episodeURL": previous.encodedURL, "vod.episodeName": "01",
                       "vod.episodeSeriesID": DriveEpisodeSeries.source(for: previous).id])
        #expect(state.playbackEpisodeContext().currentIndex == 0)
        #expect(state.playbackEpisodeContext().nextEpisode?.url == next.encodedURL)
    }

    @Test func baiduTransportMountAliasesDoNotSplitTheNinthEpisodeFromItsSeries() throws {
        let episodes = ["/sharelink0-123/Series/S01E08.mkv", "/sharelink456-123/Series/S01E09.mp4", "/sharelink0-123/Series/S01E10.mp4"].enumerated().map { index, path in
            Episode(name: "S01E\(index + 8)", url: DriveFileReference(
                provider: .baidu, shareURL: "https://pan.baidu.com/s/fixture", pwdID: "456",
                fid: "file-\(index)", fidToken: "fixture", fileName: (path as NSString).lastPathComponent,
                filePath: path
            ).encodedURL)
        }
        let group = try #require(DriveEpisodeSeries.groups(in: episodes).first)
        #expect(DriveEpisodeSeries.groups(in: episodes).count == 1)
        #expect(group.name == "Series")
        #expect(group.episodes.map(\.id) == episodes.map(\.id))
    }
}
