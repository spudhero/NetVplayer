import Foundation
import Testing
import Models
@testable import MediaLibraryEngine

@Suite("BMH-02 bounded TMDB aliases", .serialized, .timeLimit(.minutes(2)))
struct TMDBAliasConcurrencyTests {
    @Test func twentyCandidatesUseBoundedConcurrencyAndWaitForLateAmbiguity() async throws {
        let fixture = AliasHTTPFixture(mode: .lateDuplicate)
        let provider = make(fixture)
        let candidates = try await provider.search(title: "Alias Movie", year: 2020, kind: .movies)
        #expect(candidates.count == 20)
        #expect(await fixture.peak == 4)
        #expect(await fixture.aliasCalls == 20)
        #expect(await fixture.active == 0)
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "Alias Movie", year: 2020, kind: .movies) == nil)
        #expect(candidates.filter { $0.metadata.alternativeTitles?.contains("Alias Movie") == true }.count == 2)
    }
    @Test(arguments: [AliasHTTPFixture.Mode.invalid, .limited, .timeout])
    fileprivate func incompleteCoverageNeverExportsPartialAliasMatches(mode: AliasHTTPFixture.Mode) async throws {
        let fixture = AliasHTTPFixture(mode: mode)
        let provider = make(fixture, policy: .init(requestTimeout: .milliseconds(50), retryBudget: 0))
        let candidates = try await provider.search(title: "Alias Movie", year: 2020, kind: .movies)
        #expect(candidates.count == 20 && candidates.allSatisfy { $0.metadata.alternativeTitles == nil })
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "Alias Movie", year: 2020, kind: .movies) == nil)
        #expect(await fixture.active == 0)
        #expect(await fixture.attempts[19] == 1)
    }
    @Test func transientRetryAndWholeSearchRetryBudgetAreFinite() async throws {
        let recovered = AliasHTTPFixture(mode: .transient)
        let candidates = try await make(recovered, policy: .init(retryDelay: .zero)).search(title: "Alias Movie", year: 2020, kind: .movies)
        #expect(await recovered.aliasCalls == 21); #expect(await recovered.attempts[7] == 2)
        #expect(MetadataMatcher.uniqueMatch(candidates: candidates, title: "Alias Movie", year: 2020, kind: .movies)?.metadata.tmdbID == "7")
        let failed = AliasHTTPFixture(mode: .allFail)
        let unconfirmed = try await make(failed, policy: .init(retryBudget: 2, retryDelay: .zero)).search(title: "Alias Movie", year: 2020, kind: .movies)
        let attempts = await failed.attempts
        #expect(attempts.values.allSatisfy { $0 <= 2 })
        #expect(attempts.values.reduce(0) { $0 + max(0, $1 - 1) } <= 2)
        #expect(unconfirmed.allSatisfy { $0.metadata.alternativeTitles == nil })
    }
    @Test func aggregateDeadlineAndCancellationReleaseAllGlobalPermits() async throws {
        let slow = AliasHTTPFixture(mode: .slow)
        let start = ContinuousClock.now
        let suggestions = try await make(slow, policy: .init(requestTimeout: .seconds(2), totalTimeout: .milliseconds(60)))
            .search(title: "Alias Movie", year: 2020, kind: .movies)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(suggestions.allSatisfy { $0.metadata.alternativeTitles == nil })
        #expect(await slow.active == 0)
        let cancelled = AliasHTTPFixture(mode: .slow)
        let request = Task { try await make(cancelled).search(title: "Alias Movie", year: 2020, kind: .movies) }
        try await waitForActive(cancelled)
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await cancelled.active == 0)
        let normal = AliasHTTPFixture(mode: .normal)
        _ = try await make(normal).search(title: "Alias Movie", year: 2020, kind: .movies)
        #expect(await normal.peak == 4); #expect(await normal.aliasCalls == 20)
    }
    @Test func globalLimitHoldsAcrossTwoProvidersAndDuplicateIDsAreFetchedOnce() async throws {
        let shared = AliasHTTPFixture(mode: .normal)
        async let first = make(shared).search(title: "Alias Movie", year: 2020, kind: .movies)
        async let second = make(shared).search(title: "Alias Movie", year: 2020, kind: .movies)
        _ = try await (first, second)
        #expect(await shared.peak == 4); #expect(await shared.aliasCalls == 40)
        let duplicate = AliasHTTPFixture(mode: .duplicateID)
        _ = try await make(duplicate).search(title: "Alias Movie", year: 2020, kind: .movies)
        #expect(await duplicate.aliasCalls == 19); #expect(await duplicate.attempts[7] == 1)
    }
    @Test func controlledSerialAndConcurrentHTTPComparison() async throws {
        var rows: [[String: Any]] = []
        for concurrency in [1, 4] {
            let fixture = AliasHTTPFixture(mode: .normal)
            let provider = make(fixture, policy: .init(concurrency: concurrency))
            let start = ContinuousClock.now
            let candidates = try await provider.search(title: "Alias Movie", year: 2020, kind: .movies)
            let selected = try #require(MetadataMatcher.uniqueMatch(candidates: candidates, title: "Alias Movie", year: 2020, kind: .movies))
            _ = try await provider.details(id: #require(selected.metadata.tmdbID), kind: .movies)
            let duration = start.duration(to: .now).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            #expect(await fixture.totalCalls == 22); #expect(await fixture.peak == concurrency)
            rows.append(["concurrency": concurrency, "httpRequests": await fixture.totalCalls, "aliasPeak": await fixture.peak, "seconds": seconds])
        }
        if let path = ProcessInfo.processInfo.environment["NETVPLAYER_BMH02_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("alias-concurrency.json"))
        }
    }
    private func make(_ fixture: AliasHTTPFixture, policy: TMDBAliasPolicy = .init()) -> TMDBMetadataProvider {
        .init(credential: .init(kind: .apiKey, value: "fixture-only"), request: { url, _ in try await fixture.request(url) }, aliasPolicy: policy)
    }
    private func waitForActive(_ fixture: AliasHTTPFixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await fixture.active == 0 {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
private actor AliasHTTPFixture {
    enum Mode: Sendable { case normal, lateDuplicate, invalid, limited, timeout, transient, allFail, slow, duplicateID }
    let mode: Mode
    private(set) var attempts: [Int: Int] = [:]
    private(set) var aliasCalls = 0, totalCalls = 0, active = 0, peak = 0
    init(mode: Mode) { self.mode = mode }
    func request(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        totalCalls += 1
        if url.path.contains("/search/") {
            try await Task.sleep(for: .milliseconds(10))
            let rows = (1...20).map { i -> [String: Any] in
                let id = mode == .duplicateID && i == 20 ? 7 : i
                return ["id": id, "title": "Primary \(id)", "release_date": "2020-01-01"]
            }
            return try response(url, body: ["results": rows])
        }
        guard url.path.hasSuffix("/alternative_titles") else {
            try await Task.sleep(for: .milliseconds(10))
            return try response(url, body: ["id": 7, "title": "Primary 7", "release_date": "2020-01-01"])
        }
        let id = Int(url.deletingLastPathComponent().lastPathComponent)!
        aliasCalls += 1; attempts[id, default: 0] += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        let delay: Duration = mode == .slow || (mode == .timeout && id == 19) ? .seconds(2)
            : mode == .lateDuplicate && id == 19 ? .milliseconds(60) : .milliseconds(10)
        try await Task.sleep(for: delay)
        if mode == .allFail || (mode == .transient && id == 7 && attempts[id] == 1) { return try response(url, status: 503, body: [:]) }
        if mode == .limited && id == 19 { return try response(url, status: 429, body: [:]) }
        if mode == .invalid && id == 19 { return try response(url, body: [:]) }
        let title = id == 7 || (mode == .lateDuplicate && id == 19) ? "Alias Movie" : "Other \(id)"
        return try response(url, body: ["titles": [["title": title]]])
    }
    private func response(_ url: URL, status: Int = 200, body: [String: Any]) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
