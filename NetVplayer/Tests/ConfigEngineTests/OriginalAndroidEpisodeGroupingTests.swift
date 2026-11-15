import Foundation
import Testing
import Models
import Storage
import DriveEngine
import ApplicationCore
@testable import NetVplayerApp

/// Synthetic SDK records only; no Provider, account, or network is involved.
enum AndroidGroupingFixture {
    static func object(_ marker: String = "夸父盘", share: String = "fixture-share-a",
                       directory: String = "hdr", file: String = "01", token: String = "fixture-token") -> [String: Any] {
        switch marker {
        case "阿狸盘":
            return ["drive_id": "fixture-drive", "parent_file_id": directory, "sToken": token,
                    "size": 4096, "file_id": file, "sub": "", "sId": share,
                    "name": "\(file).mkv", "flag": marker, "vodName": "Fixture collection"]
        case "嘟嘟盘":
            return ["pg": 1, "parent": directory, "share_id": share, "uk": "fixture-owner",
                    "surl": "fixture-key", "fs_id": file, "shareUser": "fixture-owner",
                    "path": "/Series/\(directory)/\(file).mkv", "seKey": token,
                    "vodName": "Fixture collection", "sub": [], "size": 4096, "isdir": false,
                    "flag": marker, "server_filename": "\(file).mkv"]
        default:
            var object: [String: Any] = ["pg": 1, "parent": "/Series/\(directory)", "sId": share,
                "sToken": token, "shareUser": "fixture-user", "share_fid_token": token,
                "fid": file, "vodName": "Fixture collection", "pdir_fid": directory,
                "sub": [], "size": 4096, "flag": marker, "file_name": "\(file).mkv"]
            if marker == "夸父盘" {
                object["l_created_at"] = 0
                object["format_type"] = "video"
            }
            return object
        }
    }

    static func id(_ object: [String: Any]) throws -> String {
        "  " + String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) + " "
    }

    static func episodes(_ marker: String = "夸父盘") throws -> [Episode] {
        try [("fixture-share-a", "4K HDR", "01"), ("fixture-share-a", "4K HDR", "02"),
             ("fixture-share-a", "4K SDR", "01"), ("fixture-share-b", "4K HDR", "01")].map { share, directory, file in
            Episode(name: "\(file).mkv", url: try id(object(marker, share: share, directory: directory, file: file)))
        }
    }

    static func detail(_ episodes: [Episode], flags: [String] = ["夸父原1", "夸父智1"]) -> Vod {
        let list = episodes.map { "\($0.name)$\($0.url)" }.joined(separator: "#")
        var vod = Vod(vodId: "fixture", vodName: "Android 资源分组", vodContent: "合成目录数据",
                      vodPlayFrom: flags.joined(separator: "$$$"),
                      vodPlayUrl: flags.map { _ in list }.joined(separator: "$$$"))
        vod.originalAndroidEpisodeParsing = true
        return vod
    }
}

@Suite @MainActor
struct OriginalAndroidEpisodeGroupingTests {
    @Test(arguments: ["夸父盘", "优汐盘", "阿狸盘", "嘟嘟盘"])
    func sharesAndDirectoriesDefineGroupsWithoutChangingOriginalIDs(marker: String) throws {
        let episodes = try AndroidGroupingFixture.episodes(marker)
        let groups = DriveEpisodeSeries.groups(in: episodes)
        #expect(groups.map { $0.episodes.count } == [2, 1, 1])
        #expect(Set(groups.map(\.id)).count == 3)
        #expect(groups.flatMap(\.episodes).map(\.id) == episodes.map(\.id))
        #expect(groups[0].name == (marker == "阿狸盘" ? "" : "4K HDR"))
        #expect(groups.allSatisfy { $0.id.hasPrefix("android-series:") && !$0.id.contains("fixture-share") })
        var renamed = AndroidGroupingFixture.object(marker, directory: "4K HDR", file: "03")
        renamed[marker == "阿狸盘" ? "name" : marker == "嘟嘟盘" ? "server_filename" : "file_name"] = "1080p.mp4"
        renamed["size"] = 9000
        #expect(OriginalAndroidPlaybackIdentity.episodeSeries(for: try AndroidGroupingFixture.id(renamed))?.id == groups[0].id)
    }

