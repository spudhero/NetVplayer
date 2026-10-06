import XCTest
import Foundation
import Models
@testable import PlayerEngine
@testable import ProxyServer

final class HLSRecoveryTests: XCTestCase {
    private func master(_ count: Int = 12) -> String {
        "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Stereo\",URI=\"audio/index.m3u8\"\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"English\",URI=\"sub/index.m3u8\"\n" + (1...count).map {
            "#EXT-X-STREAM-INF:BANDWIDTH=\($0 * 100000),RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\",AUDIO=\"audio\",SUBTITLES=\"subs\"\nvideo\($0).m3u8"
        }.joined(separator: "\n")
    }

    func testRecoveryPreservesAssociatedRenditionsAndFinalURL() throws {
        let reduced = try XCTUnwrap(HLSRecovery.reducedMaster(Data(master().utf8), baseURL: URL(string: "https://fixture.example/final/master.m3u8")!))
        XCTAssertTrue(reduced.contains("https://fixture.example/final/audio/index.m3u8"))
        XCTAssertTrue(reduced.contains("https://fixture.example/final/sub/index.m3u8"))
        XCTAssertTrue(reduced.contains("https://fixture.example/final/video12.m3u8"))
        XCTAssertEqual(reduced.components(separatedBy: "#EXT-X-STREAM-INF:").count, 2)
    }

    func testUnsupportedAndSmallPlaylistsRemainUntouched() {
        let base = URL(string: "https://fixture.example/master.m3u8")!
        for text in [master(2), master() + "\n#EXT-X-SESSION-KEY:METHOD=AES-128", master().replacingOccurrences(of: "avc1.640028", with: "hvc1.1"), master().replacingOccurrences(of: "1920x1080", with: "3840x2160"), master().replacingOccurrences(of: "GROUP-ID=\"audio\"", with: "GROUP-ID=\"other\"")] {
            XCTAssertNil(HLSRecovery.reducedMaster(Data(text.utf8), baseURL: base))
        }
        XCTAssertNil(HLSRecovery.reducedMaster(Data(repeating: 65, count: HLSRecovery.maximumBytes), baseURL: base))
    }

    func testRecoveryIsOnlyOneAttemptAndDoesNotAffectOrdinaryPlayback() {
        var spec = PlaySpec(url: "https://fixture.example/master.m3u8")
        XCTAssertTrue(HLSRecovery.eligible(spec))
        spec.metadata[HLSRecovery.attemptedKey] = "true"
        XCTAssertFalse(HLSRecovery.eligible(spec))
        XCTAssertFalse(HLSRecovery.eligible(PlaySpec(url: "https://fixture.example/movie.mp4")))
    }

    func testExplicitProxyReachesBothProtocolsAndDirectRemovesOldProxy() {
        let existing = ["http-proxy": "http://127.0.0.1:7897", "stream-lavf-o": "icy=0,http_proxy=http://old", "demuxer-lavf-o": "skip_initial_bytes=16"]
        let proxy = PlaybackTransportOptions.resolved(existing, url: "https://fixture.example/master.m3u8", direct: false)
        XCTAssertEqual(proxy["stream-lavf-o"], "icy=0,http_proxy=http://127.0.0.1:7897")
        XCTAssertEqual(proxy["demuxer-lavf-o"], "skip_initial_bytes=16,http_proxy=http://127.0.0.1:7897")
        let direct = PlaybackTransportOptions.resolved(proxy, url: "https://fixture.example/master.m3u8", direct: true)
        XCTAssertEqual(direct["http-proxy"], "")
        XCTAssertEqual(direct["stream-lavf-o"], "icy=0,http_proxy=")
        XCTAssertEqual(direct["demuxer-lavf-o"], "skip_initial_bytes=16,http_proxy=")
        XCTAssertEqual(PlaybackTransportOptions.resolved([:], url: "https://fixture.example/file", direct: false), [:])
        let loopback = PlaybackTransportOptions.resolved(
            ["http-proxy": "http://127.0.0.1:7897", "stream-lavf-o": "icy=0"],
            url: "http://127.0.0.1:9978/cache?key=fixture",
            direct: false
        )
        XCTAssertEqual(loopback["http-proxy"], "")
        XCTAssertEqual(loopback["stream-lavf-o"], "icy=0,http_proxy=")
        XCTAssertEqual(loopback["demuxer-lavf-o"], "http_proxy=")
    }

