import AppKit
import Foundation
import ImageIO
import Testing
@testable import NetVplayerApp

@Suite(.serialized)
struct PosterCacheLifecycleTests {
    @Test func accessDoesNotExtendDiskTTL() async throws {
        let fixture = try PosterLifecycleFixture()
        defer { fixture.remove() }
        let clock = PosterLifecycleClock(Date().addingTimeInterval(-1_000))
        let pipeline = fixture.pipeline(ttl: 100, now: clock.now)

        _ = try await pipeline.image(request: fixture.request, key: "ttl", maxPixelSize: 64)
        clock.advance(50)
        _ = try await pipeline.image(request: fixture.request, key: "ttl", maxPixelSize: 64)
        #expect(PosterLifecycleURLProtocol.requestCount == 1)

        clock.advance(51)
        let restarted = fixture.pipeline(ttl: 100, now: clock.now)
        _ = try await restarted.image(request: fixture.request, key: "ttl", maxPixelSize: 64)
        #expect(PosterLifecycleURLProtocol.requestCount == 2)
    }

    @Test func diskWriteFailureStillReturnsDecodedPoster() async throws {
        let fixture = try PosterLifecycleFixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline()
        try FileManager.default.removeItem(at: fixture.directory)
        try Data("not a directory".utf8).write(to: fixture.directory)

        let image = try await pipeline.image(request: fixture.request, key: "read-only", maxPixelSize: 64)

        #expect(image.cgImage.width == 64)
        #expect(image.cgImage.height == 64)
    }

    @Test func diskBudgetEvictsLeastRecentlyUsedPosters() async throws {
        let fixture = try PosterLifecycleFixture()
        defer { fixture.remove() }
        let clock = PosterLifecycleClock(Date().addingTimeInterval(-1_000))
        let initial = fixture.pipeline(now: clock.now)
        _ = try await initial.image(request: fixture.request, key: "a", maxPixelSize: 64)
        let fileBytes = await initial.diskUsage()
        let pipeline = fixture.pipeline(maximumDiskBytes: fileBytes * 3, now: clock.now)
        for key in ["b", "c", "a", "d"] {
            clock.advance(1)
            _ = try await pipeline.image(request: fixture.request, key: key, maxPixelSize: 64)
        }

        #expect(await pipeline.diskUsage() <= fileBytes * 3)
        #expect(PosterLifecycleURLProtocol.requestCount == 4)
        _ = try await pipeline.image(request: fixture.request, key: "a", maxPixelSize: 64)
        #expect(PosterLifecycleURLProtocol.requestCount == 4)
        _ = try await pipeline.image(request: fixture.request, key: "b", maxPixelSize: 64)
        #expect(PosterLifecycleURLProtocol.requestCount == 5)
    }

    @Test func placeholderValidationUsesOriginalDimensions() async throws {
        let fixture = try PosterLifecycleFixture(data: Self.png(width: 128, height: 128, patterned: false))
        defer { fixture.remove() }
        let pipeline = fixture.pipeline()
        #expect(PosterLifecycleURLProtocol.dataCount <= 2_500)

        do {
            _ = try await pipeline.image(request: fixture.request, key: "placeholder", maxPixelSize: 64)
            Issue.record("A small thumbnail must not hide the source image's placeholder dimensions")
        } catch PosterImageError.placeholderImage(let width, let height, _) {
            #expect(width == 128)
            #expect(height == 128)
        }
        #expect(await pipeline.diskUsage() == 0)
    }

