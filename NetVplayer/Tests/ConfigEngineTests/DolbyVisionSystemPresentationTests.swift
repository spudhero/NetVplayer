import Foundation
import Models
import Storage
import Testing
@testable import PlayerEngine

@Suite struct DolbyVisionSystemPresentationTests {
    @Test func optInRequiresReconstructionHDRSystemSupportAndNoLatchedFailure() {
        for enabled in [false, true] {
            for mode in PlaybackVideoOutputMode.allCases {
                for reconstructed in [false, true] {
                    for hdr in [false, true] {
                        for available in [false, true] {
                            for failed in [false, true] {
                                let actual = DolbyVisionSystemPresentationPolicy.eligible(
                                    preference: .init(videoOutput: mode, systemDolbyVision: enabled),
                                    reconstructed: reconstructed, hasHDRPresentation: hdr,
                                    systemAvailable: available, failed: failed)
                                #expect(actual == (enabled && mode != .sdr && reconstructed && hdr && available && !failed))
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func preferencesMigrateWithoutEnablingExperimentalOutput() throws {
        let old = Data(#"{"version":1,"videoOutput":"hdrIfAvailable"}"#.utf8)
        #expect(try JSONDecoder().decode(PlaybackColorPreference.self, from: old).systemDolbyVision == false)
        #expect(try JSONDecoder().decode(PlaybackColorPreference.self, from: old).sourceDolbyVisionMetadata == false)
        let suite = "NetVplayer.DVOutputTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackColorPreferenceStore(defaults: defaults)
        #expect(!store.snapshot.systemDolbyVision)
        store.set(.init(systemDolbyVision: true))
        #expect(PlaybackColorPreferenceStore(defaults: defaults).snapshot.systemDolbyVision)
        store.reset()
        #expect(!store.snapshot.systemDolbyVision)
        store.set(.init(systemDolbyVision: true, sourceDolbyVisionMetadata: true))
        #expect(PlaybackColorPreferenceStore(defaults: defaults).snapshot.sourceDolbyVisionMetadata)
        store.reset()
        #expect(!store.snapshot.sourceDolbyVisionMetadata)
    }

    @Test func sourceExperimentRequiresVerifiedSingleLayerConfigurationAndNoSourceFilters() throws {
        var video = try PlaybackFormatTestFixtures.diagnostics(hdr: false).video
        video.dolbyVisionProfile = 8
        let local = LocalDolbyVisionObservation(profile: 8, level: 1, compatibilityID: 1,
            rpuFlag: true, enhancementLayer: false, baseLayer: true, frameRPU: true,
            frameMetadata: true, rpuHeaderProfile: 1, rpuInferredProfile: 8, streamIndex: 0,
            status: "first-frame-inspected")
        let dv = try #require(PlaybackDolbyVision.assess(video: video, local: local, trackIndex: 0))
        #expect(DolbyVisionSystemPresentationPolicy.sourceCompatibility(dv, options: [:]) == 1)
        for profile in [5, 7, 9] {
            var rejected = dv; rejected.configurationProfile = profile
            #expect(DolbyVisionSystemPresentationPolicy.sourceCompatibility(rejected, options: [:]) == 0)
        }
        for key in ["vf", "vf-add", "gamma", "glsl-shaders"] {
            #expect(DolbyVisionSystemPresentationPolicy.sourceCompatibility(dv, options: [key: "anything"]) == 0)
        }
        var changed = dv; changed.enhancementLayerFlag = true
        #expect(DolbyVisionSystemPresentationPolicy.sourceCompatibility(changed, options: [:]) == 0)
        changed = dv; changed.evidenceConflict = true
        #expect(DolbyVisionSystemPresentationPolicy.sourceCompatibility(changed, options: [:]) == 0)
        changed = dv; changed.configurationRPUFlag = nil
        #expect(DolbyVisionSystemPresentationPolicy.sourceCompatibility(changed, options: [:]) == 0)
        changed = dv; changed.compatibilityID = 4
        #expect(DolbyVisionSystemPresentationPolicy.sourceCompatibility(changed, options: [:]) == 4)
    }

    @Test func sourceProofDoesNotBorrowRegeneratedOrPriorFrameEvidence() {
        let renderer = DolbyRendererObservation(capabilities: 63, generation: 9, frames: 2, doviFrames: 2,
            enhancementFrames: 0, felFrames: 0, failures: 0, frameFlags: 1, pts: 2)
        let facts: [String: Any] = ["metadataFrames": 2, "submittedFrames": 2, "metadataBytes": 200,
            "lastError": 0, "currentMetadataSubmitted": true, "rendererStatus": 1,
            "lastPTS": 2, "generation": 9, "metadataOrigin": "source-rpu-unmodified",
            "sourceRPUBytesPreserved": true, "sourceDisableResidual": 1, "sourceRPUBytes": 200,
            "outputProfile": "8.1"]
        let source = DolbyVisionSystemPresentation.read(facts: facts, renderer: renderer, sameMedia: true)
        #expect(source.currentFrameSubmitted && source.outputProfile == "8.1")
        for (key, value): (String, Any) in [("sourceDisableResidual", 0), ("sourceRPUBytes", 0),
            ("sourceRPUBytesPreserved", false), ("outputProfile", "7"), ("generation", 8), ("lastPTS", 1)] {
            var invalid = facts; invalid[key] = value
            #expect(!DolbyVisionSystemPresentation.read(facts: invalid, renderer: renderer, sameMedia: true).currentFrameSubmitted)
        }
        #expect(!DolbyVisionSystemPresentation.read(facts: facts, renderer: renderer, sameMedia: false).currentFrameSubmitted)
    }

    @Test func proofRequiresCurrentMatchingFrameActualPayloadAndAcceptedSubmission() throws {
        let renderer = DolbyRendererObservation(capabilities: 3, generation: 2, frames: 1, doviFrames: 1,
            enhancementFrames: 0, felFrames: 0, failures: 0, frameFlags: 1, pts: 1.5)
        let facts: [String: Any] = ["metadataFrames": 1, "submittedFrames": 1, "metadataBytes": 350,
            "lastError": 0, "currentMetadataSubmitted": true, "rendererStatus": 1,
            "readyForDisplay": true, "lastPTS": 1.5, "generation": 2]
        let good = DolbyVisionSystemPresentation.read(facts: facts, renderer: renderer, sameMedia: true)
        #expect(good.currentFrameSubmitted && good.readyForDisplay)
        #expect(good.outputProfile == "8.4" && good.metadataOrigin == "system-regenerated+gpu-l1")
        #expect(try JSONDecoder().decode(DolbyVisionSystemPresentation.self, from: JSONEncoder().encode(good)) == good)
        for (key, value): (String, Any) in [("metadataBytes", 0), ("metadataFrames", 0), ("submittedFrames", 0), ("lastError", -12902),
                                          ("currentMetadataSubmitted", false), ("rendererStatus", 2),
                                          ("lastPTS", 1.6), ("generation", 1)] {
            var stale = facts; stale[key] = value
            #expect(!DolbyVisionSystemPresentation.read(facts: stale, renderer: renderer, sameMedia: true).currentFrameSubmitted)
        }
        var missingStatus = facts; missingStatus.removeValue(forKey: "rendererStatus")
        #expect(!DolbyVisionSystemPresentation.read(facts: missingStatus, renderer: renderer, sameMedia: true).currentFrameSubmitted)
        #expect(!DolbyVisionSystemPresentation.read(facts: facts, renderer: renderer, sameMedia: false).currentFrameSubmitted)
        #expect(!DolbyVisionSystemPresentation.read(facts: facts, renderer: nil, sameMedia: true).currentFrameSubmitted)
        var info = try PlaybackFormatTestFixtures.diagnostics(hdr: false)
        PlaybackFormatTestFixtures.reconstructDolby(&info)
        info.video.dolbyVision?.systemPresentation = good
        info.display.targetFormat = "GL_RGBA16F / CVPixelBuffer / HLG"
        #expect(PlaybackVideoOutputPolicy.assess(mode: .automatic, video: info.video, display: info.display)
            .disposition == .systemDolbyVisionPresentation)
        #expect(info.video.dolbyVision?.dolbyVisionSignalSent == false)
        let summary = PlaybackFormatTestFixtures.summary(info).video
        #expect(summary?.actualOutput == L10n.text("系统 DV 呈现 · 待设备确认"))
    }
}
