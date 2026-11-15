import Foundation
import Models
import Testing
@testable import LiveEngine

struct XMLTVTimestampCacheTests {
    private let epoch = Date(timeIntervalSince1970: 1_790_812_800)

    private func withFeed<T>(_ body: String, _ operation: (URL) throws -> T) throws -> T {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xmltv-dates-\(UUID()).xml")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(body.utf8).write(to: file)
        return try operation(file)
    }

    private func programme(_ start: String, _ stop: String, title: String = "Show") -> String {
        "<programme channel='one' start='\(start)' stop='\(stop)'><title>\(title)</title></programme>"
    }

    @Test func cachedSuccessAndFailureDoNotResolveAgain() {
        var cache = XMLTVTimestampCache(), calls = 0
        for _ in 0..<20 {
            #expect(cache.date(for: "20261001000000 +0000") { calls += 1; return epoch } == epoch)
            #expect(cache.date(for: "invalid") { calls += 1; return nil } == nil)
        }
        #expect(calls == 2)
        #expect(cache.count == 2)
    }

    @Test func hitsDoNotGrowOrReorderTheBoundedRing() {
        var cache = XMLTVTimestampCache()
        for index in 0..<XMLTVTimestampCache.capacity {
            _ = cache.date(for: "\(index)") { index == 0 ? nil : epoch }
        }
        // A hit on the oldest invalid value stays a hit but does not pin it.
        #expect(cache.date(for: "0") { Issue.record("invalid entry was lost"); return epoch } == nil)
        _ = cache.date(for: "overflow") { epoch }
        #expect(cache.count == XMLTVTimestampCache.capacity)
        var resolved = 0
        #expect(cache.date(for: "0") { resolved += 1; return epoch } == epoch)
        #expect(resolved == 1)
        // More than two full wraps keep both valid and invalid entries bounded.
        for index in 0..<(XMLTVTimestampCache.capacity * 3) {
            _ = cache.date(for: "new-\(index)") { index.isMultiple(of: 2) ? epoch : nil }
            #expect(cache.count == XMLTVTimestampCache.capacity)
        }
    }

    @Test func separateParsesOwnSeparateCaches() throws {
        var first = XMLTVTimestampCache(), second = XMLTVTimestampCache(), calls = 0
        _ = first.date(for: "same-key") { calls += 1; return epoch }
        #expect(second.date(for: "same-key") { calls += 1; return nil } == nil)
        #expect(calls == 2)
        for title in ["first import", "second import"] {
            try withFeed("<tv>" + programme("20261001000000 +0000", "20261001010000 +0000", title: title) + "</tv>") { file in
                var items: [EpgItem] = []
                _ = try XMLTVStreamingParser.parse(file: file) { items += $0.map(\.item) }
                #expect(items == [EpgItem(title: title, start: epoch, end: epoch.addingTimeInterval(3_600))])
            }
        }
    }

    @Test(arguments: [
        ["20261001000000 +0000", "20261001010000 +0000"],
        ["20261001000000+0000", "20261001010000+0000"],
        ["20261001000000", "20261001010000"],
        ["202610010000", "202610010100"],
        ["20261001080000 +0800", "20261001090000 +0800"],
        ["20260930163000 -0730", "20260930173000 -0730"],
        ["20261001054500 +0545", "20261001064500 +0545"]
    ])
    func formatsAndTimeZonesSurviveRepeatedHits(pair: [String]) throws {
        let text = "<tv>" + (0..<9).map { programme(pair[0], pair[1], title: "Show \($0)") }.joined() + "</tv>"
        try withFeed(text) { file in
            var items: [EpgItem] = []
            _ = try XMLTVStreamingParser.parse(file: file) { items += $0.map(\.item) }
            #expect(items == (0..<9).map { EpgItem(title: "Show \($0)", start: epoch, end: epoch.addingTimeInterval(3_600)) })
        }
    }

    @Test func byteLimitAndInvalidDatesKeepSkipSemantics() throws {
        let start = "20261001000000 +0000", stop = "20261001010000 +0000"
        let fortyBytes = start + String(repeating: " ", count: 20)
        #expect(fortyBytes.utf8.count == 40)
        let rejected = ["bad-date", "20260230000000 +0000", "20261301000000 +0000",
                        "20261001250000 +0000", fortyBytes + " ", start + String(repeating: "界", count: 8)]
        let rows = (0..<10).map { _ in
            programme(fortyBytes, stop) + rejected.map { programme($0, stop) }.joined()
                + programme(start, "invalid-stop")
        }.joined()
        try withFeed("<tv>" + rows + "</tv>") { file in
            var count = 0
            _ = try XMLTVStreamingParser.parse(file: file) { count += $0.count }
            #expect(count == 10)
        }
    }

    @Test func durationAndWindowChecksStillApplyOnHits() throws {
        let start = "20261001000000 +0000"
        let rows = (0..<4).map { _ in
            programme(start, start) + programme(start, "20260930230000 +0000")
                + programme(start, "20261003000000 +0000", title: "two days")
                + programme(start, "20261003000001 +0000")
                + programme(start, "20261001010000 +0000", title: "hour")
        }.joined()
        try withFeed("<tv>" + rows + "</tv>") { file in
            for offset in [0.0, 3_600, 172_800] {
                var items: [EpgItem] = []
                _ = try XMLTVStreamingParser.parse(file: file, window: DateInterval(start: epoch.addingTimeInterval(offset), duration: 3_600)) {
                    items += $0.map(\.item)
                }
                #expect(items.count == (offset == 0 ? 8 : offset == 3_600 ? 4 : 0))
            }
        }
    }

    @Test func uniqueTimestampsBeyondCapacityKeepEveryRowAndBatchOrder() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let count = XMLTVTimestampCache.capacity + 32
        let rows = (0..<count).map { index in
            let start = epoch.addingTimeInterval(Double(index * 120))
            return programme(formatter.string(from: start), formatter.string(from: start.addingTimeInterval(60)), title: "Show \(index)")
        }.joined()
        try withFeed("<tv>" + rows + "</tv>") { file in
            var limits = EPGImportLimits(); limits.batchCount = 17
            var items: [EpgItem] = []
            _ = try XMLTVStreamingParser.parse(file: file, limits: limits) {
                #expect($0.count <= 17)
                items += $0.map(\.item)
            }
            #expect(items == (0..<count).map { index in
                let start = epoch.addingTimeInterval(Double(index * 120))
                return EpgItem(title: "Show \(index)", start: start, end: start.addingTimeInterval(60))
            })
        }
    }

    @Test func receiverFailureAndWarmCacheCancellationRemainObservable() async throws {
        enum ReceiverError: Error { case stop }
        let row = programme("20261001000000 +0000", "20261001010000 +0000")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xmltv-cancel-\(UUID()).xml")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(("<tv>" + String(repeating: row, count: 1_024) + "</tv>").utf8).write(to: file)
        #expect(throws: ReceiverError.self) {
            _ = try XMLTVStreamingParser.parse(file: file) { _ in throw ReceiverError.stop }
        }
        let work = Task.detached {
            var received = 0
            do {
                _ = try XMLTVStreamingParser.parse(file: file) { batch in
                    received += batch.count
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            } catch is CancellationError { return received }
            return -1
        }
        #expect(try await work.value == 256)
        // A following import starts clean after the cancelled delegate is gone.
        var received = 0
        _ = try XMLTVStreamingParser.parse(file: file) { received += $0.count }
        #expect(received == 1_024)
    }
}
