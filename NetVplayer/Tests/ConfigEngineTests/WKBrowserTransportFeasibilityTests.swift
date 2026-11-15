import CryptoKit
import Foundation
import Testing
import WebKit

/// Architectural evidence only. No product sniffer/PlaySpec or Cookie policy is changed.
/// The browser reads finite response bytes in their original origin. This is not
/// per-request header observation or proof that arbitrary media can be replayed.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil && ProcessInfo.processInfo.environment["NETVPLAYER_LIBMPV_PATH"] != nil))
@MainActor
struct WKBrowserTransportFeasibilityTests {
    @Test func dynamicHttpOnlyResponseCanReachLocalPlayerWithoutCopyingCookies() async throws {
        let h = try WKTransportFixture(); defer { h.stop() }
        let b = try await h.browser("dynamic"); defer { b.retire() }
        let response = try await b.fetch(h.url("/media/body.mp4", "dynamic"))
        #expect(response.status == 200 && response.type == "basic" && response.documentCookie.isEmpty)
        let original = try Data(contentsOf: h.media)
        #expect(response.body == original)
        let row = try #require(try await h.rows("dynamic").first { $0.path == "/media/body.mp4" })
        #expect(row.headers["cookie"] == "account=fresh")
        try await h.play(response.body)
        try h.record("dynamic", response: response, extra: ["playerDecoded": true])
    }

    @Test func browserRecomputesCookiesOnRedirectAndAfterRotation() async throws {
        let h = try WKTransportFixture(); defer { h.stop() }
        let b = try await h.browser("redirect"); defer { b.retire() }
        let target = h.url("/media/final.mp4", "redirect", ["expect": "redirected"])
        let response = try await b.fetch(h.url("/media/redirect", "redirect", ["target": target, "rotate": "1"]))
        #expect(response.status == 200 && response.url == target)
        let media = try await h.rows("redirect").filter { $0.path?.hasPrefix("/media/") == true }
        #expect(media.map { $0.headers["cookie"] ?? "" } == ["account=fresh", "account=redirected"])
        _ = try await b.fetch(h.url("/rotate", "redirect"))
        let current = try await b.fetch(h.url("/media/rotated.mp4", "redirect", ["expect": "second"]))
        #expect(current.status == 200)
        let cross = h.url("/media/cross.mp4", "redirect", ["expect": "", "cors": "allow"], host: "sibling.example.test")
        let landed = try await b.fetch(h.url("/media/redirect", "redirect", ["target": cross]))
        #expect(landed.status == 200 && landed.url == cross)
        #expect(try await h.rows("redirect").last?.headers["cookie"] == nil)
        try h.record("redirect", response: landed)
    }

    @Test func corsDenialsAndOpaqueResponsesCannotAuthorizeBodyTransfer() async throws {
        let h = try WKTransportFixture(); defer { h.stop() }
        let b = try await h.browser("cors"); defer { b.retire() }
        let token = ["headers": ["X-Local-Token": "synthetic"]]
        let allowed = try await b.fetch(h.url("/media/allow.mp4", "cors-allow", ["expect": "", "cors": "allow"], host: "sibling.example.test"), options: token)
        #expect(allowed.status == 200 && !allowed.body.isEmpty)
        let denied = try await b.fetch(h.url("/media/denied.mp4", "cors-preflight", ["expect": "", "cors": "preflight-deny"], host: "sibling.example.test"), options: token)
        #expect(denied.error == "TypeError" && denied.body.isEmpty)
        let preflight = try await h.rows("cors-preflight")
        #expect(preflight.map(\.method) == ["OPTIONS"] && preflight.first?.status == 403)
        let responseDenied = try await b.fetch(h.url("/media/response.mp4", "cors-response", ["expect": ""], host: "sibling.example.test"))
        #expect(responseDenied.error == "TypeError" && responseDenied.body.isEmpty)
        #expect(try await h.rows("cors-response").contains { $0.method == "GET" && $0.status == 200 })
        let opaque = try await b.fetch(h.url("/media/opaque.mp4", "cors-opaque", ["expect": ""], host: "sibling.example.test"), options: ["mode": "no-cors"])
        #expect(opaque.type == "opaque" && opaque.status == 0 && opaque.body.isEmpty)
        try h.record("cors-denials", response: denied, extra: ["opaqueStatus": opaque.status, "responseDeniedError": responseDenied.error ?? ""])
    }

