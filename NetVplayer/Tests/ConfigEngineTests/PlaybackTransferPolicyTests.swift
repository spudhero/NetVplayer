import Foundation
import Models
import DriveEngine
import Networking
import Testing
@testable import PlayerEngine
@testable import ProxyServer
@testable import NetVplayerApp

@Test func liveConnectionRecoveryRecognizesFailuresWithoutTreatingReuseAsAnError() {
    #expect(LivePlaybackBufferPolicy.indicatesConnectionReuseFailure("keepalive request failed with I/O error"))
    #expect(LivePlaybackBufferPolicy.indicatesConnectionReuseFailure("Cannot reuse HTTP connection for different host"))
    #expect(LivePlaybackBufferPolicy.indicatesConnectionReuseFailure("HTTP error 400 Bad Request"))
    #expect(!LivePlaybackBufferPolicy.indicatesConnectionReuseFailure("Reusing keepalive connection"))
    #expect(!LivePlaybackBufferPolicy.indicatesConnectionReuseFailure("connection reuse enabled"))
    #expect(!LivePlaybackBufferPolicy.indicatesConnectionReuseFailure("HTTP error 404 Not Found"))
}

@Test(arguments: [DriveProvider.uc, .quark, .baidu, .ali, .p115, .pikpak])
func playbackTransferPolicySeparatesProvidersAudioAndStreaming(_ provider: DriveProvider) {
    let video = PlaybackTransferPolicy.profile(context: .init(provider: provider, media: .video, contentLength: 5_000_000_000, isOriginal: true))
    let audio = PlaybackTransferPolicy.profile(context: .init(provider: provider, media: .compressedAudio, contentLength: 5_000_000, isOriginal: true))
    let wide = PlaybackTransferPolicy.profile(context: .init(provider: provider, media: .wideAudio, contentLength: 200_000_000, isOriginal: true))
    let streaming = PlaybackTransferPolicy.profile(context: .init(provider: provider, connection: .hls, media: .video))
    #expect(audio.parallelConcurrency <= 2)
    #expect(wide.parallelConcurrency <= 6)
    #expect(audio.maximumCachedBytes < video.maximumCachedBytes)
    #expect(wide.prefetchWindowBytes > audio.prefetchWindowBytes)
    #expect(!streaming.usesParallelUpstream && !streaming.usesHTTP2Multiplexing)
    #expect(!audio.adaptsConcurrency && !wide.adaptsConcurrency)
    #expect(video.adaptsConcurrency == (provider == .uc || provider == .quark))
    let tiny = PlaybackTransferPolicy.profile(context: .init(provider: provider, media: .video, contentLength: 1000, isOriginal: true))
    #expect(tiny.parallelConcurrency == video.parallelConcurrency) // Size cannot silently change transport.
}

@Test(arguments: ["mp3", "aac", "m4a", "ogg", "opus", "wav", "flac", "ape", "aiff", "dsf", "dff"])
func playbackTransferPolicyRecognizesSignedAudioURLs(_ format: String) {
    let spec = PlaySpec(url: "https://cdn.example.test/download?sign=secret", metadata: ["drive.fileName": "track.\(format)"])
    let media = PlaybackTransferPolicy.media(for: spec)
    #expect(media.isAudio)
    #expect(media == (["wav", "flac", "ape", "aiff", "dsf", "dff"].contains(format) ? .wideAudio : .compressedAudio))
}

@Test func playbackTransferProfileIsInvalidatedWhenURLChanges() {
    var spec = PlaySpec(url: "https://example.test/video", transferProfile: PlaybackTransferPolicy.profile(context: .init(provider: .uc, media: .video, isOriginal: true)))
    spec = spec.merging(PlaySpec(url: "https://example.test/audio"))
    #expect(spec.transferProfile == nil)
}

