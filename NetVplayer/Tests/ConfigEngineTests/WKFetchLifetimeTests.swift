import Foundation
import Testing
import WebKit

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_WK_FETCH_LIFETIME_EVIDENCE_DIR"] != nil))
@MainActor
struct WKFetchLifetimeTests {
    private struct Receipt { let pages: [[String: Any]]; let beforeRelease: [String: Int] }
    private let expected = Data(repeating: 115, count: 32768) + Data(repeating: 116, count: 32768)

    private func observe(_ label: String, variant: String, scenario: String) async throws -> Receipt {
        let fixture = try SeedScopeFixture(scriptName: "wk_fetch_lifetime_fixture.py", evidenceEnvironment: "NETVPLAYER_WK_FETCH_LIFETIME_EVIDENCE_DIR")
        defer { fixture.stop() }
        let count = scenario == "quota" ? 3 : 1
        let immediate = scenario == "finite"
        let deadline = scenario == "quota" ? 1000 : 200
        let lifetime = immediate ? 3000 : deadline * 3
        let filename = variant == "candidate" ? "wk_fetch_lifetime_observer.js" : "wk_response_intrinsics_observer.js"
        let source = variant == "control" ? "" : try String(contentsOf: OriginalResponseFixture.tools.appendingPathComponent(filename), encoding: .utf8)
        let browser = try FetchLifetimeBrowser(fixture: fixture, observer: source, deadline: deadline,
                                              lifetime: lifetime, hold: scenario == "ack")
        defer { browser.retire() }
        var components = URLComponents(string: "https://video.example.test/lifetime/page")!
        components.queryItems = [URLQueryItem(name: "case", value: label), URLQueryItem(name: "count", value: String(count)),
                                URLQueryItem(name: "hold", value: immediate ? "0" : "1")]
        browser.web.load(URLRequest(url: components.url!))
        try await wait { _ = try? await browser.web.evaluateJavaScript("void(0)"); return browser.result != nil }
        try #require(browser.result == "ready")
        try await wait { try await self.rows(fixture).filter { $0["kind"] as? String == "first-block" }.count == count }
        var probe: [String: Int] = [:]
        if !immediate {
            if variant != "control" {
                try await wait { browser.sink.events.contains { $0["event"] as? String == "chunk" } }
                if scenario == "pagehide" {
                    _ = try await browser.web.evaluateJavaScript("window.dispatchEvent(new Event('pagehide'))")
                }
                if variant == "candidate" {
                    let reason = scenario == "pagehide" ? "pagehide" : "local-capture-deadline"
                    try await wait { browser.sink.events.contains { $0["event"] as? String == "cancel" && $0["reason"] as? String == reason } }
                    try await wait { try await browser.probe()["releases"] == (scenario == "quota" ? 2 : 1) }
                } else {
                    try await wait { browser.sink.events.contains { $0["event"] as? String == "cancel" && $0["reason"] as? String == "expired" } }
                }
                try #require(browser.sink.transfers.isEmpty && browser.sink.pending.isEmpty && browser.sink.retainedBytes == 0)
                try #require(browser.sink.completed.isEmpty)
            }
            probe = try await browser.probe()
            try #require(try await browser.web.evaluateJavaScript("window.pageSettled") as? Bool == false)
            if variant == "candidate" {
                try #require(probe["pendingReads"] == 0)
                try #require(probe["readers"] == probe["releases"])
                try #require(probe["clones"] == (scenario == "quota" ? 2 : 1))
                try #require((probe["cancels"] ?? 0) >= 1)
                if scenario == "quota" { try #require(browser.sink.events.contains { $0["reason"] as? String == "local-capacity" }) }
            } else if variant == "baseline" {
                try #require(probe["clones"] == count)
                if scenario != "ack" { try #require((probe["pendingReads"] ?? 0) >= 1 && probe["releases"] == 0) }
            } else {
                try #require(probe.values.allSatisfy { $0 == 0 })
            }
            for index in 0..<count {
                _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/control/release?id=\(label)-\(index)")!)
            }
        }
        let value = try await browser.web.callAsyncJavaScript("return await pagePending;", arguments: [:], in: nil, contentWorld: .page)
        let pages = try #require(value as? [[String: Any]])
        try #require(pages.count == count)
        for page in pages {
            try #require(page["sameNativePromise"] as? Bool == true && page["sameNativeResponse"] as? Bool == true)
            try #require(page["bodyUsedBefore"] as? Bool == false && page["bodyUsedAfter"] as? Bool == true)
            try #require(page["secondReadError"] as? String == "TypeError" && page["status"] as? Int == 200)
            try #require(page["bytes"] as? Int == expected.count && page["sha256"] as? String == OriginalResponseSink.hash(expected))
            try #require(page["documentCookie"] as? String == "")
        }
        if immediate && variant != "control" {
            try await wait { browser.sink.completed.count == 1 }
            try #require(try browser.sink.bytes(browser.sink.completed[0]) == expected)
        }
        if variant != "control" {
            try await wait { let state = try await browser.probe(); return state["readers"] == state["releases"] }
        }
        let finalProbe = try await browser.probe()
        let receiver = try await rows(fixture)
        let requests = receiver.filter { $0["kind"] as? String == "request" }
        try #require(requests.count == count + 2)
        let media = requests.filter { $0["path"] as? String == "/media/lifetime" }
        try #require(media.count == count && media.allSatisfy { $0["cookie"] as? String == "account=fresh" })
        try #require(requests.allSatisfy { $0["host"] as? String == "video.example.test" && $0["tls"] as? Bool == true })
        try #require(!receiver.contains { ["proxy-denied", "tls-rejected"].contains($0["kind"] as? String ?? "") })
        if !immediate { try #require(receiver.filter { $0["kind"] as? String == "gate-release" }.allSatisfy { $0["explicit_release"] as? Bool == true }) }
        try browser.sink.snapshot(to: fixture.root.appendingPathComponent(label + ".capture.json"), extra: [
            "scenario": scenario, "variant": variant, "pages": pages, "beforeRelease": probe, "finalProbe": finalProbe,
            "localDeadlineMilliseconds": deadline, "nativeLifetimeMilliseconds": lifetime,
            "syntheticPagehideEvent": scenario == "pagehide", "actualHardNavigationClaimed": false,
            "wholeWebKitTeeQueueBoundedClaimed": false, "mediaRequests": count])
        browser.retire()
        try #require(browser.sink.retainedBytes == 0 && browser.sink.transfers.isEmpty && browser.sink.pending.isEmpty)
        let live = try FileManager.default.contentsOfDirectory(atPath: browser.sink.root.path)
        try #require(live.isEmpty)
        return Receipt(pages: pages, beforeRelease: probe)
    }

    private func compare(_ scenario: String) async throws {
        let control = try await observe(scenario + "-control", variant: "control", scenario: scenario)
        let baseline = try await observe(scenario + "-baseline", variant: "baseline", scenario: scenario)
        let candidate = try await observe(scenario + "-candidate", variant: "candidate", scenario: scenario)
        let reference = try JSONSerialization.data(withJSONObject: control.pages, options: .sortedKeys)
        #expect(try JSONSerialization.data(withJSONObject: baseline.pages, options: .sortedKeys) == reference)
        #expect(try JSONSerialization.data(withJSONObject: candidate.pages, options: .sortedKeys) == reference)
    }

    @Test func stalledReadRetiresWithoutWaitingForOriginalPage() async throws { try await compare("stall") }
    @Test func localCapacityRejectsThirdCloneBeforeAdmission() async throws { try await compare("quota") }
    @Test func deadlineReleasesCloneDuringHeldNativeAcknowledgement() async throws { try await compare("ack") }
    @Test func syntheticPagehideReleasesCloneWhilePageCanFinish() async throws { try await compare("pagehide") }
    @Test func finiteResponseStillCapturesExactlyAndRetires() async throws { try await compare("finite") }

    private func rows(_ fixture: SeedScopeFixture) async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/control/records")!)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<400 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw URLError(.timedOut)
    }
}

@MainActor
private final class FetchLifetimeBrowser: SeedBrowser {
    let web: WKWebView, sink: OriginalResponseSink
    private var active = true
    init(fixture: SeedScopeFixture, observer: String, deadline: Int, lifetime: Int, hold: Bool) throws {
        sink = try OriginalResponseSink(root: fixture.root.appendingPathComponent("spool"))
        sink.lifetimeMilliseconds = lifetime; sink.holdAcknowledgements = hold
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); fixture.configure(config.websiteDataStore)
        config.userContentController.addScriptMessageHandler(sink, contentWorld: .page, name: "responseClone")
        let probe = """
        (()=>{const apply=Reflect.apply,then=Promise.prototype.then;
          const s=window.__lifetimeProbe={clones:0,readers:0,reads:0,pendingReads:0,cancels:0,releases:0};
          const rawClone=Response.prototype.clone;
          Response.prototype.clone=function(...args){s.clones++;return apply(rawClone,this,args)};
          const get=ReadableStream.prototype.getReader,read=ReadableStreamDefaultReader.prototype.read;
          const cancel=ReadableStreamDefaultReader.prototype.cancel,release=ReadableStreamDefaultReader.prototype.releaseLock;
          ReadableStream.prototype.getReader=function(...args){const r=apply(get,this,args);s.readers++;return r};
          ReadableStreamDefaultReader.prototype.read=function(...args){const p=apply(read,this,args);s.reads++;s.pendingReads++;
            void apply(then,p,[()=>{s.pendingReads--},()=>{s.pendingReads--}]);return p};
          ReadableStreamDefaultReader.prototype.cancel=function(...args){s.cancels++;return apply(cancel,this,args)};
          ReadableStreamDefaultReader.prototype.releaseLock=function(...args){const value=apply(release,this,args);s.releases++;return value};
          const raw=fetch;window.__lifetimeNative=[];
          window.fetch=function(...args){const p=apply(raw,this,args),row={promise:p,response:null};window.__lifetimeNative.push(row);
            void apply(then,p,[r=>{row.response=r},()=>{}]);return p};
        })();
        """
        let candidate = observer.replacingOccurrences(of: "__SESSION__", with: sink.session)
            .replacingOccurrences(of: "__CAPTURE_LIFETIME_MS__", with: String(deadline))
        for source in [probe, candidate] where !source.isEmpty {
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        web = WKWebView(frame: .zero, configuration: config)
        super.init(certificate: fixture.certificate); web.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { result = "ready" }
    func probe() async throws -> [String: Int] {
        try #require(try await web.evaluateJavaScript("({...window.__lifetimeProbe})") as? [String: Int])
    }
    func retire() {
        guard active else { return }; active = false
        sink.retire(); web.stopLoading(); web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "responseClone", contentWorld: .page)
    }
}
