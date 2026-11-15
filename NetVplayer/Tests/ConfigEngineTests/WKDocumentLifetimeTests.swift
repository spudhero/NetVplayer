import Foundation
import Testing
import WebKit

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_WK_DOCUMENT_LIFETIME_EVIDENCE_DIR"] != nil))
@MainActor
struct WKDocumentLifetimeTests {
    private struct Receipt { let pages: [[String: Any]]; let mediaRequests: Int; let commits: Int; let outcome: [String: Any] }
    private let expected = Data(repeating: 115, count: 32768) + Data(repeating: 116, count: 32768)

    private func observe(_ scenario: String, candidate: Bool, rawFragment: Bool = false) async throws -> Receipt {
        let variant = rawFragment ? "raw-fragment" : (candidate ? "candidate" : "control"), label = scenario + "-" + variant
        let fixture = try SeedScopeFixture(scriptName: "wk_document_lifetime_fixture.py",
            evidenceEnvironment: "NETVPLAYER_WK_DOCUMENT_LIFETIME_EVIDENCE_DIR")
        defer { fixture.stop() }
        let source = try String(contentsOf: OriginalResponseFixture.tools.appendingPathComponent("wk_fetch_lifetime_observer.js"), encoding: .utf8)
        let suppressedPagehide = scenario == "navigation"
        let browser = try DocumentLifetimeBrowser(fixture: fixture, observer: candidate ? source : "",
            nativeGuard: candidate, hold: suppressedPagehide, suppressPagehide: suppressedPagehide, normalizeFragment: !rawFragment)
        defer { browser.close() }
        var components = URLComponents(string: "https://video.example.test/lifetime/page")!
        components.queryItems = [URLQueryItem(name: "case", value: label), URLQueryItem(name: "hold", value: "1")]
        let originalURL = try #require(components.url)
        browser.web.load(URLRequest(url: originalURL))
        try await wait { browser.commits == 1 && browser.finishes == 1 }
        try await wait { try await self.rows(fixture).contains { $0["kind"] as? String == "first-block" } }
        if candidate {
            try await wait { browser.sink.events.contains { $0["event"] as? String == "chunk" } }
            if suppressedPagehide { try #require(browser.sink.pending.count == 1) }
        }
        let originalCapability = browser.sink.transfers.keys.first ?? "not-admitted-in-control"
        let began = ProcessInfo.processInfo.systemUptime
        switch scenario {
        case "navigation":
            browser.web.load(URLRequest(url: URL(string: "https://video.example.test/lifetime/destination")!))
            try await wait { browser.commits == 2 && browser.finishes == 2 }
        case "reload":
            browser.web.reload()
            try await wait { browser.commits == 2 && browser.finishes == 2 }
            try await wait { try await self.rows(fixture).filter { $0["kind"] as? String == "first-block" }.count == 2 }
        case "fragment":
            _ = try await browser.web.evaluateJavaScript("location.hash = 'same-document'")
            try await wait { browser.web.url?.fragment == "same-document" }
            try #require(browser.commits == 1 && browser.provisionalStarts == 1)
        case "failure":
            browser.web.load(URLRequest(url: URL(string: "https://video.example.test/lifetime/fail-before-headers")!))
            try await wait { !browser.failures.isEmpty }
            try #require(browser.commits == 1)
        default: throw URLError(.unsupportedURL)
        }
        let cleanupSeconds = ProcessInfo.processInfo.systemUptime - began
        let beforeRelease: [String: Any] = ["active": browser.sink.active, "transfers": browser.sink.transfers.count,
            "pending": browser.sink.pending.count, "bytes": browser.sink.retainedBytes,
            "nativeRetirements": browser.nativeRetirements, "secondsAfterNavigationAction": cleanupSeconds]
        var oldCapabilityRejected = false
        if candidate && scenario != "fragment" {
            try #require(browser.nativeRetirements == 1 && !browser.sink.active)
            try #require(browser.sink.transfers.isEmpty && browser.sink.pending.isEmpty && browser.sink.retainedBytes == 0)
            try #require(browser.sink.completed.isEmpty && cleanupSeconds < 10)
            try #require(browser.sink.events.contains { $0["event"] as? String == "cancel" && $0["reason"] as? String == "session-retired" })
            let rejected = try await browser.web.callAsyncJavaScript("""
            try { await webkit.messageHandlers.responseClone.postMessage({session,op:'chunk',cap,seq:0,offset:0,data:'c3M='});return false; }
            catch(error) { return String(error).includes('retired-session'); }
            """, arguments: ["session": browser.sink.session, "cap": originalCapability], in: nil, contentWorld: .page)
            oldCapabilityRejected = rejected as? Bool == true
            try #require(oldCapabilityRejected)
        } else if candidate {
            try #require(browser.nativeRetirements == 0 && browser.sink.active && browser.sink.transfers.count == 1)
        }
        let heldRows = try await rows(fixture)
        try #require(!heldRows.contains { $0["kind"] as? String == "gate-release" })
        if scenario == "fragment" || scenario == "reload" {
            try #require(try await browser.web.evaluateJavaScript("pageSettled") as? Bool == false)
        }
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/control/release?id=\(label)-0")!)
        var pages: [[String: Any]] = []
        var outcome: [String: Any] = ["status": "discarded-document"]
        if scenario != "navigation" {
            let value = try await browser.web.callAsyncJavaScript("""
            try { return {status:'fulfilled',pages:await pagePending,headers:__pageHeaders}; }
            catch(error) { return {status:'rejected',errorName:error.name,errorMessage:error.message,headers:__pageHeaders}; }
            """, arguments: [:], in: nil, contentWorld: .page)
            outcome = try #require(value as? [String: Any])
            let headers = try #require(outcome["headers"] as? [[String: Any]])
            try #require(headers.count == 1)
            let header = try #require(headers.first)
            try #require(header["sameNativePromise"] as? Bool == true && header["sameNativeResponse"] as? Bool == true)
            try #require(header["bodyUsedBefore"] as? Bool == false && header["status"] as? Int == 200)
            try #require(header["documentCookie"] as? String == "")
            if scenario == "failure" {
                try #require(outcome["status"] as? String == "rejected" && outcome["errorName"] as? String == "TypeError")
            } else {
                try #require(outcome["status"] as? String == "fulfilled")
                pages = try #require(outcome["pages"] as? [[String: Any]])
                try #require(pages.count == 1)
            let page = try #require(pages.first)
            try #require(page["sameNativePromise"] as? Bool == true && page["sameNativeResponse"] as? Bool == true)
            try #require(page["bodyUsedBefore"] as? Bool == false && page["bodyUsedAfter"] as? Bool == true)
            try #require(page["secondReadError"] as? String == "TypeError" && page["status"] as? Int == 200)
            try #require(page["bytes"] as? Int == expected.count && page["sha256"] as? String == DocumentResponseSink.hash(expected))
            try #require(page["documentCookie"] as? String == "")
            }
        }
        if candidate && scenario == "fragment" {
            if rawFragment {
                try await wait { browser.sink.events.contains { $0["event"] as? String == "rejected-capability" } }
                try #require(browser.sink.completed.isEmpty && browser.sink.transfers.count == 1)
            } else {
                try await wait { browser.sink.completed.count == 1 }
                try #require(try browser.sink.bytes(browser.sink.completed[0]) == expected)
            }
        }
        let mediaCount = scenario == "reload" ? 2 : 1
        try await wait { try await self.rows(fixture).filter { $0["kind"] as? String == "gate-drained" }.count == mediaCount }
        let records = try await rows(fixture), requests = records.filter { $0["kind"] as? String == "request" }
        let media = requests.filter { $0["path"] as? String == "/media/lifetime" }
        try #require(media.count == mediaCount && media.allSatisfy { $0["cookie"] as? String == "account=fresh" })
        try #require(requests.allSatisfy { $0["tls"] as? Bool == true && $0["host"] as? String == "video.example.test" })
        try #require(!records.contains { ["proxy-denied", "tls-rejected"].contains($0["kind"] as? String ?? "") })
        try #require(records.filter { $0["kind"] as? String == "gate-release" }.allSatisfy { $0["explicit_release"] as? Bool == true })
        try browser.sink.snapshot(to: fixture.root.appendingPathComponent(label + ".capture.json"), extra: [
            "scenario": scenario, "variant": variant, "beforeRelease": beforeRelease, "pages": pages,
            "originalPageOutcome": outcome, "rawFragmentURLBinding": rawFragment,
            "committedDocuments": browser.commits, "provisionalStarts": browser.provisionalStarts,
            "provisionalFailures": browser.failures, "nativeRetirements": browser.nativeRetirements,
            "pagehideHandlerIntentionallySuppressed": suppressedPagehide && candidate,
            "oldCapabilityRejected": oldCapabilityRejected, "nativeLifetimeMilliseconds": 30000,
            "observerLifetimeMilliseconds": 30000, "mediaRequests": mediaCount,
            "oneDocumentCaptureScope": true, "automaticRearmInNewDocument": false,
            "fullOriginalBodyClaimedForDiscardedDocument": false,
            "uniqueNativeFrameIdentityClaimed": false])
        let commits = browser.commits
        browser.close()
        try #require(browser.sink.retainedBytes == 0 && browser.sink.transfers.isEmpty && browser.sink.pending.isEmpty)
        let liveFiles = try FileManager.default.contentsOfDirectory(atPath: browser.sink.root.path)
        try #require(liveFiles.isEmpty)
        return Receipt(pages: pages, mediaRequests: mediaCount, commits: commits, outcome: outcome)
    }

    private func compare(_ scenario: String) async throws {
        let control = try await observe(scenario, candidate: false)
        if scenario == "fragment" {
            let raw = try await observe(scenario, candidate: true, rawFragment: true)
            #expect(try JSONSerialization.data(withJSONObject: raw.outcome, options: .sortedKeys)
                == JSONSerialization.data(withJSONObject: control.outcome, options: .sortedKeys))
        }
        let candidate = try await observe(scenario, candidate: true)
        #expect(try JSONSerialization.data(withJSONObject: control.outcome, options: .sortedKeys)
            == JSONSerialization.data(withJSONObject: candidate.outcome, options: .sortedKeys))
        #expect(control.mediaRequests == candidate.mediaRequests && control.commits == candidate.commits)
    }
    @Test func actualNavigationRetiresHeldReplyWithoutPagehideHandler() async throws { try await compare("navigation") }
    @Test func actualSameURLReloadRejectsOldCapability() async throws { try await compare("reload") }
    @Test func fragmentNavigationKeepsOriginalDocumentCapture() async throws { try await compare("fragment") }
    @Test func failedProvisionalNavigationMatchesOriginalFetchRejection() async throws { try await compare("failure") }

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
private final class DocumentLifetimeBrowser: SeedBrowser {
    let web: WKWebView, sink: DocumentResponseSink
    private let nativeGuard: Bool
    private var closed = false
    private(set) var commits = 0, finishes = 0, provisionalStarts = 0, nativeRetirements = 0
    private(set) var failures: [Int] = []

