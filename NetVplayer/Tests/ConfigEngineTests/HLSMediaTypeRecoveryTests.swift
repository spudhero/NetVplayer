import Foundation
import Testing
import Models
import Networking
@testable import PlayerEngine

private let disguisedHLS = Data("#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXTINF:8,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)

@Test func hlsTypeRecoveryRequiresNativeStartupEvidence() {
    var spec = PlaySpec(url: "https://fixture.example/movie.jpg")
    let failure = MPVPlaybackFailure(message: "localized message", nativeError: -17)
    #expect(HLSMediaTypeRecovery.eligible(spec, failure: failure))
    for code: Int32 in [-14, -15, -19, -3] {
        #expect(!HLSMediaTypeRecovery.eligible(spec, failure: .init(message: "format", nativeError: code)))
    }
    for status in [401, 403, 404, 429, 503] {
        #expect(!HLSMediaTypeRecovery.eligible(spec, failure: .init(message: "failure", nativeError: -13, httpStatus: status)))
    }
    #expect(!HLSMediaTypeRecovery.eligible(spec, failure: .init(message: "failure", nativeError: -13, playbackStarted: true)))
    spec.metadata[HLSMediaTypeRecovery.attemptedKey] = "true"
    #expect(!HLSMediaTypeRecovery.eligible(spec, failure: failure))
    for url in ["file:///tmp/movie", "http://fixture.example/index.m3u8"] {
        #expect(!HLSMediaTypeRecovery.eligible(PlaySpec(url: url), failure: failure))
    }
    #expect(!HLSMediaTypeRecovery.eligible(PlaySpec(url: "https://fixture.example/video", format: "application/vnd.apple.mpegurl"), failure: failure))
}

@Test func hlsTypeProbeDoesNotAcceptOrdinaryPlaylistsHTMLOrBinaryMedia() {
    #expect(HLSMediaTypeRecovery.isHLS(disguisedHLS))
    #expect(HLSMediaTypeRecovery.isHLS(Data("\u{feff}#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1234\nlow.m3u8\n".utf8)))
    for body in ["#EXTM3U\n#EXTINF:0,Channel\nhttps://fixture.example/channel", "<html>#EXTM3U</html>", "#EXTM3U\n#EXT-X-TARGETDURATION:8", "#EXTM3U\n\0#EXT-X-STREAM-INF:x\nx", "ftypmp42"] {
        #expect(!HLSMediaTypeRecovery.isHLS(Data(body.utf8)))
    }
    #expect(!HLSMediaTypeRecovery.isHLS(disguisedHLS + Data(repeating: 65, count: HLSMediaTypeRecovery.maximumBytes)))
}

@Test func hlsTypeRetryPreservesPlaybackOwnershipHeadersAndStart() {
    var spec = PlaySpec(url: "https://fixture.example/video", headers: ["Authorization": "fixture"], initialStartPositionSeconds: 42)
    spec.metadata["playback.sessionGeneration"] = "19"
    let retry = HLSMediaTypeRecovery.recovering(spec)
    #expect(retry.url == spec.url)
    #expect(retry.headers == spec.headers)
    #expect(retry.initialStartPositionSeconds == 42)
    #expect(retry.metadata["playback.sessionGeneration"] == "19")
    #expect(retry.mpvOptions["demuxer-lavf-format"] == "hls")
    #expect(!HLSMediaTypeRecovery.eligible(retry, failure: .init(message: "failure", nativeError: -13)))
    #expect(HLSRecovery.eligible(retry)) // The existing, independent master recovery remains available.
}

@Test func hlsTypeProbeEnforcesStatusSizeAndDeadline() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HLSProbeProtocol.self]
    let client = HTTPClient(session: URLSession(configuration: config))
    #expect(try await HLSMediaTypeRecovery.prepare(PlaySpec(url: "https://fixture.example/hls"), client: client))
    for path in ["unauthorized", "oversized", "html"] {
        let accepted = (try? await HLSMediaTypeRecovery.prepare(PlaySpec(url: "https://fixture.example/" + path), client: client)) == true
        #expect(!accepted)
    }
    let clock = ContinuousClock()
    let start = clock.now
    do {
        _ = try await HLSMediaTypeRecovery.prepare(PlaySpec(url: "https://fixture.example/hold"), client: client, budget: .milliseconds(40))
        Issue.record("The held request must reach its deadline")
    } catch {
        #expect(clock.now - start < .seconds(1))
    }
}

private final class HLSProbeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path != "/hold" else { return }
        let status = request.url?.path == "/unauthorized" ? 403 : 200
        let body = request.url?.path == "/html" ? Data("<html>verification</html>".utf8) : disguisedHLS
        let length = request.url?.path == "/oversized" ? HLSMediaTypeRecovery.maximumBytes + 1 : body.count
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Length": String(length), "Content-Type": "image/jpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
