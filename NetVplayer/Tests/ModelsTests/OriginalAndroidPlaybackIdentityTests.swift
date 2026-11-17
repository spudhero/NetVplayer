import Foundation
import Models
import Testing

private func originalBaiduID(token: String = "session-one", file: String = "file-one", extra: Bool = false) throws -> String {
    var object: [String: Any] = ["pg": 1, "parent": "folder", "share_id": "share", "uk": "owner", "surl": "share-key",
        "fs_id": file, "shareUser": "owner", "path": "/folder/movie.mkv", "seKey": token, "vodName": "Movie",
        "sub": [], "size": 100000, "isdir": false, "flag": "嘟嘟盘", "server_filename": "movie.mkv"]
    if extra { object["new-field"] = "unrecognized" }
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
}

@Test func originalAndroidFileSizeIsReadOnlyAndRejectsInvalidOrUnknownValues() throws {
    let id = try originalBaiduID()
    #expect(OriginalAndroidPlaybackIdentity.fileSizeBytes(for: id) == 100000)
    #expect(try OriginalAndroidPlaybackIdentity.fileSizeBytes(for: originalBaiduID(extra: true)) == nil)
    var object = try #require(JSONSerialization.jsonObject(with: Data(id.utf8)) as? [String: Any])
    for value: Any in [true, -1, 0, 3.5, "1234", NSNull()] {
        object["size"] = value
        let invalid = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(OriginalAndroidPlaybackIdentity.fileSizeBytes(for: invalid) == nil)
    }
    object["size"] = Int64.max
    let large = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    #expect(OriginalAndroidPlaybackIdentity.fileSizeBytes(for: large) == Int64.max)
    #expect(OriginalAndroidPlaybackIdentity.fileSizeBytes(for: "https://example.test/movie.mkv?size=200") == nil)
}

@Test func originalAndroidHistoryKeepsRequestAndFileIdentityWithoutSDKSession() throws {
    let original = try originalBaiduID()
    let saved = HistoryPersistencePolicy.sanitized(History(siteKey: "JPan", vodId: "returned-share-key", vodFlag: "original",
        episodeUrl: original, episodeName: "same-name", position: 83000,
        originalDetailRequestID: "https://share.example.test/original-request",
        originalEpisodeIdentitySHA256: OriginalAndroidPlaybackIdentity.episodeSHA256(for: original)))
    let bytes = try JSONEncoder().encode(saved)
    let decoded = try JSONDecoder().decode(History.self, from: bytes)
    #expect(decoded.originalDetailRequestID == saved.originalDetailRequestID)
    #expect(decoded.episodeUrl.isEmpty && !String(decoding: bytes, as: UTF8.self).contains("session-one"))
    let refreshed = try originalBaiduID(token: "session-two")
    let other = try originalBaiduID(token: "session-two", file: "file-two")
    let right = Episode(name: "same-name", url: refreshed)
    let wrong = Episode(name: "same-name", url: other)
    #expect(PlaybackLinkage.preferredEpisode(from: decoded, episodes: [wrong, right])?.url == refreshed)
    #expect(PlaybackLinkage.preferredEpisode(from: decoded, episodes: [wrong]) == nil)
}

@Test func originalAndroidIdentityRejectsUnknownSDKFieldsAndPreservesOpaqueIDs() throws {
    #expect(try OriginalAndroidPlaybackIdentity.stableCloudSHA256(for: originalBaiduID(extra: true)) == nil)
    #expect(try OriginalAndroidPlaybackIdentity.episodeSHA256(for: originalBaiduID(extra: true)) != OriginalAndroidPlaybackIdentity.episodeSHA256(for: originalBaiduID()))
    #expect(OriginalAndroidPlaybackIdentity.episodeSHA256(for: "episode:1") != OriginalAndroidPlaybackIdentity.episodeSHA256(for: "episode:2"))
}

@Test func originalAndroidHistoryFieldsAreOptionalForLegacyRecords() throws {
    let old = try JSONDecoder().decode(History.self, from: Data("{\"vodId\":\"legacy\"}".utf8))
    #expect(old.originalDetailRequestID == nil && old.originalEpisodeIdentitySHA256 == nil)
    let invalid = HistoryPersistencePolicy.sanitized(History(originalDetailRequestID: "bad\nrequest", originalEpisodeIdentitySHA256: "not-a-digest"))
    #expect(invalid.originalDetailRequestID == nil && invalid.originalEpisodeIdentitySHA256 == nil)
}
