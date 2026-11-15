import Foundation
import CoreAudio
import Storage
import Testing
@testable import PlayerEngine

@Suite struct TrueHDObjectAudioTests {
    private let labels = ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR", "TFL", "TFR", "TBL", "TBR"]
    private func device(_ channels: Int, labels: [String]?) -> PlaybackAudioDeviceSnapshot {
        .init(enumerationSucceeded: true, outputs: [.init(id: "physical", name: "Fixture",
            transport: .usb, channelCapacity: channels, preferredChannels: labels,
            nominalSampleRate: 48_000, reportedLatencySeconds: nil, bufferFrames: nil)], systemDefaultUID: "physical")
    }

    @Test func speakersRequireTwelveExplicitPositionsAndRuntimeCapability() {
        for snapshot in [device(8, labels: Array(labels.prefix(8))), device(12, labels: nil), device(16, labels: Array(repeating: "unknown", count: 12))] {
            let plan = PlaybackAudioOutputPolicy.resolve(preference: .init(trueHDObjects: .speakers714),
                devices: snapshot, nativeDolbyAvailable: true, trueHDObjectsAvailable: true)
            #expect(plan.objectRenderingUnavailable && plan.trueHDObjects == .automatic)
            #expect(plan.nativeDolbyEnabled && plan.options["netvplayer-truehd-objects"] == "off")
        }
        let ready = PlaybackAudioOutputPolicy.resolve(preference: .init(deviceUID: "physical", trueHDObjects: .speakers714),
            devices: device(12, labels: labels), nativeDolbyAvailable: true, trueHDObjectsAvailable: true)
        #expect(ready.trueHDObjects == .speakers714 && !ready.objectRenderingUnavailable && !ready.nativeDolbyEnabled)
        #expect(ready.options["audio-spdif"] == "" && ready.device == "coreaudio/physical")
        #expect(ready.channels.components(separatedBy: "-").count == 12)
        let old = PlaybackAudioOutputPolicy.resolve(preference: .init(trueHDObjects: .headphones),
            devices: device(2, labels: ["FL", "FR"]), nativeDolbyAvailable: true)
        #expect(old.objectRenderingUnavailable && old.nativeDolbyEnabled)
        #expect(old.options["netvplayer-truehd-objects"] == nil)
    }

    @Test func headphonesUseStereoPCMAndBoundTrackingQueues() {
        let devices = device(2, labels: ["FL", "FR"])
        let tracked = PlaybackAudioOutputPolicy.resolve(preference: .init(dolbyAudio: .passthrough, trueHDObjects: .trackedHeadphones),
            devices: devices, nativeDolbyAvailable: true, trueHDObjectsAvailable: true)
        #expect(tracked.channels == "stereo" && !tracked.nativeDolbyEnabled)
        #expect(tracked.options["netvplayer-truehd-objects"] == "tracked")
        #expect(tracked.options["ad-queue-max-secs"] == "0.02" && tracked.options["audio-buffer"] == "0.05")
        let restored = PlaybackAudioOutputPolicy.resolve(preference: .init(), devices: devices,
            nativeDolbyAvailable: true, trueHDObjectsAvailable: true)
        #expect(restored.nativeDolbyEnabled && restored.options["netvplayer-truehd-objects"] == "off")
        #expect(restored.options["ad-queue-max-secs"] == "1" && restored.options["audio-buffer"] == "0.2")
    }

