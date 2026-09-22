import AppKit
import Foundation
import ImageIO
import Models
import SpiderEngine
import Storage
import Testing
@testable import NetVplayerApp

private final class PerformanceCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor PerformanceCacheCounter {
    private var value = 0

    func increment() { value += 1 }
    func count() -> Int { value }
}

private actor DeferredPerformanceResult {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<Result, Never>?

    func load() async -> Result {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func complete(_ result: Result) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

@Test func cacheManagerClearsManagedPostersWithoutDeletingFeedback() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("netvplayer-cache-manager-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = CacheManager(cacheDirectory: root)
    let posterFile = manager.directory(for: .posters).appendingPathComponent("poster.img")
    try Data(repeating: 1, count: 8_192).write(to: posterFile)
    let feedbackDirectory = root.appendingPathComponent("Feedback", isDirectory: true)
    try FileManager.default.createDirectory(at: feedbackDirectory, withIntermediateDirectories: true)
    let feedbackFile = feedbackDirectory.appendingPathComponent("report.json")
    try Data("feedback".utf8).write(to: feedbackFile)

    #expect(manager.size(for: .posters) >= 8_192)
    try manager.clearCache()

    #expect(manager.size(for: .posters) == 0)
    #expect(FileManager.default.fileExists(atPath: feedbackFile.path))
}

@Test func catalogRepositoryRestoresPagesAndAppliesFreshnessWindows() async throws {
    let clock = PerformanceCacheClock(Date(timeIntervalSince1970: 1_000))
    let repository = CatalogRepository(
        maximumPages: 4,
        freshTTL: 300,
        staleTTL: 1_800,
        now: clock.now
    )
    let key = CatalogCacheBaseKey(
        revision: 1,
        siteKey: "site",
        kind: .category("movie"),
        selection: ["area": "cn"]
    )
    let counter = PerformanceCacheCounter()

    _ = try await repository.result(for: key, page: 1) {
        await counter.increment()
        return Result(
            list: [Vod(vodId: "1", vodName: "One")],
            page: 1,
            pagecount: 2
        )
    }
    _ = try await repository.result(for: key, page: 1) {
        await counter.increment()
        return .empty
    }
    _ = try await repository.result(for: key, page: 2) {
        await counter.increment()
        return Result(
            list: [Vod(vodId: "2", vodName: "Two")],
            page: 2,
            pagecount: 2
        )
    }

    var lookup = await repository.lookup(key)
    #expect(lookup.pages.count == 2)
    #expect(lookup.pages.flatMap(\.list).map(\.vodId) == ["1", "2"])
    #expect(lookup.freshness == .fresh)
    #expect(await counter.count() == 2)

    clock.advance(301)
    lookup = await repository.lookup(key)
    #expect(lookup.freshness == .stale)

    clock.advance(1_500)
    lookup = await repository.lookup(key)
    #expect(lookup.freshness == .expired)

    await repository.invalidate(key)
    #expect((await repository.lookup(key)).freshness == .miss)
}

@Test func detailRepositoryCoalescesRequestsAndCachesSuccessfulResult() async throws {
    let repository = VodDetailRepository(maximumEntries: 2, ttl: 600)
    let key = VodDetailCacheKey(revision: 1, siteKey: "site", vodID: "vod")
    let counter = PerformanceCacheCounter()

    async let first = repository.result(for: key) {
        await counter.increment()
        try await Task.sleep(for: .milliseconds(50))
        return Result(list: [Vod(vodId: "vod", vodName: "Detail")])
    }
    async let second = repository.result(for: key) {
        await counter.increment()
        return .empty
    }
    let values = try await [first, second]
    #expect(values.allSatisfy { $0.list.first?.vodName == "Detail" })
    #expect(await counter.count() == 1)

    _ = try await repository.result(for: key) {
        await counter.increment()
        return .empty
    }
    #expect(await counter.count() == 1)
    #expect(await repository.entryCount() == 1)
}

@Test func invalidatedCatalogRequestCannotRepopulateCacheAfterIgnoringCancellation() async throws {
    let repository = CatalogRepository()
    let key = CatalogCacheBaseKey(revision: 1, siteKey: "site", kind: .category("movie"))
    let deferred = DeferredPerformanceResult()
    let request = Task {
        try await repository.result(for: key, page: 1) {
            await deferred.load()
        }
    }

    await deferred.waitUntilStarted()
    await repository.invalidate(key)
    await deferred.complete(Result(list: [Vod(vodId: "late", vodName: "Late")]))
    _ = try await request.value

    #expect((await repository.lookup(key)).freshness == .miss)
    #expect((await repository.stats()).pageCount == 0)
}

@Test func clearedDetailPrefetchCannotRepopulateCacheAfterIgnoringCancellation() async throws {
    let repository = VodDetailRepository()
    let key = VodDetailCacheKey(revision: 1, siteKey: "site", vodID: "vod")
    let deferred = DeferredPerformanceResult()
    await repository.prefetch(key: key) {
        await deferred.load()
    }

    await deferred.waitUntilStarted()
    await repository.clear()
    await deferred.complete(Result(list: [Vod(vodId: "vod", vodName: "Late")]))
    try await Task.sleep(for: .milliseconds(20))

    #expect(await repository.entryCount() == 0)
}

@MainActor
@Test func appStateReusesCategoryPagesWhenSwitchingBack() async throws {
    await CatalogRepository.shared.clear()
    let provider = CountingCatalogProvider()
    let site = Site(
        key: "performance-cache-site",
        name: "Performance Cache",
        type: 3,
        api: "csp_PerformanceCache",
        searchable: 1
    )
    await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: provider)
    let state = AppState(
        loadDefaultConfig: false,
        startProxyServer: false,
        providerRuntimeRegistrationOverride: { true },
        providerRuntimeStartupOverride: { true }
    )
    state.sites = [site]
    state.activeSite = site
    state.isConfigLoaded = true
    let movies = VodClass(typeId: "movie", typeName: "电影")
    let series = VodClass(typeId: "series", typeName: "剧集")

    await state.selectCategory(movies)
    await state.selectCategory(movies)
    #expect(await provider.categoryCallCount() == 1)

    await state.selectCategory(series)
    #expect(await provider.categoryCallCount() == 2)

    await state.selectCategory(movies)
    #expect(await provider.categoryCallCount() == 2)
    #expect(state.vods.map(\.vodId) == ["movie-1"])
}

@MainActor
@Test func latestCategorySelectionRejectsEarlierSlowResponse() async throws {
    await CatalogRepository.shared.clear()
    let provider = RacingCatalogProvider()
    let site = Site(
        key: "performance-race-site",
        name: "Performance Race",
        type: 3,
        api: "csp_PerformanceRace",
        searchable: 1
    )
    await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: provider)
    let state = AppState(
        loadDefaultConfig: false,
        startProxyServer: false,
        providerRuntimeRegistrationOverride: { true },
        providerRuntimeStartupOverride: { true }
    )
    state.sites = [site]
    state.activeSite = site
    state.isConfigLoaded = true

    let slow = Task { await state.selectCategory(VodClass(typeId: "slow", typeName: "慢")) }
    try await Task.sleep(for: .milliseconds(10))
    let fast = Task { await state.selectCategory(VodClass(typeId: "fast", typeName: "快")) }
    await fast.value
    await slow.value

    #expect(state.selectedCategory?.typeId == "fast")
    #expect(state.vods.map(\.vodId) == ["fast-1"])
}

