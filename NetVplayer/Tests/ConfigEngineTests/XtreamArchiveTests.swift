import Foundation
import Testing
import Models
import Networking
import Storage
@testable import LiveEngine
@testable import SpiderEngine
@testable import NetVplayerApp
@testable import PlayerEngine

private final class ArchiveFixture: @unchecked Sendable {
    struct State {
        var credentials: XtreamCredentials? = .init(username: "fixture-user", password: "fictional-secret")
        var zone: String? = "Asia/Kathmandu"
        var enabled = true, days = 7, hasArchive = true, failHistory = false, empty = false
        var historyOverride: String?
        var delay: TimeInterval = 0
        var authDelay: TimeInterval = 0
        var actions: [String] = []
    }
    let lock = NSLock()
    private var state = State()
    let configuration: XtreamConfiguration
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60 - 3_600 + 37)
    let session: URLSession
    lazy var provider = try! XtreamSiteProvider(configuration: configuration,
        client: HTTPClient(session: session), credentials: { [self] in
            guard let result = read({ $0.credentials }) else { throw XtreamError.authorizationRequired }
            return result
        })
    init() throws {
        configuration = try .init(name: "Archive", server: "https://archive-\(UUID().uuidString.lowercased()).invalid/base")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArchiveProtocol.self]
        session = URLSession(configuration: config)
        ArchiveProtocol.install(host: URL(string: configuration.server)!.host!) { [weak self] request in self?.response(request) ?? ("{}", 0) }
    }
    func close() { session.invalidateAndCancel(); ArchiveProtocol.remove(host: URL(string: configuration.server)!.host!) }
    func mutate(_ body: (inout State) -> Void) { lock.lock(); defer { lock.unlock() }; body(&state) }
    func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(state) }
    var window: DateInterval { .init(start: start.addingTimeInterval(-60), duration: 3_600) }
    func channel() async throws -> Channel { try #require(try await provider.liveGroups().first?.channels.first) }
    func history(_ channel: Channel, scope: String = "test", force: Bool = false) async -> EpgLoadResult {
        await provider.guideEpg(channel: channel, window: window, scope: scope, forceRefresh: force)
    }
    private func response(_ request: URLRequest) -> (String, TimeInterval) {
        if request.url?.path.hasSuffix("player_api.php") != true {
            return ("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n", 0)
        }
        let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value ?? "auth"
        mutate { $0.actions.append(action) }
        let value = read { $0 }, epoch = Int(start.timeIntervalSince1970)
        switch action {
        case "auth":
            let zone = value.zone.map { ",\"server_info\":{\"timezone\":\"\($0)\"}" } ?? ""
            return ("{\"user_info\":{\"auth\":1,\"status\":\"Active\"}\(zone)}", value.authDelay)
        case "get_live_categories": return ("[{\"category_id\":\"1\",\"category_name\":\"Fixture\"}]", 0)
        case "get_live_streams": return ("[{\"stream_id\":41,\"name\":\"Fixture\",\"category_id\":\"1\",\"tv_archive\":\(value.enabled ? 1 : 0),\"tv_archive_duration\":\"\(value.days)\"}]", 0)
        case "get_simple_data_table":
            if let override = value.historyOverride { return (override, value.delay) }
            if value.failHistory { return ("{\"error\":\"unavailable\"}", value.delay) }
            if value.empty { return ("{\"epg_listings\":[]}", value.delay) }
            return ("{\"epg_listings\":[{\"title\":\"Archive programme\",\"start_timestamp\":\(epoch),\"stop_timestamp\":\(epoch + 1_500),\"has_archive\":\(value.hasArchive ? 1 : 0)}]}", value.delay)
        case "get_short_epg": return ("{\"epg_listings\":[{\"title\":\"Short only\",\"start_timestamp\":\(epoch),\"stop_timestamp\":\(epoch + 600),\"has_archive\":1}]}", 0)
        default: return ("{}", 0)
        }
    }
}