    @Test func cacheStorageReadsOldResponseAfterCookieRotationWithoutNewRequest() async throws {
        let h = try WKTransportFixture(); defer { h.stop() }
        let b = try await h.browser("cache"); defer { b.retire() }
        let value = try await b.script("""
        const cache = await caches.open('local-finite');
        const response = await fetch(target, {credentials:'include'});
        await cache.put(target,response.clone()); const first = await response.text();
        await fetch('/rotate'); const second = await (await cache.match(target)).text();
        return {first,second};
        """, arguments: ["target": h.url("/media/cache", "cache", ["payload": "cookie"])])
        #expect(value["first"] as? String == "account=fresh" && value["second"] as? String == "account=fresh")
        #expect(try await h.rows("cache").filter { $0.path == "/media/cache" }.count == 1)
        let current = try await b.fetch(h.url("/media/current.mp4", "cache", ["expect": "second"]))
        #expect(current.status == 200)
        try h.record("cache", response: current, extra: value)
    }

    @Test func omittedCredentialsAndRangeRemainBrowserDecisions() async throws {
        let h = try WKTransportFixture(); defer { h.stop() }
        let b = try await h.browser("omit-range"); defer { b.retire() }
        let omitted = try await b.fetch(h.url("/media/omit.mp4", "omit-range", ["expect": ""]), options: ["credentials": "omit"])
        #expect(omitted.status == 200)
        let ranged = try await b.fetch(h.url("/media/range.mp4", "omit-range"), options: ["headers": ["Range": "bytes=1-2"]])
        let expectedRange = try Data(contentsOf: h.media).subdata(in: 1..<3)
        #expect(ranged.status == 206 && ranged.body == expectedRange)
        let rows = try await h.rows("omit-range")
        #expect(rows.first { $0.path == "/media/omit.mp4" }?.headers["cookie"] == nil)
        #expect(rows.first { $0.path == "/media/range.mp4" }?.headers["range"] == "bytes=1-2")
        try h.record("range", response: ranged)
    }

    @Test func abortAndRetirementPreventLateRedirectAndCookieReuse() async throws {
        let h = try WKTransportFixture(); defer { h.stop() }
        let b = try await h.browser("abort")
        let target = h.url("/media/late.mp4", "abort")
        _ = try await b.script("window.controller=new AbortController();window.pending=fetch(target,{signal:controller.signal}).then(r=>r.arrayBuffer()).then(()=>({unexpected:true}),e=>({error:e.name}));return {};", arguments: ["target": h.url("/media/hold", "abort", ["target": target])])
        try await h.wait { try await h.rows("abort").contains { $0.path == "/media/hold" } }
        let aborted = try await b.script("controller.abort();return await pending;")
        #expect(aborted["error"] as? String == "AbortError")
        try await h.release("abort")
        #expect(try await h.rows("abort").allSatisfy { $0.path != "/media/late.mp4" })
        b.retire()
        let held = try await h.browser("retire")
        _ = try await held.script("void fetch(target).catch(()=>{});return {};", arguments: ["target": h.url("/media/hold", "retire", ["target": h.url("/media/late.mp4", "retire")])])
        try await h.wait { try await h.rows("retire").contains { $0.path == "/media/hold" } }
        held.retire()
        try await h.release("retire")
        let next = try await h.browser("replacement", seed: false); defer { next.retire() }
        let response = try await next.fetch(h.url("/media/new.mp4", "replacement", ["expect": ""]))
        #expect(response.status == 200)
        #expect(try await h.rows("replacement").last?.headers["cookie"] == nil)
        #expect(try await h.rows("retire").allSatisfy { $0.path != "/media/late.mp4" })
        try h.record("retirement", response: response, extra: ["oldAborted": true])
    }
}

private struct WKTransportRow: Decodable {
    let kind: String
    let host: String?
    let path: String?
    let method: String?
    let status: Int?
    let headers: [String: String]
}

private struct WKTransportResponse {
    let status: Int
    let type: String
    let url: String
    let body: Data
    let documentCookie: String
    let error: String?
}