@MainActor
@Test func appStateShowsProvisionalDetailThenAppliesExpandedEpisodes() async throws {
    await VodDetailRepository.shared.clear()
    let provider = ProgressiveDetailProvider()
    let site = Site(
        key: "progressive-detail-site",
        name: "Progressive Detail",
        type: 3,
        api: "csp_ProgressiveDetail",
        searchable: 1
    )
    await SpiderReplacementRegistry.shared.register(originalAPI: site.api, provider: provider)
    let state = AppState(
        loadDefaultConfig: false,
        startProxyServer: false,
        providerRuntimeRegistrationOverride: { true },
        providerRuntimeStartupOverride: { true }
    )
    state.sites = [site]
    state.activeSite = site
    state.isConfigLoaded = true

    let load = Task {
        await state.selectVod(Vod(vodId: "progressive-vod", vodName: "Initial", siteKey: site.key))
    }
    try await Task.sleep(for: .milliseconds(50))

    #expect(state.detailVod?.vodContent == "详情已显示")
    #expect(state.detailVod?.vodPlayUrl.contains("netvplayer-pending:") == true)
    #expect(state.playFlags == ["夸克网盘"])
    #expect(state.isDetailLoading)

    await load.value
    #expect(state.detailVod?.vodPlayUrl == "第1集$https://media.example.test/episode-1.m3u8")
    #expect(state.episodes.map(\.name) == ["第1集"])
    #expect(!state.isDetailLoading)
    #expect(await provider.detailCallCount() == 2)
    #expect(await VodDetailRepository.shared.entryCount() == 1)
}