    init(fixture: SeedScopeFixture, observer: String, nativeGuard: Bool, hold: Bool, suppressPagehide: Bool, normalizeFragment: Bool) throws {
        self.nativeGuard = nativeGuard
        sink = try DocumentResponseSink(root: fixture.root.appendingPathComponent("spool"), normalizeFragment: normalizeFragment)
        sink.lifetimeMilliseconds = 30000; sink.holdAcknowledgements = hold
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); fixture.configure(config.websiteDataStore)
        config.userContentController.addScriptMessageHandler(sink, contentWorld: .page, name: "responseClone")
        let probe = """
        (()=>{const raw=fetch,apply=Reflect.apply,then=Promise.prototype.then;window.__lifetimeNative=[];
          window.fetch=function(...args){const p=apply(raw,this,args),row={promise:p,response:null};window.__lifetimeNative.push(row);
            void apply(then,p,[r=>{row.response=r},()=>{}]);return p};})();
        """
        var candidate = observer.replacingOccurrences(of: "__SESSION__", with: sink.session)
            .replacingOccurrences(of: "__CAPTURE_LIFETIME_MS__", with: "30000")
        if suppressPagehide && !observer.isEmpty {
            let hook = "apply(addEvent, window, ['pagehide', () => { for (const stop of active) stop('pagehide'); }]);"
            guard candidate.contains(hook) else { throw URLError(.cannotParseResponse) }
            candidate = candidate.replacingOccurrences(of: hook, with: "/* Fixture fault injection: pagehide callback unavailable. */")
        }
        for source in [probe, candidate] where !source.isEmpty {
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        web = WKWebView(frame: .zero, configuration: config)
        super.init(certificate: fixture.certificate); web.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        provisionalStarts += 1
        if nativeGuard && commits > 0 && sink.active {
            nativeRetirements += 1; sink.retire()
        }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { commits += 1 }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishes += 1 }
    override func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failures.append((error as NSError).code)
    }
    func close() {
        guard !closed else { return }; closed = true
        sink.retire(); web.stopLoading(); web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "responseClone", contentWorld: .page)
    }
}
