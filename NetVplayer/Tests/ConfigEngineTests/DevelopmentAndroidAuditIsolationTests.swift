import AppKit
import ConfigEngine
import Foundation
import Models
import Networking
import ProviderRuntime
@testable import PlayerEngine
import SpiderEngine
import Storage
import Testing
@testable import NetVplayerApp

@Suite("Android audit request isolation", .serialized)
@MainActor
struct DevelopmentAndroidAuditIsolationTests {
    @Test(arguments: [false, true])
    func auditDoesNotFetchEmbeddedOrSavedLiveContent(savedLive: Bool) async throws {
        let fixture = try await Fixture(savedLive: savedLive)
        defer { fixture.close() }
        let plan = try JSONDecoder().decode(DevelopmentAndroidAppAudit.Plan.self, from: JSONSerialization.data(withJSONObject: [
            "config": fixture.config.path, "output": fixture.output.path,
            "only": [fixture.site.key], "providerExecutionPreference": "macPreferred",
            "inventoryOnly": true, "homeOnly": true, "sampleCount": 0, "singlePlaybackAttempt": true
        ]))
        await DevelopmentAndroidAppAudit.run(plan, state: fixture.state)
        let ledger = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            fixture.output.appendingPathComponent("app-audit.json"))) as? [String: Any])
        #expect(ledger["status"] as? String == "complete")
        #expect(ledger["configuration_live_content_requested"] as? Bool == false)
        #expect(ledger["single_playback_attempt"] as? Bool == true)
        #expect(fixture.state.allowsAutomaticVodPlaybackActions)
        #expect(await fixture.provider.homeCalls() == 1)
        #expect(fixture.state.activeSite?.key == fixture.site.key)
        #expect(fixture.server.requests().isEmpty)
        #expect(fixture.state.activeLive == nil)
        #expect(fixture.state.channelGroups.isEmpty)
        #expect(fixture.state.configurationRefreshTask == nil)
        print("[AUDIT_ISOLATION] savedLive=\(savedLive) homeCalls=\(await fixture.provider.homeCalls()) liveRequests=\(fixture.server.requests().count)")
    }

    @Test(arguments: [false, true])
    func ordinaryConfigurationStillLoadsItsSelectedLiveContent(savedLive: Bool) async throws {
        let fixture = try await Fixture(savedLive: savedLive)
        defer { fixture.close() }
        let json = String(decoding: try Data(contentsOf: fixture.config), as: UTF8.self)
        let canonical = "local-audit-isolation-control"
        await fixture.state.loadConfig(url: canonical, persistUserConfig: false,
            waitForProviderRuntime: false, refreshCachedConfiguration: false,
            preparedInput: ResolvedVodInput(json: json, config: Config(url: canonical),
                kind: .configuration, canonicalURL: canonical, initialResult: nil,
                usesCachedConfiguration: true))
        #expect(fixture.state.isConfigLoaded)
        #expect(await fixture.provider.homeCalls() == 1)
        #expect(fixture.server.requests() == (savedLive ? ["/saved.json", "/saved.m3u"] : ["/embedded.m3u"]))
        #expect(fixture.state.channelGroups.flatMap(\.channels).count == 1)
        #expect(fixture.state.activeLive?.name == (savedLive ? "Saved" : "Embedded"))
        await fixture.state.cancelLoading()
        print("[AUDIT_ISOLATION_CONTROL] savedLive=\(savedLive) liveRequests=\(fixture.server.requests().count)")
    }

    @Test(arguments: ["/failed.m3u8", "/opaque"], [false, true])
    func mediaFailureRespectsAutomaticRecoveryPolicy(path: String, automatic: Bool) async throws {
        let fixture = try await Fixture(savedLive: false)
        defer { fixture.close() }
        fixture.state.allowsAutomaticVodPlaybackActions = automatic
        let spec = PlaySpec(url: fixture.server.url(path),
                            metadata: ["playback.sessionGeneration": "1"], siteKey: "")
        fixture.state.playerState.currentSpec = spec
        fixture.state.isPlayerPresented = true
        fixture.state.handleMPVPlaybackFailure(spec: spec, message: "loading failed",
            failure: MPVPlaybackFailure(message: "loading failed", nativeError: -13))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while fixture.state.playerState.errorMessage == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.state.playerState.errorMessage != nil)
        #expect(fixture.server.requests() == (automatic ? [path] : []))
        print("[AUDIT_SINGLE_ATTEMPT] automatic=\(automatic) path=\(path) recoveryRequests=\(fixture.server.requests().count)")
        await fixture.state.cancelLoading()
    }

    @Test(arguments: ["provider_timeout", "connection_lost"], [false, true])
    func preparationFailureRespectsAutomaticRecoveryPolicy(failure: String, automatic: Bool) async throws {
        let fixture = try await Fixture(savedLive: false, playerFailure: failure)
        defer { fixture.close() }
        let plan = try JSONDecoder().decode(DevelopmentAndroidAppAudit.Plan.self, from: JSONSerialization.data(withJSONObject: [
            "config": fixture.config.path, "output": fixture.output.path,
            "only": [fixture.site.key], "providerExecutionPreference": "macPreferred",
            "homeOnly": true, "sampleCount": 1, "allSelectedSamples": true,
            "singlePlaybackAttempt": !automatic, "playbackSeconds": 1
        ]))
        await DevelopmentAndroidAppAudit.run(plan, state: fixture.state)
        let ledger = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            fixture.output.appendingPathComponent("app-audit.json"))) as? [String: Any])
        let timedOut = failure == "provider_timeout"
        #expect(ledger["status"] as? String == (timedOut ? "aborted_timeout" : "complete"))
        let records = try #require(ledger["sites"] as? [[String: Any]])
        let attempts = try #require(records.first?["attempts"] as? [[String: Any]])
        #expect(attempts.count == 1)
        #expect(attempts.first?["status"] as? String == (timedOut ? "playback_timeout" : "playback_failed"))
        if timedOut { #expect(attempts.first?["timeout_origin"] as? String == "playback_operation") }
        #expect(await fixture.provider.playerCalls() == (automatic ? 2 : 1))
        #expect(fixture.state.allowsAutomaticVodPlaybackActions)
        #expect(fixture.server.requests().isEmpty)
        print("[AUDIT_PREPARATION_ATTEMPTS] failure=\(failure) automatic=\(automatic) playerCalls=\(await fixture.provider.playerCalls())")
        await fixture.state.cancelLoading()
    }

    @Test(arguments: [false, true], ["position", "evaluate", "queued"])
    func nextEpisodePreloadRespectsSingleAttemptPolicy(automatic: Bool, callback: String) async throws {
        let fixture = try await Fixture(savedLive: false, preloadFixture: true)
        defer { fixture.close() }
        let state = fixture.state
        state.allowsAutomaticVodPlaybackActions = automatic
        state.sites = [fixture.site]
        state.activeSite = fixture.site
        let episodes = [Episode(name: "First", url: "fixture-episode"),
                        Episode(name: "Second", url: "fixture-next")]
        state.detailVod = Vod(vodId: "fixed", siteKey: fixture.site.key)
        state.episodes = episodes
        state.selectedPlayFlag = "fixture-line"
        var submissions = 0
        state.playSpecHandler = { spec in
            await Task.yield()
            state.playerState.currentSpec = spec
            submissions += 1
        }
        await state.playEpisode(episodes[0])
        let spec = try #require(state.playerState.currentSpec)
        #expect(await fixture.provider.playerCalls() == 1)
        state.playerState.duration = 600
        state.playerState.position = 590
        state.playerState.bufferedUntil = 590
        state.playerState.isMediaLoading = false
        for _ in 0..<3 {
            if callback == "position" {
                state.handleMPVPlaybackPosition(spec: spec, positionSeconds: 590)
            } else if callback == "queued" {
                state.allowsAutomaticVodPlaybackActions = true
                state.evaluateNextEpisodePreload(spec: spec, positionSeconds: 590)
                state.allowsAutomaticVodPlaybackActions = automatic
            } else {
                state.evaluateNextEpisodePreload(spec: spec, positionSeconds: 590)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while automatic, await fixture.provider.playerCalls() < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.provider.playerCalls() == (automatic ? 2 : 1))
        #expect(submissions == 1)
        #expect(state.playerState.currentSpec?.metadata["vod.episodeURL"] == episodes[0].url)
        #expect(state.selectedPlayFlag == "fixture-line")
        #expect(fixture.server.requests().allSatisfy { $0.hasPrefix("/media/") })
        print("[AUDIT_PRELOAD_POLICY] automatic=\(automatic) callback=\(callback) playerCalls=\(await fixture.provider.playerCalls()) submissions=\(submissions)")
        await state.cancelLoading()
    }

    @Test(arguments: [false, true])
    func homeFailureRespectsAutomaticRecoveryPolicy(automatic: Bool) async throws {
        let fixture = try await Fixture(savedLive: false, homeFailure: true)
        defer { fixture.close() }
        let plan = try JSONDecoder().decode(DevelopmentAndroidAppAudit.Plan.self, from: JSONSerialization.data(withJSONObject: [
            "config": fixture.config.path, "output": fixture.output.path,
            "only": [fixture.site.key], "providerExecutionPreference": "macPreferred",
            "inventoryOnly": true, "homeOnly": true, "sampleCount": 0,
            "singlePlaybackAttempt": !automatic
        ]))
        await DevelopmentAndroidAppAudit.run(plan, state: fixture.state)
        #expect(await fixture.provider.homeCalls() == (automatic ? 2 : 1))
        #expect(await fixture.provider.playerCalls() == 0)
        #expect(fixture.state.allowsAutomaticVodPlaybackActions)
        #expect(fixture.server.requests().isEmpty)
        print("[AUDIT_HOME_ATTEMPTS] automatic=\(automatic) homeCalls=\(await fixture.provider.homeCalls())")
        await fixture.state.cancelLoading()
    }

    @Test(arguments: [false, true], ["local search fixture", "https://pan.quark.cn/s/fixture"])
    func searchAuditDoesNotExpandAnUnavailableSelection(searchable: Bool, keyword: String) async throws {
        let fixture = try await Fixture(savedLive: false)
        defer { fixture.close() }
        let other = Site(key: fixture.site.key + ".other", type: 3, api: "csp_other_" + fixture.site.key)
        await SpiderReplacementRegistry.shared.register(originalKey: other.key, originalAPI: other.api, provider: fixture.provider)
        try JSONSerialization.data(withJSONObject: ["sites": [
            ["key": fixture.site.key, "name": fixture.site.name, "type": 3, "api": fixture.site.api,
             "searchable": searchable ? 1 : 0],
            ["key": other.key, "type": 3, "api": other.api, "searchable": 1]
        ]]).write(to: fixture.config)
        let plan = try JSONDecoder().decode(DevelopmentAndroidAppAudit.Plan.self, from: JSONSerialization.data(withJSONObject: [
            "config": fixture.config.path, "output": fixture.output.path,
            "only": [fixture.site.key], "providerExecutionPreference": "macPreferred",
            "homeOnly": true, "sampleCount": 0, "searchKeyword": keyword,
            "singlePlaybackAttempt": true
        ]))
        await DevelopmentAndroidAppAudit.run(plan, state: fixture.state)
        #expect(fixture.state.allowsSearchFallbacks)
        let ledger = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            fixture.output.appendingPathComponent("app-audit.json"))) as? [String: Any])
        #expect(ledger["search_selection_fallback_allowed"] as? Bool == false)
        let auditCalls = await fixture.provider.searchCalls()
        #expect(auditCalls[fixture.site.key, default: 0] == (searchable ? 1 : 0))
        #expect(auditCalls[other.key, default: 0] == 0)
        #expect(fixture.server.requests().isEmpty)
        print("[AUDIT_SEARCH_SCOPE] searchable=\(searchable) selected=\(auditCalls[fixture.site.key, default: 0]) other=\(auditCalls[other.key, default: 0])")
        // Normal search keeps the existing preference recovery behavior.
        fixture.state.selectedSearchSiteKeys = [fixture.site.key]
        await fixture.state.search(keyword: "local search fixture", forceRefresh: true)
        let ordinaryCalls = await fixture.provider.searchCalls()
        #expect(ordinaryCalls[other.key, default: 0] == (searchable ? 0 : 1))
        #expect(ordinaryCalls[fixture.site.key, default: 0] == (searchable ? 2 : 0))
        await fixture.state.cancelLoading()
    }

    @Test
    func nativeFailureCannotCrossMediaGenerationOrChangedIdentity() async throws {
        _ = NSApplication.shared
        let engine = MPVPlayerEngine(videoSurface: .vod)
        let state = PlayerState()
        engine.playerState = state
        defer { engine.stop() }
        let original = PlaySpec(url: "http://127.0.0.1:9/not-requested",
            headers: ["X-Fixture": "private-audit-header"],
            metadata: ["playback.sessionGeneration": "1", "vod.id": "vod", "vod.episodeURL": "episode"],
            flag: "line", siteKey: "fixture")
        await engine.play(spec: original) // No surface: no media request.
        engine.reportUnavailableVideoSurface(.vod)
        #expect(engine.playbackFailure(for: original) != nil)
        for key in ["playback.sessionGeneration", "vod.id", "vod.episodeURL"] {
            var changed = original
            changed.metadata[key] = "changed"
            #expect(engine.playbackFailure(for: changed) == nil)
        }
        var changedHeader = original
        changedHeader.headers["X-Fixture"] = "changed"
        #expect(engine.playbackFailure(for: changedHeader) == nil)
        let observation = await DevelopmentAndroidAppAudit.nativeFailureObservation(for: original, engine: engine)
        #expect(observation["observed"] as? Bool == true)
        #expect(observation["http_status"] is NSNull)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: observation), as: UTF8.self)
        #expect(!encoded.contains("private-audit-header"))
        #expect(!encoded.contains("127.0.0.1"))
        var replacement = original
        replacement.metadata["playback.sessionGeneration"] = "2"
        await engine.play(spec: replacement)
        #expect(engine.playbackFailure(for: original) == nil)
        #expect(engine.playbackFailure(for: replacement) == nil)
        engine.reportUnavailableVideoSurface(.vod)
        #expect(engine.playbackFailure(for: replacement) != nil)
        await engine.stopAndWaitForRetirement()
        #expect(engine.playbackFailure(for: replacement) == nil)
    }

    @Test(arguments: [200, 403, 503])
    func nativeMediaFailureReportsOnlyObservedHTTPStatus(status: Int) async throws {
        let fixture = try await Fixture(savedLive: false)
        defer { fixture.close() }
        let engine = MPVPlayerEngine(videoSurface: .vod)
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
        let path = "/media/\(status)"
        let spec = PlaySpec(url: fixture.server.url(path),
            headers: ["X-Fixture": "private-audit-header"],
            metadata: ["playback.sessionGeneration": "1", "vod.id": "vod", "vod.episodeURL": "episode"],
            flag: "line", siteKey: fixture.site.key)
        await engine.play(spec: spec)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while state.errorMessage == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let failure = try #require(engine.playbackFailure(for: spec))
        #expect(failure.nativeError != nil)

        #expect(!failure.playbackStarted)
        #expect(fixture.server.requests() == [path])
        let observation = await DevelopmentAndroidAppAudit.nativeFailureObservation(for: spec, engine: engine)
        try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
            .write(to: fixture.root.appendingPathComponent("native-failure.safe.json"))
        #expect(observation["observed"] as? Bool == true)
        #expect(observation["playback_generation"] as? String == "1")
        #expect(status == 200 ? observation["http_status"] is NSNull : observation["http_status"] as? Int == status)
        print("[AUDIT_NATIVE_FAILURE] response=\(status) native=\(failure.nativeError ?? 0) observedHTTP=\(failure.httpStatus ?? 0) requests=\(fixture.server.requests().count)")
        await engine.stopAndWaitForRetirement()
        #expect(engine.playbackFailure(for: spec) == nil)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let output: URL
        let config: URL
        let server: AuditIsolationServer
        let suite: String
        let site: Site
        let provider: AuditIsolationProvider
        let state: AppState
        let retain: Bool

        init(savedLive: Bool, playerFailure: String? = nil, homeFailure: Bool = false, preloadFixture: Bool = false) async throws {
            _ = NSApplication.shared
            let evidence = ProcessInfo.processInfo.environment["NETVPLAYER_AUDIT_ISOLATION_EVIDENCE_DIR"]
            retain = evidence != nil
            let parent = evidence.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            root = parent.appendingPathComponent("audit-isolation-\(savedLive)-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            output = root.appendingPathComponent("audit", isDirectory: true)
            config = root.appendingPathComponent("config.json")
            server = try AuditIsolationServer(root: root)
            suite = "AuditIsolation.\(UUID())"
            let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!, credentialStore: MemoryCredentialStore())
            preferences.providerExecutionPreference = .macPreferred
            if savedLive {
                preferences.currentLiveConfigUrl = server.url("/saved.json")
                preferences.currentLiveName = "Saved"
            }
            site = Site(key: suite, name: "Local fixture", type: 3, api: "csp_\(suite)")
            provider = AuditIsolationProvider(playerFailure: playerFailure, homeFailure: homeFailure,
                playerURL: preloadFixture ? server.url("/media/200") : nil)
            await SpiderReplacementRegistry.shared.register(originalKey: site.key, originalAPI: site.api, provider: provider)
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.connectionProxyDictionary = [:]
            let client = HTTPClient(session: URLSession(configuration: sessionConfig))
            state = AppState(loadDefaultConfig: false, startProxyServer: false, startProviderRuntime: false,
                liveHTTPClient: client,
                configResolver: ConfigResolver(httpClient: client, preferences: preferences, allowsProxyFallback: false),
                storageManager: StorageManager(storageDirectory: root.appendingPathComponent("state")),
                userPreferences: preferences, providerRuntimeBootstrap: nil,
                androidProviderRegistrationOverride: { _ in }, catalogRepository: CatalogRepository())
            let body: [String: Any] = ["sites": [["key": site.key, "name": site.name, "type": 3, "api": site.api]],
                "lives": [["name": "Embedded", "url": server.url("/embedded.m3u")]]]
            try JSONSerialization.data(withJSONObject: body).write(to: config)
        }

        func close() {
            server.stop()
            LiveConfig.shared.clear()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            if !retain { try? FileManager.default.removeItem(at: root) }
        }
    }
}

