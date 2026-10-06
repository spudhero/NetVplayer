import Foundation
import Testing
import Models
import Storage
import PlayerEngine

@Test func subtitleDelayUsesSourceAndEpisodeIdentityRatherThanExpiringURL() throws {
    var first = PlaySpec(url: "https://cdn.test/v?token=first", metadata: [
        "library.sourceFingerprint": "source-a", "vod.siteKey": "site", "vod.id": "42", "vod.episodeName": "E01"
    ], title: "Same title")
    let key = try #require(SubtitleMediaIdentity.key(for: first))
    first.url = "https://other-cdn.test/v?token=new"
    #expect(SubtitleMediaIdentity.key(for: first) == key)
    first.metadata["vod.episodeName"] = "E02"
    #expect(SubtitleMediaIdentity.key(for: first) != key)
    first.metadata["vod.episodeName"] = "E01"
    first.metadata["library.sourceFingerprint"] = "source-b"
    #expect(SubtitleMediaIdentity.key(for: first) != key)
    #expect(!key.contains("42" + "E01"))
    #expect(SubtitleMediaIdentity.key(for: PlaySpec(url: "https://cdn.test/a?token=secret", title: "Same title")) == nil)
}

@Test func subtitleAppearanceClampsUntrustedBackupValuesAndRecognizesBitmapTracks() throws {
    let appearance = SubtitleAppearance(borderWidth: .nan, backgroundOpacity: 20, bitmapScale: -1)
    #expect(appearance.borderWidth == 2)
    #expect(appearance.backgroundOpacity == 1)
    #expect(appearance.bitmapScale == 0.5)
    let decoded = try JSONDecoder().decode(SubtitleAppearance.self, from: Data("{}".utf8))
    #expect(decoded == SubtitleAppearance())
    #expect(SubtitleTrackFormat(codec: "hdmv_pgs_subtitle") == .bitmap)
    #expect(SubtitleTrackFormat(codec: "dvd_subtitle") == .bitmap)
    #expect(SubtitleTrackFormat(codec: "ass") == .styledText)
    #expect(SubtitleTrackFormat(codec: "subrip") == .text)
    let settings = SubtitleRenderSettings(appearance: SubtitleAppearance(bitmapScale: 1.5))
    #expect(PlayerSubtitlePolicy.mpvOptions(for: settings, trackFormat: .bitmap)["sub-scale"] == "1.5")
    #expect(PlayerSubtitlePolicy.mpvOptions(for: settings, trackFormat: .text)["sub-scale"] == "1.0")
}

@Test func subtitlePreferencesPersistZeroPositionAndRestoreOptionalBackupFields() throws {
    let suite = "subtitle-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = UserPreferences(defaults: defaults)
    #expect(prefs.subtitlePosition == 95)
    prefs.subtitlePosition = 0
    #expect(prefs.subtitlePosition == 0)
    let first = PlaySpec(url: "file:///tmp/first.mkv")
    let second = PlaySpec(url: "file:///tmp/second.mkv")
    prefs.saveSubtitleDelay(1.25, for: first)
    #expect(prefs.subtitleDelay(for: first) == 1.25)
    #expect(prefs.subtitleDelay(for: second) == 0)
    prefs.subtitleAppearance = SubtitleAppearance(color: .yellow, backgroundOpacity: 0.5)
    let data = try JSONEncoder().encode(UserPreferenceSnapshot(preferences: prefs))
    let snapshot = try JSONDecoder().decode(UserPreferenceSnapshot.self, from: data)
    prefs.subtitleDelayRecords = []
    prefs.subtitleAppearance = .init()
    snapshot.apply(to: prefs)
    #expect(prefs.subtitleDelay(for: first) == 1.25)
    #expect(prefs.subtitleAppearance.color == .yellow)
    prefs.saveSubtitleDelay(0, for: first)
    #expect(prefs.subtitleDelayRecords.isEmpty)
    prefs.saveSubtitleDelay(3, for: PlaySpec(url: "https://cdn.test/a"))
    #expect(prefs.subtitleDelayRecords.isEmpty)
}

@Test func subtitleDelayPersistenceIsBoundedAndDeduplicated() {
    let records = (0..<1002).map { SubtitleDelayRecord(key: String(format: "%064x", $0), seconds: 999) }
    let sanitized = SubtitleDelayRecord.sanitized(records + [records[1001], .init(key: "secret-url", seconds: 2)])
    #expect(sanitized.count == 1000)
    #expect(sanitized.allSatisfy { $0.seconds == 120 })
    #expect(Set(sanitized.map(\.key)).count == sanitized.count)
    #expect(SubtitleMediaIdentity.normalizedDelay(.nan) == 0)
}