    @Test func sameShareAndDirectoryAcrossDriveTypesStaySeparate() throws {
        let episodes = try ["夸父盘", "优汐盘", "阿狸盘", "嘟嘟盘"].map {
            Episode(name: "01", url: try AndroidGroupingFixture.id(AndroidGroupingFixture.object($0)))
        }
        #expect(DriveEpisodeSeries.groups(in: episodes).count == 4)
        var explicit = episodes[0]
        explicit.series = EpisodeSeries(id: "explicit", name: "Already supplied")
        #expect(DriveEpisodeSeries.source(for: explicit) == explicit.series)
    }

    @Test func detailAndCachePreserveFlagsIDsAndDeriveGroupsForExistingCaches() throws {
        let episodes = try AndroidGroupingFixture.episodes()
        let original = AndroidGroupingFixture.detail(episodes)
        let decoded = try JSONDecoder().decode(Vod.self, from: JSONEncoder().encode(original))
        #expect(decoded.vodPlayFrom == original.vodPlayFrom)
        #expect(decoded.vodPlayUrl.utf8.elementsEqual(original.vodPlayUrl.utf8))
        #expect(decoded.episodeDetails.isEmpty)
        #expect(decoded.parseFlags().map(\.name) == ["夸父原1", "夸父智1"])
        #expect(decoded.parseFlags().allSatisfy { $0.episodes.map(\.url) == episodes.map(\.url) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
        state.applyPlaybackAvailability(for: decoded)
        #expect(state.playFlags == ["夸父原1", "夸父智1"])
        #expect(state.selectedPlayFlag == "夸父原1")
        #expect(state.displayedEpisodeGroups.map { $0.episodes.count } == [2, 1, 1])
        state.episodes = [episodes[0], episodes[1]]
        #expect(state.displayedEpisodeGroups.count == 1)
        #expect(state.displayedPlaybackEpisodes.map(\.url) == Array(episodes.prefix(2)).map(\.url))
    }