@Test func aliOriginalVideoUsesBoundedParallelRangesWithoutApplyingThemToAudioOrHLS() throws {
    let candidate = DrivePlaybackCandidate(id: "ali-original", providerRoute: DrivePlaybackRoute.originalDownload,
        kind: .original, transport: .localRangeProxy, url: "https://example.test/file",
        quality: .init(width: 1920, height: 1080))
    var spec = PlaySpec(url: candidate.url, contentLength: 2_000_000_000)
    spec.drivePlaybackPlan = .init(provider: .ali,
        asset: .init(provider: .ali, sourceFileID: "file"), candidates: [candidate])
    spec = DrivePlaybackRoutePolicy.spec(for: candidate, basedOn: spec, manualSelection: true)
    let relay = try #require(LiveHLSRelayPolicy.parallelSegmentedOpenEndedUpstreamConfiguration(for: spec))
    #expect(relay.concurrency == 8 && relay.segmentSize == 256 * 1024)
    #expect(!relay.usesCurl && !relay.usesHTTP2Multiplexing)
    #expect(PlaybackTransferPolicy.profile(for: spec).maximumCachedBytes == 32 * 1024 * 1024)
    for media in [PlaybackTransferMedia.compressedAudio, .wideAudio] {
        let audio = PlaybackTransferPolicy.profile(context: .init(provider: .ali, media: media, isOriginal: true))
        #expect(!audio.usesParallelUpstream && audio.initialReadBytes == 64 * 1024)
    }
    let hls = PlaybackTransferPolicy.profile(context: .init(provider: .ali, connection: .hls, media: .video))
    #expect(!hls.usesParallelUpstream)
}

@Test func playbackTransferVideoEvidenceOverridesRenamedAudioWithoutUsingSize() {
    let candidate = DrivePlaybackCandidate(id: "video", providerRoute: DrivePlaybackRoute.originalDownload,
        kind: .original, transport: .localRangeProxy, url: "https://example.test/file",
        quality: .init(width: 1920, height: 1080))
    var spec = PlaySpec(url: candidate.url, contentLength: 3_000_000_000,
        metadata: ["drive.fileName": "episode.mp3"])
    // Large genuine audio files keep their audio profile.
    #expect(PlaybackTransferPolicy.media(for: spec) == .compressedAudio)
    spec.drivePlaybackPlan = .init(provider: .quark,
        asset: .init(provider: .quark, sourceFileID: "file"), candidates: [candidate])
    #expect(PlaybackTransferPolicy.media(for: spec) == .video)
    spec.drivePlaybackPlan = nil
    spec.format = "video/mp4"
    #expect(PlaybackTransferPolicy.media(for: spec) == .video)
    spec.format = "audio/mpeg"
    #expect(PlaybackTransferPolicy.media(for: spec) == .compressedAudio)
    spec.metadata[PlaybackTransferPolicy.detectedContainerMetadataKey] = "mov"
    #expect(PlaybackTransferPolicy.media(for: spec) == .unknown)
    spec.metadata["drive.fileName"] = "track.m4a"
    #expect(PlaybackTransferPolicy.media(for: spec) == .compressedAudio)
    #expect(QuarkShareExtractor.container(forProbedMediaHeader: [0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]) == "mov")
    #expect(QuarkShareExtractor.container(forProbedMediaHeader: [0x1A, 0x45, 0xDF, 0xA3]) == "matroska")
    #expect(QuarkShareExtractor.container(forProbedMediaHeader: [0x49, 0x44, 0x33, 0, 0, 0, 0, 0]) == nil)
}

@Test func playbackTransferBaiduLegacyRepairKeepsFileIdentityAndRejectsAmbiguity() {
    let reference = DriveFileReference(provider: .baidu, shareURL: "https://pan.baidu.com/s/1fixture",
        pwdID: "", fid: "wanted", fidToken: "", fileName: "track.wav", size: 100)
    let wrong = BaiduShareFile(fileID: "wrong", name: "other.wav", path: "/other.wav", size: 100, category: 2, isDirectory: false)
    let wanted = BaiduShareFile(fileID: "wanted", name: "track.wav", path: "/one/track.wav", size: 100, category: 2, isDirectory: false)
    let duplicate = BaiduShareFile(fileID: "duplicate", name: "track.wav", path: "/two/track.wav", size: 100, category: 2, isDirectory: false)
    #expect(BaiduShareExtractor.legacyFile(matching: reference, in: [wrong, wanted, duplicate])?.fileID == "wanted")
    let missingID = DriveFileReference(provider: .baidu, shareURL: reference.shareURL,
        pwdID: "", fid: "old", fidToken: "", fileName: "track.wav", size: 100)
    #expect(BaiduShareExtractor.legacyFile(matching: missingID, in: [wrong, wanted])?.fileID == "wanted")
    #expect(BaiduShareExtractor.legacyFile(matching: missingID, in: [wanted, duplicate]) == nil)
    #expect(BaiduShareExtractor.legacyFile(matching: missingID, in: [wrong]) == nil)
}