private final class ArchiveProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (String, TimeInterval)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private let deliveryLock = NSLock()
    private var stopped = false
    static func install(host: String, handler: @escaping Handler) { lock.lock(); defer { lock.unlock() }; handlers[host] = handler }
    static func remove(host: String) { lock.lock(); defer { lock.unlock() }; handlers[host] = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handlers[request.url!.host!]; Self.lock.unlock()
        let (body, delay) = handler?(request) ?? ("{}", 0)
        let work = DispatchWorkItem { [self] in
            deliveryLock.lock(); defer { deliveryLock.unlock() }
            guard !stopped else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }
    override func stopLoading() { deliveryLock.lock(); stopped = true; deliveryLock.unlock() }
}

@Suite(.serialized)
struct XtreamArchiveTests {
    @Test func serverCapabilitiesAndHistoricalProofControlReplay() async throws {
        let f = try ArchiveFixture(); defer { f.close() }
        let channel = try await f.channel(), result = await f.history(channel)
        let item = try #require(result.data.items.first)
        #expect(channel.xtreamArchive?.days == 7 && channel.xtreamArchive?.enabled == true)
        #expect(result.coverage == .xtreamHistory && item.xtreamArchive?.hasArchive == true)
        #expect(LiveCatchupPolicy.availability(channel: channel, programme: item, timeZone: nil).isAvailable)
        f.mutate { $0.hasArchive = false }
        let unavailable = await f.history(channel, force: true)
        #expect(XtreamArchivePolicy.availability(channel: channel, programme: unavailable.data.items.first) == .unavailable(.noArchive))
        f.mutate { $0.enabled = false }
        #expect(try await f.channel().xtreamArchive?.enabled == true, "Catalogue remains bounded by its TTL until refresh")
        await f.provider.clearContentCache()
        let disabled = try await f.channel()
        #expect(XtreamArchivePolicy.availability(channel: disabled, programme: item) == .unavailable(.noArchive))
    }

    @Test func minuteRouteUsesServerZoneAndCompensatesSecondsWithoutChangingProgramme() async throws {
        let f = try ArchiveFixture(); defer { f.close() }
        let channel = try await f.channel(), result = await f.history(channel)
        let item = try #require(result.data.items.first)
        let request = try await f.provider.archiveRequest(channel: channel, programme: item, scope: "test", offset: 70)
        #expect(request.mediaStartOffset == 23 && request.initialPosition == 47)
        let start = item.start.addingTimeInterval(23)
        let route = XtreamArchivePolicy.routeStart(start, timeZone: TimeZone(identifier: "Asia/Kathmandu")!)
        #expect(request.url.hasSuffix("/25/\(route)/41.ts"))
        let context = LiveCatchupContext(sourceFingerprint: "test", sourceRevision: UUID(), channelFingerprint: "test", channelName: "test",
            programme: item, mediaStartOffset: request.mediaStartOffset, supportsRequestSeek: true)
        #expect(context.programmePosition(mediaPosition: 47) == 70)
        #expect(context.programme == item)
        let initial = try await f.provider.archiveRequest(channel: channel, programme: item, scope: "test", offset: 0)
        #expect(initial.mediaStartOffset == -37 && initial.initialPosition == 37)
        var spec = PlaySpec(url: request.url)
        spec.liveCatchup = .init(sourceFingerprint: "", sourceRevision: UUID(), channelFingerprint: "", channelName: "",
            programme: item, mediaStartOffset: -37, supportsRequestSeek: true)
        spec.initialStartPositionSeconds = 37
        #expect(MPVInitialStartPolicy.loadFileOptions(for: spec) == "start=37.0,end=1537.0")
        #expect(MPVInitialStartPolicy.recoverySpec(for: spec, durationSeconds: 20, isCurrentFileLoaded: true, playbackStarted: false, reachedEOF: true) == nil)
        #expect(!XtreamLogRedaction.redact(request.url).contains("fictional-secret"))
        #expect(!String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("scope"))
    }

    @Test func missingAndInvalidServerZonesNeverDefaultToDeviceOrUTC() async throws {
        for zone: String? in [nil, "Not/AZone"] {
            let f = try ArchiveFixture(); defer { f.close() }; f.mutate { $0.zone = zone }
            let channel = try await f.channel(), result = await f.history(channel)
            #expect(result.data.items.count == 1, "Absolute epochs can still be displayed")
            #expect(XtreamArchivePolicy.availability(channel: channel, programme: result.data.items.first) == .unavailable(.serverTimeZoneUnknown))
        }
    }

