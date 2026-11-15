import Foundation
import Models
import Testing
@testable import NetVplayerApp
@testable import PlayerEngine

@Suite("Dolby source badges and verified output")
struct DolbyBadgeTests {
    @Test func filenameTagsHaveBoundariesAndRemainUnverified() {
        let tags = DolbySourceFormat.filename("Example.2160p.DoVi.TrueHD.Atmos.mkv")
        #expect(tags.map(\.format) == [.vision, .atmos])
        #expect(tags.allSatisfy { $0.evidence == .filename })
        #expect(DolbySourceFormat.filename("DVD.DVDRip.Atmosphere.Adventure.mkv").isEmpty)
        #expect(DolbySourceFormat.filename("Example.HDR10.TrueHD.7.1.mkv").isEmpty)
        #expect(DolbySourceFormat.filename("Example.DV.Dolby-Vision.Dolby.Atmos.mkv").count == 2)
    }

    @Test func explicitVersionMetadataWinsAndAudioDoesNotImplyAtmos() {
        var file = MediaServerFileDetail(id: "one", episodeURL: "fixture", name: "Example.DoVi.Atmos.mkv",
            videoRange: "SDR", audio: ["AAC · stereo"])
        #expect(DolbySourceFormat.serverFile(file).isEmpty)
        file.videoRange = "DOVIWithHDR10"; file.audio = ["TrueHD · 7.1"]
        #expect(DolbySourceFormat.serverFile(file).map(\.format) == [.vision])
        file.audio = ["Dolby TrueHD + Dolby Atmos · 7.1"]
        #expect(DolbySourceFormat.serverFile(file).map(\.format) == [.vision, .atmos])
        #expect(DolbySourceFormat.serverFile(file).allSatisfy { $0.evidence == .server })
        file.videoRange = nil; file.audio = []
        #expect(DolbySourceFormat.serverFile(file).allSatisfy { $0.evidence == .filename })
        let other = MediaServerFileDetail(id: "two", episodeURL: "fixture", name: "Example.1080p.mkv",
            videoRange: "HDR10", audio: ["EAC3 · 5.1"])
        #expect(DolbySourceFormat.serverFile(other).isEmpty)
    }

    @Test func playbackLogoRequiresTheCurrentVerifiedRoute() throws {
        var info = try PlaybackFormatTestFixtures.diagnostics(hdr: false)
        info.video.dolbyVisionProfile = 8
        #expect(PlaybackFormatTestFixtures.summary(info).video?.dolbyLogoFormat == nil)
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.dolbyLogoFormat == nil)
        PlaybackFormatTestFixtures.reconstructDolby(&info)
        #expect(PlaybackFormatTestFixtures.summary(info).video?.dolbyLogoFormat == .vision)
        PlaybackFormatTestFixtures.reconstructDolby(&info, failed: true)
        #expect(PlaybackFormatTestFixtures.summary(info).video?.dolbyLogoFormat == nil)
        info.audio.mode = .passthrough
        info.audio.outputDriver = "coreaudio_exclusive"; info.audio.outputFormat = "spdif-truehd"
        info.audio.compressedAudio = .init(codec: info.audio.codec, profile: info.audio.profile,
            mode: .passthrough, passthroughProperty: nil)
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.dolbyLogoFormat == .atmos)
        info.audio.outputFormat = "spdif-eac3"
        #expect(PlaybackFormatTestFixtures.summary(info).audio?.dolbyLogoFormat == nil)
        #expect(PlaybackFormatTestFixtures.summary(info, owner: UUID()).video?.dolbyLogoFormat == nil)
    }
}