    @Test(arguments: [false, true])
    func originalAndroidQueuesFollowVisibleGroupAndStopAtBothEnds(descending: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
        state.applyPlaybackAvailability(for: AndroidGroupingFixture.detail(try AndroidGroupingFixture.episodes()))
        state.episodeSortOrder = descending ? .descending : .ascending
        let groups = state.displayedEpisodeGroups
        for group in groups {
            for (index, episode) in group.episodes.enumerated() {
                state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/current",
                    metadata: ["vod.episodeURL": episode.url, "vod.episodeName": episode.name, "vod.episodeSeriesID": group.id], flag: "夸父原1")
                let context = state.playbackEpisodeContext()
                #expect(context.currentIndex == index && context.total == group.episodes.count)
                #expect(context.previousEpisode?.id == (index > 0 ? group.episodes[index - 1].id : nil))
                #expect(context.nextEpisode?.id == (index + 1 < group.episodes.count ? group.episodes[index + 1].id : nil))
                let transition = PlaybackSessionCore.requestAutoAdvance(PlaybackSessionState(),
                    episodeURL: episode.url, context: context, isLoading: false)
                #expect(transition.targetEpisode?.id == context.nextEpisode?.id)
                // Browsing the other original SDK line cannot change the queue.
                state.selectPlayFlag("夸父智1")
                #expect(state.playbackEpisodeContext().nextEpisode?.id == context.nextEpisode?.id)
                state.selectPlayFlag("夸父原1")
            }
        }
    }

    @Test(arguments: ["夸父盘", "优汐盘", "阿狸盘", "嘟嘟盘"])
    func refreshedSDKTokensFindExactFileAndRemovedFilesNeverMatchByName(marker: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false,
            storageManager: StorageManager(storageDirectory: directory), providerRuntimeBootstrap: nil)
        let old = try AndroidGroupingFixture.id(AndroidGroupingFixture.object(marker, token: "old-session"))
        let current = Episode(name: "same-name", url: try AndroidGroupingFixture.id(AndroidGroupingFixture.object(marker, token: "new-session")))
        let other = Episode(name: "same-name", url: try AndroidGroupingFixture.id(AndroidGroupingFixture.object(marker, file: "02", token: "new-session")))
        let series = try #require(DriveEpisodeSeries.source(for: current))
        state.episodes = [other, current]
        state.playerState.currentSpec = PlaySpec(url: "https://media.example.test/current",
            metadata: ["vod.episodeURL": old, "vod.episodeName": "same-name", "vod.episodeSeriesID": series.id])
        #expect(state.episodeForCurrentPlayback(in: state.episodes)?.url == current.url)
        #expect(OriginalAndroidPlaybackIdentity.episodeSeries(for: old)?.id == series.id)
        state.episodes = [other]
        #expect(state.episodeForCurrentPlayback(in: state.episodes) == nil)
        #expect(state.playbackEpisodeContext().currentIndex == nil)
        #expect(!state.playbackEpisodeContext().hasNext)
    }

    @Test func baiduPathsDecodeOnceAndOwnerIsPartOfTheShareIdentity() throws {
        var raw = AndroidGroupingFixture.object("嘟嘟盘")
        raw["path"] = "/Series/4K%2F HDR/01.mkv"
        var encoded = raw
        encoded["path"] = "%2FSeries%2F4K%252F%20HDR%2F02.mkv"
        let first = try #require(OriginalAndroidPlaybackIdentity.episodeSeries(for: AndroidGroupingFixture.id(raw)))
        let second = try #require(OriginalAndroidPlaybackIdentity.episodeSeries(for: AndroidGroupingFixture.id(encoded)))
        #expect(first == second && first.name == "4K%2F HDR")
        encoded["uk"] = "another-owner"
        #expect(OriginalAndroidPlaybackIdentity.episodeSeries(for: try AndroidGroupingFixture.id(encoded))?.id != first.id)
    }

    @Test func unknownAndInvalidSchemasKeepTheirOriginalPresentation() throws {
        let base = AndroidGroupingFixture.object()
        var cases: [[String: Any]] = []
        for (key, value) in [("unexpected", "future"), ("sId", ""), ("pdir_fid", "bad\nparent"),
                             ("pdir_fid", String(repeating: "x", count: 4097)), ("flag", "unknown")] {
            var object = base
            object[key] = value
            cases.append(object)
        }
        var missing = base
        missing.removeValue(forKey: "pdir_fid")
        cases.append(missing)
        var wrongType = base
        wrongType["pdir_fid"] = 7
        cases.append(wrongType)
        var invalidPath = AndroidGroupingFixture.object("嘟嘟盘")
        invalidPath["path"] = "%2FSeries%2Fbad%0Apath%2F01.mkv"
        cases.append(invalidPath)
        let ids = try cases.map(AndroidGroupingFixture.id) + ["opaque-id", "{invalid", String(repeating: "x", count: 65537)]
        #expect(ids.allSatisfy { OriginalAndroidPlaybackIdentity.episodeSeries(for: $0) == nil })
        let episodes = ids.map { Episode(name: "4K HDR 01", url: $0) }
        #expect(DriveEpisodeSeries.groups(in: episodes).count == 1)
        #expect(DriveEpisodeSeries.groups(in: episodes)[0].episodes.map(\.url) == ids)
        var unnamed = base
        unnamed["parent"] = "opaque-parent"
        unnamed["pdir_fid"] = ""
        let series = try #require(OriginalAndroidPlaybackIdentity.episodeSeries(for: AndroidGroupingFixture.id(unnamed)))
        #expect(series.name.isEmpty)
    }
}
