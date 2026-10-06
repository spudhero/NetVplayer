import XCTest
import Foundation
import Models
import Networking
@testable import LiveEngine
@testable import NetVplayerApp

final class EPGStreamingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_812_800) // 2026-10-01 00:00 UTC
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("epg-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func xml(_ count: Int = 1) -> Data {
        Data(("<tv><channel id='one'><display-name>One</display-name></channel>" + (0..<count).map {
            "<programme channel='one' start='20261001000000 +0000' stop='20261001010000 +0000'><title><![CDATA[Show \($0)]]></title></programme>"
        }.joined() + "</tv>").utf8)
    }
    private func client() -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EPGFixtureProtocol.self]
        return HTTPClient(session: URLSession(configuration: config))
    }

    func testStreamingBatchesRejectMalformedEntityAndQuotaOverflow() throws {
        let file = try folder().appendingPathComponent("feed.xml")
        try xml(17).write(to: file)
        var limits = EPGImportLimits(); limits.batchCount = 3
        var batches: [[XMLTVProgramme]] = []
        let channels = try XMLTVStreamingParser.parse(file: file, limits: limits) { batches.append($0) }
        XCTAssertEqual(channels["one"], "One")
        XCTAssertEqual(batches.flatMap { $0 }.count, 17)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 3 })
        XCTAssertEqual(batches.first?.first?.item.title, "Show 0")
        limits.programmeCount = 16
        XCTAssertThrowsError(try XMLTVStreamingParser.parse(file: file, limits: limits) { _ in })
        for text in ["<tv><programme>", "<!DOCTYPE tv [<!ENTITY e 'expanded'>]><tv>&e;</tv>", "<not-tv/>"] {
            try Data(text.utf8).write(to: file)
            XCTAssertThrowsError(try XMLTVStreamingParser.parse(file: file) { _ in })
        }
        try xml().write(to: file)
        limits = EPGImportLimits(); limits.fieldBytes = 4
        XCTAssertThrowsError(try XMLTVStreamingParser.parse(file: file, limits: limits) { _ in })
    }

    func testGzipRejectsTruncationAndExpandedBudget() throws {
        let directory = try folder(), input = directory.appendingPathComponent("feed.gz")
        let data = try XCTUnwrap(Data(base64Encoded: "H4sIAIsQOWoAA7MpKbOzSc5IzMtLzVHITLFVSq9SsrNJySwuyEms1M1LzE21c4+y0UcRsNGHarCzKSjKTy9KzM1NVYAKgQ1QKC5JLCqxVTIyMDIzMDMyMrAwAAIFbRAJkswvQJKzRJKzsynJLMkBWlmVWaAQnJFfbqMPEbDRh9sEZAPdDAA1HuAYuAAAAA=="))
        try data.write(to: input)
        let expanded = try EPGFileExpansion.expandIfNeeded(input: input, output: directory.appendingPathComponent("valid.xml"), maximumBytes: 1_024)
        XCTAssertEqual(try XMLTVStreamingParser.parse(file: expanded) { _ in }["gz"], "GZ")
        XCTAssertThrowsError(try EPGFileExpansion.expandIfNeeded(input: input, output: directory.appendingPathComponent("too-big.xml"), maximumBytes: 32))
        try data.dropLast(5).write(to: input)
        XCTAssertThrowsError(try EPGFileExpansion.expandIfNeeded(input: input, output: directory.appendingPathComponent("truncated.xml"), maximumBytes: 1_024))
    }

    func testAtomicRefreshPreservesOldIndexOnInvalidDownloadAndCancellation() async throws {
        let now = self.now
        let directory = try folder(), url = "https://epg.invalid/\(UUID()).xml"
        var limits = EPGImportLimits(); limits.downloadBytes = 2_048
        let repository = XMLTVRepository(directory: directory, client: client(), limits: limits)
        let window = DateInterval(start: now, duration: 6 * 3_600)
        EPGFixtureProtocol.set(url, data: xml())
        let first = await repository.programmes(url: url, channelID: "one", channelName: "One", window: window, now: now)
        XCTAssertEqual(first.availability, .available)
        XCTAssertEqual(first.data.items.first?.title, "Show 0")
        let active = directory.appendingPathComponent(XMLTVIndex.digest(url)).appendingPathComponent("active.json")
        let before = try Data(contentsOf: active)
        EPGFixtureProtocol.set(url, data: Data("<tv><programme>broken".utf8))
        let failed = await repository.programmes(url: url, channelID: "one", channelName: "One", window: window, forceRefresh: true, now: now)
        XCTAssertEqual(failed.availability, .stale)
        XCTAssertEqual(failed.data.items, first.data.items)
        XCTAssertEqual(try Data(contentsOf: active), before)

        EPGFixtureProtocol.set(url, data: Data(repeating: 65, count: 4_096))
        let oversized = await repository.programmes(url: url, channelID: "one", channelName: "One", window: window, forceRefresh: true, now: now)
        XCTAssertEqual(oversized.availability, .stale)
        XCTAssertEqual(try Data(contentsOf: active), before)

        let started = expectation(description: "download started")
        EPGFixtureProtocol.set(url, data: xml(), hold: true, onStart: { started.fulfill() })
        let cancelled = Task { await repository.programmes(url: url, channelID: "one", channelName: "One", window: window, forceRefresh: true, now: now) }
        await fulfillment(of: [started], timeout: 3)
        await repository.cancelImport(url: url)
        let result = await cancelled.value
        XCTAssertEqual(result.availability, .stale)
        XCTAssertEqual(try Data(contentsOf: active), before)
        EPGFixtureProtocol.set(url, data: Data("<tv/>".utf8))
        let empty = await repository.programmes(url: url, channelID: "one", channelName: "One", window: window, forceRefresh: true, now: now)
        XCTAssertEqual(empty.availability, .empty, "A valid empty feed may replace old data")
    }

    func testFeedCacheIsSharedAcrossChannelsAndDoesNotGuessAmbiguousName() async throws {
        let now = self.now
        let directory = try folder(), url = "https://epg.invalid/\(UUID()).xml"
        let repository = XMLTVRepository(directory: directory, client: client())
        let data = String(decoding: xml(), as: UTF8.self).replacingOccurrences(of: "</tv>", with: "<channel id='two'><display-name>One</display-name></channel></tv>")
        EPGFixtureProtocol.set(url, data: Data(data.utf8))
        let window = DateInterval(start: now, duration: 6 * 3_600)
        async let one = repository.programmes(url: url, channelID: "one", channelName: "One", window: window, now: now)
        async let two = repository.programmes(url: url, channelID: "two", channelName: "One", window: window, now: now)
        let results = await [one, two]
        XCTAssertEqual(results[0].data.items.count, 1)
        XCTAssertEqual(results[1].data.items.count, 0)
        XCTAssertEqual(EPGFixtureProtocol.count(url), 1)
        let ambiguous = await repository.programmes(url: url, channelID: "missing", channelName: "One", window: window, now: now)
        XCTAssertTrue(ambiguous.data.items.isEmpty)
    }

    @MainActor
    func testGuideLimitsConcurrencyAndIgnoresOldWindowCompletions() async throws {
        let gate = EPGGuideGate(), model = EPGGuideModel()
        let window = DateInterval(start: now, duration: 6 * 3_600)
        model.reset(window: window) { channel, _, _ in await gate.load(channel.name) }
        for index in 0..<50 { model.appear(id: "\(index)", channel: Channel(name: "old-\(index)"), generation: model.generation) }
        for _ in 0..<100 where await gate.count < 4 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.loading.count, 4)
        let count = await gate.count
        XCTAssertEqual(count, 4)
        let oldGeneration = model.generation
        model.reset(window: DateInterval(start: now.addingTimeInterval(21_600), duration: 21_600)) { channel, _, _ in
            EpgLoadResult(data: EpgData(channelName: channel.name, items: [EpgItem(title: "new")]), availability: .available)
        }
        model.appear(id: "0", channel: Channel(name: "new"), generation: model.generation)
        model.disappear(id: "0", generation: oldGeneration)
        await gate.releaseAll()
        for _ in 0..<100 where model.rows["0"] == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.rows["0"]?.data.items.first?.title, "new")
        XCTAssertEqual(model.rows.count, 1)
        model.stop()
        XCTAssertTrue(model.rows.isEmpty)
    }
}

private actor EPGGuideGate {
    var pending: [CheckedContinuation<EpgLoadResult, Never>] = []
    var count: Int { pending.count }
    func load(_ name: String) async -> EpgLoadResult { await withCheckedContinuation { pending.append($0) } }
    func releaseAll() {
        let values = pending; pending = []
        values.forEach { $0.resume(returning: EpgLoadResult(data: EpgData(items: [EpgItem(title: "old")]), availability: .available)) }
    }
}

private final class EPGFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture: Sendable { var data: Data; var hold: Bool; var onStart: (@Sendable () -> Void)?; var count = 0 }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: Fixture] = [:]
    static func set(_ url: String, data: Data, hold: Bool = false, onStart: (@Sendable () -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        fixtures[url] = Fixture(data: data, hold: hold, onStart: onStart)
    }
    static func count(_ url: String) -> Int { lock.lock(); defer { lock.unlock() }; return fixtures[url]?.count ?? 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let fixture = Self.fixtures[request.url!.absoluteString]
        Self.fixtures[request.url!.absoluteString]?.count += 1
        Self.lock.unlock()
        fixture?.onStart?()
        guard let fixture, !fixture.hold else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