@MainActor
private final class WKTransportBrowser: SeedBrowser {
    let browser: WKWebView
    var active = true
    init(fixture: SeedScopeFixture) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        fixture.configure(config.websiteDataStore)
        browser = WKWebView(frame: .zero, configuration: config)
        super.init(certificate: fixture.certificate)
        browser.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { result = "ready" }
    func script(_ code: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        guard active else { throw CancellationError() }
        let value = try await browser.callAsyncJavaScript(code, arguments: arguments, in: nil, contentWorld: .page)
        guard active else { throw CancellationError() }
        return try #require(value as? [String: Any])
    }
    func fetch(_ url: String, options: [String: Any] = [:]) async throws -> WKTransportResponse {
        let r = try await script("""
        try {
          const response = await fetch(target,{credentials:'include',...options});
          // Finite capability proof only: no unbounded whole-media buffering.
          const reader = response.body?.getReader();let chunks=[],length=0;
          if(reader)while(true){const {done,value}=await reader.read();if(done)break;
            length+=value.length;if(length>1024*1024){await reader.cancel();throw Error('finite body limit');}chunks.push(value);}
          const body=new Uint8Array(length);let offset=0;for(const c of chunks){body.set(c,offset);offset+=c.length;}
          return {status:response.status,type:response.type,url:response.url,body:Array.from(body),documentCookie:document.cookie};
        } catch(e){return {error:e.name,status:0,type:'error',url:target,body:[],documentCookie:document.cookie};}
        """, arguments: ["target": url, "options": options])
        return WKTransportResponse(status: r["status"] as? Int ?? 0, type: r["type"] as? String ?? "", url: r["url"] as? String ?? "",
                                   body: Data((r["body"] as? [NSNumber] ?? []).map(\.uint8Value)), documentCookie: r["documentCookie"] as? String ?? "", error: r["error"] as? String)
    }
    func retire() {
        active = false
        browser.stopLoading()
        browser.load(URLRequest(url: URL(string: "about:blank")!))
        browser.navigationDelegate = nil
    }
}

@MainActor
private final class WKTransportFixture {
    let fixture: SeedScopeFixture
    let media: URL
    var root: URL { fixture.root }
    init() throws {
        media = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"]))
        fixture = try SeedScopeFixture(scriptName: "browser_transport_fixture.py", evidenceEnvironment: "NETVPLAYER_BROWSER_TRANSPORT_EVIDENCE_DIR")
    }
    func stop() { fixture.stop() }
    func url(_ path: String, _ label: String, _ query: [String: String] = [:], host: String = "video.example.test") -> String {
        var c = URLComponents(string: "https://\(host)\(path)")!
        c.queryItems = (query.merging(["case": label]) { _, r in r }).sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!.absoluteString
    }
    func browser(_ label: String, seed: Bool = true) async throws -> WKTransportBrowser {
        let b = WKTransportBrowser(fixture: fixture)
        b.browser.load(URLRequest(url: URL(string: url("/page", label, ["seed": seed ? "1" : "0"]))!))
        try await wait {
            _ = try? await b.browser.evaluateJavaScript("void(0)")
            return b.result != nil
        }
        try #require(b.result == "ready", "navigation \(b.result ?? "none")")
        return b
    }
    func control(_ path: String = "records") async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/control/\(path)")!)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
    func rows(_ label: String) async throws -> [WKTransportRow] {
        let rows = try await control().filter { $0["kind"] as? String == "request" && $0["case"] as? String == label }
        return try JSONDecoder().decode([WKTransportRow].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    func wait(_ body: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await body() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }
    func release(_ label: String) async throws {
        _ = try await control("release?id=" + label)
        try await wait { try await self.control().contains { $0["kind"] as? String == "gate-drained" && $0["case"] as? String == label } }
    }
    func record(_ name: String, response: WKTransportResponse, extra: [String: Any] = [:]) throws {
        let row: [String: Any] = ["name": name, "status": response.status, "type": response.type, "bytes": response.body.count,
                                 "bodySHA256": SHA256.hash(data: response.body).map { String(format: "%02x", $0) }.joined(),
                                 "headersObserved": false, "automaticCookieCopied": false, "extra": extra]
        try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent(name + ".safe.json"))
    }
    func play(_ body: Data) async throws {
        let dir = root.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let token = String(repeating: "a", count: 64)
        let file = dir.appendingPathComponent(token + ".mp4")
        try body.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var repo = URL(fileURLWithPath: #filePath);for _ in 0..<4 { repo.deleteLastPathComponent() }
        let spoolURL = "http://127.0.0.1:\(fixture.port)/spool/" + token
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-B", repo.appendingPathComponent("script/fixtures/web-transport/probe_browser_spool_player.py").path,
                          "--library", try #require(ProcessInfo.processInfo.environment["NETVPLAYER_LIBMPV_PATH"]), "--url", spoolURL]
        let output = root.appendingPathComponent("player.stdout"), error = root.appendingPathComponent("player.stderr")
        for p in [output, error] { FileManager.default.createFile(atPath: p.path, contents: nil) }
        task.standardOutput = try FileHandle(forWritingTo: output); task.standardError = try FileHandle(forWritingTo: error)
        try task.run(); task.waitUntilExit()
        let stderr = try String(contentsOf: error, encoding: .utf8)
        try #require(task.terminationStatus == 0, "player: \(stderr)")
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("browser-response.mp4"))
        let (_, response) = try await URLSession.shared.data(from: URL(string: spoolURL)!)
        #expect((response as? HTTPURLResponse)?.statusCode == 410)
    }
}
