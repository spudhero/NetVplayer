import Foundation
import Storage
import Testing
@testable import PlayerEngine

@Suite struct PlaybackVideoOutputPolicyTests {
    private func video(_ transfer: String? = nil, matrix: String = "bt.2020-ncl", profile: Int? = nil) -> PlaybackDiagnostics.Video {
        var params: [String: Any] = ["colormatrix": matrix, "pixelformat": "yuv420p10le"]
        params["gamma"] = transfer
        var track: [String: Any] = [:]
        track["dolby-vision-profile"] = profile
        return PlaybackDiagnostics(mediaID: UUID(), properties: [
            "video-dec-params": try! JSONSerialization.data(withJSONObject: params),
            "current-tracks/video": try! JSONSerialization.data(withJSONObject: track)
        ]).video
    }

    @Test func onlyExplicitTemporaryPolicyCanRequestSystemHDR() {
        for transfer in ["pq", "hlg", "bt.1886", "unknown"] {
            let source = video(transfer)
            #expect(!PlaybackVideoOutputPolicy.requestsSystemHDR(mode: .automatic, video: source))
            #expect(!PlaybackVideoOutputPolicy.requestsSystemHDR(mode: .sdr, video: source))
            #expect(PlaybackVideoOutputPolicy.requestsSystemHDR(mode: .hdrIfAvailable, video: source)
                == ["pq", "hlg"].contains(transfer))
        }
        // A Dolby Vision track tag by itself still cannot change the display.
        #expect(!PlaybackVideoOutputPolicy.requestsSystemHDR(mode: .hdrIfAvailable, video: video("pq", profile: 8)))
    }

    @Test func automaticOnExternalSDRNeverUsesPotentialHeadroomToStartEDR() {
        for systemHDR in [false, nil] as [Bool?] {
            let eligible = PlaybackVideoOutputPolicy.allowsEDRActivation(mode: .automatic,
                currentHeadroom: 1, potentialHeadroom: 8, isBuiltin: false, systemHDREnabled: systemHDR)
            #expect(!eligible)
            var activation = PlaybackHDRActivation()
            #expect(activation.update(eligible: eligible, currentHeadroom: 1, now: 0) == nil)
            #expect(activation.phase == .idle)
        }
        // A user's known OFF preference wins over a stale current observation.
        #expect(!PlaybackVideoOutputPolicy.allowsEDRActivation(mode: .automatic,
            currentHeadroom: 4, potentialHeadroom: 8, isBuiltin: false, systemHDREnabled: false))
    }

    @Test func automaticKeepsNativeEDRAndAlreadyEnabledSystemHDR() {
        let alreadyEnabled = PlaybackVideoOutputPolicy.allowsEDRActivation(mode: .automatic,
            currentHeadroom: 1, potentialHeadroom: 8, isBuiltin: false, systemHDREnabled: true)
        #expect(alreadyEnabled)
        var activation = PlaybackHDRActivation()
        let waiting = activation.update(eligible: alreadyEnabled, currentHeadroom: 1, now: 0)
        #expect(waiting?.awaitingHeadroom == true)
        #expect(waiting?.maximumLinearComponent == 1)
        #expect(PlaybackVideoOutputPolicy.allowsEDRActivation(mode: .automatic,
            currentHeadroom: 1, potentialHeadroom: 8, isBuiltin: true, systemHDREnabled: nil))
        // Public current headroom remains usable if the private observer is unavailable.
        #expect(PlaybackVideoOutputPolicy.allowsEDRActivation(mode: .automatic,
            currentHeadroom: 4, potentialHeadroom: 8, isBuiltin: false, systemHDREnabled: nil))
        for mode in PlaybackVideoOutputMode.allCases {
            #expect(!PlaybackVideoOutputPolicy.allowsEDRActivation(mode: mode,
                currentHeadroom: 4, potentialHeadroom: 1, isBuiltin: false, systemHDREnabled: true))
        }
        #expect(!PlaybackVideoOutputPolicy.allowsEDRActivation(mode: .sdr,
            currentHeadroom: 4, potentialHeadroom: 8, isBuiltin: true, systemHDREnabled: true))
    }

    @Test func unactivatedSurfaceReportsSDREvenWhenHDRWasRequested() {
        for transfer in ["pq", "smpte2084", "hlg", "arib-std-b67"] {
            for mode in PlaybackVideoOutputMode.allCases {
                // A capable display alone does not establish a submitted HDR surface.
                let result = PlaybackVideoOutputPolicy.assess(mode: mode, video: video(transfer), display: .init(
                    currentEDRHeadroom: 4, potentialEDRHeadroom: 8, targetFormat: "GL_RGBA8", edrEnabled: false))
                #expect(result.requestedMode == mode)
                #expect(result.disposition == (mode == .sdr ? .sdrRequested : .hdrMappedToSDR))
                #expect(result.hdrRestrictions.isEmpty)
                let options = PlaybackColorPolicy.options(source: ["target-trc": "pq", "target-peak": "10000"],
                                                          preference: .init(videoOutput: mode))
                #expect(options["target-trc"]?.value == "srgb")
                #expect(options["target-peak"]?.value == "203")
                #expect(options["blend-subtitles"]?.value == "no")
            }
        }
    }

    @Test func capabilityLossAndRestorationDoNotUsePotentialAsCurrentHeadroom() {
        for (current, potential, expected) in [
            (Optional(1.0), Optional(1.0), PlaybackVideoOutputAssessment.HDRRestriction.sdrDisplay),
            (1, 8, .headroomUnavailable), (nil, 8, .headroomUnavailable), (8, nil, .displayUnknown),
            (Double.nan, Double.infinity, .displayUnknown)
        ] {
            let display = PlaybackDiagnostics.Display(currentEDRHeadroom: current, potentialEDRHeadroom: potential,
                                                      targetFormat: "GL_RGBA8", edrEnabled: false)
            let result = PlaybackVideoOutputPolicy.assess(mode: .hdrIfAvailable, video: video("pq"), display: display)
            #expect(result.hdrRestrictions == [expected])
            #expect(display.outputDescription == "SDR")
        }
        let restored = PlaybackVideoOutputPolicy.assess(mode: .automatic, video: video("pq"), display: .init(
            currentEDRHeadroom: 3, potentialEDRHeadroom: 8, targetFormat: "GL_RGBA8", edrEnabled: false))
        #expect(restored.hdrRestrictions.isEmpty)
        #expect(restored.disposition == .hdrMappedToSDR)
    }

    @Test func sourceFactsAreIndependentOfBitDepthAndRequestedOutput() {
        let display = PlaybackDiagnostics.Display(targetFormat: "GL_RGBA8", edrEnabled: false)
        let cases: [(PlaybackDiagnostics.Video, PlaybackVideoOutputAssessment.Signal, PlaybackVideoOutputAssessment.Disposition)] = [
            (video("bt.1886"), .sdr, .sdrContent), (video(), .unknown, .unknownContent),
            (video("linear"), .unknown, .unknownContent),
            (video("pq", profile: 8), .dolbyVision, .dolbyVisionDeferred),
            (video("pq", matrix: "dolbyvision"), .dolbyVision, .dolbyVisionDeferred)
        ]
        for (input, signal, disposition) in cases {
            let result = PlaybackVideoOutputPolicy.assess(mode: .hdrIfAvailable, video: input, display: display)
            #expect(result.sourceSignal == signal)
            #expect(result.disposition == disposition)
        }
    }

    @Test func submittedFP16AndAbsentSurfaceDoNotEstablishEDRPresentation() {
        let probe = PlaybackDiagnostics.Display(currentEDRHeadroom: 4, potentialEDRHeadroom: 8,
                                               targetFormat: "GL_RGBA16F / rgba16Float")
        #expect(probe.edrEnabled == nil)
        #expect(PlaybackVideoOutputPolicy.assess(mode: .hdrIfAvailable, video: video("pq"), display: probe).disposition == .developmentProbe)
        let detached = PlaybackVideoOutputPolicy.assess(mode: .automatic, video: video("pq"), display: .init())
        #expect(detached.disposition == .awaitingRender)
        #expect(detached.hdrRestrictions.contains(.displayUnknown))
    }

    @Test func preferenceMigrationPersistenceAndResetKeepSDROverrides() throws {
        let suite = "NetVplayer.output-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"version":1,"toneMapping":"mobius","peakNits":150}"#.utf8), forKey: PlaybackColorPreferenceStore.key)
        let store = PlaybackColorPreferenceStore(defaults: defaults)
        #expect(store.snapshot == .init(toneMapping: .mobius, peakNits: 150))
        var preference = store.snapshot
        preference.videoOutput = .hdrIfAvailable
        store.set(preference)
        #expect(PlaybackColorPreferenceStore(defaults: defaults).snapshot == preference)
        defaults.set(Data(#"{"version":1,"toneMapping":"reinhard","peakNits":100,"videoOutput":"future-mode"}"#.utf8), forKey: PlaybackColorPreferenceStore.key)
        #expect(PlaybackColorPreferenceStore(defaults: defaults).snapshot == .init(toneMapping: .reinhard, peakNits: 100))
        store.reset()
        #expect(PlaybackColorPreferenceStore(defaults: defaults).snapshot == .init())
    }

    @Test func redactedExportRetainsOnlyTypedOutputFacts() throws {
        var info = PlaybackDiagnostics(mediaID: UUID(), properties: [:], display: .init(
            name: "private-monitor", currentEDRHeadroom: 1, potentialEDRHeadroom: 1, targetFormat: "GL_RGBA8", edrEnabled: false))
        info.display.videoOutput = PlaybackVideoOutputPolicy.assess(mode: .hdrIfAvailable, video: info.video, display: info.display)
        let json = info.redactedJSON()
        #expect(!json.contains("private-monitor"))
        #expect(json.contains("sdrDisplay"))
        #expect(json.contains("hdrIfAvailable"))
        #expect(try JSONDecoder().decode(PlaybackDiagnostics.self, from: Data(json.utf8)).display.videoOutput == info.display.videoOutput)
    }
}