    @Test func differentThumbnailSizesShareOneDownload() async throws {
        let fixture = try PosterLifecycleFixture(delay: 0.05)
        defer { fixture.remove() }
        let pipeline = fixture.pipeline()
        let request = fixture.request
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let size = index.isMultiple(of: 2) ? 64 : 256
                    let image = try await pipeline.image(request: request, key: "shared", maxPixelSize: CGFloat(size))
                    #expect(image.cgImage.width == size)
                    return image.cgImage.width
                }
            }
            for try await _ in group {}
        }
        #expect(PosterLifecycleURLProtocol.requestCount == 1)
    }

    @MainActor
    @Test func clearingMemoryRejectsExistingLoaderAndCoalescedWaiter() async throws {
        ImageLoader.clearMemoryCache()
        let fixture = try PosterLifecycleFixture(delay: 0.1)
        defer { fixture.remove(); ImageLoader.clearMemoryCache() }
        let pipeline = fixture.pipeline()
        let first = ImageLoader(pipeline: pipeline)
        let second = ImageLoader(pipeline: pipeline)
        first.load(from: fixture.request.url!.absoluteString, maxPixelSize: 64)
        second.load(from: fixture.request.url!.absoluteString, maxPixelSize: 64)
        try await waitForRequest()

        ImageLoader.clearMemoryCache()
        try await waitUntilFinished(first, second)

        #expect(first.image == nil)
        #expect(second.image == nil)
        #expect(PosterLifecycleURLProtocol.requestCount == 1)
    }

    @MainActor
    @Test func loaderChangesThumbnailSizeWithoutAnotherDownload() async throws {
        ImageLoader.clearMemoryCache()
        let fixture = try PosterLifecycleFixture()
        defer { fixture.remove(); ImageLoader.clearMemoryCache() }
        let loader = ImageLoader(pipeline: fixture.pipeline())
        loader.load(from: fixture.request.url!.absoluteString, maxPixelSize: 64)
        try await waitUntilFinished(loader)
        #expect(loader.image?.size.width == 64)

        loader.load(from: fixture.request.url!.absoluteString, maxPixelSize: 256)
        try await waitUntilFinished(loader)
        #expect(loader.image?.size.width == 256)
        #expect(PosterLifecycleURLProtocol.requestCount == 1)
    }

    @Test func diskClearCancelsAllSharedWaitersWithoutRepopulation() async throws {
        let fixture = try PosterLifecycleFixture(delay: 0.1)
        defer { fixture.remove() }
        let pipeline = fixture.pipeline()
        let first = Task { try await pipeline.image(request: fixture.request, key: "clear", maxPixelSize: 64) }
        let second = Task { try await pipeline.image(request: fixture.request, key: "clear", maxPixelSize: 64) }
        try await waitForRequest()
        try await pipeline.clearDiskCache()

        for task in [first, second] {
            do {
                _ = try await task.value
                Issue.record("A cache clear must invalidate every waiter")
            } catch {}
        }
        #expect(await pipeline.diskUsage() == 0)
    }

    private func waitForRequest() async throws {
        for _ in 0..<200 where PosterLifecycleURLProtocol.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(PosterLifecycleURLProtocol.requestCount > 0)
    }

    @MainActor
    private func waitUntilFinished(_ loaders: ImageLoader...) async throws {
        for _ in 0..<200 where loaders.contains(where: \.isLoading) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(loaders.allSatisfy { !$0.isLoading })
    }

    fileprivate static func png(width: Int = 300, height: Int = 300, patterned: Bool = true) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for y in 0..<height {
            for x in 0..<width {
                let value = patterned ? CGFloat((x &* 37 &+ y &* 101) % 256) / 255 : 0.5
                context.setFillColor(red: value, green: 0.3, blue: 1 - value, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private struct PosterLifecycleFixture {
    let directory: URL
    let session: URLSession
    let request: URLRequest

    init(data: Data? = nil, delay: TimeInterval = 0) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("netvplayer-poster-lifecycle-\(UUID().uuidString)")
        request = URLRequest(url: URL(string: "https://poster-lifecycle.test/\(UUID().uuidString).png")!)
        PosterLifecycleURLProtocol.configure(data: try data ?? PosterCacheLifecycleTests.png(), delay: delay)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PosterLifecycleURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func pipeline(ttl: TimeInterval = 604_800, maximumDiskBytes: Int64 = 256 * 1024 * 1024, now: @escaping @Sendable () -> Date = Date.init) -> PosterImagePipeline {
        PosterImagePipeline(session: session, cacheDirectory: directory, maximumDiskBytes: maximumDiskBytes, ttl: ttl, now: now)
    }

    func remove() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class PosterLifecycleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

private final class PosterLifecycleURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var data = Data()
    nonisolated(unsafe) private static var delay: TimeInterval = 0
    nonisolated(unsafe) private static var count = 0
    private let workLock = NSLock()
    private var work: DispatchWorkItem?

    static var requestCount: Int { lock.withLock { count } }
    static var dataCount: Int { lock.withLock { data.count } }
    static func configure(data: Data, delay: TimeInterval) {
        lock.withLock { Self.data = data; Self.delay = delay; count = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, delay) = Self.lock.withLock {
            Self.count += 1
            return (Self.data, Self.delay)
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.workLock.withLock({ self.work?.isCancelled == false }) else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        workLock.withLock { work = item }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
    }
    override func stopLoading() { workLock.withLock { work?.cancel() } }
}
