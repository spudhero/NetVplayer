#if DEBUG
import Foundation
import Models
import Testing
@testable import NetVplayerApp
@testable import SpiderEngine

private let auditMagnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=%E6%B5%8B%E8%AF%95+title&tr=https%3A%2F%2Ftracker.example.test%2Fannounce"
private let auditBundle = Episode(name: "Original bundle", url: auditMagnet)

@Test func magnetAuditUsesActualExpandedFirstFileAndItsOriginalIndex() throws {
    let files = MagnetPlaybackEpisodes.episodes(for: auditMagnet, files: [
        SixVMagnetPlaybackFile(index: 7, name: "First$#file.mkv", length: 1024,
                               url: URL(string: "http://127.0.0.1:32123/files/7")!),
        SixVMagnetPlaybackFile(index: 0, name: "Second.mkv", length: 2048,
                               url: URL(string: "http://127.0.0.1:32123/files/0")!)
    ])
    let prefix = Episode(name: "Earlier", url: "https://media.example.test/earlier.mp4")
    let suffix = Episode(name: "Later", url: "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    let selection = try DevelopmentAndroidMagnetAudit.select(
        original: auditBundle, before: [prefix, auditBundle, suffix], after: [prefix] + files + [suffix])
    #expect(selection.episode.name == files[0].name)
    #expect(selection.episode.url == files[0].url)
    #expect(selection.fileIndex == 7)
    #expect(selection.fileCount == 2)
    #expect(selection.requiresExplicitSelection)
}

@Test func magnetAuditDoesNotClickAgainAfterSingleFileAutomaticSelection() throws {
    let file = Episode(name: "One.mkv", url: auditMagnet + "&netvplayer_file=0")
    let selection = try DevelopmentAndroidMagnetAudit.select(original: auditBundle, before: [auditBundle], after: [file])
    #expect(!selection.requiresExplicitSelection)
    #expect(selection.episode.name == file.name)
    #expect(selection.episode.url == file.url)
    #expect(selection.fileIndex == 0)
}

@Test func magnetAuditScopeRequiresExactSiteAPITypeFlagAndVod() {
    let site = Site(key: "fixture-sixv", name: "Fixture", type: 3, api: "csp_SixVGuard")
    let scope = DevelopmentAndroidMagnetAudit.Scope(site: site, flag: "magnet", vodID: "fixture-vod")
    #expect(scope.matches(site: site, flag: "magnet", vodID: "fixture-vod"))
    #expect(!scope.matches(site: nil, flag: "magnet", vodID: "fixture-vod"))
    #expect(!scope.matches(site: site, flag: "another-line", vodID: "fixture-vod"))
    #expect(!scope.matches(site: site, flag: "magnet", vodID: "another-vod"))
    #expect(!scope.matches(site: site, flag: "magnet", vodID: nil))
    for changed in [Site(key: "other", type: 3, api: site.api),
                    Site(key: site.key, type: 3, api: "csp_Other"),
                    Site(key: site.key, type: 1, api: site.api)] {
        #expect(!scope.matches(site: changed, flag: "magnet", vodID: "fixture-vod"))
    }
}

@Test func magnetAuditRejectsChangedMagnetOrAdditionalQueryIdentity() {
    let invalid = [
        auditMagnet.replacingOccurrences(of: "0123456789abcdef0123456789abcdef01234567", with: String(repeating: "a", count: 40)),
        auditMagnet.replacingOccurrences(of: "tracker.example.test", with: "other.example.test"),
        auditMagnet + "&dn=another-title", auditMagnet + "&tr=https://extra.example.test/announce",
        auditMagnet + "#fragment", "https://media.example.test/file.mkv"
    ]
    for url in invalid {
        #expect(throws: DevelopmentAndroidMagnetAudit.Failure.fileIdentityInvalid) {
            try DevelopmentAndroidMagnetAudit.select(original: auditBundle, before: [auditBundle],
                after: [Episode(name: "File.mkv", url: url + "&netvplayer_file=0")])
        }
    }
}

