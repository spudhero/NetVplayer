import Foundation
import Testing
@testable import Models

@Test func originalAndroidEpisodesPreserveBareIDsAndDefaultLabels() {
    let raw = "bare-fragment#  精确集名  $ raw$id #$empty-name#  $blank-name"
    let episodes = Episode.parseOriginalAndroid(from: raw)
    #expect(episodes.map(\.name) == ["01", "精确集名", "03", ""])
    #expect(episodes.map(\.url) == ["bare-fragment", " raw$id ", "empty-name", "blank-name"])
    #expect(Episode.parse(from: raw).map(\.url) == [" raw$id ", "empty-name", "blank-name"])
}

@Test func originalAndroidEpisodeDuplicatesUseExactNameAndID() {
    let episodes = Episode.parseOriginalAndroid(from: "X$u#X$u#x$u#X$v#bare#bare")
    #expect(episodes.map(\.name) == ["X", "x", "X", "05", "06"])
    #expect(episodes.map(\.url) == ["u", "u", "v", "bare", "bare"])
    #expect(Episode.parseOriginalAndroid(from: "a#01$a").count == 1)
    let distinctUnicode = Episode.parseOriginalAndroid(from: "é$u#e\u{301}$u#X$é#X$e\u{301}")
    #expect(distinctUnicode.count == 4)
    #expect(distinctUnicode[0].name.utf8.elementsEqual(distinctUnicode[1].name.utf8) == false)
    #expect(distinctUnicode[2].url.utf8.elementsEqual(distinctUnicode[3].url.utf8) == false)
}

@Test func originalAndroidEpisodeSplitKeepsInteriorEmptyFields() {
    let episodes = Episode.parseOriginalAndroid(from: "first$one##third$three###")
    #expect(episodes.map(\.name) == ["first", "02", "third"])
    #expect(episodes.map(\.url) == ["one", "", "three"])
    #expect(Episode.parseOriginalAndroid(from: "###").isEmpty)
    #expect(Episode.parseOriginalAndroid(from: "").map(\.name) == ["01"])
    #expect(Episode.parseOriginalAndroid(from: "label$").map(\.url) == [""])
}

@Test func originalAndroidEpisodeNameTrimMatchesJavaASCIIContract() {
    let episodes = Episode.parseOriginalAndroid(from: "\u{0}\t label \r$name#\u{00A0}label\u{00A0}$other")
    #expect(episodes.map(\.name) == ["label", "\u{00A0}label\u{00A0}"])
    #expect(episodes.map(\.url) == ["name", "other"])
}

@Test func originalAndroidVodUsesOriginalLineBoundariesWithoutChangingRawData() {
    var vod = Vod(vodPlayFrom: " original $$$missing$$$   $$$tail", vodPlayUrl: "bare#label$raw$$$valid$two$$$ignored$$$")
    let legacy = vod.parseFlags()
    #expect(legacy.count == 4)
    #expect(legacy[0].name == " original ")
    #expect(legacy[0].episodes.map(\.url) == ["raw"])
    vod.originalAndroidEpisodeParsing = true
    let original = vod.parseFlags()
    #expect(original.map(\.name) == ["original", "missing"])
    #expect(original[0].episodes.map(\.url) == ["bare", "raw"])
    #expect(vod.vodPlayFrom == " original $$$missing$$$   $$$tail")
    #expect(vod.vodPlayUrl == "bare#label$raw$$$valid$two$$$ignored$$$")
}

@Test func originalAndroidEpisodeProvenanceSurvivesDetailCache() throws {
    var vod = Vod(vodId: "original", vodPlayFrom: "line", vodPlayUrl: "raw-id#label$id")
    let legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(vod)) as? [String: Any])
    #expect(legacyObject["_netvplayer_android_original_episodes"] == nil)
    vod.originalAndroidEpisodeParsing = true
    let decoded = try JSONDecoder().decode(Vod.self, from: JSONEncoder().encode(vod))
    #expect(decoded.originalAndroidEpisodeParsing)
    #expect(decoded.parseFlags()[0].episodes.map(\.url) == ["raw-id", "id"])
    let old = try JSONDecoder().decode(Vod.self, from: Data(#"{"vod_play_from":"line","vod_play_url":"raw-id#label$id"}"#.utf8))
    #expect(!old.originalAndroidEpisodeParsing)
    #expect(old.parseFlags()[0].episodes.map(\.url) == ["id"])
}