@MainActor
@Test func posterPipelineCoalescesNetworkAndSurvivesRecreation() async throws {
    PosterCacheURLProtocol.reset()
    defer { PosterCacheURLProtocol.reset() }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("netvplayer-poster-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let data = try makePosterPNG()
    PosterCacheURLProtocol.responseData = data
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PosterCacheURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let request = URLRequest(url: URL(string: "https://poster.example.test/image.png")!)
    let pipeline = PosterImagePipeline(session: session, cacheDirectory: directory)

    async let first = pipeline.image(request: request, key: "fixture", maxPixelSize: 256)
    async let second = pipeline.image(request: request, key: "fixture", maxPixelSize: 256)
    let images = try await [first, second]
    #expect(images.allSatisfy { $0.cgImage.width == 32 && $0.cgImage.height == 32 })
    #expect(PosterCacheURLProtocol.requestCount == 1)
    #expect(await pipeline.diskUsage() > 0)

    let recreated = PosterImagePipeline(session: session, cacheDirectory: directory)
    _ = try await recreated.image(request: request, key: "fixture", maxPixelSize: 256)
    #expect(PosterCacheURLProtocol.requestCount == 1)

    try await recreated.clearDiskCache()
    #expect(await recreated.diskUsage() == 0)
}

@MainActor
private func makePosterPNG() throws -> Data {
    let width = 32
    let height = 32
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        "public.png" as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private final class PosterCacheURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock()
        count = 0
        responseData = Data()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let data = Self.responseData
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor CountingCatalogProvider: SiteContentProvider {
    private var categoryCalls = 0

    func categoryCallCount() -> Int { categoryCalls }

    func homeContent(site: Site) async throws -> Result {
        Result(types: [VodClass(typeId: "movie", typeName: "电影")])
    }

    func categoryContent(
        site: Site,
        tid: String,
        page: String,
        filter: Bool,
        extend: [String: String]
    ) async throws -> Result {
        categoryCalls += 1
        return Result(
            list: [Vod(vodId: "\(tid)-\(page)", vodName: tid, siteKey: site.key)],
            page: Int(page) ?? 1,
            pagecount: 1
        )
    }

    func detailContent(site: Site, id: String) async throws -> Result {
        Result(list: [Vod(vodId: id, vodName: id, siteKey: site.key)])
    }

    func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        Result(url: id, flag: flag, key: site.key)
    }

    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        .empty
    }
}

private actor RacingCatalogProvider: SiteContentProvider {
    func homeContent(site: Site) async throws -> Result { .empty }

    func categoryContent(
        site: Site,
        tid: String,
        page: String,
        filter: Bool,
        extend: [String: String]
    ) async throws -> Result {
        if tid == "slow" {
            try await Task.sleep(for: .milliseconds(100))
        }
        return Result(
            list: [Vod(vodId: "\(tid)-1", vodName: tid, siteKey: site.key)],
            page: 1,
            pagecount: 1
        )
    }

    func detailContent(site: Site, id: String) async throws -> Result { .empty }
    func playerContent(site: Site, flag: String, id: String) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}

private actor ProgressiveDetailProvider: SiteContentProvider {
    private var detailCalls = 0

    func detailCallCount() -> Int { detailCalls }
    func homeContent(site: Site) async throws -> Result { .empty }

    func categoryContent(
        site: Site,
        tid: String,
        page: String,
        filter: Bool,
        extend: [String: String]
    ) async throws -> Result { .empty }

    func detailContent(site: Site, id: String) async throws -> Result {
        detailCalls += 1
        let playURL = detailCalls == 1
            ? "正在加载夸克网盘资源$netvplayer-pending://episode?title=Detail"
            : "第1集$https://media.example.test/episode-1.m3u8"
        return Result(list: [Vod(
            vodId: id,
            vodName: "Progressive",
            vodContent: "详情已显示",
            vodPlayFrom: "夸克网盘",
            vodPlayUrl: playURL,
            siteKey: site.key
        )])
    }

    func playerContent(site: Site, flag: String, id: String) async throws -> Result { .empty }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result { .empty }
}
