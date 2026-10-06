import AppKit
import Foundation
import ImageIO
import Testing
@testable import NetVplayerApp

@MainActor
@Suite(.serialized)
struct PosterCancellationTests {
    @Test func sourceChangeCancelsAllOldDownloadsAndLoadsNewPosters() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline()
        let old = (0..<8).map { _ in ImageLoader(pipeline: pipeline) }
        for (index, loader) in old.enumerated() {
            loader.load(from: fixture.url("/blocked/old-\(index)").absoluteString, maxPixelSize: 64)
        }
        try await waitUntil { PosterCancellationURLProtocol.state.requestCount == 8 }

        for loader in old { loader.cancel() }
        #expect(old.allSatisfy { !$0.isLoading })
        let fresh = ImageLoader(pipeline: pipeline)
        fresh.load(from: fixture.url("/ready/new").absoluteString, maxPixelSize: 64)

        // Old responses never arrive: success requires cancelling their actual downloads.
        try await waitUntil {
            PosterCancellationURLProtocol.state.cancellationCount == 8 && fresh.image != nil
        }
        #expect(PosterCancellationURLProtocol.state.count(for: "/ready/new") == 1)
        #expect(old.allSatisfy { $0.image == nil })
    }

    @Test func cancellingQueuedPosterPreventsItFromTakingReleasedSlot() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline(limit: 1)
        let active = fixture.start(pipeline, path: "/blocked/active")
        defer { active.task.cancel() }
        try await waitUntil { PosterCancellationURLProtocol.state.count(for: "/blocked/active") == 1 }
        let queued = fixture.start(pipeline, path: "/blocked/queued")
        defer { queued.task.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        queued.task.cancel()
        try await waitUntil { queued.isFinished }
        try await expectCancellation(queued.task)

        let fresh = fixture.start(pipeline, path: "/ready/new")
        defer { fresh.task.cancel() }
        PosterCancellationURLProtocol.state.complete(path: "/blocked/active")
        try await waitUntil { active.isFinished && fresh.isFinished }
        _ = try await active.task.value
        _ = try await fresh.task.value
        #expect(PosterCancellationURLProtocol.state.count(for: "/blocked/queued") == 0)
    }

    @Test(arguments: [64, 256])
    func cancellingOneWaiterPreservesSharedDownload(secondSize: Int) async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline()
        let first = fixture.start(pipeline, path: "/blocked/shared", size: 64)
        let second = fixture.start(pipeline, path: "/blocked/shared", size: secondSize)
        defer { first.task.cancel(); second.task.cancel() }
        try await waitUntil { PosterCancellationURLProtocol.state.count(for: "/blocked/shared") == 1 }
        try await Task.sleep(for: .milliseconds(20))

        first.task.cancel()
        try await waitUntil { first.isFinished }
        try await expectCancellation(first.task)
        #expect(PosterCancellationURLProtocol.state.cancellationCount == 0)
        #expect(!second.isFinished)

        PosterCancellationURLProtocol.state.complete(path: "/blocked/shared")
        try await waitUntil { second.isFinished }
        let image = try await second.task.value
        #expect(image.cgImage.width == secondSize)
        #expect(PosterCancellationURLProtocol.state.count(for: "/blocked/shared") == 1)
    }

    @Test func cancelledLoaderCanLoadSamePosterAgain() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let loader = ImageLoader(pipeline: fixture.pipeline())
        let url = fixture.url("/blocked/reappear").absoluteString
        loader.load(from: url, maxPixelSize: 64)
        try await waitUntil { PosterCancellationURLProtocol.state.requestCount == 1 }

        loader.cancel()
        try await waitUntil { PosterCancellationURLProtocol.state.cancellationCount == 1 }
        loader.load(from: url, maxPixelSize: 64)
        try await waitUntil { PosterCancellationURLProtocol.state.requestCount == 2 }
        PosterCancellationURLProtocol.state.complete(path: "/blocked/reappear")
        try await waitUntil { !loader.isLoading }

        #expect(loader.image != nil)
        #expect(PosterCancellationURLProtocol.state.cancellationCount == 1)
    }

    @Test func cancellingAllThumbnailSizesStopsSharedDownload() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline()
        let first = fixture.start(pipeline, path: "/blocked/shared", size: 64)
        let second = fixture.start(pipeline, path: "/blocked/shared", size: 256)
        defer { first.task.cancel(); second.task.cancel() }
        try await waitUntil { PosterCancellationURLProtocol.state.requestCount == 1 }
        try await Task.sleep(for: .milliseconds(20))

        first.task.cancel()
        second.task.cancel()

        try await waitUntil {
            first.isFinished && second.isFinished && PosterCancellationURLProtocol.state.cancellationCount == 1
        }
        try await expectCancellation(first.task)
        try await expectCancellation(second.task)
        #expect(PosterCancellationURLProtocol.state.requestCount == 1)
    }

    @Test func cancelledThumbnailSizeCanRejoinSharedDownload() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline()
        let first = fixture.start(pipeline, path: "/blocked/shared", size: 64)
        let second = fixture.start(pipeline, path: "/blocked/shared", size: 256)
        defer { first.task.cancel(); second.task.cancel() }
        try await waitUntil { PosterCancellationURLProtocol.state.requestCount == 1 }
        try await Task.sleep(for: .milliseconds(20))
        first.task.cancel()
        try await waitUntil { first.isFinished }
        try await expectCancellation(first.task)
        let replacement = fixture.start(pipeline, path: "/blocked/shared", size: 64)
        defer { replacement.task.cancel() }
        try await Task.sleep(for: .milliseconds(20))

        PosterCancellationURLProtocol.state.complete(path: "/blocked/shared")
        try await waitUntil { second.isFinished && replacement.isFinished }

        #expect(try await second.task.value.cgImage.width == 256)
        #expect(try await replacement.task.value.cgImage.width == 64)
        #expect(PosterCancellationURLProtocol.state.requestCount == 1)
        #expect(PosterCancellationURLProtocol.state.cancellationCount == 0)
    }

    @Test func changingPosterURLCancelsPreviousDownload() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        let loader = ImageLoader(pipeline: fixture.pipeline(limit: 1))
        loader.load(from: fixture.url("/blocked/old").absoluteString, maxPixelSize: 64)
        try await waitUntil { PosterCancellationURLProtocol.state.requestCount == 1 }

        loader.load(from: fixture.url("/ready/new").absoluteString, maxPixelSize: 64)
        try await waitUntil {
            PosterCancellationURLProtocol.state.cancellationCount == 1 && loader.image != nil
        }
        #expect(PosterCancellationURLProtocol.state.count(for: "/ready/new") == 1)
    }

    @Test func releasingLoaderCancelsItsDownload() async throws {
        let fixture = try PosterCancellationFixture()
        defer { fixture.remove() }
        var loader: ImageLoader? = ImageLoader(pipeline: fixture.pipeline())
        let isAlive = { [weak loader] in loader != nil }
        loader?.load(from: fixture.url("/blocked/released").absoluteString, maxPixelSize: 64)
        try await waitUntil { PosterCancellationURLProtocol.state.requestCount == 1 }

        loader = nil

        #expect(!isAlive())
        try await waitUntil { PosterCancellationURLProtocol.state.cancellationCount == 1 }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PosterCancellationProbeError.timedOut
    }

    private func expectCancellation(_ task: Task<DecodedPosterImage, Error>) async throws {
        do {
            _ = try await task.value
            Issue.record("A cancelled poster waiter must finish with CancellationError")
        } catch is CancellationError {}
    }
}