    @Test func strictDSTAndCrossMidnightParsing() throws {
        let ny = try #require(TimeZone(identifier: "America/New_York"))
        #expect(XtreamArchivePolicy.instant("2026-11-01 01:30:00", timeZone: ny) == nil)
        #expect(XtreamArchivePolicy.instant("2026-03-08 02:30:00", timeZone: ny) == nil)
        #expect(XtreamArchivePolicy.instant("2026-02-30 12:30:00", timeZone: ny) == nil)
        let row: JSONDynamicValue = .object(["title": .string("跨午夜"), "start": .string("2026-10-01 23:59:37"), "end": .string("2026-10-02 00:10:12")])
        let item = try XtreamEPGParser.item(row, timeZone: ny)
        #expect(item.end.timeIntervalSince(item.start) == 635)
        let session = UUID(), ref = try XtreamResource(accountID: UUID(), kind: "live", streamID: "1", format: "ts")
        let start = Date(timeIntervalSince1970: 1_793_511_037) // 2026-11-01 01:30:37 EDT
        let repeated = EpgItem(title: "DST", start: start, end: start.addingTimeInterval(600),
            xtreamArchive: .init(resource: ref.encoded, scope: "test", session: session, hasArchive: true))
        let channel = Channel(urls: [ref.encoded], xtreamArchive: .init(enabled: true, days: 7, timeZone: ny.identifier, session: session, credentialIdentity: ""))
        #expect(XtreamArchivePolicy.availability(channel: channel, programme: repeated, now: start.addingTimeInterval(3_600)) == .unavailable(.ambiguousArchiveTime))
    }

    @Test func fallbackStaysShortAndHasBoundedRetryWithIndependentScope() async throws {
        let f = try ArchiveFixture(); defer { f.close() }; f.mutate { $0.failHistory = true }
        let channel = try await f.channel()
        for _ in 0..<3 {
            let result = await f.history(channel)
            #expect(result.coverage == .xtreamShort && result.availability == .stale)
            #expect(result.data.items.first?.xtreamArchive == nil)
            #expect(XtreamArchivePolicy.availability(channel: channel, programme: result.data.items.first) == .unavailable(.archiveUnconfirmed))
        }
        #expect(f.read { $0.actions.filter { $0 == "get_simple_data_table" }.count } == 1)
        #expect(f.read { $0.actions.filter { $0 == "get_short_epg" }.count } == 1)
        f.mutate { $0.failHistory = false }
        let fresh = await f.history(channel, scope: "new-source")
        #expect(fresh.coverage == .xtreamHistory && fresh.data.items.first?.title == "Archive programme")
        let old = await f.history(channel)
        #expect(old.coverage == .xtreamShort)
    }

    @Test func malformedHistoryIsAtomicAndValidEmptyClearsOldData() async throws {
        let f = try ArchiveFixture(); defer { f.close() }
        let channel = try await f.channel(), first = await f.history(channel)
        f.mutate { $0.historyOverride = "{\"epg_listings\":[{\"title\":\"Bad\",\"start_timestamp\":\"NaN\"}]}" }
        let stale = await f.history(channel, force: true)
        #expect(stale.availability == .stale && stale.coverage == .xtreamHistory && stale.data == first.data)
        #expect(await f.history(channel).availability == .stale)
        f.mutate { $0.historyOverride = nil; $0.empty = true }
        let empty = await f.history(channel, force: true)
        #expect(empty.availability == .empty && empty.data.items.isEmpty)
        f.mutate { $0.failHistory = true }
        #expect(await f.history(channel, force: true).data.items.isEmpty)
    }

