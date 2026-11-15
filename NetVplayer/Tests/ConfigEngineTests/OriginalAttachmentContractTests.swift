import Foundation
import Testing
import Models
@testable import PlayerEngine

struct OriginalAttachmentContractTests {
    @Test func originalDanmakuAcceptsWireFormsWithoutChangingURLsOrOrder() throws {
        let url = "https://example.test/d.xml?signature=a%2Bb&x=1"
        let forms: [Any] = [url, [["name": "First", "url": url], ["name": "Second", "url": "http://127.0.0.1:9978/proxy?do=dm&csp=Guard"]],
            #"[{"name":"First","url":"https://example.test/d.xml?signature=a%2Bb&x=1"}]"#]
        for value in forms {
            let bytes = try JSONSerialization.data(withJSONObject: ["danmaku": value])
            let result = try JSONDecoder().decode(Result.self, from: bytes)
            #expect(result.danmaku.first?.url == url)
            let encoded = try JSONEncoder().encode(result)
            #expect(try JSONDecoder().decode(Result.self, from: encoded).danmaku == result.danmaku)
        }
        let result = try JSONDecoder().decode(Result.self, from: Data(#"{"danmaku":[{"url":""},{"url":"https://one.test"},{"name":"other","url":"https://two.test"}]}"#.utf8))
        #expect(result.danmaku.map(\.url) == ["https://one.test", "https://two.test"])
        #expect(Result.fromJSON("{}").danmaku.isEmpty)
    }

    @Test func originalExplicitSubtitleChoiceSurvivesEpisodesAndTrackRenumberingOnlyWithinSeries() {
        var spec = PlaySpec(url: "https://media.test/one", metadata: ["android.originalAttachments":"true", "vod.id":"same", "library.sourceFingerprint":"configA"], siteKey:"original")
        var choice = OriginalSubtitleSelection()
        choice.begin(spec)
        #expect(choice.choice == nil)
        choice.select(nil)
        spec.url = "https://media.test/next"
        spec.metadata["vod.episodeURL"] = "next"
        choice.begin(spec)
        #expect(choice.matchingID(in: []) == "no")
        choice.select(PlayerTrackInfo(id:"12", kind:.subtitle, name:"歌词", language:"", format:"ass", isExternal:true))
        choice.begin(spec)
        #expect(choice.matchingID(in:[PlayerTrackInfo(id:"3", kind:.subtitle, name:"歌词", language:"", format:"ass", isExternal:true)]) == "3")
        #expect(choice.matchingID(in:[PlayerTrackInfo(id:"12", kind:.subtitle, name:"unrelated", language:"en", format:"srt")]) == nil)
        spec.metadata["library.sourceFingerprint"] = "configB"
        choice.begin(spec)
        #expect(choice.choice == nil)
        choice.select(nil)
        spec.metadata["vod.id"] = "other"
        choice.begin(spec)
        #expect(choice.choice == nil)
        choice.select(nil)
        spec.metadata["android.originalAttachments"] = nil
        choice.begin(spec)
        #expect(choice.choice == nil)
    }
    @Test func explicitDuplicateLanguageTrackDoesNotSnapBackToFirstTrack() {
        var spec = PlaySpec(url: "one", metadata: ["android.originalAttachments":"true", "vod.id":"series"], siteKey:"original")
        let tracks = [PlayerTrackInfo(id:"1", kind:.subtitle, language:"zh", format:"hdmv_pgs_subtitle"),
                      PlayerTrackInfo(id:"2", kind:.subtitle, language:"zh", format:"hdmv_pgs_subtitle")]
        var choice = OriginalSubtitleSelection()
        choice.begin(spec)
        choice.select(tracks[1])
        #expect(choice.matchingID(in: tracks) == "2")
        spec.url = "next"
        choice.begin(spec)
        #expect(choice.matchingID(in: tracks) == nil)
        #expect(choice.matchingID(in: [tracks[0]]) == "1")
    }

}