private enum PosterCancellationProbeError: Error { case timedOut }

private struct PosterCancellationFixture {
    let directory: URL
    let session: URLSession
    private let baseURL = "https://poster-cancellation-\(UUID().uuidString).test"

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("netvplayer-poster-cancellation-\(UUID().uuidString)")
        PosterCancellationURLProtocol.state.configure(data: try Self.png())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PosterCancellationURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func url(_ path: String) -> URL { URL(string: baseURL + path)! }

    func pipeline(limit: Int = 8) -> PosterImagePipeline {
        PosterImagePipeline(session: session, cacheDirectory: directory, maximumConcurrentDownloads: limit)
    }

    func start(_ pipeline: PosterImagePipeline, path: String, size: Int = 64) -> TrackedPosterRequest {
        TrackedPosterRequest(pipeline: pipeline, request: URLRequest(url: url(path)), key: path, size: size)
    }

    func remove() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func png() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 1_200,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for y in 0..<300 {
            for x in 0..<300 {
                let value = CGFloat((x &* 37 &+ y &* 101) % 256) / 255
                context.setFillColor(red: value, green: 0.3, blue: 1 - value, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private struct TrackedPosterRequest {
    let task: Task<DecodedPosterImage, Error>
    private let completion = PosterRequestCompletion()
    var isFinished: Bool { completion.isFinished }

    init(pipeline: PosterImagePipeline, request: URLRequest, key: String, size: Int) {
        let completion = self.completion
        task = Task {
            defer { completion.finish() }
            return try await pipeline.image(request: request, key: key, maxPixelSize: CGFloat(size))
        }
    }
}

private final class PosterRequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.withLock { finished } }
    func finish() { lock.withLock { finished = true } }
}

private final class PosterCancellationURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = PosterCancellationProtocolState()
    let id = UUID()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.start(self)
        if request.url!.path.hasPrefix("/ready/") { complete() }
    }

    override func stopLoading() { Self.state.cancel(self) }

    func complete() {
        guard let data = Self.state.finish(self) else { return }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class PosterCancellationProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var requests: [String: Int] = [:]
    private var active: [UUID: PosterCancellationURLProtocol] = [:]
    private var cancellations = 0

    var requestCount: Int { lock.withLock { requests.values.reduce(0, +) } }
    var cancellationCount: Int { lock.withLock { cancellations } }
    func count(for path: String) -> Int { lock.withLock { requests[path, default: 0] } }

    func configure(data: Data) {
        lock.withLock {
            self.data = data
            requests.removeAll()
            active.removeAll()
            cancellations = 0
        }
    }

    func start(_ request: PosterCancellationURLProtocol) {
        lock.withLock {
            requests[request.request.url!.path, default: 0] += 1
            active[request.id] = request
        }
    }

    func cancel(_ request: PosterCancellationURLProtocol) {
        lock.withLock {
            if active.removeValue(forKey: request.id) != nil { cancellations += 1 }
        }
    }

    func finish(_ request: PosterCancellationURLProtocol) -> Data? {
        lock.withLock {
            guard active.removeValue(forKey: request.id) != nil else { return nil }
            return data
        }
    }

    func complete(path: String) {
        let pending = lock.withLock { active.values.filter { $0.request.url!.path == path } }
        for request in pending { request.complete() }
    }
}
