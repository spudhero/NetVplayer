import Foundation
import Testing
import Models
import Networking
import Storage
@testable import LiveEngine
@testable import NetVplayerApp

@Suite("Bounded historical EPG", .serialized)
struct EPGHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_792_360_800)
    private func item(_ title: String, _ start: Double, _ end: Double) -> EpgItem {
        .init(title: title, start: now.addingTimeInterval(start), end: now.addingTimeInterval(end))
    }
    private func feed(_ items: [EpgItem], channel: Bool = true) -> Data {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss Z"
        return Data(("<tv>" + (channel ? "<channel id='one'><display-name>One</display-name></channel>" : "") + items.map {
            "<programme channel='one' start='\(formatter.string(from: $0.start))' stop='\(formatter.string(from: $0.end))'><title>\($0.title)</title></programme>"
        }.joined() + "</tv>").utf8)
    }
    private func client() -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [EPGFixtureProtocol.self]
        return HTTPClient(session: URLSession(configuration: config))
    }

    @Test func overlapCorrectionsRetainOnlyPastWithinSevenDaysWithoutClipping() {
        let past = item("retained", -172_800, -169_200), old = item("incorrect", -7_200, -3_600)
        let correction = item("corrected", -7_140, -3_540)
        let result = EPGHistoryMerge.items(old: [past, old, item("expired", -9 * 86_400, -8 * 86_400), item("future", 10, 20)], new: [correction], now: now)
        #expect(result == [past, correction])
        #expect(!result.contains { $0.title == "incorrect" })
        #expect(EPGHistoryMerge.items(old: [old], new: [item("touching", -3_600, -1_800)], now: now).count == 2)
    }

    @Test func repositoryMergesAtomicallyAndRemovalCannotResurrectHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("epg-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = XMLTVRepository(directory: directory, client: client())
        let url = "https://epg.invalid/\(UUID()).json" // XML recognition is independent of extension.
        let history = item("history", -4 * 86_400, -4 * 86_400 + 3_600)
        let old = item("old", -7_200, -3_600), correction = item("new", -7_100, -3_500)
        let window = DateInterval(start: now.addingTimeInterval(-86_400), duration: 86_400)
        func query(_ scope: String = "one") async -> EpgLoadResult {
            await repository.programmes(url: url, channelID: "one", channelName: "One", window: window, forceRefresh: true, now: now, scope: scope)
        }
        EPGFixtureProtocol.set(url, data: feed([history, old]))
        #expect(await query().data.items == [old])
        EPGFixtureProtocol.set(url, data: feed([correction]))
        #expect(await query().data.items == [correction])
        let earlier = await repository.programmes(url: url, channelID: "one", channelName: "One",
            window: DateInterval(start: history.start, duration: 3_600), now: now, scope: "one")
        #expect(earlier.data.items == [history])
        EPGFixtureProtocol.set(url, data: Data("<broken".utf8))
        let stale = await query()
        #expect(stale.availability == .stale && stale.data.items == [correction])
        #expect(await query("changed-source").availability == .unavailable)
        EPGFixtureProtocol.set(url, data: feed([], channel: false))
        #expect(await query().data.items.isEmpty)
        EPGFixtureProtocol.set(url, data: feed([item("return", -600, -300)]))
        #expect(await query().data.items.map(\.title) == ["return"])
        let removedHistory = await repository.programmes(url: url, channelID: "one", channelName: "One",
            window: DateInterval(start: history.start, duration: 3_600), now: now, scope: "one")
        #expect(removedHistory.data.items.isEmpty)
    }

    @Test func mergedCapacityEvictsOldestHistoryBeforeFreshData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("epg-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = EPGImportLimits(); limits.programmeCount = 2
        let repo = XMLTVRepository(directory: directory, client: client(), limits: limits)
        let url = "https://epg.invalid/\(UUID())"
        let old = [item("a", -9_000, -8_000), item("b", -7_000, -6_000)]
        EPGFixtureProtocol.set(url, data: feed(old))
        let window = DateInterval(start: now.addingTimeInterval(-10_000), duration: 10_000)
        let first = await repo.programmes(url: url, channelID: "one", channelName: "One", window: window, now: now)
        #expect(first.data.items == old)
        EPGFixtureProtocol.set(url, data: feed([item("c", -5_000, -4_000)]))
        let result = await repo.programmes(url: url, channelID: "one", channelName: "One", window: window, forceRefresh: true, now: now)
        #expect(result.availability == .available && result.data.items.map(\.title) == ["b", "c"])
        let source = directory.appendingPathComponent(XMLTVIndex.digest(url))
        let generations = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { UUID(uuidString: $0) != nil }
        #expect(generations.count == 1)
    }

    @Test func tvboxPreservesCrossMidnightAnd24HourBoundaryInExplicitZone() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let request = TVBoxEPGRequest(date: "2026-10-19", timeZone: zone, channelID: "one", channelName: "One")
        let data = Data(#"{"date":"2026-10-19","epg_data":[{"title":"跨午夜","start":"23:45:30","end":"00:15:45"},{"title":"边界","start":"22:00","end":"24:00"}]}"#.utf8)
        let result = try TVBoxEPGParser.parse(data: data, request: request)
        let iso = ISO8601DateFormatter()
        #expect(result.items[0].start == iso.date(from: "2026-10-19T14:00:00Z"))
        #expect(result.items[0].end == iso.date(from: "2026-10-19T16:00:00Z"))
        #expect(result.items[1].start == iso.date(from: "2026-10-19T15:45:30Z"))
        #expect(result.items[1].end == iso.date(from: "2026-10-19T16:15:45Z"))
        let window = DateInterval(start: try #require(iso.date(from: "2026-10-19T15:00:00Z")), duration: 7_200)
        #expect(try TVBoxEPGRequest.dates(window: window, timeZone: zone) == ["2026-10-18", "2026-10-19", "2026-10-20"])
        #expect(throws: EPGImportError.self) { try TVBoxEPGRequest.dates(window: DateInterval(start: now, duration: 86_401), timeZone: zone) }
    }

    @Test(arguments: ["24:01", "24:00:01", "25:00", "12:60", "1:00", "12:00:60", "bogus"])
    func rejectsInvalidClocks(_ end: String) throws {
        let request = TVBoxEPGRequest(date: "2026-10-19", timeZone: TimeZone(secondsFromGMT: 0)!, channelID: "one", channelName: "One")
        let data = try JSONSerialization.data(withJSONObject: ["date": request.date, "epg_data": [["title": "x", "start": "01:00", "end": end]]])
        #expect(throws: EPGImportError.self) { try TVBoxEPGParser.parse(data: data, request: request) }
    }

    @Test func rejectsDateMismatchMissingFieldsAndAmbiguousLocalTimes() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        for (date, start, end) in [("2026-03-08", "02:30", "03:30"), ("2026-11-01", "01:30", "02:30")] {
            let request = TVBoxEPGRequest(date: date, timeZone: zone, channelID: "one", channelName: "One")
            let data = try JSONSerialization.data(withJSONObject: ["date": date, "epg_data": [["title": "x", "start": start, "end": end]]])
            #expect(throws: EPGImportError.self) { try TVBoxEPGParser.parse(data: data, request: request) }
        }
        let request = TVBoxEPGRequest(date: "2026-10-19", timeZone: zone, channelID: "one", channelName: "One")
        for text in [#"{"date":"2026-10-18","epg_data":[]}"#, #"{"date":"2026-10-19","epg_data":[{}]}"#, "<tv/>", "{}"] {
            #expect(throws: EPGImportError.self) { try TVBoxEPGParser.parse(data: Data(text.utf8), request: request) }
        }
        #expect(try TVBoxEPGParser.parse(data: Data(#"{"date":"2026-10-19","epg_data":[]}"#.utf8), request: request).items.isEmpty)
        #expect(throws: EPGImportError.self) { try TVBoxEPGParser.parse(data: Data(repeating: 32, count: TVBoxEPGParser.maximumBytes + 1), request: request) }
    }

    @Test func inheritedEPGValuesAreEncodedExactlyOnceAndPlainXMLTVInherits() {
        let channel = Channel(name: "Name & 日期", epg: "标记&a=1", tvgId: "id/?&={date}")
        let inherited = channel.applying(live: Live(epg: "https://guide.invalid/?id={id}&name={name}&epg={epg}&date={date}"))
        #expect(inherited.epg.contains("id=id%2F%3F%26%3D%7Bdate%7D"))
        #expect(inherited.epg.contains("%26a%3D1") && inherited.epg.hasSuffix("date={date}"))
        #expect(inherited.applying(live: Live(epg: "https://guide.invalid/?id={id}")).epg == inherited.epg)
        #expect(Channel(name: "One").applying(live: Live(epg: "https://guide.invalid/feed.xml")).epg == "https://guide.invalid/feed.xml")
    }

    @Test func dateLoaderUsesSourceDatesBoundsRequestsAndPreservesOtherDatesOnFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("epg-dates-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = XMLTVRepository(directory: directory, client: client())
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let today = calendar.startOfDay(for: Date())
        let window = DateInterval(start: today.addingTimeInterval(-3_600), duration: 7_200)
        let dates = try TVBoxEPGRequest.dates(window: window, timeZone: zone)
        let root = "https://epg.invalid/\(UUID()).xml?date=" // JSON despite .xml.
        let channel = Channel(name: "One", epg: root + "{date}", tvgId: "one")
        let loader = LiveEPGLoader(accounts: [], sourceTimeZone: zone.identifier, scope: "fixture", repository: repo)
        func fixture(_ date: String, title: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["date": date, "epg_data": [["title": title, "start": "00:00", "end": "24:00"]]])
        }
        for date in dates { EPGFixtureProtocol.set(root + date, data: try fixture(date, title: date)) }
        let first = await loader.load(channel: channel, window: window, forceRefresh: false)
        #expect(first.availability == .available && first.data.items.count == 2)
        #expect(dates.count == 3 && dates.allSatisfy { EPGFixtureProtocol.count(root + $0) == 1 })
        #expect(first.data.items[0].end == today && first.data.items[0].start == calendar.date(byAdding: .day, value: -1, to: today))
        EPGFixtureProtocol.set(root + dates.last!, data: Data("{}".utf8))
        let partial = await loader.load(channel: channel, window: window, forceRefresh: true)
        #expect(partial.availability == .stale && partial.data.items == first.data.items)
        EPGFixtureProtocol.set(root + dates.last!, data: Data("{\"date\":\"\(dates.last!)\",\"epg_data\":[]}".utf8))
        let empty = await loader.load(channel: channel, window: window, forceRefresh: true)
        #expect(empty.availability == .available && empty.data.items.count == 1)
        var missingZone = loader; missingZone.sourceTimeZone = ""
        let unavailable = await missingZone.load(channel: channel, window: window, forceRefresh: true)
        #expect(unavailable.availability == .unavailable && unavailable.message?.contains("timeZone") == true)
        #expect(EPGFixtureProtocol.count(root + dates.last!) == 1, "Missing zone must not issue requests")
    }

    @Test func xmlOffsetAndCrossMidnightSurviveRepositoryMerge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("epg-zone-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = XMLTVRepository(directory: directory, client: client())
        let url = "https://epg.invalid/\(UUID())"
        EPGFixtureProtocol.set(url, data: Data("<tv><programme channel='one' start='20261018233000 +0800' stop='20261019003000 +0800'><title>Midnight</title></programme></tv>".utf8))
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-18T15:30:00Z"))
        let result = await repo.programmes(url: url, channelID: "one", channelName: "One",
            window: DateInterval(start: start.addingTimeInterval(1_800), duration: 3_600), now: start.addingTimeInterval(86_400))
        #expect(result.data.items == [EpgItem(title: "Midnight", start: start, end: start.addingTimeInterval(3_600))])
    }

    @Test @MainActor func sourceRefreshRemovalAndReadditionUseNewCacheScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("epg-scope-\(UUID())")
        let suite = "epg-scope-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            storageManager: StorageManager(storageDirectory: directory), userPreferences: UserPreferences(defaults: defaults))
        let channel = Channel(name: "One", tvgId: "one", urls: ["https://epg.invalid/live"])
        let live = Live(name: "One", url: "https://epg.invalid/list", timeZone: "UTC")
        await state.changeLive(live, initialGroups: [.init(name: "Group", channels: [channel])])
        let first = state.makeLiveEpgLoader(), firstRevision = state.liveSourceRevision
        state.channelGroups = []
        let removed = state.makeLiveEpgLoader()
        #expect(removed.scope != first.scope)
        #expect(await removed.load(channel: channel, window: DateInterval(start: now, duration: 3_600), forceRefresh: false).availability == .unavailable)
        state.channelGroups = [.init(name: "Group", channels: [channel])]
        #expect(state.makeLiveEpgLoader().scope != first.scope)
        await state.changeLive(live, initialGroups: state.channelGroups)
        #expect(state.liveSourceRevision != firstRevision && state.makeLiveEpgLoader().scope != first.scope)
    }
}
