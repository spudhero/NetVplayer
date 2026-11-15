import AppKit
import Foundation
import Models
import Storage
import Testing
@testable import PlayerEngine

@Suite struct PlaybackColorPolicyTests {
    @Test func automaticUserSourceAndDisplayPriorities() {
        let spec = PlaySpec(url: "file:///fixture.mkv", mpvOptions: [
            "tone-mapping": "reinhard", "tone-mapping-param": "0.7", "target-peak": "100",
            "target-trc": "pq", "target-prim": "bt.2020", "icc-profile": "/private/old.icc",
            "blend-subtitles": "video", "video-output-levels": "limited"
        ])
        let automatic = MPVOptionPolicy.resolve(spec: spec, user: [:], session: [:])
        #expect(automatic["tone-mapping"]?.origin == .source)
        #expect(automatic["tone-mapping-param"]?.value == "0.7")
        #expect(automatic["target-peak"]?.value == "100")
        let manual = MPVOptionPolicy.resolve(spec: spec, user: [:], session: [:], color: .init(toneMapping: .mobius, peakNits: 150))
        #expect(manual["tone-mapping"]?.value == "mobius")
        #expect(manual["tone-mapping"]?.origin == .user)
        #expect(manual["tone-mapping-param"]?.value == "0.3")
        #expect(manual["target-peak"]?.value == "150")
        for plan in [automatic, manual] {
            #expect(plan["target-trc"]?.value == "srgb")
            #expect(plan["icc-profile"]?.value == "")
            #expect(plan["icc-profile-auto"]?.value == "yes")
            #expect(plan["blend-subtitles"]?.value == "no")
            #expect(plan["video-output-levels"]?.value == "full")
            #expect(plan["target-trc"]?.origin == .display)
            #expect(plan["hdr-compute-peak"]?.value == "no")
        }
        #expect(MPVOptionPolicy.resolve(spec: spec, user: [:], session: [:]) == automatic)
        let next = MPVOptionPolicy.resolve(spec: PlaySpec(url: "file:///next.mkv"), user: [:], session: [:])
        #expect(next["tone-mapping"]?.value == "bt.2390")
        #expect(next["target-peak"]?.value == "203")
        #expect(next["tone-mapping-param"]?.value == "1")
        #expect(next["tone-mapping"]?.origin == .colorDefault)
    }

    @Test func unsupportedCurvesAndHDRDisguisedAsSDRAreRejected() {
        for curve in ["spline", "bt.2446a", "../../private", "auto"] {
            let plan = PlaybackColorPolicy.options(source: ["tone-mapping": curve, "target-peak": "1000"], preference: .init())
            #expect(plan["tone-mapping"]?.value == "bt.2390")
            #expect(plan["target-peak"]?.value == "203")
        }
        for peak in ["nan", "inf", "-1", "79", "204", "1e10"] {
            #expect(PlaybackColorPolicy.options(source: ["target-peak": peak], preference: .init())["target-peak"]?.value == "203")
        }
        for (curve, invalid, fallback) in [("mobius", "1", "0.3"), ("reinhard", "0", "0.5"),
                                           ("reinhard", "1", "0.5"), ("gamma", "0", "1.8"),
                                           ("linear", "nan", "1")] {
            let plan = PlaybackColorPolicy.options(source: ["tone-mapping": curve, "tone-mapping-param": invalid], preference: .init())
            #expect(plan["tone-mapping-param"]?.value == fallback)
        }
    }

    @Test func persistentPreferencesAreBoundedVersionedAndResettable() throws {
        let suite = "NetVplayer.color-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackColorPreferenceStore(defaults: defaults)
        #expect(store.snapshot == .init())
        store.set(.init(toneMapping: .reinhard, peakNits: 999))
        #expect(PlaybackColorPreferenceStore(defaults: defaults).snapshot == .init(toneMapping: .reinhard, peakNits: 203))
        store.set(.init(peakNits: -10))
        #expect(store.snapshot.peakNits == 80)
        store.reset()
        #expect(PlaybackColorPreferenceStore(defaults: defaults).snapshot == .init())
        defaults.set(Data(#"{"version":2,"peakNits":100}"#.utf8), forKey: PlaybackColorPreferenceStore.key)
        #expect(PlaybackColorPreferenceStore(defaults: defaults).snapshot == .init())
        defaults.set(Data("broken".utf8), forKey: PlaybackColorPreferenceStore.key)
        #expect(PlaybackColorPreferenceStore(defaults: defaults).snapshot == .init())
    }

    @Test func ICCValidationRejectsTruncationWrongSpaceAndSize() throws {
        let data = try #require(NSColorSpace.sRGB.iccProfileData)
        #expect(PlaybackColorPolicy.validICC(data))
        #expect(!PlaybackColorPolicy.validICC(data.prefix(127)))
        #expect(!PlaybackColorPolicy.validICC(data + Data([0])))
        var wrong = data
        wrong.replaceSubrange(16..<20, with: Data("CMYK".utf8))
        #expect(!PlaybackColorPolicy.validICC(wrong))
        wrong = data
        wrong[36] = 0
        #expect(!PlaybackColorPolicy.validICC(wrong))
        #expect(!PlaybackColorPolicy.validICC(Data(count: PlaybackColorPolicy.maximumICCBytes + 1)))
    }
}
