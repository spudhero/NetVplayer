import Foundation
import Models
import Testing

@Suite("History source file identity")
struct HistoryFileIdentityTests {
    @Test(arguments: [false, true])
    func refreshedCredentialsAndPresentationKeepTheSameSourceFile(referenceOnly: Bool) throws {
        let old = locator()
        let history = HistoryPersistencePolicy.sanitized(History(
            siteKey: "s", vodId: "v", episodeUrl: referenceOnly ? "" : old,
            episodeName: "旧片名", driveReferenceURL: old
        ))
        let current = Episode(name: "新片名", url: locator(token: "new", fileName: "renamed.mp4", personalID: "new-copy"))
        let stored = try JSONDecoder().decode(History.self, from: JSONEncoder().encode(history))
        #expect(PlaybackLinkage.preferredEpisode(from: stored, episodes: [current])?.url == current.url)
    }

    @Test(arguments: ["file", "provider", "share", "shareID"])
    func uniqueSameNameCannotReplaceAKnownSourceFile(change: String) {
        let history = History(siteKey: "s", vodId: "v", episodeUrl: locator(), episodeName: "第1集")
        let candidate = Episode(name: "第1集", url: locator(
            provider: change == "provider" ? "uc" : "quark",
            share: change == "share" ? "https://pan.quark.cn/s/other" : "https://pan.quark.cn/s/share",
            shareID: change == "shareID" ? "other-share" : "share",
            fileID: change == "file" ? "file-b" : "file-a"
        ))
        #expect(PlaybackLinkage.preferredEpisode(from: history, episodes: [candidate]) == nil)
    }

    @Test func savedDriveReferenceAlsoConstrainsAnOpaqueOrMissingEpisodeLocator() {
        let history = History(siteKey: "s", vodId: "v", episodeUrl: "old-opaque-id", episodeName: "第1集", driveReferenceURL: locator())
        #expect(PlaybackLinkage.preferredEpisode(from: history, episodes: [Episode(name: "第1集", url: "replacement-opaque-id")]) == nil)
        // The original opaque key remains valid evidence when the provider does not expose a file locator.
        let original = Episode(name: "第1集", url: "old-opaque-id")
        #expect(PlaybackLinkage.preferredEpisode(from: history, episodes: [original])?.url == original.url)
    }

    @Test func multipleMatchesDoNotChooseAnArbitraryVersion() {
        let history = History(siteKey: "s", vodId: "v", episodeUrl: locator(), episodeName: "第1集")
        let variants = [Episode(name: "第1集", url: locator(token: "new-1")), Episode(name: "第1集", url: locator(token: "new-2"))]
        #expect(PlaybackLinkage.preferredEpisode(from: history, episodes: variants) == nil)
        #expect(PlaybackLinkage.preferredEpisode(from: history, episodes: [Episode(name: "第1集", url: locator(fileID: "file-b")), Episode(name: "第1集", url: locator(fileID: "file-c"))]) == nil)
    }

    @Test func pikPakAndCompositeLocatorsKeepFileIdentity() {
        let history = History(siteKey: "s", vodId: "v", episodeUrl: "第1集$pikpak://file/file-a", episodeName: "第1集")
        let same = Episode(name: "已改名", url: "pikpak://file/file-a")
        #expect(PlaybackLinkage.preferredEpisode(from: history, episodes: [same])?.url == same.url)
        #expect(PlaybackLinkage.preferredEpisode(from: history, episodes: [Episode(name: "第1集", url: "pikpak://file/file-b")]) == nil)
    }

    @Test func legacyHistoriesWithoutAFileIDKeepUniqueNameFallback() {
        let candidate = Episode(name: "第1集", url: "refreshed-site-locator")
        for locator in ["", "old-site-locator", "netvplayer-drive://quark/file?share=https://pan.quark.cn/s/share"] {
            let history = History(siteKey: "s", vodId: "v", episodeUrl: locator, episodeName: " 第1集 ")
            #expect(PlaybackLinkage.preferredEpisode(from: history, episodes: [candidate])?.url == candidate.url)
            #expect(PlaybackLinkage.preferredEpisode(from: history, episodes: [candidate, candidate]) == nil)
        }
    }

    private func locator(
        provider: String = "quark", share: String = "https://pan.quark.cn/s/share", shareID: String = "share",
        fileID: String = "file-a", token: String = "old", fileName: String = "original.mp4", personalID: String = "old-copy"
    ) -> String {
        var value = URLComponents()
        value.scheme = "netvplayer-drive"
        value.host = provider
        value.path = "/file"
        value.queryItems = [
            .init(name: "share", value: share), .init(name: "pwd_id", value: shareID),
            .init(name: "fid", value: fileID), .init(name: "fid_token", value: token),
            .init(name: "passcode", value: token), .init(name: "file_name", value: fileName),
            .init(name: "personal_file_id", value: personalID)
        ]
        return value.string!
    }
}