@Test func magnetAuditRequiresUniqueCanonicalNonnegativeFileIndex() {
    for suffix in ["", "&netvplayer_file", "&netvplayer_file=", "&netvplayer_file=-1",
                   "&netvplayer_file=01", "&netvplayer_file=+1", "&netvplayer_file=1.0",
                   "&netvplayer_file=999999999999999999999999", "&netvplayer_file=0&netvplayer_file=1"] {
        #expect(throws: DevelopmentAndroidMagnetAudit.Failure.fileIdentityInvalid) {
            try DevelopmentAndroidMagnetAudit.select(original: auditBundle, before: [auditBundle],
                after: [Episode(name: "File.mkv", url: auditMagnet + suffix)])
        }
    }
    #expect(throws: DevelopmentAndroidMagnetAudit.Failure.duplicateFileIndex) {
        try DevelopmentAndroidMagnetAudit.select(original: auditBundle, before: [auditBundle], after: [
            Episode(name: "File A.mkv", url: auditMagnet + "&netvplayer_file=2"),
            Episode(name: "File B.mkv", url: auditMagnet + "&netvplayer_file=2")])
    }
}

@Test func magnetAuditRejectsUnrelatedEpisodeListOrTitleChanges() {
    let prefix = Episode(name: "Earlier", url: "https://media.example.test/a.mp4")
    let suffix = Episode(name: "Later", url: "https://media.example.test/b.mp4")
    let file = Episode(name: "File.mkv", url: auditMagnet + "&netvplayer_file=3")
    for after in [
        [Episode(name: "Changed", url: prefix.url), file, suffix],
        [Episode(name: prefix.name, url: suffix.url), file, suffix],
        [prefix, file, Episode(name: "Changed", url: suffix.url)],
        [prefix, file, Episode(name: suffix.name, url: prefix.url)],
        [file, prefix, suffix]
    ] {
        #expect(throws: DevelopmentAndroidMagnetAudit.Failure.surroundingEpisodesChanged) {
            try DevelopmentAndroidMagnetAudit.select(original: auditBundle, before: [prefix, auditBundle, suffix], after: after)
        }
    }
}

@Test func magnetAuditRejectsMissingAmbiguousOrPreviouslyExpandedOriginal() {
    let file = Episode(name: "File.mkv", url: auditMagnet + "&netvplayer_file=1")
    for before in [[], [Episode(name: "Changed", url: auditMagnet)], [auditBundle, auditBundle]] {
        #expect(throws: DevelopmentAndroidMagnetAudit.Failure.originalAmbiguous) {
            try DevelopmentAndroidMagnetAudit.select(original: auditBundle, before: before, after: [file])
        }
    }
    #expect(throws: DevelopmentAndroidMagnetAudit.Failure.originalInvalid) {
        try DevelopmentAndroidMagnetAudit.select(original: file, before: [file], after: [file])
    }
    #expect(throws: DevelopmentAndroidMagnetAudit.Failure.notExpanded) {
        try DevelopmentAndroidMagnetAudit.select(original: auditBundle, before: [auditBundle], after: [])
    }
    #expect(throws: DevelopmentAndroidMagnetAudit.Failure.fileIdentityInvalid) {
        try DevelopmentAndroidMagnetAudit.select(original: auditBundle, before: [auditBundle], after: [auditBundle])
    }
}

@Test func magnetAuditRejectsReorderedOriginalQueryItems() {
    var components = URLComponents(string: auditMagnet)!
    components.queryItems = components.queryItems!.reversed() + [URLQueryItem(name: "netvplayer_file", value: "0")]
    #expect(throws: DevelopmentAndroidMagnetAudit.Failure.fileIdentityInvalid) {
        try DevelopmentAndroidMagnetAudit.select(original: auditBundle, before: [auditBundle],
            after: [Episode(name: "File.mkv", url: components.string!)])
    }
}
#endif
