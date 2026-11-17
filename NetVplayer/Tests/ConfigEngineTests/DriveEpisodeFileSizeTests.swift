import DriveEngine
import Models
import Testing

@Test func episodeFileSizeUsesSuppliedReferenceWithoutChangingPlaybackIdentity() {
    let reference = DriveFileReference(provider: .quark, shareURL: "https://pan.quark.cn/s/test",
        pwdID: "test", fid: "file", fidToken: "", fileName: "movie.mkv", size: 5_368_709_120)
    let episode = Episode(name: "Movie", url: reference.encodedURL)
    #expect(DriveEpisodeFileSize.bytes(for: episode) == 5_368_709_120)
    #expect(DriveEpisodeFileSize.label(for: episode)?.contains("GB") == true)
    #expect(episode.url == reference.encodedURL)
    #expect(DriveEpisodeFileSize.bytes(for: Episode(name: "Unknown", url: "https://example.test/movie.mkv")) == nil)
    #expect(DriveEpisodeFileSize.label(for: Episode()) == nil)
}
