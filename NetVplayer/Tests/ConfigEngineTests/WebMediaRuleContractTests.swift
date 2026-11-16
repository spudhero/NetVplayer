import Foundation
import AppKit
@testable import PlayerEngine
import Models
import Testing
@testable import ParseEngine
@testable import SpiderEngine

@Suite(.serialized)
@MainActor
struct WebMediaRuleContractTests {
    @Test func ruleFindsExtensionlessFetch() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        let policy = WebMediaPolicy(rules: [Rule(hosts: ["127.0.0.1"], regex: ["/stream/opaque"])])
        let spec = try await WebViewSniffer().sniff(url: server.url("/page/opaque"), timeout: 1.5, policy: policy)
        #expect(spec.url == server.url("/stream/opaque?raw=a%2Fb+%20"))
        try await server.save("extensionless-rule")
    }

    @Test func originalSpiderCanRejectDOMAndAcceptExtensionlessXHR() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        let calls = RuleCheckCalls()
        let policy = WebMediaPolicy(check: { url in
            await calls.append(url)
            return url.contains("/stream/opaque")
        })
        let spec = try await WebViewSniffer().sniff(url: server.url("/page/spider"), timeout: 2, policy: policy)
        #expect(spec.url == server.url("/stream/opaque?raw=a%2Fb+%20"))
        let observed = await calls.values
        #expect(observed.contains(server.url("/decoy/movie.mp4")))
        #expect(observed.contains(server.url("/stream/opaque?raw=a%2Fb+%20")))
        try await server.save("spider-xhr")
    }

    @Test func matchedRuleExcludesFalsePositiveBeforeDefaultFormat() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        let rule = try JSONDecoder().decode(Rule.self, from: Data(#"{"name":"local","hosts":["127.0.0.1"],"regex":["/stream/opaque"],"script":[],"exclude":["/decoy/"]}"#.utf8))
        let spec = try await WebViewSniffer().sniff(url: server.url("/page/spider"), timeout: 2,
            policy: WebMediaPolicy(rules: [rule]))
        #expect(spec.url == server.url("/stream/opaque?raw=a%2Fb+%20"))
        try await server.save("rule-exclude")
    }

    @Test func clickAndRuleScriptsRunInOrderAfterPageLoad() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        let click = "window.order = window.loaded ? 'C' : 'early'"
        let scripts = ["", "window.order += 'A'", "if(window.order==='CA') fetch('/stream/opaque?order=CA')"]
        let policy = WebMediaPolicy(rules: [Rule(hosts: ["127.0.0.1"], regex: ["/stream/opaque"], script: scripts)])
        let spec = try await WebViewSniffer().sniff(url: server.url("/page/script"), clickScript: click,
            timeout: 2, policy: policy)
        #expect(spec.url == server.url("/stream/opaque?order=CA"))
        try await server.save("rule-script-order")
    }
    @Test func defaultFormatAndRuleSemanticsMatchFrozenOracle() throws {
        let policy = WebMediaPolicy()
        let cases: [(String, Bool)] = [
            ("https://media.example.test/movie.mp4", true), ("https://media.example.test/movie.MP4", false),
            ("https://media.example.test/video/tos/opaque", true), ("https://media.example.test/opaque", false),
            ("https://media.example.test/player.html?x=movie.mp4", false),
            ("https://media.example.test/next?url=https://other.test/movie.mp4", false),
            ("https://media.example.test/next?v=http://other.test/movie.mp4", false),
            ("https://media.example.test/movie.mp4/part", true), ("https://media.example.test/audio.wav", false)
        ]
        for (url, expected) in cases { #expect(try policy.defaultAccepts(url) == expected) }
        let first = Rule(name: "first", hosts: ["example.test"], regex: ["/opaque", "special.[0-9]+"],
            script: ["", "window.a=1", "window.b=2"], exclude: ["/ad/", "block.[0-9]+"])
        let rules = WebMediaPolicy(rules: [first, Rule(hosts: ["example.test"], regex: ["/second"])])
        for url in ["https://cdn.example.test/opaque", "https://cdn.example.test/special-123"] { #expect(try rules.defaultAccepts(url)) }
        for url in ["https://cdn.example.test/ad/opaque.mp4", "https://cdn.example.test/block-123/movie.mp4", "https://cdn.example.test/second"] { #expect(try !rules.defaultAccepts(url)) }
        let nested = "https://parser.invalid/watch?url=https%3A%2F%2FCDN.EXAMPLE.TEST%2Fwatch"
        #expect(rules.matchingRule(for: nested)?.name == "first")
        #expect(rules.scripts(for: nested, click: "window.a=1") == ["window.a=1", "window.b=2"])
        #expect(rules.scripts(for: nested, click: "click()") == ["click()", "window.a=1", "window.b=2"])
        #expect(WebMediaPolicy(rules: [Rule(hosts: [#"cdn\..*test"#])]).matchingRule(for: "https://cdn.example.test/a") == nil)
        #expect(WebMediaPolicy(rules: [Rule(hosts: [#"cdn\..*test,"#])]).matchingRule(for: "https://cdn.example.test/a") != nil)
    }

    @Test func sparseRulesDecodeAndRetainExclude() throws {
        let rules = try JSONDecoder().decode([Rule].self, from: Data(#"[{"hosts":["example.test"],"exclude":["/ad/"]},{}]"#.utf8))
        #expect(rules.count == 2 && rules[0].exclude == ["/ad/"])
        #expect(rules[0].name.isEmpty && rules[0].regex.isEmpty && rules[0].script.isEmpty)
        #expect(rules[1].hosts.isEmpty && rules[1].exclude.isEmpty)
    }

    @Test func slowRejectedCandidateKeepsLaterCandidatesAndCancellationIsolatesReuse() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        let sniffer = WebViewSniffer()
        let calls = RuleCheckCalls()
        let policy = WebMediaPolicy(check: { url in
            await calls.append(url)
            try await Task.sleep(for: .milliseconds(250))
            return url.contains("/stream/opaque")
        })
        let first = try await sniffer.sniff(url: server.url("/page/spider"), timeout: 3, policy: policy)
        #expect(first.url == server.url("/stream/opaque?raw=a%2Fb+%20"))
        let cancelled = Task { try await sniffer.sniff(url: server.url("/page/spider"), timeout: 3, policy: policy) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("cancelled policy succeeded") } catch { #expect(error is CancellationError) }
        let next = try await sniffer.sniff(url: server.url("/page/opaque"), timeout: 2,
            policy: WebMediaPolicy(rules: [Rule(hosts: ["127.0.0.1"], regex: ["/stream/opaque"])]))
        #expect(next.url == first.url)
        try await server.save("slow-cancel-reuse")
    }

    @Test func ruleScriptErrorsContinueAndFrameAPIsUseTheSamePolicy() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        let scripts = ["throw Error('local-fixture')", "document.querySelector('iframe').src='/page/opaque'"]
        let spec = try await WebViewSniffer().sniff(url: server.url("/page/frame"), timeout: 2,
            policy: WebMediaPolicy(rules: [Rule(hosts: ["127.0.0.1"], regex: ["/stream/opaque"], script: scripts)]))
        #expect(spec.url == server.url("/stream/opaque?raw=a%2Fb+%20"))
        try await server.save("script-error-frame")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_WEB_RULE_RUNTIME_FIXTURE"] != nil))
    func realOriginalSpiderRunnerFeedsParserAndBrowser() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        let (provider, site, state) = try makeProvider(server: server, mode: "custom")
        do {
            let result = try await provider.playerContent(site: site, flag: "raw-line", id: "first")
            let policy = try await provider.webMediaPolicy(site: site, rules: [Rule(hosts: ["127.0.0.1"], exclude: ["/stream/"])])
            let parser = ParseEngine()
            let spec = await parser.resolve(result: result, parse: nil, webPolicy: policy)
            #expect(parser.lastFailure == nil)
            #expect(spec.url == server.url("/stream/opaque?raw=a%2Fb+%20"))
            #expect(spec.headerPolicy == .replace)
            await provider.shutdown()
            let calls = try providerCalls(state)
            #expect(calls.filter { $0 == "init" }.count == 1)
            #expect(calls.contains("player:first") && calls.contains("manual:first"))
            #expect(calls.contains("format:first:" + server.url("/decoy/movie.mp4")))
            #expect(calls.contains("format:first:" + spec.url))
            try await server.save("real-spider-parser")
        } catch { await provider.shutdown(); throw error }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_WEB_RULE_RUNTIME_FIXTURE"] != nil))
    func originalDefaultAndSpiderExceptionSelectHostFallback() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        for mode in ["default", "exception"] {
            let (provider, site, state) = try makeProvider(server: server, mode: mode)
            do {
                _ = try await provider.playerContent(site: site, flag: "raw-line", id: "first")
                let policy = try await provider.webMediaPolicy(site: site, rules: [])
                let spec = try await WebViewSniffer().sniff(url: server.url("/page/spider"), timeout: 3, policy: policy)
                #expect(spec.url == server.url("/decoy/movie.mp4"))
                await provider.shutdown()
                let calls = try providerCalls(state)
                #expect(calls.contains("manual:first"))
                #expect(calls.contains { $0.hasPrefix("format:") } == (mode == "exception"))
            } catch { await provider.shutdown(); throw error }
        }
        try await server.save("real-spider-fallback")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_WEB_RULE_RUNTIME_FIXTURE"] != nil))
    func originalSpiderLeaseExpiresOnPlayerCacheConfigurationAndShutdown() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        let (provider, site, state) = try makeProvider(server: server, mode: "slow")
        do {
            _ = try await provider.playerContent(site: site, flag: "line", id: "first")
            let old = try await provider.webMediaPolicy(site: site, rules: [])
            let check = Task { try await old.accepts(server.url("/stream/opaque?raw=a%2Fb+%20")) }
            try await Task.sleep(for: .milliseconds(100))
            _ = try await provider.playerContent(site: site, flag: "line", id: "second")
            do { _ = try await check.value; Issue.record("old in-flight Spider check succeeded") } catch { }
            do { _ = try await old.accepts(server.url("/decoy/movie.mp4")); Issue.record("old Spider lease revived") } catch { }
            let next = try await provider.webMediaPolicy(site: site, rules: [])
            await provider.clearContentCache()
            do { _ = try await next.accepts(server.url("/decoy/movie.mp4")); Issue.record("cleared Spider lease revived") } catch { }
            _ = try await provider.playerContent(site: site, flag: "line", id: "third")
            let third = try await provider.webMediaPolicy(site: site, rules: [])
            var changed = site; changed.ext = site.ext + " "
            _ = try await provider.playerContent(site: changed, flag: "line", id: "fourth")
            do { _ = try await third.accepts(server.url("/decoy/movie.mp4")); Issue.record("configuration lease revived") } catch { }
            let last = try await provider.webMediaPolicy(site: changed, rules: [])
            await provider.shutdown()
            do { _ = try await last.accepts(server.url("/decoy/movie.mp4")); Issue.record("stopped Spider lease revived") } catch { }
            let calls = try providerCalls(state)
            #expect(!calls.contains { $0.hasPrefix("format:second:") || $0.hasPrefix("format:third:") || $0.hasPrefix("format:fourth:") })
        } catch { await provider.shutdown(); throw error }
    }


    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_WEB_RULE_RUNTIME_FIXTURE"] != nil && ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil))
    func originalSpiderExtensionlessMediaActuallyDecodesInLibmpv() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        let (provider, site, _) = try makeProvider(server: server, mode: "custom")
        let state = PlayerState(), engine = MPVPlayerEngine(videoSurface: .vod)
        _ = NSApplication.shared
        engine.playerState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
        let view = try #require(MPVOpenGLVideoView(engine: engine, surface: .vod))
        view.frame = window.contentView!.bounds; window.contentView = view; window.orderFrontRegardless()
        engine.attach(to: view, surface: .vod)
        defer { engine.stop(); engine.detach(from: view); window.orderOut(nil) }
        do {
            let result = try await provider.playerContent(site: site, flag: "raw-line", id: "first")
            let policy = try await provider.webMediaPolicy(site: site, rules: [])
            let parser = ParseEngine()
            var spec = await parser.resolve(result: result, parse: nil, webPolicy: policy)
            try #require(parser.lastFailure == nil)
            #expect(spec.url == server.url("/stream/opaque?raw=a%2Fb+%20"))
            #expect(!PlaybackProxyPolicy.shouldAttemptWebSniff(for: spec, sourceResolvedDirectMedia: true))
            spec.headers["X-Fixture-Actor"] = "player"
            spec.metadata["network.explicitDirect"] = "true"
            await engine.play(spec: spec)
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while ContinuousClock.now < deadline,
                  engine.nativePropertyJSON("video-format")?.contains("h264") != true || (Double(engine.nativePropertyJSON("time-pos") ?? "") ?? 0) <= 0.2,
                  state.errorMessage == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(state.errorMessage == nil)
            #expect(engine.nativePropertyJSON("video-format")?.contains("h264") == true)
            let progressed = Double(engine.nativePropertyJSON("time-pos") ?? "") ?? 0
            #expect(progressed > 0.2)
            if let directory = ProcessInfo.processInfo.environment["NETVPLAYER_WEB_RULE_EVIDENCE_DIR"] {
                let data = try JSONSerialization.data(withJSONObject: ["H264": true, "playback_seconds": progressed], options: [.sortedKeys])
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-progress.safe.json"), options: .withoutOverwriting)
            }
            await provider.shutdown()
            try await server.save("real-spider-libmpv")
        } catch { await provider.shutdown(); throw error }
    }

    @Test func diagnosticsHashRuleScriptsAndRecordRejectedChecks() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        let base = ProcessInfo.processInfo.environment["NETVPLAYER_WEB_RULE_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("rule-diagnostic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            // Keep standalone CI failures actionable without logging URLs or scripts.
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
               let file = files.first, let data = try? Data(contentsOf: file),
               let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let events = report["events"] as? [[String: Any]] {
                print("Web media diagnostic stages: " + events.compactMap { $0["stage"] as? String }.joined(separator: ","))
            }
        }
        // Page-owned media can finish the session before didFinish runs its scripts.
        // Discover media from the second script so the first script's hash must
        // already be recorded, independent of WebKit's page-load timing.
        let scripts = ["window.privateRule='rule-secret'",
                       "fetch('/decoy/movie.mp4'); fetch('/stream/opaque')"]
        let policy = WebMediaPolicy(rules: [Rule(hosts: ["127.0.0.1"], script: scripts)], check: { $0.contains("/stream/opaque") })
        // This test also runs alone, before WebKit's processes have been started.
        let spec = try await WebViewSniffer(diagnosticDirectory: directory).sniff(url: server.url("/page/frame"), timeout: 10, policy: policy)
        #expect(spec.url == server.url("/stream/opaque"))
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: file)
        let text = String(data: data, encoding: .utf8)!
        #expect(!text.contains("rule-secret") && !text.contains(server.url("")))
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(report["events"] as? [[String: Any]])
        #expect(report["schema"] as? Int == 7 && events.count <= 128)
        #expect(events.contains { $0["stage"] as? String == "mediaCheck" && $0["accepted"] as? Bool == false })
        #expect(events.contains { $0["stage"] as? String == "mediaCheck" && $0["accepted"] as? Bool == true })
        #expect(events.contains { $0["stage"] as? String == "ruleScript" && $0["index"] as? Int == 0 && ($0["scriptSHA256"] as? String)?.count == 64 })
    }


    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_WEB_RULE_RUNTIME_FIXTURE"] != nil))
    func queuedSpiderCheckMustNotExecuteAfterCacheInvalidation() async throws {
        let server = try RuleLoopbackServer()
        defer { server.stop() }
        let (provider, site, state) = try makeProvider(server: server, mode: "custom")
        do {
            _ = try await provider.playerContent(site: site, flag: "line", id: "first")
            let policy = try await provider.webMediaPolicy(site: site, rules: [])
            let held = Task { try await provider.homeContent(site: site) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline, try !providerCalls(state).contains("home-held") {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(providerCalls(state).contains("home-held"))
            let queued = Task { try await policy.accepts(server.url("/stream/opaque?raw=a%2Fb+%20")) }
            try await Task.sleep(for: .milliseconds(50))
            await provider.clearContentCache()
            _ = try await held.value
            do { _ = try await queued.value; Issue.record("queued stale check succeeded") } catch { }
            await provider.shutdown()
            let calls = try providerCalls(state)
            #expect(!calls.contains { $0.hasPrefix("manual:") || $0.hasPrefix("format:") })
        } catch { await provider.shutdown(); throw error }
    }

    private func makeProvider(server: RuleLoopbackServer, mode: String) throws -> (DevelopmentAndroidSiteProvider, Site, URL) {
        let root = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_WEB_RULE_RUNTIME_FIXTURE"])
        let runtime = try DevelopmentAndroidRuntimeLayout.load(root: URL(fileURLWithPath: root))
        let stateRoot = ProcessInfo.processInfo.environment["NETVPLAYER_WEB_RULE_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let state = stateRoot.appendingPathComponent("spider-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let ext = String(data: try JSONSerialization.data(withJSONObject: ["base": server.url(""), "mode": mode], options: [.sortedKeys]), encoding: .utf8)!
        let site = Site(key: "RuleSpiderFixture", name: "Offline fixture", type: 3, api: "csp_WebMediaContractGuard", ext: ext)
        let provider = DevelopmentAndroidSiteProvider(runtime: runtime, binding: try #require(runtime.manifest.bindings.first), stateDirectory: state)
        return (provider, site, state)
    }

    private func providerCalls(_ state: URL) throws -> [String] {
        let files = FileManager.default.enumerator(at: state, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "web-media-calls.log" }
        return try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init) }
    }

}

private actor RuleCheckCalls {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

@MainActor
private final class RuleLoopbackServer {
    private let process: Process
    private let port: Int
    init() throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        guard let text = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8),
              let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate(); throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }
    func url(_ path: String) -> String { "http://127.0.0.1:\(port)" + path }
    func stop() { #expect(stopOwnedFixtureProcess(process)) }
    func save(_ name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["NETVPLAYER_WEB_RULE_EVIDENCE_DIR"] else { return }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: URL(string: url("/records"))!)
        let file = URL(fileURLWithPath: path).appendingPathComponent(name + "-" + UUID().uuidString + ".json")
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private static let script = #"""
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import json,time,threading,os
fixture=os.environ.get("NETVPLAYER_FEATURE_FIXTURE")
records=[]
lock=threading.Lock()
media='/stream/opaque?raw=a%2Fb+%20'
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  path=self.path.split('?')[0]
  if path=='/records':
   with lock:payload=json.dumps(records).encode()
   content='application/json'
  else:
   with lock:records.append({'path':self.path,'headers':dict(self.headers)})
   content='text/html';body='<html><body>'
   if path=='/page/opaque':body+='<script>fetch("'+media+'")</script>'
   elif path=='/page/spider':body+='<video src="/decoy/movie.mp4"></video><script>setTimeout(()=>{let x=new XMLHttpRequest();x.open("GET","'+media+'");x.send()},150)</script>'
   elif path=='/page/frame':body+='<iframe></iframe>'
   elif path=='/page/script':body+='<img src="/slow.png"><script>window.addEventListener("load",()=>window.loaded=true)</script>'
   elif path=='/slow.png':time.sleep(.25)
   elif path.startswith('/stream/'):body='local-original-contract';content='text/plain'
   body+='</body></html>' if content=='text/html' else ''
   payload=open(fixture,'rb').read() if path.startswith('/stream/') and fixture else body.encode()
   if path.startswith('/stream/') and fixture:content='video/mp4'
  self.send_response(200);self.send_header('Content-Type',content);self.send_header('Content-Length',str(len(payload)));self.end_headers()
  try:self.wfile.write(payload)
  except (BrokenPipeError,ConnectionResetError):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""#
}