private actor AuditIsolationProvider: SiteContentProvider {
    private var homes = 0
    private var players = 0
    private let playerFailure: String?
    private let homeFailure: Bool
    private let playerURL: String?
    private var searches: [String: Int] = [:]
    init(playerFailure: String? = nil, homeFailure: Bool = false, playerURL: String? = nil) {
        self.playerFailure = playerFailure
        self.homeFailure = homeFailure
        self.playerURL = playerURL
    }
    func homeCalls() -> Int { homes }
    func playerCalls() -> Int { players }
    func searchCalls() -> [String: Int] { searches }
    func homeContent(site: Site) async throws -> Models.Result {
        homes += 1
        if homeFailure { throw URLError(.networkConnectionLost) }
        return Models.Result(list: [Vod(vodId: "fixed", vodName: "Local fixture")])
    }
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Models.Result { .empty }
    func detailContent(site: Site, id: String) async throws -> Models.Result {
        guard playerFailure != nil else { return .empty }
        return Models.Result(list: [Vod(vodId: id, vodName: "Local fixture",
            vodPlayFrom: "fixture-line", vodPlayUrl: "Fixture$fixture-episode")])
    }
    func playerContent(site: Site, flag: String, id: String) async throws -> Models.Result {
        players += 1
        switch playerFailure {
        case "provider_timeout": throw ProviderProcessError.timedOut("local-fixture")
        case "connection_lost": throw URLError(.networkConnectionLost)
        default:
            guard let playerURL else { return .empty }
            return Models.Result(url: playerURL, format: "mp4")
        }
    }
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Models.Result {
        searches[site.key, default: 0] += 1
        return .empty
    }
}