    func testRecoverySlotsKeepLiveAndVODIndependentAndRejectStaleCompletion() throws {
        var slots = HLSRecoverySlots()
        let vod = try XCTUnwrap(slots.claim(live: false))
        let live = try XCTUnwrap(slots.claim(live: true))
        XCTAssertNil(slots.claim(live: false))
        XCTAssertTrue(slots.isCurrent(vod, live: false))
        XCTAssertTrue(slots.isCurrent(live, live: true))
        slots.invalidate(live: false)
        XCTAssertFalse(slots.complete(vod, live: false))
        XCTAssertTrue(slots.complete(live, live: true))
        XCTAssertNotNil(slots.claim(live: false))
    }

    func testCrossOriginRecoveryStripsSensitiveHeadersAndRedactsXtreamLogs() throws {
        let inherited = #"{"Cookie":"session=fixture","Authorization":"Bearer fixture","X-Api-Key":"key-fixture","X-Token":"token-fixture","User-Agent":"NetVplayer","Referer":"https://origin.example/page"}"#
        let crossOrigin = ProxyPlaybackHandler.hlsChildRelayHeader(
            for: "https://cdn.example/video/index.m3u8",
            baseURL: "https://origin.example/master.m3u8",
            inheritedHeader: inherited
        )
        let crossHeaders = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(crossOrigin.utf8)) as? [String: String]
        )
        XCTAssertNil(crossHeaders["Cookie"])
        XCTAssertNil(crossHeaders["Authorization"])
        XCTAssertNil(crossHeaders["X-Api-Key"])
        XCTAssertNil(crossHeaders["X-Token"])
        XCTAssertEqual(crossHeaders["User-Agent"], "NetVplayer")

        let sameOrigin = ProxyPlaybackHandler.hlsChildRelayHeader(
            for: "https://origin.example/video/index.m3u8",
            baseURL: "https://origin.example/master.m3u8",
            inheritedHeader: inherited
        )
        let sameHeaders = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(sameOrigin.utf8)) as? [String: String]
        )
        XCTAssertEqual(sameHeaders["Cookie"], "session=fixture")

        let label = ProxyPlaybackHandler.upstreamLogLabel(
            URL(string: "https://fixture.example/live/user-fixture/password-fixture/41.m3u8?token=secret")!
        )
        XCTAssertFalse(label.contains("user-fixture"))
        XCTAssertFalse(label.contains("password-fixture"))
        XCTAssertFalse(label.contains("token=secret"))
        let streamLabel = ProxyServer.redactedURL(
            "https://fixture.example/movie/user-fixture/password-fixture/3.mp4?token=secret"
        )
        XCTAssertFalse(streamLabel.contains("user-fixture"))
        XCTAssertFalse(streamLabel.contains("password-fixture"))
        XCTAssertFalse(streamLabel.contains("token=secret"))
    }

    func testEnglishDiagnosticsKeepStableErrorClassification() {
        XCTAssertEqual(MPVPlayerEngine.diagnosticErrorKind(for: "Initialization failed"), 1)
        XCTAssertEqual(MPVPlayerEngine.diagnosticErrorKind(for: "Local video stream failed"), 2)
        XCTAssertEqual(MPVPlayerEngine.diagnosticErrorKind(for: "Proxy streaming failed"), 3)
        XCTAssertEqual(MPVPlayerEngine.diagnosticErrorKind(for: "External audio failed"), 4)
        XCTAssertEqual(MPVPlayerEngine.diagnosticErrorKind(for: "Decoder format error"), 5)
        XCTAssertEqual(MPVPlayerEngine.diagnosticErrorKind(for: "Event error"), 6)
    }
}