    @Test func olderSavedPreferencesStayCompatible() throws {
        let old = Data(#"{"version":1,"mode":"surround71","dolbyAudio":"passthrough","pcmSampleRate":"source"}"#.utf8)
        let decoded = try JSONDecoder().decode(PlaybackAudioOutputPreference.self, from: old)
        #expect(decoded.trueHDObjects == .automatic && decoded.mode == .surround71 && decoded.pcmSampleRate == .source)
        let suite = "TrueHDObjects.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackAudioOutputPreferenceStore(defaults: defaults)
        store.set(.init(trueHDObjects: .trackedHeadphones))
        #expect(PlaybackAudioOutputPreferenceStore(defaults: defaults).snapshot.trueHDObjects == .trackedHeadphones)
        store.reset(); #expect(store.snapshot.trueHDObjects == .automatic)
    }

    @Test func coreAudioAtmosLabelsPreserveAllHeightsAndRearOrder() {
        // CoreAudio Atmos tag order uses side surrounds before rear surrounds.
        let native: [UInt32] = [1,2,3,4,5,6,33,34,13,15,52,54]
        var data = Data(count: 12 + native.count * MemoryLayout<AudioChannelDescription>.stride)
        data.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: UInt32(native.count), toByteOffset: 8, as: UInt32.self)
            for (i,label) in native.enumerated() {
                bytes.storeBytes(of: label, toByteOffset: 12+i*MemoryLayout<AudioChannelDescription>.stride, as: UInt32.self)
            }
        }
        #expect(PlaybackAudioDeviceProbe.channelNames(layoutData: data) ==
            ["FL","FR","FC","LFE","SL","SR","BL","BR","TFL","TFR","TBL","TBR"])
    }

    private var observation: [String: Any] { [
        "mode": 3, "samplerate": 48_000, "presentation": 3, "elements": 16,
        "has-objects": true, "metadata-seen": true, "frames": Int64(4800), "object-blocks": Int64(100),
        "metadata-updates": Int64(4), "fallback-blocks": Int64(0), "decode-errors": Int64(0),
        "sync-errors": Int64(0), "metadata-errors": Int64(0), "binaural-frames": Int64(4800),
        "tracking-requested": true, "tracking-active": true, "poses": Int64(10), "pose-age": 0.01
    ] }
    private func assessment(_ values: [String: Any], decoder: String = "truehd_objects_tracked",
                            driver: String = "coreaudio", mode: PlaybackDiagnostics.AudioMode = .pcm) -> PlaybackSpatialAudioAssessment {
        .init(driver: driver, mode: mode, objects: ObjectAudioObservation(values), decoder: decoder, outputChannels: 2)
    }

    @Test func onlyLiveDecoderEvidenceConfirmsApplicationProcessing() throws {
        let spatial = assessment(observation)
        #expect(spatial.applicationBinaural == .hrtf && spatial.atmosRendering == .applicationObjects)
        #expect(spatial.headTracking == .receivingPose && spatial.systemSpatialAudio == .unverified)
        for state in [assessment(observation, decoder: "truehd"), assessment(observation, driver: "null"),
                      assessment(observation, mode: .passthrough)] {
            #expect(state.applicationBinaural == .notEnabled && state.atmosRendering == .unverified)
        }
        for (key,value) in [("poses", Int64(0) as Any), ("tracking-active", false), ("pose-age", 0.6)] {
            var changed = observation; changed[key] = value
            #expect(assessment(changed).headTracking == .waitingForPose)
        }
        var changed = observation; changed["fallback-blocks"] = Int64(1)
        #expect(assessment(changed).atmosRendering == .partialFallback)
        changed = observation; changed["has-objects"] = false; changed["object-blocks"] = Int64(0)
        #expect(assessment(changed).atmosRendering == .unverified)
        changed = observation; changed["metadata-updates"] = Int64(-1)
        #expect(ObjectAudioObservation(changed) == nil)
    }

    @Test func diagnosticsParseAndExportActiveObjects() throws {
        let props: [String: Any] = ["current-tracks/audio": ["codec":"truehd", "decoder":"truehd_objects_tracked"],
            "current-ao":"coreaudio", "audio-out-params":["format":"float", "channel-count":2],
            "netvplayer-object-audio":observation]
        let info = PlaybackDiagnostics(mediaID: UUID(), properties: try props.mapValues {
            try JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed)
        })
        #expect(info.audio.objectAudio?.hasRenderedObjects == true)
        #expect(info.audio.spatialAudio?.headTracking == .receivingPose)
        let decoded = try JSONDecoder().decode(PlaybackDiagnostics.self, from: Data(info.redactedJSON().utf8))
        #expect(decoded.audio.objectAudio == info.audio.objectAudio)
    }
}