    @Test func channelRetentionAndStreamIdentityCannotBeBorrowed() throws {
        let session = UUID(), account = UUID()
        let first = try XtreamResource(accountID: account, kind: "live", streamID: "1", format: "ts")
        let second = try XtreamResource(accountID: account, kind: "live", streamID: "2", format: "ts")
        let capability = XtreamArchiveChannel(enabled: true, days: 1, timeZone: "UTC", session: session, credentialIdentity: "")
        let a = Channel(name: "Same title", urls: [first.encoded], xtreamArchive: capability)
        let b = Channel(name: "Same title", urls: [second.encoded], xtreamArchive: capability)
        #expect(LiveChannelMerger.merge(groups: [.init(name: "G", channels: [a, b])]).first?.channels.count == 2)
        let now = Date(), proof = XtreamProgrammeArchive(resource: first.encoded, scope: "test", session: session, hasArchive: true)
        var item = EpgItem(title: "Old", start: now.addingTimeInterval(-90_000), end: now.addingTimeInterval(-89_000), xtreamArchive: proof)
        #expect(XtreamArchivePolicy.availability(channel: a, programme: item, now: now) == .unavailable(.expired))
        item.start = now.addingTimeInterval(-300); item.end = now.addingTimeInterval(-100)
        #expect(XtreamArchivePolicy.availability(channel: b, programme: item, now: now) == .unavailable(.archiveUnconfirmed))
        item.end = now.addingTimeInterval(100)
        #expect(XtreamArchivePolicy.availability(channel: a, programme: item, now: now) == .unavailable(.onAir))
        item.start = now.addingTimeInterval(1)
        #expect(XtreamArchivePolicy.availability(channel: a, programme: item, now: now) == .unavailable(.future))
        let restored = try JSONDecoder().decode(Channel.self, from: JSONEncoder().encode(a))
        #expect(restored.xtreamArchive == nil)
    }

    @Test func payloadAndRowBudgetsRejectWithoutPromotingShortData() async throws {
        let f = try ArchiveFixture(); defer { f.close() }; let channel = try await f.channel()
        for body in [String(repeating: "x", count: 2 * 1_024 * 1_024 + 1), "{\"epg_listings\":[" + Array(repeating: "{}", count: 2_049).joined(separator: ",") + "]}"] {
            f.mutate { $0.historyOverride = body }
            let result = await f.history(channel, force: true)
            #expect(result.coverage == .xtreamShort && result.availability == .stale)
        }
    }

    @Test func credentialRotationAndRevocationDiscardOldCacheAndChannels() async throws {
        let f = try ArchiveFixture(); defer { f.close() }; let channel = try await f.channel()
        _ = await f.history(channel)
        f.mutate { $0.credentials = .init(username: "second/account", password: "new?secret#") }
        let rejected = await f.history(channel)
        #expect(rejected.discardsPreviousData && rejected.data.items.isEmpty)
        let current = try await f.channel(), result = await f.history(current)
        let item = try #require(result.data.items.first)
        let request = try await f.provider.archiveRequest(channel: current, programme: item, scope: "test", offset: 0)
        #expect(request.url.contains("/second%2Faccount/new%3Fsecret%23/"))
        f.mutate { $0.credentials = nil }
        #expect(await f.history(current).discardsPreviousData)
    }

    @Test func lateResponseCannotRepopulateAfterRefreshCredentialChangeOrCancellation() async throws {
        for action in 0..<3 {
            let f = try ArchiveFixture(); defer { f.close() }; let channel = try await f.channel()
            f.mutate { $0.delay = 0.25 }
            let task = Task { await f.history(channel) }
            try await wait { f.read { $0.actions.contains("get_simple_data_table") } }
            if action == 0 { await f.provider.clearContentCache() }
            if action == 1 { f.mutate { $0.credentials = .init(username: "new", password: "new") } }
            if action == 2 { task.cancel() }
            let result = await task.value
            #expect(result.discardsPreviousData && result.data.items.isEmpty)
        }
    }

    @Test func newerForcedRefreshWinsOverAnOlderResponse() async throws {
        let f = try ArchiveFixture(); defer { f.close() }; let channel = try await f.channel()
        f.mutate { $0.delay = 0.25 }
        let old = Task { await f.history(channel) }
        try await wait { f.read { $0.actions.contains("get_simple_data_table") } }
        f.mutate { $0.delay = 0; $0.empty = true }
        let fresh = await f.history(channel, force: true)
        #expect(fresh.data.items.isEmpty && fresh.availability == .empty)
        #expect(await old.value.discardsPreviousData)
        #expect(await f.history(channel).data.items.isEmpty)
    }

