import Foundation
import Testing
@testable import PlayerEngine

@Suite struct PlaybackSpatialAudioTests {
    @Test func routesAndSourceLabelsCannotConfirmSpatialEffects() throws {
        for (driver, format, expected) in [
            ("coreaudio", "float", PlaybackSpatialAudioAssessment.Route.coreAudioPCM),
            ("avfoundation", "float", .avFoundationPCM),
            ("coreaudio_exclusive", "s16", .coreAudioPCM),
            ("pcm", "float", .otherPCM),
            ("coreaudio", "spdif-truehd", .encoded),
            ("null", "float", .unavailable),
            ("null", "spdif-eac3", .unavailable),
            ("avfoundation", "unknown", .unavailable)
        ] {
            let properties: [String: Any] = [
                "current-tracks/audio": ["codec": "truehd", "codec-profile": "Dolby TrueHD + Dolby Atmos",
                                         "title": "AirPods Pro Head Tracked Spatial Audio"],
                "audio-params": ["channels": "7.1", "channel-count": 8],
                "audio-out-params": ["format": format, "channels": "stereo", "channel-count": 2],
                "current-ao": driver, "options/audio-spdif": ["truehd"],
                "af": [["name": "lavfi", "params": ["graph": "headphone"]]]
            ]
            var info = PlaybackDiagnostics(mediaID: UUID(), properties: try properties.mapValues {
                try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed])
            })
            info.audio.deviceName = "AirPods Pro"; info.audio.deviceTransport = .bluetooth
            let spatial = try #require(info.audio.spatialAudio)
            #expect(spatial.route == expected)
            #expect(spatial.applicationBinaural == .notEnabled)
            #expect(spatial.systemSpatialAudio == .unverified && spatial.headTracking == .unverified)
            #expect(spatial.atmosRendering == .unverified)
        }
    }

    @Test func absentAudioAndUnknownOutputStayUnconfirmed() throws {
        let noAudio = PlaybackDiagnostics(mediaID: UUID(), properties: [
            "current-ao": Data("\"avfoundation\"".utf8),
            "audio-out-params": Data("{\"format\":\"float\"}".utf8)
        ])
        #expect(noAudio.audio.spatialAudio == nil)
        let unknown = PlaybackDiagnostics(mediaID: UUID(), properties: [
            "current-tracks/audio": Data("{\"codec\":\"aac\"}".utf8)
        ])
        #expect(unknown.audio.spatialAudio?.route == .unavailable)
        #expect(unknown.audio.spatialAudio?.headTracking == .unverified)
    }

    @Test func exportsKeepTypedFactsAndDecodeOlderDiagnostics() throws {
        var info = PlaybackDiagnostics(mediaID: UUID(), properties: [
            "current-tracks/audio": Data("{\"codec\":\"aac\"}".utf8),
            "current-ao": Data("\"coreaudio\"".utf8),
            "audio-out-params": Data("{\"format\":\"float\"}".utf8)
        ])
        info.audio.deviceName = "private headphone account"
        info.audio.systemDefaultDeviceName = "private UID"
        let data = Data(info.redactedJSON().utf8)
        #expect(data.count < 16_384 && !info.redactedJSON().contains("private"))
        let decoded = try JSONDecoder().decode(PlaybackDiagnostics.self, from: data)
        #expect(decoded.audio.spatialAudio == info.audio.spatialAudio)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var audio = try #require(old["audio"] as? [String: Any])
        audio.removeValue(forKey: "spatialAudio"); old["audio"] = audio
        let oldData = try JSONSerialization.data(withJSONObject: old)
        #expect(try JSONDecoder().decode(PlaybackDiagnostics.self, from: oldData).audio.spatialAudio == nil)
    }
}
