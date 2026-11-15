#if DEBUG
import Foundation
import Models
import Testing
@testable import NetVplayerApp

@Test func playbackTargetRequiresTheFirstSettledPosition() {
    var landing = DevelopmentAndroidSampling.PlaybackTargetLanding(targetSeconds: 100)
    let loading = landing.observe(position: 0, settled: false)
    #expect(!loading)
    #expect(!landing.failed)
    let reached = landing.observe(position: 101, settled: true)
    #expect(reached)
    #expect(landing.firstSettledPosition == 101)
    let later = landing.observe(position: 150, settled: true)
    #expect(later)
    #expect(landing.firstSettledPosition == 101)
}

@Test func ignoredSeekCannotPassByEventuallyPlayingThroughTarget() {
    var landing = DevelopmentAndroidSampling.PlaybackTargetLanding(targetSeconds: 100)
    for position in 0...150 {
        let accepted = landing.observe(position: Double(position), settled: true)
        #expect(!accepted)
    }
    #expect(landing.failed)
    #expect(landing.firstSettledPosition == 0)
}

@Test func playbackTargetRejectsInvalidPositionAndBoundsBothDirections() {
    for position in [-1.0, Double.nan, Double.infinity, 87, 113] {
        var landing = DevelopmentAndroidSampling.PlaybackTargetLanding(targetSeconds: 100)
        let accepted = landing.observe(position: position, settled: true)
        #expect(!accepted)
        #expect(landing.failed)
    }
    for target in [-1.0, Double.nan, Double.infinity] {
        var landing = DevelopmentAndroidSampling.PlaybackTargetLanding(targetSeconds: target)
        let accepted = landing.observe(position: 0, settled: true)
        #expect(!accepted)
        #expect(landing.failed)
    }
}

private func actualSavedHistory() -> History {
    History(key: "source@@vod", siteKey: "source", vodId: "vod", vodFlag: "line",
        episodeUrl: "opaque:episode", position: 47_000, duration: 200_000,
        sourceFingerprint: "frozen-source", originalDetailRequestID: "detail")
}

private func matchingSavedHistory(_ items: [History]) -> History? {
    DevelopmentAndroidHistoryAudit.matchingHistory(items, siteKey: "source", vodID: "vod",
        detailRequestID: "detail", flag: "line", episodeURL: "opaque:episode", sourceFingerprint: "frozen-source")
}

@Test func savedHistoryRetainsTheRealPositionAndRequiresOneExactRecord() {
    let saved = actualSavedHistory()
    #expect(matchingSavedHistory([saved]) == saved)
    #expect(matchingSavedHistory([]) == nil)
    #expect(matchingSavedHistory([saved, saved]) == nil)
    var wrongEpisode = saved
    wrongEpisode.episodeUrl = "opaque:other"
    #expect(matchingSavedHistory([wrongEpisode]) == nil)
    #expect(matchingSavedHistory([wrongEpisode, saved]) == saved)
}

@Test func savedHistoryRejectsDifferentContentSourceAndInvalidResumeState() {
    for field in ["site", "vod", "request", "flag", "source", "empty_source", "zero", "ended", "speed", "identity"] {
        var saved = actualSavedHistory()
        switch field {
        case "site": saved.siteKey = "other"
        case "vod": saved.vodId = "other"
        case "request": saved.originalDetailRequestID = "other"
        case "flag": saved.vodFlag = "other"
        case "source": saved.sourceFingerprint = "other"
        case "empty_source": saved.sourceFingerprint = ""
        case "zero": saved.position = 0
        case "ended": saved.position = saved.duration
        case "speed": saved.speed = 2
        default: saved.originalEpisodeIdentitySHA256 = String(repeating: "0", count: 64)
        }
        #expect(matchingSavedHistory([saved]) == nil)
    }
    var sanitized = actualSavedHistory()
    sanitized.originalEpisodeIdentitySHA256 = OriginalAndroidPlaybackIdentity.episodeSHA256(for: sanitized.episodeUrl)
    sanitized.episodeUrl = ""
    #expect(matchingSavedHistory([sanitized]) == sanitized)
}
@Test func savedHistoryMatchesItsPersistedEpisodeKeyAfterRemoteLocatorRemoval() {
    let rawURL = "https://fixture.invalid/original-episode?token=temporary"
    let actual = History(key: "source@@vod", siteKey: "source", vodId: "vod", vodFlag: "line",
        episodeUrl: rawURL, position: 47_000, duration: 200_000,
        sourceFingerprint: "frozen-source", originalDetailRequestID: "detail")
    let stored = HistoryPersistencePolicy.sanitized(actual)
    #expect(stored.episodeUrl.isEmpty)
    #expect(!stored.episodeKey.isEmpty)
    let match = DevelopmentAndroidHistoryAudit.matchingHistory([stored], siteKey: "source", vodID: "vod",
        detailRequestID: "detail", flag: "line", episodeURL: rawURL, sourceFingerprint: "frozen-source")
    #expect(match == stored)
    for field in ["site", "vod", "flag", "file", "key", "explicit_identity", "source", "request"] {
        var changed = stored
        switch field {
        case "site": changed.siteKey = "other"
        case "vod": changed.vodId = "other"
        case "flag": changed.vodFlag = "other"
        case "file": changed.episodeKey = HistoryPersistencePolicy.episodeKey(
            siteKey: "source", vodId: "vod", vodFlag: "line", episodeURL: "https://fixture.invalid/another-file")
        case "key": changed.episodeKey = ""
        case "explicit_identity": changed.originalEpisodeIdentitySHA256 = String(repeating: "0", count: 64)
        case "source": changed.sourceFingerprint = "another-source"
        default: changed.originalDetailRequestID = "another-request"
        }
        #expect(DevelopmentAndroidHistoryAudit.matchingHistory([changed], siteKey: "source", vodID: "vod",
            detailRequestID: "detail", flag: "line", episodeURL: rawURL, sourceFingerprint: "frozen-source") == nil)
    }
    #expect(DevelopmentAndroidHistoryAudit.matchingHistory([stored, stored], siteKey: "source", vodID: "vod",
        detailRequestID: "detail", flag: "line", episodeURL: rawURL, sourceFingerprint: "frozen-source") == nil)
}
#endif