    @Test func oldAuthenticationCannotRestoreAReplacedServerTimeZone() async throws {
        let f = try ArchiveFixture(); defer { f.close() }
        _ = try await f.channel()
        f.mutate { $0.authDelay = 0.25; $0.zone = "UTC" }
        let old = Task { try await f.provider.authenticate(forceRefresh: true) }
        try await wait { f.read { $0.actions.filter { $0 == "auth" }.count >= 2 } }
        f.mutate { $0.authDelay = 0; $0.zone = nil }
        try await f.provider.authenticate(forceRefresh: true)
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(try await f.channel().xtreamArchive?.timeZone == nil)
    }

    @Test func playbackRechecksPerProgrammeAndChannelArchivePermission() async throws {
        let f = try ArchiveFixture(); defer { f.close() }; let channel = try await f.channel()
        let item = try #require(await f.history(channel).data.items.first)
        f.mutate { $0.hasArchive = false }
        await #expect(throws: LiveCatchupUnavailableReason.noArchive) {
            _ = try await f.provider.archiveRequest(channel: channel, programme: item, scope: "test", offset: 0)
        }
        f.mutate { $0.hasArchive = true; $0.days = 0 }
        await #expect(throws: LiveCatchupUnavailableReason.noArchive) {
            _ = try await f.provider.archiveRequest(channel: channel, programme: item, scope: "test", offset: 0)
        }
        await #expect(throws: LiveCatchupUnavailableReason.staleSource) {
            _ = try await f.provider.archiveRequest(channel: channel, programme: item, scope: "different-source", offset: 0)
        }
    }

    @Test @MainActor func appStateRejectsOldGuideSourceAndAccountCallbacks() async throws {
        let f = try ArchiveFixture(); defer { f.close() }
        let suite = "archive-state-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let preferences = UserPreferences(defaults: defaults)
        preferences.xtreamConfigurations = [f.configuration]
        try preferences.saveXtreamCredentials(try #require(f.read { $0.credentials }), for: f.configuration.id, server: f.configuration.server)
        let site = try f.configuration.site()
        await SpiderReplacementRegistry.shared.register(originalKey: site.key, originalAPI: site.api, provider: f.provider)
        let state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
            liveHTTPClient: HTTPClient(session: f.session), storageManager: StorageManager(storageDirectory: directory),
            userPreferences: preferences, providerRuntimeBootstrap: nil)
        let channel = try await f.channel()
        await state.changeLive(.init(name: "Fixture", url: f.configuration.url), initialGroups: [.init(name: "G", channels: [channel])])
        let loader = state.makeLiveEpgLoader()
        let result = await loader.load(channel: channel, window: f.window, forceRefresh: false)
        let item = try #require(result.data.items.first)
        state.isLivePlayerPresented = true
        defer { state.dismissLivePlayer() }
        var specs: [PlaySpec] = []
        state.playSpecHandler = { spec in specs.append(spec); state.livePlayerState.currentSpec = spec }
        await state.playLiveCatchup(channel: channel, programme: item)
        let spec = try #require(specs.last)
        #expect(spec.liveCatchup?.programme == item && spec.initialStartPositionSeconds == 37)
        state.handleMPVPlaybackStarted(spec: spec)
        state.handleMPVPlaybackPosition(spec: spec, positionSeconds: 42)
        #expect(state.liveCatchupPosition == 5)
        let oldRevision = state.liveSourceRevision
        state.channelGroups = state.channelGroups
        await state.playLiveCatchup(channel: channel, programme: item, revision: oldRevision)
        #expect(specs.count == 1 && state.liveCatchupContext == nil)
        #expect(!state.liveCatchupAvailability(channel: channel, programme: item).isAvailable)
        let currentItem = try #require(await state.makeLiveEpgLoader().load(channel: channel, window: f.window, forceRefresh: false).data.items.first)
        await state.playLiveCatchup(channel: channel, programme: currentItem)
        let currentSpec = try #require(specs.last)
        try preferences.saveCredential("", for: "xtream." + f.configuration.id.uuidString.lowercased())
        state.invalidateLiveXtreamAccount(f.configuration.id)
        state.handleMPVPlaybackStarted(spec: currentSpec)
        state.handleMPVPlaybackPosition(spec: currentSpec, positionSeconds: 900)
        #expect(state.liveCatchupContext == nil && state.channelGroups.isEmpty)
        #expect(!state.liveCatchupAvailability(channel: channel, programme: currentItem).isAvailable)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate())
    }
}
