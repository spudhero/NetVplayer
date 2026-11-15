#if DEBUG
import Foundation
import Models
import DriveEngine
import SpiderEngine
import Testing
@testable import NetVplayerApp

@Test func developmentAndroidReplaySelectsOriginalFileAfterReorderAndSessionRefresh() throws {
    let selection = try JSONDecoder().decode(DevelopmentAndroidReplayAudit.Selection.self,
        from: Data(#"{"vodID":"original-share","flag":"阿狸原","fileID":"file-100"}"#.utf8))
    let original = Episode(name: "Episode 100", url: #"{"file_id":"file-100","sToken":"old-session"}"#)
    let refreshed = Episode(name: "Episode 100", url: #"{"file_id":"file-100","sToken":"new-session"}"#)
    let other = Episode(name: "Episode 125", url: #"{"file_id":"file-125"}"#)
    #expect(selection.episodeIndex(in: [original, other]) == 0)
    #expect(selection.episodeIndex(in: [other, refreshed]) == 1)
    #expect(selection.episodeIndex(in: [other]) == nil)
    #expect(selection.episodeIndex(in: [original, refreshed]) == nil)
    #expect(selection.episodeIndex(in: [Episode(name: "Episode 100", url: "https://example.test/file-100")]) == nil)
    let native = DriveFileReference(provider: .ali, shareURL: "https://www.alipan.com/s/original-share",
        pwdID: "original-share", fid: "file-100", fidToken: "", fileName: "100.mp4")
    let expanded = Episode(name: "100.mp4", url: native.encodedURL)
    #expect(selection.episodeIndex(in: [other, expanded]) == 1)
    #expect(selection.episodeIndex(in: [expanded, original]) == nil)
    #expect(selection.episodeIndex(in: [Episode(name: "100.mp4", url: native.encodedURL + "&fid=another")]) == nil)
    #expect(selection.episodeKinds(in: [other, expanded]) == ["json": 1, "native_drive": 1])
}

@Test func developmentAndroidReplayRejectsInvalidInputInsteadOfChoosingFirstEpisode() throws {
    for (vod, flag, file): (String, String, String) in [
        ("", "阿狸原", "file-100"), ("original-share", "", "file-100"),
        ("original-share", "阿狸原", ""), ("original-share", "阿狸原", "file-100\n"),
        (String(repeating: "x", count: 64 * 1024 + 1), "阿狸原", "file-100")
    ] {
        let data = try JSONSerialization.data(withJSONObject: ["vodID": vod, "flag": flag, "fileID": file])
        let selection = try JSONDecoder().decode(DevelopmentAndroidReplayAudit.Selection.self, from: data)
        #expect(!selection.isValid)
        #expect(selection.episodeIndex(in: [Episode(name: "Episode 100", url: #"{"file_id":"file-100"}"#)]) == nil)
    }
}

@Test func developmentAndroidReplayAllowsOnlyIdenticalStableFilesAmongDuplicateIDs() throws {
    let original: [String: Any] = ["drive_id": "shared-drive", "parent_file_id": "parent", "sToken": "old-session",
        "size": 4096, "file_id": "file-100", "sub": "", "sId": "original-share", "name": "100.mp4", "flag": "阿狸盘", "vodName": "Fixture"]
    func json(_ fields: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }
    let identity = try #require(DevelopmentAndroidReplayAudit.Selection.stableIdentitySHA256(for: json(original)))
    var selection = try JSONDecoder().decode(DevelopmentAndroidReplayAudit.Selection.self,
        from: Data(#"{"vodID":"original-share","flag":"阿狸原","fileID":"file-100"}"#.utf8))
    selection.episodeIdentitySHA256 = identity
    var refreshed = original
    refreshed["sToken"] = "new-session"
    let duplicate = Episode(name: "Reordered label", url: try json(refreshed))
    for key in ["drive_id", "parent_file_id", "name", "sId", "sub", "vodName"] {
        var different = original
        different[key] = "different"
        let other = Episode(name: "Same file ID", url: try json(different))
        #expect(selection.episodeIndex(in: [other]) == nil)
        #expect(selection.episodeIndex(in: [other, duplicate, duplicate]) == 1)
        #expect(selection.identityMatchingIndices(in: [other, duplicate, duplicate]) == [1, 2])
    }
    var differentSize = original
    differentSize["size"] = 8192
    #expect(selection.episodeIndex(in: [Episode(name: "Changed", url: try json(differentSize))]) == nil)
    selection.episodeIdentitySHA256 = "invalid"
    #expect(!selection.isValid)
    #expect(selection.episodeIndex(in: [duplicate]) == nil)
}
@Test(arguments: ["嘟嘟盘", "夸父盘", "优汐盘"])
func developmentAndroidReplayRequiresSameCloudShareFileAndSubtitleAcrossRefresh(marker: String) throws {
    let baidu = marker == "嘟嘟盘"
    let fileKey = baidu ? "fs_id" : "fid"
    let keys: [String] = baidu
        ? ["pg", "parent", "share_id", "uk", "surl", "fs_id", "shareUser", "path", "seKey", "vodName", "sub", "size", "isdir", "flag", "server_filename"]
        : ["pg", "parent", "sId", "sToken", "shareUser", "share_fid_token", "fid", "vodName", "pdir_fid", "sub", "size", "flag", "file_name"] + (marker == "夸父盘" ? ["l_created_at", "format_type"] : [])
    var original: [String: Any] = Dictionary(uniqueKeysWithValues: keys.map { ($0, "fixture-" + $0) })
    original["size"] = 4096
    original["flag"] = marker
    original[fileKey] = "file-100"
    func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    var selection = try JSONDecoder().decode(DevelopmentAndroidReplayAudit.Selection.self,
        from: Data(#"{"vodID":"fixed-share","flag":"original-line","fileID":"file-100"}"#.utf8))
    #expect(selection.episodeIndex(in: [Episode(name: "same ID without stable identity", url: try json(original))]) == nil)
    selection.episodeIdentitySHA256 = DevelopmentAndroidReplayAudit.Selection.stableIdentitySHA256(for: try json(original))
    var refreshed = original
    for key in baidu ? ["seKey"] : ["sToken", "share_fid_token"] { refreshed[key] = "refreshed-session" }
    let episode = Episode(name: "same file", url: try json(refreshed))
    #expect(selection.episodeIndex(in: [episode]) == 0)
    for key in [fileKey, baidu ? "share_id" : "sId", "sub", "size"] {
        var changed = refreshed
        changed[key] = "different"
        let wrong = Episode(name: "same title", url: try json(changed))
        #expect(selection.episodeIndex(in: [wrong]) == nil)
        #expect(selection.episodeIndex(in: [wrong, episode]) == 1)
    }
}

@Test func developmentAndroidReplayRequiresExactRawEpisodeBytesAndUniqueMatch() throws {
    let url = "https://original.example.test/watch?id=one&sign=a%2Bb"
    let hash = DevelopmentAndroidLifecycleDiagnostics.sha256(Data(url.utf8))
    var selection = try JSONDecoder().decode(DevelopmentAndroidReplayAudit.Selection.self,
        from: JSONSerialization.data(withJSONObject: ["vodID": "original-film", "flag": "original-line", "episodeURLSHA256": hash]))
    let same = Episode(name: "title can change", url: url)
    let changed = Episode(name: "same title", url: url.replacingOccurrences(of: "one", with: "two"))
    #expect(selection.isValid)
    #expect(selection.episodeIndex(in: [changed, same]) == 1)
    #expect(selection.episodeIndex(in: [changed]) == nil)
    #expect(selection.episodeIndex(in: [same, same]) == nil)
    selection.episodeIdentitySHA256 = hash
    #expect(!selection.isValid)
}
#endif