@Test func playbackTransferBaiduLegacyRepairRequestsOriginShareBeforePlayback() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BaiduRepairOriginProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let extractor = BaiduShareExtractor(httpClient: HTTPClient(session: session), cookieProvider: { "BDUSS=fixture" })
    let reference = DriveFileReference(provider: .baidu, shareURL: "https://pan.baidu.com/s/1legacyfixture",
        pwdID: "123456789", fid: "wanted", fidToken: "", fileName: "track.wav")
    BaiduRepairOriginProtocol.capture.clear()
    // The fixture intentionally has no share state. This verifies that recovery
    // requests the original share, before any account transfer or media request.
    do { _ = try await extractor.fetchResult(url: reference.encodedURL); Issue.record("Empty share fixture unexpectedly resolved") }
    catch { }
    #expect(BaiduRepairOriginProtocol.capture.paths().contains("/s/1legacyfixture"))
}

private final class BaiduRepairOriginCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ path: String) { lock.withLock { values.append(path) } }
    func clear() { lock.withLock { values.removeAll() } }
    func paths() -> [String] { lock.withLock { values } }
}

private final class BaiduRepairOriginProtocol: URLProtocol, @unchecked Sendable {
    static let capture = BaiduRepairOriginCapture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"]) else { return }
        Self.capture.append(url.path)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html>fixture without share state</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@Test func playbackTransferRouteSwitchDropsOriginalPolicyAndFileSize() throws {
    var spec = PlaySpec(url: "https://example.test/original.mp4", contentLength: 5_000_000_000,
        metadata: [DrivePlaybackMetadataKey.provider: "quark", DrivePlaybackMetadataKey.route: DrivePlaybackRoute.originalDownload,
                   DrivePlaybackMetadataKey.size: "5000000000"],
        transferProfile: PlaybackTransferPolicy.profile(context: .init(provider: .quark, media: .video, isOriginal: true)))
    let transcode = DrivePlaybackCandidate(id: "smart", providerRoute: DrivePlaybackRoute.personalTranscode,
        kind: .transcode, transport: .hlsRelay, url: "https://example.test/smart.m3u8",
        quality: .init(value: "FHD", label: "1080P"))
    spec.drivePlaybackPlan = DrivePlaybackPlan(provider: .quark,
        asset: .init(provider: .quark, shareID: "share", sourceFileID: "file"),
        candidates: [DrivePlaybackCandidate(id: "original", providerRoute: DrivePlaybackRoute.originalDownload,
            kind: .original, transport: .localRangeProxy, url: spec.url,
            quality: .init(value: "Origin", label: "原画")), transcode])
    let switched = DrivePlaybackRoutePolicy.spec(for: transcode, basedOn: spec, manualSelection: true)
    #expect(switched.transferProfile == nil && switched.contentLength == nil)
    #expect(switched.metadata[DrivePlaybackMetadataKey.size] == nil)
    let profile = PlaybackTransferPolicy.profile(for: switched)
    #expect(profile.context.connection == .hls && !profile.context.isOriginal)
    #expect(!profile.usesParallelUpstream && !profile.adaptsConcurrency)
    // The typed plan remains authoritative when legacy metadata is inconsistent.
    spec.metadata[DrivePlaybackMetadataKey.provider] = "115"
    spec.transferProfile = nil
    #expect(PlaybackTransferPolicy.profile(for: spec).context.provider == .quark)
}

@Test func playbackTransferControllerLowersCongestionAndRestoresIndependentlyOfPreloadQuota() {
    #expect(RemoteStreamParallelConcurrencyController.isTimeout(CurlRangeTransportError(code: 28, message: "fixture")))
    #expect(RemoteStreamParallelConcurrencyController.isTimeout(URLError(.timedOut)))
    #expect(!RemoteStreamParallelConcurrencyController.isTimeout(CurlRangeTransportError(code: 42, message: "cancelled")))
    #expect(!RemoteStreamParallelConcurrencyController.isTimeout(URLError(.userAuthenticationRequired)))
    #expect(!RemoteStreamParallelConcurrencyController.isTimeout(CancellationError()))
    let controller = RemoteStreamParallelConcurrencyController(maximum: 60, adaptive: true)
    #expect(controller.setLimit(36) == 60)
    for index in 0..<6 { controller.record(timedOut: index < 2, now: Double(index), bufferedEnough: false) }
    #expect(controller.currentLimit == 30)
    controller.setLimit(60)
    #expect(controller.currentLimit == 30) // Preload restoration cannot erase congestion control.
    for index in 6...20 { controller.record(timedOut: false, now: Double(index), bufferedEnough: true) }
    #expect(controller.currentLimit == 60)
    let fixed = RemoteStreamParallelConcurrencyController(maximum: 2)
    for index in 0..<20 { fixed.record(timedOut: true, now: Double(index)) }
    #expect(fixed.currentLimit == 2)
}

@Test func playbackTransferSnapshotRequiresContinuousActualCoverage() {
    let snapshot = RemoteStreamBufferSnapshot(chunkRanges: [.init(start: 0, end: 63), .init(start: 64, end: 127), .init(start: 256, end: 511)],
        inFlightRanges: [.init(start: 128, end: 255)], cachedBytes: 384, deliveredBytes: 0, receivedBytes: 384)
    #expect(snapshot.covers([.init(start: 0, end: 127)]))
    #expect(!snapshot.covers([.init(start: 0, end: 511)]))
    #expect(!snapshot.covers([.init(start: 128, end: 255)]))
}

@Test func playbackTransferNASPreloadReusesTheSameResourceAndBoundsCache() async throws {
    let server = ProxyServer(); try server.start(); defer { server.stop() }
    let reads = TransferReadCounter()
    let profile = PlaybackTransferProfile.seekable(context: .init(connection: .smb, media: .wideAudio, contentLength: 4 * 1024 * 1024, isOriginal: true))
    let url = try server.registerSeekableResource(.init(size: 4 * 1024 * 1024, readChunkSize: profile.steadyReadBytes, transferProfile: profile) { range in
        await reads.record(); return Data(repeating: 42, count: range.count)
    })
    let storedProfile = try #require(server.seekableResourceTransferProfile(forLocalURL: url))
    #expect(storedProfile.steadyReadBytes == 4_194_304)
    let warmed = try #require(try await server.prefetchRemoteStream(forLocalURL: url, mode: .essentials))
    #expect(warmed.covers([.init(start: 0, end: Int64(512 * 1024 - 1))]))
    #expect(warmed.cachedBytes == 512 * 1024)
    var request = URLRequest(url: URL(string: url)!); request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
    let (data, _) = try await URLSession.shared.data(for: request)
    #expect(data == Data(repeating: 42, count: 64 * 1024))
    #expect(await reads.count == 1)
    server.unregisterSeekableResource(url: url)
    #expect(server.seekableResourceTransferProfile(forLocalURL: url) == nil)
}

private actor TransferReadCounter { var count = 0; func record() { count += 1 } }

private actor TransferDataGate {
    var started = false
    var continuation: CheckedContinuation<Data, Never>?
    func wait() async -> Data { started = true; return await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(returning: Data(repeating: 1, count: 64)); continuation = nil }
}

@Test func playbackTransferClosedStreamRejectsNonCooperativeLateCompletion() async throws {
    let buffer = RemoteStreamBuffer(id: "cancelled")
    let gate = TransferDataGate()
    let task = Task { try await buffer.parallelContinuousChunk(for: .init(start: 0, end: 63)) { range in
        let data = await gate.wait()
        return RemoteStreamChunk(range: range, data: data, headers: [:], contentType: "video/mp4", totalLength: 64)
    } }
    while !(await gate.started) { await Task.yield() }
    await buffer.cancelAll()
    await gate.finish()
    do { _ = try await task.value; Issue.record("Closed stream published data") }
    catch { #expect(error is CancellationError) }
    let snapshot = await buffer.snapshot()
    #expect(snapshot.cachedBytes == 0 && snapshot.inFlightRanges.isEmpty)
}

@Test func playbackTransferSnapshotUsesActualBytesInsteadOfPromisedRange() async throws {
    let buffer = RemoteStreamBuffer(id: "partial")
    _ = try await buffer.parallelContinuousChunk(for: .init(start: 0, end: 1023)) { range in
        RemoteStreamChunk(range: range, data: Data(repeating: 1, count: 64), headers: [:], contentType: "audio/mpeg", totalLength: 1024)
    }
    let snapshot = await buffer.snapshot()
    #expect(snapshot.covers([.init(start: 0, end: 63)]))
    #expect(!snapshot.covers([.init(start: 0, end: 1023)]))
    #expect(snapshot.cachedBytes == 64)
}

@Test func playbackTransferCredentialExpiryRejectsUnknownExpiredAndInvalidClocks() {
    #expect(ThunderCredentialVault.parseLiteralKey("APP_ID=fixture\nAPI_key=fixture-key-123456789\n") == ["app_id": "fixture", "api_key": "fixture-key-123456789"])
    #expect(ThunderCredentialVault.parseLiteralKey("APP_ID=fixture\nAPI_key=$(printenv)\n") == nil)
    #expect(ThunderCredentialVault.parseLiteralKey("APP_ID=fixture\nAPI_key=***\n") == nil)
    #expect(ThunderDownloadConfiguration.credentialsAreFresh(issuedAt: 1000, expiresIn: 3600, now: 1100))
    #expect(!ThunderDownloadConfiguration.credentialsAreFresh(issuedAt: 1000, expiresIn: 3600, now: 4550))
    #expect(!ThunderDownloadConfiguration.credentialsAreFresh(issuedAt: nil, expiresIn: nil, now: 1100))
    #expect(!ThunderDownloadConfiguration.credentialsAreFresh(issuedAt: .nan, expiresIn: 3600, now: 1100))
    #expect(!ThunderDownloadConfiguration.credentialsAreFresh(issuedAt: 2000, expiresIn: 3600, now: 1100))
}

@Test func playbackTransferSDKExcludesAudioUnknownSizeAndUnboundedFiles() {
    let metadata = ["drive.provider": "uc", "drive.route": "uc-original-proxy"]
    #expect(!ThunderNextEpisodeCache.supports(PlaySpec(url: "https://example.test/track.flac", contentLength: 100, metadata: metadata)))
    #expect(!ThunderNextEpisodeCache.supports(PlaySpec(url: "https://example.test/video.mp4", metadata: metadata)))
    #expect(!ThunderNextEpisodeCache.supports(PlaySpec(url: "https://example.test/video.mp4", contentLength: 3_000_000_000, metadata: metadata)))
}

@Test func playbackTransferLiveOptionsRespectSourceSettingsAndRepairOnce() throws {
    let spec = PlaySpec(url: "https://example.test/live.m3u8", mpvOptions: ["cache-secs": "30",
        "stream-lavf-o": "custom=value,icy=1,http_persistent=1,multiple_requests=1",
        "demuxer-lavf-o": "http_seekable=0,http_persistent=1"], metadata: ["playback.kind": "live"])
    let options = MPVOptionPolicy.resolve(spec: spec, user: [:], session: [:])
    #expect(options["cache-secs"]?.value == "30")
    #expect(options["cache-pause-wait"]?.value == "3")
    let repaired = try #require(LivePlaybackBufferPolicy.shortConnectionSpec(from: spec))
    #expect(repaired.url == spec.url)
    #expect(repaired.mpvOptions["stream-lavf-o"] == "custom=value,icy=0,multiple_requests=0")
    #expect(repaired.mpvOptions["demuxer-lavf-o"] == "http_seekable=0,http_persistent=0")
    #expect(LivePlaybackBufferPolicy.shortConnectionSpec(from: repaired) == nil)
    #expect(MPVOptionPolicy.resolve(spec: PlaySpec(url: "https://example.test/video.mp4"), user: [:], session: [:])["cache-pause-wait"] == nil)
    var window = LivePlaybackStallWindow()
    for (duration, time, expected) in [(0.5, 0.0, false), (1.1, 1.0, false), (1.2, 10.0, false),
                                     (1.1, 20.0, true), (1.1, 30.0, false), (1.1, 100.0, false)] {
        let result = window.record(duration: duration, at: time)
        #expect(result == expected)
    }
}
