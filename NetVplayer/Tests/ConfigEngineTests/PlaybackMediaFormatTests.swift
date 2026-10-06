import Models
import PlayerEngine
import Testing

@Test func declaredMediaFormatKeepsExtensionlessStreamsOutOfWebSniffing() {
    let url = "https://media.example.test/video/tos/stream/?mime_type=video_mp4"
    for format in ["mp4", "video/mp4", "VIDEO/MP4; codecs=hvc1", "video/x-matroska"] {
        let spec = PlaySpec(url: url, format: format)
        #expect(PlaybackProxyPolicy.bypassReason(for: spec) == .directMedia)
        #expect(!PlaybackProxyPolicy.shouldAttemptWebSniff(for: spec, sourceResolvedDirectMedia: false))
    }
    for format in ["", "html", "text/html", "application/octet-stream", "unknown"] {
        let spec = PlaySpec(url: "https://site.example.test/watch/1", format: format)
        #expect(PlaybackProxyPolicy.bypassReason(for: spec) == nil)
        #expect(PlaybackProxyPolicy.shouldAttemptWebSniff(for: spec, sourceResolvedDirectMedia: false))
    }
}
