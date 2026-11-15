import AppKit
import Foundation
import Testing
import Models
@testable import PlayerEngine

@Suite("Chinese then English subtitle defaults")
struct SubtitleDefaultSelectionTests {
    @Test(arguments: ["zh", "zh-Hans", "zh_Hant", "chi", "zho", "cmn", "yue"])
    func recognizesChineseLanguageTags(_ language: String) {
        let tracks = [
            PlayerTrackInfo(id: "1", kind: .subtitle, language: "ara"),
            PlayerTrackInfo(id: "2", kind: .subtitle, language: "eng"),
            PlayerTrackInfo(id: "34", kind: .subtitle, name: "Simplified", language: language),
            PlayerTrackInfo(id: "40", kind: .subtitle, name: "Arabic (SRT)", isExternal: true)
        ]
        #expect(PlayerSubtitlePolicy.preferredInitialSubtitleTrack(from: tracks, selectedID: "40")?.id == "34")
    }

    @Test func includesExternalTracksAndFallsBackToEnglish() {
        let english = PlayerTrackInfo(id: "38", kind: .subtitle, name: "English (SRT)", isExternal: true)
        let chinese = PlayerTrackInfo(id: "44", kind: .subtitle, name: "繁体中文", isExternal: true)
        let arabic = PlayerTrackInfo(id: "40", kind: .subtitle, name: "Arabic (SRT)", isExternal: true)
        #expect(PlayerSubtitlePolicy.preferredInitialSubtitleTrack(from: [arabic, english, chinese], selectedID: "40")?.id == "44")
        #expect(PlayerSubtitlePolicy.preferredInitialSubtitleTrack(from: [arabic, english], selectedID: "40")?.id == "38")
        #expect(PlayerSubtitlePolicy.preferredInitialSubtitleTrack(from: [arabic, english], selectedID: "38") == nil)
        #expect(PlayerSubtitlePolicy.preferredInitialSubtitleTrack(from: [arabic], selectedID: "40") == nil)
        #expect(PlayerSubtitlePolicy.preferredInitialSubtitleTrack(from: [
            PlayerTrackInfo(id: "1", kind: .subtitle, name: "Bengali", language: "ben"),
            PlayerTrackInfo(id: "2", kind: .audio, language: "zh")
        ], selectedID: nil) == nil)
    }

    @Test func selectsExplicitExternalLyricsWithoutGuessingTheirLanguage() {
        let lyrics = PlayerTrackInfo(id: "4", kind: .subtitle, name: "歌词", format: "ass", isExternal: true)
        let english = PlayerTrackInfo(id: "2", kind: .subtitle, language: "eng")
        #expect(PlayerSubtitlePolicy.preferredInitialSubtitleTrack(from: [lyrics], selectedID: nil)?.id == "4")
        #expect(PlayerSubtitlePolicy.preferredInitialSubtitleTrack(from: [lyrics], selectedID: "4") == nil)
        #expect(PlayerSubtitlePolicy.preferredInitialSubtitleTrack(from: [lyrics, english], selectedID: nil)?.id == "2")
        #expect(PlayerSubtitlePolicy.preferredInitialSubtitleTrack(from: [
            PlayerTrackInfo(id: "5", kind: .subtitle, name: " Lyrics ", language: "und", isExternal: true)
        ], selectedID: nil)?.id == "5")
        for track in [
            PlayerTrackInfo(id: "6", kind: .subtitle, name: "Unknown", isExternal: true),
            PlayerTrackInfo(id: "7", kind: .subtitle, name: "歌词", isExternal: false),
            PlayerTrackInfo(id: "8", kind: .subtitle, name: "Lyrics", language: "ara", isExternal: true),
            PlayerTrackInfo(id: "9", kind: .audio, name: "歌词", isExternal: true)
        ] {
            #expect(PlayerSubtitlePolicy.preferredInitialSubtitleTrack(from: [track], selectedID: nil) == nil)
        }
    }
}

@MainActor
@Suite("Native subtitle default selection", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_SUBTITLE_DEFAULT_FIXTURES"] != nil))
struct NativeSubtitleDefaultSelectionTests {
    @Test func embeddedExternalManualAndDisabledSelections() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_SUBTITLE_DEFAULT_FIXTURES"]))
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod, stopResourcePolicy: .fullDestroy)
        let state = PlayerState(); engine.playerState = state
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
        func subtitle(_ name: String, _ language: String) -> Sub {
            let bytes = Data("1\n00:00:00,000 --> 00:00:12,000\n\(name)\n".utf8).base64EncodedString()
            return Sub(name: name, url: "data:text/plain;base64," + bytes, lang: language, format: "srt")
        }
        func selectedLanguage() -> String? { state.subtitleTracks.first { $0.id == state.selectedSubtitleTrackID }?.language }
        func spec(_ file: String, subs: [Sub] = []) -> PlaySpec {
            PlaySpec(url: root.appendingPathComponent(file + ".mkv").absoluteString, subs: subs)
        }
        let arabic = subtitle("Arabic (SRT)", "ara")
        let english = subtitle("English (SRT)", "eng")
        await engine.play(spec: spec("chinese", subs: [arabic, english]))
        try #require(await wait { state.subtitleTracks.count == 5 && selectedLanguage() == "chi" })
        let arabicID = try #require(state.subtitleTracks.first { $0.language == "ara" }?.id)
        engine.selectSubtitleTrack(id: arabicID)
        try #require(await wait { state.selectedSubtitleTrackID == arabicID })
        engine.loadExternalSubtitle(subtitle("Traditional", "zho"), select: false)
        try #require(await wait { state.subtitleTracks.count == 6 })
        try #require(state.selectedSubtitleTrackID == arabicID)
        engine.disableSubtitle()
        try #require(await wait { state.selectedSubtitleTrackID == nil })
        engine.loadExternalSubtitle(subtitle("Simplified", "zh-Hans"), select: false)
        try #require(await wait { state.subtitleTracks.count == 7 })
        try #require(state.selectedSubtitleTrackID == nil)

        await engine.play(spec: spec("english", subs: [arabic]))
        try #require(await wait { state.subtitleTracks.count == 3 && selectedLanguage() == "eng" })
        await engine.play(spec: spec("plain", subs: [arabic, english]))
        try #require(await wait { state.subtitleTracks.count == 2 && selectedLanguage() == "eng" })
        engine.loadExternalSubtitle(subtitle("简体中文", ""), select: false)
        try #require(await wait { state.subtitleTracks.count == 3 && state.subtitleTracks.first { $0.id == state.selectedSubtitleTrackID }?.name == "简体中文" })

        var disabled = spec("chinese", subs: [arabic, english]); disabled.mpvOptions["sid"] = "no"
        await engine.play(spec: disabled)
        try #require(await wait { !state.isMediaLoading && state.subtitleTracks.count == 5 })
        try #require(state.selectedSubtitleTrackID == nil)
        print("[SUBTITLE_DEFAULTS] native=true chinese=passed englishFallback=passed externalLanguage=passed lateChinese=passed manual=preserved disabled=preserved mediaReset=passed")
    }

    private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }
}