private final class AuditIsolationServer {
    private let process: Process
    private let port: Int
    private let receipt: URL

    init(root: URL) throws {
        receipt = root.appendingPathComponent("requests.jsonl")
        FileManager.default.createFile(atPath: receipt.path, contents: Data())
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script, receipt.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        let value = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(value) else {
            process.terminate()
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }
    func requests() -> [String] {
        (try? String(contentsOf: receipt, encoding: .utf8))?.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])?["path"]
        } ?? []
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }

    private static let script = #"""
import json,sys
from http.server import HTTPServer,BaseHTTPRequestHandler
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  with open(sys.argv[1],'a') as f:f.write(json.dumps({'path':self.path})+'\n')
  if self.path=='/saved.json':
   body=json.dumps({'lives':[{'name':'Saved','url':'http://127.0.0.1:%d/saved.m3u'%self.server.server_port}]}).encode()
  elif self.path in ['/saved.m3u','/embedded.m3u']:
   body=('#EXTM3U\n#EXTINF:-1 group-title="Fixture",Local channel\nhttp://127.0.0.1:%d/unrequested.m3u8\n'%self.server.server_port).encode()
  elif self.path.startswith('/media/'):
   status=int(self.path.rsplit('/',1)[-1]);body=b'Not a media resource'
   self.send_response(status);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
  else:
   self.send_error(404);return
  self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
server=HTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""#
}
