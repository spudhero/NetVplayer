#if DEBUG
import Foundation
import Models
import Testing

@Test func developmentAndroidQualityCandidateKeepsItsOwnAudioAndDecodesLegacyPayload() throws {
    let first = PlaybackCandidate(providerKey: "test", providerName: "test", name: "480P", kind: .directURL,
        status: .playable, url: "https://media.example.test/480", externalAudioURL: "https://media.example.test/audio-480")
    let second = PlaybackCandidate(providerKey: "test", providerName: "test", name: "360P", kind: .directURL,
        status: .playable, url: "https://media.example.test/360", externalAudioURL: "https://media.example.test/audio-360")
    let decoded = try JSONDecoder().decode([PlaybackCandidate].self, from: JSONEncoder().encode([first, second]))
    #expect(decoded.map(\.externalAudioURL) == [first.externalAudioURL, second.externalAudioURL])
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
    legacy.removeValue(forKey: "externalAudioURL")
    let old = try JSONDecoder().decode(PlaybackCandidate.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(old.isPlayable && old.externalAudioURL == nil)
}
#endif
