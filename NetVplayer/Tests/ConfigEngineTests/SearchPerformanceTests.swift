import Foundation
import Testing
import Models
import Storage
import ApplicationCore
@testable import SearchEngine
@testable import NetVplayerApp

@Suite(.serialized)
struct SearchPerformanceTests {
    private let site = Site(key: "same", name: "Source", type: 1, api: "https://source.example.test/api")
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func identity(_ site: Site, config: String = "config-a") -> String {
        SearchPerformanceIdentity.fingerprint(site: site, configuration: config)
    }

    @Test func identitySeparatesConfigurationRequestAndRuntimeButPreservesPresentation() throws {
        let original = identity(site)
        #expect(identity(site, config: "config-b") != original)
        var changed = site; changed.name = "Renamed"; changed.isSelected = true
        #expect(identity(changed) == original)
        for mutation: (inout Site) -> Void in [
            { $0.api += "/other" }, { $0.ext = #"{"token":"private-value"}"# },
            { $0.jar = "new.jar" }, { $0.header = ["Authorization": "secret"] }, { $0.timeout += 1 }
        ] {
            var changed = site; mutation(&changed)
            #expect(identity(changed) != original)
        }
        #expect(SearchPerformanceIdentity.fingerprint(site: site, configuration: "config-a", runtime: "v2") != original)
        #expect(SearchPerformanceIdentity.fingerprint(site: site, configuration: "config-a", quick: true) != original)
        var a = site, b = site
        a.ext = #"{"a":1,"b":2}"#; b.ext = #"{ "b":2, "a":1 }"#
        #expect(identity(a) == identity(b))
    }

    @Test func storeBoundsSamplesSourcesRetentionAndRestoresOnlyEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = StorageManager(storageDirectory: directory)
        let store = SearchPerformanceStore(storage: storage, now: date)
        for index in 0..<40 {
            let at = date.addingTimeInterval(Double(index))
            let attempt = store.beginAttempt(identity: identity(site), now: at)
            store.record(attempt, success: true, durationMs: index == 0 ? 900 : 20, now: at)
        }
        #expect(store.summaries(now: date.addingTimeInterval(40))[identity(site)]?.sampleCount == 32)
        // The first measurement was evicted along with the oldest eight samples.
        #expect(store.summaries(now: date.addingTimeInterval(40))[identity(site)]?.firstDurationMs == nil)
        for index in 0..<520 {
            let at = date.addingTimeInterval(Double(index + 100))
            let attempt = store.beginAttempt(identity: "source-\(index)", now: at)
            store.record(attempt, success: true, durationMs: 10, now: at)
        }
        let now = date.addingTimeInterval(700)
        let summaries = store.summaries(now: now)
        #expect(summaries.count == 512)
        #expect(summaries["source-0"] == nil)
        #expect(summaries["source-519"] != nil)
        store.flushPendingWrites()
        let reopened = SearchPerformanceStore(storage: storage, now: now)
        #expect(reopened.summaries(now: now).count == 512)
        #expect(reopened.beginAttempt(identity: "source-519", now: now).phase == .first)
        #expect(reopened.summaries(now: now.addingTimeInterval(15 * 86_400)).isEmpty)
    }

    @Test func decayApproachesNeutralAndColdAndWarmPredictionsStaySeparate() throws {
        let samples = [SearchPerformanceSample(timestamp: date, phase: .first, success: true, durationMs: 900),
                       .init(timestamp: date, phase: .subsequent, success: true, durationMs: 20)]
        let first = SearchPerformanceSummary(samples: samples, nextPhase: .first, now: date)
        let warm = SearchPerformanceSummary(samples: samples, nextPhase: .subsequent, now: date)
        #expect(first.firstDurationMs == 900)
        #expect(first.subsequentDurationMs == 20)
        #expect(first.schedulingCostMs > warm.schedulingCostMs)
        let oldFailure = [SearchPerformanceSample(timestamp: date, phase: .first, success: false, durationMs: 1_000)]
        let fresh = SearchPerformanceSummary(samples: oldFailure, nextPhase: .first, now: date)
        let aged = SearchPerformanceSummary(samples: oldFailure, nextPhase: .first, now: date.addingTimeInterval(12 * 86_400))
        #expect(fresh.successProbability < aged.successProbability)
        #expect(abs(aged.schedulingCostMs - 4_000) < abs(fresh.schedulingCostMs - 4_000))
    }

