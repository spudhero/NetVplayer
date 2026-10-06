import AppKit
import Foundation
import Models
import Storage
import Testing
@testable import NetVplayerApp
@testable import PlayerEngine

@MainActor
@Suite(.serialized)
struct PlaybackArtworkLoaderTests {
    @Test func protectedCoverUsesPosterHeadersAndDecodesToLocalPNG() async throws {
        let fixture = try ArtworkLoaderFixture()
        defer { fixture.remove() }
        let source = "https://img1.doubanio.com/album.jpg"
        let spec = PlaySpec(url: "https://audio.example.test/song.flac", headers: ["Cookie": "private-media-cookie"],
                            audioFallbackArtwork: source, artworkHeaders: ["Referer": "https://media.example.test/"])
        let data = try await PlaybackArtworkLoader.load(spec, pipeline: fixture.pipeline)
        // A rejected request produces the 1280px fallback, rather than this 64px fixture cover.
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == 64)
        #expect(image.pixelsHigh == 96)
        let request = try #require(ArtworkLoaderURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.douban.com/")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla") == true)
    }

    @Test func embeddedImageHeadersKeepTheirPrecedence() async throws {
        let fixture = try ArtworkLoaderFixture()
        defer { fixture.remove() }
        let spec = PlaySpec(audioFallbackArtwork: "https://images.example.test/album.png@Referer=https%3A%2F%2Fwww.douban.com%2F",
                            artworkHeaders: ["Referer": "https://media.example.test/"])
        let data = try await PlaybackArtworkLoader.load(spec, pipeline: fixture.pipeline)
        #expect(NSBitmapImageRep(data: data)?.pixelsWide == 64)
        #expect(ArtworkLoaderURLProtocol.lastRequest?.url?.path == "/album.png")
    }

    @Test func missingImageProducesMusicBackdropWithoutFailingAudio() async throws {
        let fixture = try ArtworkLoaderFixture()
        defer { fixture.remove() }
        let spec = PlaySpec(audioFallbackArtwork: "https://images.example.test/missing", title: "测试音乐")
        let data = try await PlaybackArtworkLoader.load(spec, pipeline: fixture.pipeline)
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == 1_280)
        #expect(image.pixelsHigh == 720)
        #expect(image.colorAt(x: 200, y: 300) != image.colorAt(x: 1_000, y: 600))
    }

    @Test func cancellationDoesNotGenerateAReplacementBackdrop() async throws {
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await PlaybackArtworkLoader.load(PlaySpec(audioFallbackArtwork: PlaybackArtworkLoader.placeholderSource))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled artwork must not be attached") }
        catch is CancellationError { }
    }

    @Test func knownAudioWithoutAnImageStillHasABackdropCandidate() {
        let episode = Episode(name: "song.flac", url: "https://audio.example.test/file")
        #expect(AppState.audioFallbackArtwork(from: Result(url: episode.url), episode: episode, detailArtwork: "") == PlaybackArtworkLoader.placeholderSource)
        let video = Episode(name: "film.mkv", url: "https://video.example.test/file")
        #expect(AppState.audioFallbackArtwork(from: Result(url: video.url), episode: video, detailArtwork: "").isEmpty)
    }

    @Test func posterUsesEpisodeThenDetailThenPlaybackSnapshot() {
        let episode = Episode(name: "track", url: "file:///track.flac", artwork: "https://img.example.test/track.jpg")
        let detail = Vod(vodPic: "https://img.example.test/album.jpg")
        let spec = PlaySpec(artwork: "https://img.example.test/player.jpg", metadata: ["vod.pic": "https://img.example.test/history.jpg"])
        #expect(PlayerPosterSource.resolve(episode: episode, detail: detail, spec: spec) == episode.artwork)
        #expect(PlayerPosterSource.resolve(episode: nil, detail: detail, spec: spec) == detail.vodPic)
        #expect(PlayerPosterSource.resolve(episode: nil, detail: nil, spec: spec) == spec.metadata["vod.pic"])
    }

    @Test func parsingAndProxyOverridesPreserveSeparateImageHeaders() {
        let spec = PlaySpec(audioFallbackArtwork: "https://img.example.test/album.jpg", artworkHeaders: ["Referer": "https://images.example.test/"])
        let merged = spec.merging(PlaySpec(url: "http://127.0.0.1/stream", headers: ["Cookie": "media-only"]))
        #expect(merged.artworkHeaders == spec.artworkHeaders)
        #expect(merged.artworkHeaders["Cookie"] == nil)
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_RUN_MPV_AUDIO_RENDERING_TEST"] != "1"))
    func protectedCoverReachesMPVAndLateImageCannotFollowReplacement() async throws {
        let fixture = try ArtworkLoaderFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let audioURL = fixture.directory.appendingPathComponent("silent.wav")
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        let count: UInt32 = 44_100 * 4 * 20
        append(count + 36); wav.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(2)); append(UInt32(44_100)); append(UInt32(44_100 * 4))
        append(UInt16(4)); append(UInt16(16)); wav.append(Data("data".utf8)); append(count)
        wav.append(Data(count: Int(count)))
        try wav.write(to: audioURL)
        let suite = "ArtworkTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackAudioPreferenceStore(defaults: defaults)
        preferences.setMuted(true)
        let engine = MPVPlayerEngine(videoSurface: .vod, stopResourcePolicy: .warmStop, audioPreferences: preferences)
        let state = PlayerState()
        engine.playerState = state
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        view.frame = window.contentLayoutRect
        window.contentView = view
        window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
        engine.artworkLoader = { spec in try await PlaybackArtworkLoader.load(spec, pipeline: fixture.pipeline) }
        await engine.play(spec: PlaySpec(url: audioURL.absoluteString, audioFallbackArtwork: "https://img1.doubanio.com/album.jpg"))
        try await waitUntil { state.position > 0.2 && !engine.hasAudioOnlyMediaTracks() }
        #expect(state.errorMessage == nil)
        #expect(state.duration >= 19)
        engine.seek(to: 5_000)
        try await waitUntil { state.position > 5 }

        let gate = ArtworkLoadGate()
        engine.artworkLoader = { spec in
            await gate.wait()
            return try await PlaybackArtworkLoader.placeholder(title: spec.title)
        }
        await engine.play(spec: PlaySpec(url: audioURL.absoluteString, audioFallbackArtwork: "https://img1.doubanio.com/slow.jpg"))
        try await waitUntil { await gate.isWaiting }
        // Replaying even the same URL is a new media owner.
        await engine.play(spec: PlaySpec(url: audioURL.absoluteString))
        await gate.release()
        try await waitUntil { state.position > 0.4 }
        #expect(engine.hasAudioOnlyMediaTracks(), "Late cover must not attach to the replacement")
        #expect(state.errorMessage == nil)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(await condition(), "Timed out waiting for native artwork playback")
    }
}

private actor ArtworkLoadGate {
    var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private struct ArtworkLoaderFixture {
    let directory: URL
    let pipeline: PosterImagePipeline
    let session: URLSession

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkLoaderURLProtocol.self]
        session = URLSession(configuration: configuration)
        pipeline = PosterImagePipeline(session: session, cacheDirectory: directory)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 96,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32))
        bitmap.bitmapData?.initialize(repeating: 180, count: 256 * 96)
        ArtworkLoaderURLProtocol.configure(try #require(bitmap.representation(using: .png, properties: [:])))
    }

    func remove() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ArtworkLoaderURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bytes = Data()
    nonisolated(unsafe) private static var requestSnapshot: URLRequest?
    static var lastRequest: URLRequest? { lock.withLock { requestSnapshot } }
    static func configure(_ data: Data) { lock.withLock { bytes = data; requestSnapshot = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.lock.withLock { Self.requestSnapshot = request; return Self.bytes }
        let accepted = request.url?.path != "/missing" && request.value(forHTTPHeaderField: "Referer") == "https://www.douban.com/"
        let response = HTTPURLResponse(url: request.url!, statusCode: accepted ? 200 : 403,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: accepted ? data : Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
