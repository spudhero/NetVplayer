import Models
import PlayerEngine
import Testing

@Test func dashManifestsPlayDirectlyByPathOrDeclaredMIMEType() {
    for ext in ["mpd", "MPD"] {
        let spec = PlaySpec(url: "https://media.example.test/manifest.\(ext)?token=signed")
        #expect(PlaybackProxyPolicy.bypassReason(for: spec) == .directMedia)
        #expect(!PlaybackProxyPolicy.shouldAttemptWebSniff(for: spec, sourceResolvedDirectMedia: false))
    }
    for format in ["mpd", "application/dash+xml", "APPLICATION/DASH+XML; charset=utf-8"] {
        let spec = PlaySpec(url: "https://media.example.test/opaque?id=1", format: format)
        #expect(PlaybackProxyPolicy.bypassReason(for: spec) == .directMedia)
        #expect(!PlaybackProxyPolicy.shouldAttemptWebSniff(for: spec, sourceResolvedDirectMedia: false))
    }
}

@Test func dashNamesInPageQueriesDoNotDeclarePlayableMedia() {
    for url in ["https://site.example.test/watch?file=manifest.mpd", "https://site.example.test/mpd/watch"] {
        let spec = PlaySpec(url: url, format: "text/html")
        #expect(PlaybackProxyPolicy.bypassReason(for: spec) == nil)
        #expect(PlaybackProxyPolicy.shouldAttemptWebSniff(for: spec, sourceResolvedDirectMedia: false))
    }
}

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

@Test func audioStreamsPlayDirectlyWithoutLoadingAWebPage() {
    for ext in ["mp3", "MP3", "aac", "flac", "wav", "ogg", "opus", "aiff", "alac"] {
        let spec = PlaySpec(url: "https://audio.example.test/episode.\(ext)?token=fixture")
        #expect(PlaybackProxyPolicy.bypassReason(for: spec) == .directMedia)
        #expect(!PlaybackProxyPolicy.shouldAttemptWebSniff(for: spec, sourceResolvedDirectMedia: false))
    }
    for format in ["mp3", "audio/mpeg", "audio/aac", "audio/ogg; codecs=opus", "audio/opus", "audio/x-aiff"] {
        let spec = PlaySpec(url: "https://audio.example.test/stream/1", format: format)
        #expect(PlaybackProxyPolicy.bypassReason(for: spec) == .directMedia)
    }
    let page = PlaySpec(url: "https://audio.example.test/listen?file=episode.mp3")
    #expect(PlaybackProxyPolicy.shouldAttemptWebSniff(for: page, sourceResolvedDirectMedia: false))
}

@Test func originalAndroidDirectResultSurvivesUnknownSuffixWithoutBrowserSniff() {
    for suffix in ["image", "opaque"] {
        let url = "https://media.example.test/stream.\(suffix)?signed=a%2Fb+%20"
        let result = Models.Result(url: url, parse: 0, header: ["Referer": "https://source.example.test/"])
        let direct = PlaybackProxyPolicy.sourceConfirmsDirectMedia(
            for: result, originalAndroidProvider: true, resolvedURL: url,
            sourceIsDirectMedia: false, sourceNeedsParse: false
        )
        let spec = PlaySpec(url: url, headers: result.header)
        #expect(direct)
        #expect(!PlaybackProxyPolicy.shouldAttemptWebSniff(for: spec, sourceResolvedDirectMedia: direct))
        #expect(PlaybackProxyPolicy.shouldAttemptWebSniff(for: spec, sourceResolvedDirectMedia: false))
    }
}

@Test func explicitParseRequirementsOverrideOriginalDirectDeclaration() {
    let url = "https://media.example.test/opaque"
    for result in [Models.Result(url: url, parse: 1), Models.Result(url: url, jx: 1)] {
        #expect(!PlaybackProxyPolicy.sourceConfirmsDirectMedia(
            for: result, originalAndroidProvider: true, resolvedURL: url,
            sourceIsDirectMedia: true, sourceNeedsParse: false
        ))
    }
    #expect(!PlaybackProxyPolicy.sourceConfirmsDirectMedia(
        for: Models.Result(url: url), originalAndroidProvider: true, resolvedURL: url,
        sourceIsDirectMedia: true, sourceNeedsParse: true
    ))
}

@Test func directDeclarationDoesNotLeakAcrossProvidersOrRewrittenURLs() {
    let original = "https://media.example.test/opaque?sig=a%2Fb"
    let rewritten = "https://media.example.test/opaque?sig=a/b"
    for (isOriginal, resolved) in [(false, original), (true, rewritten)] {
        #expect(!PlaybackProxyPolicy.sourceConfirmsDirectMedia(
            for: Models.Result(url: original), originalAndroidProvider: isOriginal, resolvedURL: resolved,
            sourceIsDirectMedia: false, sourceNeedsParse: false
        ))
    }
    #expect(!PlaybackProxyPolicy.sourceConfirmsDirectMedia(
        for: Models.Result(), originalAndroidProvider: true, resolvedURL: "",
        sourceIsDirectMedia: false, sourceNeedsParse: false
    ))
    #expect(PlaybackProxyPolicy.sourceConfirmsDirectMedia(
        for: Models.Result(url: original), originalAndroidProvider: true, resolvedURL: rewritten,
        sourceIsDirectMedia: true, sourceNeedsParse: false
    ))
}

@Test func playableCandidateKeepsItsDirectContractOnlyAtItsOwnURL() {
    let url = "https://media.example.test/opaque"
    let candidate = PlaybackCandidate(providerKey: "fixture", providerName: "Fixture", kind: .directURL,
                                      status: .playable, url: url)
    let result = Models.Result(url: url, playbackCandidates: [candidate])
    #expect(PlaybackProxyPolicy.sourceConfirmsDirectMedia(
        for: result, originalAndroidProvider: false, resolvedURL: url,
        sourceIsDirectMedia: false, sourceNeedsParse: false
    ))
    #expect(!PlaybackProxyPolicy.sourceConfirmsDirectMedia(
        for: result, originalAndroidProvider: false, resolvedURL: url + "/rewritten",
        sourceIsDirectMedia: false, sourceNeedsParse: false
    ))
}

@Test func confirmedDirectMediaRetainsItsTransportDecision() {
    var spec = PlaySpec(url: "http://[::1]:12345/opaque.image", headers: ["Referer": "https://source.example.test/"])
    #expect(PlaybackProxyPolicy.bypassReason(for: spec) == nil)
    spec.metadata[PlaybackProxyPolicy.sourceResolvedDirectMediaMetadataKey] = "true"
    #expect(PlaybackProxyPolicy.bypassReason(for: spec) == .directMedia)
    #expect(!PlaybackProxyPolicy.shouldAttemptWebSniff(for: spec, sourceResolvedDirectMedia: false))
    spec.url = "https://media.example.test/playlist.m3u8"
    #expect(PlaybackProxyPolicy.bypassReason(for: spec) == .directHLS)
    spec.url = "https://a.v.anime1.me/video.mp4"
    spec.headers = ["Cookie": "fixture=synthetic", "Referer": "https://anime1.me/"]
    #expect(PlaybackProxyPolicy.shouldUseRemoteStreamProxy(for: spec))
}