    @Test func clearRejectsInflightCompletionAndPersistenceContainsOnlyDigestsAndNumbers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = StorageManager(storageDirectory: directory)
        let store = SearchPerformanceStore(storage: storage)
        var secret = site; secret.header = ["Authorization": "private-credential"]; secret.api += "?token=private-token"
        let attempt = store.beginAttempt(identity: identity(secret))
        store.record(attempt, success: true, durationMs: 10)
        store.flushPendingWrites()
        let payload = try String(contentsOf: directory.appendingPathComponent("search_performance_v1.json"), encoding: .utf8)
        #expect(!payload.contains("private-") && !payload.contains("source.example.test"))
        store.clear()
        store.record(attempt, success: false, durationMs: 1_000)
        store.flushPendingWrites()
        #expect(SearchPerformanceStore(storage: storage).summaries().isEmpty)
    }

    @Test func fallbackCountsOnceCacheReplayDoesNotTrainAndPagesAreExcluded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SearchPerformanceStore(storage: StorageManager(storageDirectory: directory))
        let calls = PerformanceCalls()
        let engine = SearchEngine(performanceStore: store) { _, query, _, page in
            await calls.enter(query + page)
            if query.contains("·") { return .empty }
            return Result(list: [Vod(vodId: page, vodName: "电影第二季")], page: Int(page)!, pagecount: 2)
        }
        for await _ in engine.search(keyword: "电影·第二季", sites: [site], cacheScope: "scope", performanceConfiguration: "config-a") {}
        #expect(await calls.values.count == 2)
        #expect(store.summaries()[identity(site)]?.sampleCount == 1)
        for await result in engine.search(keyword: "电影·第二季", sites: [site], cacheScope: "scope", performanceConfiguration: "config-a") { #expect(result.isCached) }
        for await _ in engine.search(keyword: "电影第二季", sites: [site], page: "2", cacheScope: "scope", performanceConfiguration: "config-a") {}
        #expect(store.summaries()[identity(site)]?.sampleCount == 1)
        for await _ in engine.search(keyword: "电影·第二季", sites: [site], cacheScope: "scope", bypassCache: true, performanceConfiguration: "config-a") {}
        let summary = try #require(store.summaries()[identity(site)])
        #expect(summary.sampleCount == 2)
        #expect(summary.firstDurationMs != nil && summary.subsequentDurationMs != nil)
        #expect(engine.performanceSummaries(sites: [site], configuration: "config-b").isEmpty)
    }

    @Test func emptyPagesAreSuccessAndBothCancellationErrorKindsAreExcluded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SearchPerformanceStore(storage: StorageManager(storageDirectory: directory))
        let engine = SearchEngine(performanceStore: store) { _, query, _, _ in
            if query == "cancel" { throw CancellationError() }
            if query == "urlcancel" || query == "电影第二季" { throw URLError(.cancelled) }
            if query == "failure" { throw URLError(.cannotConnectToHost) }
            return .empty
        }
        for query in ["empty", "cancel", "urlcancel", "电影·第二季", "failure"] {
            for await result in engine.search(keyword: query, sites: [site], performanceConfiguration: "config-a") {
                #expect(result.isCancelled == ["cancel", "urlcancel", "电影·第二季"].contains(query))
            }
        }
        let summary = try #require(store.summaries()[identity(site)])
        #expect(summary.sampleCount == 2)
        #expect(abs(summary.successProbability - 0.5) < 0.001)
    }

    @Test func literalQueryRecordsOneAttemptAndNeverReusesFallbackEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SearchPerformanceStore(storage: StorageManager(storageDirectory: directory))
        let calls = PerformanceCalls()
        let engine = SearchEngine(performanceStore: store) { _, query, _, _ in
            await calls.enter(query)
            return Result(list: [query.contains("·")
                ? Vod(vodId: "original", vodName: "Unrelated original result")
                : Vod(vodId: "fallback", vodName: query)])
        }
        for await _ in engine.search(keyword: "电影·第二季", sites: [site], cacheScope: "scope", performanceConfiguration: "config-a") {}
        for await result in engine.search(keyword: "电影·第二季", sites: [site], cacheScope: "scope", allowsQueryFallback: false, performanceConfiguration: "config-a") {
            #expect(!result.isCached && result.vods.map(\.vodId) == ["original"])
        }
        #expect(await calls.values == ["电影·第二季", "电影第二季", "电影·第二季"])
        #expect(store.summaries()[identity(site)]?.sampleCount == 2)
        for await result in engine.search(keyword: "电影·第二季", sites: [site], cacheScope: "scope", allowsQueryFallback: false, performanceConfiguration: "config-a") {
            #expect(result.isCached && result.vods.map(\.vodId) == ["original"])
        }
        #expect(store.summaries()[identity(site)]?.sampleCount == 2)
        let scoped = SearchSitePlanner.orderedSearchSites(sites: [site], activeSiteKey: site.key,
            selectedKeys: ["missing"], performanceSummaries: engine.performanceSummaries(sites: [site], configuration: "config-a"),
            healthSortingEnabled: true, allowsSelectionFallback: false)
        #expect(scoped.isEmpty)
    }

    @Test func cancellationBeforeAdmissionOrAfterProviderStartsDoesNotRecordOrAdmitQueuedSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SearchPerformanceStore(storage: StorageManager(storageDirectory: directory))
        let gate = PerformanceGate()
        let engine = SearchEngine(maxConcurrentSites: 1, performanceStore: store) { source, _, _, _ in
            await gate.wait(source.key) // Deliberately ignores cancellation until released.
            return .empty
        }
        let first = Task { for await _ in engine.search(keyword: "first", sites: [site]) {} }
        try await waitUntil { await gate.values.count == 1 }
        let queuedSite = Site(key: "queued", type: 1)
        let queued = Task { for await _ in engine.search(keyword: "queued", sites: [queuedSite]) {} }
        try await Task.sleep(for: .milliseconds(30))
        let start = ContinuousClock.now
        queued.cancel(); first.cancel()
        await queued.value; await first.value
        let cancelledMs = milliseconds(start.duration(to: .now))
        #expect(cancelledMs < 250)
        #expect(await gate.values == [site.key])
        #expect(store.summaries().isEmpty)
        await gate.release()
        try await Task.sleep(for: .milliseconds(40))
        #expect(store.summaries().isEmpty)
        // The queued source was never admitted and remains process-first.
        #expect(store.beginAttempt(identity: SearchPerformanceIdentity.fingerprint(site: queuedSite, configuration: "")).phase == .first)
        print("OV91_06_CANCEL elapsedMs=\(cancelledMs) providerAdmissions=1 queuedAdmissions=0 lateSamples=0")
    }

    @Test func timeoutRecordsOneFailureAndLateProviderCompletionCannotRecordSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SearchPerformanceStore(storage: StorageManager(storageDirectory: directory))
        let gate = PerformanceGate()
        let engine = SearchEngine(performanceStore: store) { source, _, _, _ in
            await gate.wait(source.key)
            return Result(list: [Vod(vodId: "late")])
        }
        var source = site; source.timeout = 1
        for await result in engine.search(keyword: "timeout", sites: [source], performanceConfiguration: "config-a") {
            #expect(result.error != nil && !result.isCancelled)
        }
        #expect(store.summaries()[identity(source)]?.sampleCount == 1)
        #expect(store.summaries()[identity(source)]?.successProbability ?? 1 < 0.5)
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.summaries()[identity(source)]?.sampleCount == 1)
    }

    @MainActor
    @Test func ownedSearchCountsOnceAndPreferenceClearAndScopeStayConnectedToEngine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "search-performance-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = StorageManager(storageDirectory: directory)
        let store = SearchPerformanceStore(storage: storage)
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, storageManager: storage,
            userPreferences: preferences, providerRuntimeBootstrap: nil)
        defer { state.resetSearchState() }
        let calls = PerformanceCalls()
        state.sites = [site]
        state.searchEngine = SearchEngine(performanceStore: store) { source, query, _, page in
            await calls.enter(source.key)
            try await Task.sleep(for: .milliseconds(40))
            return Result(list: [Vod(vodId: page, vodName: query)], page: Int(page)!, pagecount: 2)
        }
        let first = Task { await state.search(keyword: "Film") }
        try await waitUntil { await calls.values.count == 1 }
        first.cancel()
        await state.search(keyword: "Film")
        await first.value
        #expect(await calls.values.count == 1)
        #expect(store.summaries().values.first?.sampleCount == 1)
        await state.search(keyword: "Film")
        #expect(store.summaries().values.first?.sampleCount == 1)
        state.clearSiteHealthRecords()
        #expect(store.summaries().isEmpty)
    }

    @Test func plannerPreservesUserScopeRankToggleAndAllSlowSources() {
        let sources = [Site(key: "active", type: 1), Site(key: "slow", type: 1), Site(key: "fast", type: 1),
                       Site(key: "unsupported", type: 3, api: "csp_Unsupported"),
                       Site(key: "replacement", type: 3, api: "csp_Replacement")]
        let summaries = ["active": summary(800), "slow": summary(500), "fast": summary(10)]
        let sorted = SearchSitePlanner.orderedSearchSites(sites: sources, activeSiteKey: "active", selectedKeys: [],
            replacementSiteKeys: ["replacement"], performanceSummaries: summaries, healthSortingEnabled: true)
        #expect(sorted.map(\.key) == ["active", "replacement", "fast", "slow"])
        let disabled = SearchSitePlanner.orderedSearchSites(sites: sources, activeSiteKey: "active", selectedKeys: [],
            replacementSiteKeys: ["replacement"], performanceSummaries: summaries, healthSortingEnabled: false)
        #expect(disabled.map(\.key) == ["active", "replacement", "slow", "fast"])
        let scoped = SearchSitePlanner.orderedSearchSites(sites: sources, activeSiteKey: "active", selectedKeys: ["slow"],
            performanceSummaries: summaries, healthSortingEnabled: true)
        #expect(scoped.map(\.key) == ["slow"])
    }

    @Test func equivalentEvidenceKeepsStableConfigurationOrderDespiteTimestampNoise() {
        let first = SearchPerformanceSample(timestamp: date, phase: .first, success: true, durationMs: 50)
        let later = SearchPerformanceSample(timestamp: date.addingTimeInterval(0.001), phase: .first, success: true, durationMs: 50)
        let now = date.addingTimeInterval(1)
        let sources = [Site(key: "a", type: 1), Site(key: "b", type: 1)]
        let evidence = ["a": SearchPerformanceSummary(samples: [first], nextPhase: .first, now: now),
                        "b": SearchPerformanceSummary(samples: [later], nextPhase: .first, now: now)]
        let planned = SearchSitePlanner.orderedSearchSites(sites: sources, activeSiteKey: nil, selectedKeys: [],
            performanceSummaries: evidence, healthSortingEnabled: true)
        #expect(planned.map(\.key) == ["a", "b"])
    }

    @MainActor
    @Test func sameSampleComparesUsefulAdmissionAndFullSourceCoverageWithSixSlots() async throws {
        let sources = (0..<12).map { Site(key: "s\($0)", type: 1) }
        let evidence = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.key, summary($0.offset < 6 ? 120 : 15)) })
        for sorted in [false, true] {
            let calls = PerformanceCalls()
            let engine = SearchEngine { source, query, _, _ in
                let slow = Int(source.key.dropFirst())! < 6
                await calls.enter(source.key)
                try await Task.sleep(for: .milliseconds(slow ? 120 : 15))
                await calls.leave()
                return Result(list: slow ? [] : (0..<12).map { Vod(vodId: "\($0)", vodName: query) })
            }
            let planned = SearchSitePlanner.orderedSearchSites(sites: sources, activeSiteKey: nil, selectedKeys: [],
                performanceSummaries: evidence, healthSortingEnabled: sorted)
            let start = ContinuousClock.now
            var state = ContentSearchCore.begin(.init(), keyword: "Film", siteOrder: planned.map(\.key))
            var useful: Double?, twelve: Double?
            let publisher = SearchSnapshotPublisher { snapshot in
                let count = snapshot.results.reduce(0) { $0 + $1.vods.count }
                if count > 0 && useful == nil { useful = milliseconds(start.duration(to: .now)) }
                if count >= 12 && twelve == nil { twelve = milliseconds(start.duration(to: .now)) }
            }
            for await result in engine.search(keyword: "Film", sites: planned) {
                state = ContentSearchCore.ingest(state, generation: state.generation, result: result)
                publisher.submit(state)
            }
            publisher.flush()
            #expect(Set(await calls.values).count == 12)
            #expect(await calls.peak <= 6)
            #expect(state.results.reduce(0) { $0 + $1.vods.count } == 60)
            print("OV91_06_SAMPLE sorted=\(sorted) firstUsefulMs=\(useful ?? -1) first12AdmittedMs=\(twelve ?? -1) allSourcesMs=\(milliseconds(start.duration(to: .now))) coverage=12/12 peak=\(await calls.peak)")
        }
    }

    @MainActor
    @Test func injectedPreferenceScopeAndToggleUseSearchEvidenceInsteadOfMixedHealth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "search-performance-preference-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserPreferences(defaults: defaults, credentialStore: MemoryCredentialStore())
        preferences.defaultSearchSiteKeys = ["a", "b"]
        let storage = StorageManager(storageDirectory: directory)
        let store = SearchPerformanceStore(storage: storage)
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, storageManager: storage,
            userPreferences: preferences, providerRuntimeBootstrap: nil)
        defer { state.resetSearchState() }
        #expect(state.selectedSearchSiteKeys == ["a", "b"])
        state.sites = ["a", "b", "excluded"].map { Site(key: $0, type: 1) }
        state.siteHealthSummaries = ["a": .init(siteKey: "a", score: 1), "b": .init(siteKey: "b", score: 0)]
        for source in state.sites {
            let key = SearchPerformanceIdentity.fingerprint(site: source, configuration: state.libraryConfigurationURL)
            for _ in 0..<8 { store.record(store.beginAttempt(identity: key), success: true, durationMs: source.key == "b" ? 10 : 900) }
        }
        state.searchEngine = SearchEngine(performanceStore: store) { _, _, _, _ in .empty }
        await state.search(keyword: "Film")
        #expect(state.contentSearchState.siteOrder == ["b", "a"])
        preferences.siteHealthSortingEnabled = false
        await state.search(keyword: "Other")
        #expect(state.contentSearchState.siteOrder == ["a", "b"])
        #expect(state.searchResults.allSatisfy { $0.siteKey != "excluded" })
    }

    private func summary(_ ms: Double) -> SearchPerformanceSummary {
        SearchPerformanceSummary(samples: (0..<8).map { _ in .init(timestamp: date, phase: .first, success: true, durationMs: ms) }, nextPhase: .first, now: date)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), .now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(await predicate())
    }
}

private actor PerformanceCalls {
    private(set) var values: [String] = []
    private var active = 0
    private(set) var peak = 0
    func enter(_ value: String) { values.append(value); active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

private actor PerformanceGate {
    private(set) var values: [String] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    func wait(_ value: String) async {
        values.append(value)
        await withCheckedContinuation { pending.append($0) }
    }
    func release() { let callbacks = pending; pending = []; callbacks.forEach { $0.resume() } }
}
