import AppKit
import Foundation
import Testing
import Models
import Storage
@testable import PlayerEngine

@Test func dualSubtitleParserDistinguishesBothSelectedTracksAndExternalAliases() throws {
    let json = #"[{"id":1,"type":"sub","codec":"ass","selected":true,"main-selection":0},{"id":2,"type":"sub","codec":"subrip","selected":true,"main-selection":1,"external":true,"external-filename":"/tmp/s.srt"}]"#
    let parsed = try MPVTrackListParser.parse(json: json)
    #expect(parsed.selectedSubtitleTrackID == "1")
    #expect(parsed.selectedSecondarySubtitleTrackID == "2")
    #expect(parsed.externalTrackIDs["/tmp/s.srt"] == "2")
    let style = PlayerSubtitlePolicy.mpvOptions(for: .init())
    #expect(style["secondary-sid"] == nil)
    #expect(style["secondary-sub-visibility"] == nil)
    #expect(style["secondary-sub-pos"] == "5")
}

@Test func dualSubtitleTimingAndExternalIdentityRemainIndependent() throws {
    let suite = "dual-subtitle-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = UserPreferences(defaults: defaults)
    let spec = PlaySpec(url: "file:///tmp/a.mkv")
    prefs.saveSubtitleDelay(1.5, for: spec)
    prefs.saveSubtitleDelay(-2, for: spec, secondary: true)
    #expect(prefs.subtitleDelay(for: spec) == 1.5)
    #expect(prefs.subtitleDelay(for: spec, secondary: true) == -2)
    prefs.saveSubtitleDelay(0, for: spec)
    #expect(prefs.subtitleDelay(for: spec, secondary: true) == -2)
    let legacy = try JSONDecoder().decode(SubtitleDelayRecord.self, from: Data(#"{"key":"fixture","seconds":2}"#.utf8))
    #expect(legacy.secondarySeconds == 0)
    let a = Sub(name: "English", url: "https://cdn.test/a?token=first", lang: "eng", format: "srt")
    var b = a; b.url = "https://other.test/a?token=new"
    #expect(SubtitleMediaIdentity.externalIdentifier(for: a) == SubtitleMediaIdentity.externalIdentifier(for: b))
    #expect(!SubtitleMediaIdentity.externalIdentifier(for: a).contains("token"))
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil))
func dualSubtitleNativeSelectionReuseAndMediaReset() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"])
    _ = NSApplication.shared
    let engine = MPVPlayerEngine(videoSurface: .vod)
    let state = PlayerState(); engine.playerState = state
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
    let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
    view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
    engine.attach(to: view, surface: .vod)
    defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
    let data = Data("1\n00:00:00,000 --> 00:00:30,000\nSubtitle\n".utf8).base64EncodedString()
    let first = Sub(name: "Chinese", url: "data:text/plain;base64," + data, lang: "chi", format: "srt")
    let second = Sub(name: "English", url: "data:text/plain;base64," + data, lang: "eng", format: "srt")
    await engine.play(spec: PlaySpec(url: URL(fileURLWithPath: path).absoluteString, subs: [first, second]))
    try #require(await dualSubtitleWait { !state.isMediaLoading && state.subtitleTracks.count == 2 })
    let tracks = state.subtitleTracks
    engine.selectSubtitleTrack(id: tracks[0].id)
    engine.selectSubtitleTrack(id: tracks[1].id, slot: .secondary)
    let selected = await dualSubtitleWait { state.selectedSubtitleTrackID == tracks[0].id && state.selectedSecondarySubtitleTrackID == tracks[1].id }
    try #require(selected, "expected \(tracks.map(\.id)), got \(state.selectedSubtitleTrackID ?? "nil")/\(state.selectedSecondarySubtitleTrackID ?? "nil"); \(engine.nativePropertyJSON("track-list") ?? "nil")")
    engine.refreshSubtitleStyle()
    #expect(engine.nativePropertyJSON("secondary-sid") == tracks[1].id)
    engine.loadExternalSubtitle(tracks[1].name == "English" ? second : first, select: true, slot: .secondary)
    #expect(await dualSubtitleWait { state.subtitleTracks.count == 2 })
    engine.selectSubtitleTrack(id: tracks[1].id)
    try #require(await dualSubtitleWait { state.selectedSubtitleTrackID == tracks[1].id && state.selectedSecondarySubtitleTrackID == nil })
    engine.setSubtitleDelay(2); engine.setSubtitleDelay(-1, slot: .secondary)
    await engine.play(spec: PlaySpec(url: URL(fileURLWithPath: path).absoluteString))
    try #require(await dualSubtitleWait { !state.isMediaLoading && state.subtitleTracks.isEmpty })
    #expect(state.subtitleDelaySeconds == 0)
    #expect(state.secondarySubtitleDelaySeconds == 0)
    #expect(state.selectedSecondarySubtitleTrackID == nil)
}

@MainActor
private func dualSubtitleWait(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
    return predicate()
}
