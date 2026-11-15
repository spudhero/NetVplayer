import Foundation
import Testing
@testable import PlayerEngine

@Suite struct PlaybackHDRVividTests {
    @Test func onlyCurrentSuccessfulMappedFramesActivateVivid() throws {
        var renderer = DolbyRendererObservation(capabilities: 31, generation: 4, frames: 100,
            doviFrames: 80, enhancementFrames: 0, felFrames: 0, failures: 0, frameFlags: 48, pts: 2)
        let mapped = try #require(PlaybackHDRVivid.assess(renderer: renderer))
        #expect(mapped.dynamicMappingApplied && !mapped.usingBaseSignal)
        #expect(try JSONDecoder().decode(PlaybackHDRVivid.self, from: JSONEncoder().encode(mapped)) == mapped)
        renderer.frameFlags = 80
        #expect(PlaybackHDRVivid.assess(renderer: renderer)?.usingBaseSignal == true)
        renderer.frameFlags = 56
        #expect(PlaybackHDRVivid.assess(renderer: renderer) == nil)
        renderer.frameFlags = 0
        #expect(PlaybackHDRVivid.assess(renderer: renderer) == nil)
        renderer.frameFlags = 48; renderer.capabilities = 15
        #expect(PlaybackHDRVivid.assess(renderer: renderer)?.dynamicMappingApplied == false)
    }

    @Test func activeMappingDescribesActualHDRorSDROutput() throws {
        let renderer = DolbyRendererObservation(capabilities: 31, generation: 1, frames: 1,
            doviFrames: 0, enhancementFrames: 0, felFrames: 0, failures: 0, frameFlags: 48, pts: 1)
        for hdr in [false, true] {
            var info = try PlaybackFormatTestFixtures.diagnostics(hdr: hdr)
            info.video.hdrVivid = PlaybackHDRVivid.assess(renderer: renderer)
            let status = try #require(PlaybackFormatTestFixtures.summary(info).video)
            #expect(status.format == "HDR Vivid" && status.formatIsActive && status.state == .enabled)
            #expect(status.presentedHDR == hdr)
            #expect(info.video.signalDescription == "HDR Vivid")
            var fallback = renderer; fallback.frameFlags = 80
            info.video.hdrVivid = PlaybackHDRVivid.assess(renderer: fallback)
            #expect(PlaybackFormatTestFixtures.summary(info).video?.formatIsActive == false)
            #expect(PlaybackFormatTestFixtures.summary(info).video?.state == .baseLayer)
        }
    }
}
