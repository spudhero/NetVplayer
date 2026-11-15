import Foundation
import Storage
import Testing
@testable import PlayerEngine

@Suite struct PlaybackHDRPresentationTests {
    @Test func bootstrapDoesNotSpendPotentialHeadroomAndTimesOut() {
        var activation = PlaybackHDRActivation()
        let first = activation.update(eligible: true, currentHeadroom: 1, now: 10)
        #expect(first?.awaitingHeadroom == true)
        #expect(first?.maximumLinearComponent == 1)
        #expect(activation.update(eligible: true, currentHeadroom: nil, now: 12.9) == first)
        #expect(activation.update(eligible: true, currentHeadroom: 1, now: 13) == nil)
        #expect(activation.phase == .failed)
        #expect(activation.update(eligible: true, currentHeadroom: 4, now: 14) == nil)
        activation.reset() // Explicit display / preference / new-media event.
        #expect(activation.update(eligible: true, currentHeadroom: 4, now: 15)?.awaitingHeadroom == false)
    }

    @Test func headroomReductionAndLossCannotReusePreviousPeak() {
        var activation = PlaybackHDRActivation()
        let high = activation.update(eligible: true, currentHeadroom: 4.1770954132, now: 0)!
        let low = activation.update(eligible: true, currentHeadroom: 1.5, now: 1)!
        #expect(high.targetPeakSignalNits == 847)
        #expect(low.targetPeakSignalNits == 304)
        #expect(low.maximumLinearComponent <= 1.5)
        #expect(low.referenceWhiteSignalNits == 203)
        #expect(activation.update(eligible: true, currentHeadroom: 1, now: 2) == nil)
        #expect(activation.phase == .failed)
        #expect(activation.update(eligible: false, currentHeadroom: 4, now: 3) == nil)
        #expect(activation.phase == .idle)
    }

    @Test func invalidAndUnboundedRatiosHaveFiniteSignalBudgets() {
        for input in [nil, .nan, .infinity, -.infinity, -1, 0, 0.9] as [Double?] {
            #expect(PlaybackHDRPresentation.plan(headroom: input, awaitingHeadroom: true).maximumLinearComponent == 1)
        }
        let maximum = PlaybackHDRPresentation.plan(headroom: 1e200, awaitingHeadroom: false)
        #expect(maximum.targetPeakSignalNits == 10_000)
        #expect(maximum.options["fbo-format"] == "rgba32f")
        #expect(maximum.options["icc-profile-auto"] == "no")
        #expect(maximum.options["blend-subtitles"] == "no")
    }

    @Test func automaticRequiresHDRSourceAndDolbyRequiresRenderedMetadata() throws {
        for transfer in ["pq", "hlg", "bt.1886", "unknown"] {
            let properties = ["video-dec-params": try JSONSerialization.data(withJSONObject: ["gamma": transfer])]
            let video = PlaybackDiagnostics(mediaID: UUID(), properties: properties).video
            #expect(PlaybackVideoOutputPolicy.allowsHDRPresentation(mode: .automatic, video: video) == ["pq", "hlg"].contains(transfer))
            #expect(!PlaybackVideoOutputPolicy.allowsHDRPresentation(mode: .sdr, video: video))
            #expect(PlaybackVideoOutputPolicy.allowsHDRPresentation(mode: .hdrIfAvailable, video: video) == ["pq", "hlg"].contains(transfer))
        }
        let dv = PlaybackDiagnostics(mediaID: UUID(), properties: [
            "video-dec-params": Data(#"{"gamma":"pq"}"#.utf8),
            "current-tracks/video": Data(#"{"dolby-vision-profile":8}"#.utf8)
        ]).video
        #expect(!PlaybackVideoOutputPolicy.allowsHDRPresentation(mode: .hdrIfAvailable, video: dv))
    }
}
