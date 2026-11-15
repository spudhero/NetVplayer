import AppKit
import Foundation
import Models
import Testing
import WebKit
@testable import ParseEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil))
@MainActor
struct WKRequestDedupTests {
    @Test func fetchHeaderReplacementSurvivesDelayedRejection() async throws { try await run("fetch", "headers") }
    @Test func xhrReopenHeaderReplacementSurvivesDelayedRejection() async throws { try await run("xhr", "headers") }
    @Test func fetchCredentialsChangeSurvivesDelayedRejection() async throws { try await run("fetch", "credentials") }
    @Test func xhrCredentialsChangeSurvivesDelayedRejection() async throws { try await run("xhr", "credentials") }
    @Test func fetchMethodChangePreservesOriginalBodyAndResponse() async throws { try await run("fetch", "method") }
    @Test func xhrMethodChangePreservesOriginalBodyAndResponse() async throws { try await run("xhr", "method") }
    @Test func equivalentHeaderOrderAndCaseDoNotRepeatChecks() async throws { try await run("fetch", "duplicate") }
    @Test func firstAcceptedContextIsNotReplacedWhileChecking() async throws { try await run("fetch", "first-accepted") }

    @Test func fetchAndXHRContextsAtSameURLStayDistinct() async throws { try await run("fetch", "source") }
    @Test func repeatedXHRHeadersDoNotRepeatChecks() async throws { try await run("xhr", "duplicate") }
    @Test func DOMObservationCannotSuppressLaterFetchContext() async throws { try await run("fetch", "dom-first") }
    @Test func DOMObservationCannotSuppressLaterXHRContext() async throws { try await run("xhr", "dom-first") }
    @Test func requestFloodHasBoundedChecksWhileOriginalRequestsComplete() async throws { try await run("fetch", "flood") }
    @Test func oversizedFetchContextIsBoundedWithoutChangingPageRequest() async throws { try await run("fetch", "oversize") }
    @Test func oversizedXHRContextIsBoundedWithoutChangingPageRequest() async throws { try await run("xhr", "oversize") }

    private func run(_ api: String, _ mode: String) async throws {
        let h = try ContextHarness(), gate = ContextGate(firstAccepted: mode == "first-accepted", flood: mode == "flood")
        defer { gate.release(); h.stop() }
        let label = api + "-" + mode
        let task = Task { try await h.sniffer.sniff(url: "https://video.example.test/context/page?case=" + label + "&api=" + api + "&mode=" + mode,
            timeout: mode == "flood" ? 20 : 15, policy: WebMediaPolicy(rules: [Rule(hosts: ["example.test"], regex: ["/context/media", "/context/fallback"])], check: { url in try await gate.check(url) })) }
        defer { task.cancel() }
        if mode == "oversize" {
            try await h.wait { h.delegate?.messages.contains { $0["stage"] as? String == "response" } == true }
        } else { try await h.wait { gate.pending != nil } }
        _ = try await h.browser?.evaluateJavaScript("window.advance(); void(0)")
        try await h.wait { h.delegate?.messages.contains { $0["stage"] as? String == "done" } == true }
        gate.release()
        var spec: PlaySpec?, failure: String?
        do { spec = try await task.value } catch { failure = String(describing: error) }
        let rows = try await h.rows()
        let done = try #require(h.delegate?.messages.first { $0["stage"] as? String == "done" })
        let responses = try #require(done["results"] as? [[String: Any]])
        let diagnostics = try h.diagnostics()
        let candidate = diagnostics.first { $0["stage"] as? String == "candidate" } ?? [:]
        let receipt = rows.filter { $0["path"] as? String == "/context/media" }
        let value: [String: Any] = ["api": api, "mode": mode, "calls": gate.calls, "spec": spec?.url ?? NSNull(),
            "headers": spec?.headers ?? [:], "error": failure ?? NSNull(), "done": done, "rows": rows,
            "candidate": candidate, "diagnostics": diagnostics, "attached": h.attached, "visible": h.visible]
        try h.save(label, value)
        #expect(mode == "flood" ? failure == "noMediaFound" : failure == nil)
        #expect(h.attached && !h.visible)
        #expect(rows.allSatisfy { $0["kind"] as? String != "proxy-denied" })
        #expect(receipt.count == responses.count)
        #expect(receipt.allSatisfy { $0["tls"] as? Bool == true })
        #expect(done["playCalls"] as? Int == 0)
        #expect(!rows.contains { $0["path"] as? String == "/context/fallback.mp4" })
        for response in responses {
            #expect(response["status"] as? Int == 200 && response["text"] as? String == "original-response")
            if response["api"] as? String == "fetch" {
                #expect(response["promise"] as? Bool == true && response["response"] as? Bool == true)
                #expect(response["bodyUsedBefore"] as? Bool == false && response["bodyUsedAfter"] as? Bool == true)
            } else { #expect(response["readyState"] as? Int == 4 && response["sendUndefined"] as? Bool == true) }
        }
        if mode == "credentials" {
            let cookies = receipt.compactMap { $0["headers"] as? [String: String] }.map { $0["cookie"] ?? "" }
            #expect(cookies == ["", "context=local"])
            #expect(spec?.headers.keys.contains { $0.lowercased() == "cookie" } == false)
        }
        if mode == "method" {
            #expect(receipt.map { $0["method"] as? String ?? "" } == ["POST", "GET"])
            #expect(receipt.first?["body_bytes"] as? Int == 13)
            #expect(responses.first?["api"] as? String != "fetch" || responses.first?["inputBodyUsed"] as? Bool == true)
        }
        let count = gate.calls.filter { $0.contains("/context/media?") }.count
        if mode == "flood" {
            #expect(count >= 500 && count <= 512)
            #expect(receipt.count == 520 && spec == nil)
            #expect(diagnostics.contains { $0["stage"] as? String == "discoveryLimit" && $0["reason"] as? String == "count" })
        } else if mode == "oversize" {
            #expect(count == 0 && receipt.count == 2)
            #expect(receipt.allSatisfy { ($0["headers"] as? [String: String])?["x-long"]?.count == 17000 })
            #expect(spec?.url.contains("/context/fallback.mp4") == true)
            #expect(diagnostics.contains { $0["stage"] as? String == "discoveryLimit" && $0["reason"] as? String == "contextSize" })
        } else if mode == "duplicate" {
            #expect(count == 1)
            #expect(spec?.url.contains("/context/fallback.mp4") == true)
        } else {
            #expect(count == (mode == "first-accepted" ? 1 : 2))
            #expect(spec?.url == done["url"] as? String)
            #expect(candidate["source"] as? String == (mode == "source" ? "xhr" : api))
            #expect(candidate["credentialsMode"] as? String == (mode == "credentials" ? "include" : "same-origin"))
            #expect(candidate["method"] as? String == "GET")
            if mode == "headers" || mode == "first-accepted" {
                #expect(spec?.headers.first { $0.key.lowercased() == "x-phase" }?.value == (mode == "headers" ? "second" : "first"))
                #expect(spec?.headers.first { $0.key.lowercased() == "authorization" }?.value == (mode == "headers" ? nil : "Local first"))
            }
        }
        weak var retiredBrowser = h.browser
        weak var retiredWindow = h.browser?.window
        h.cleanup()
        try await h.wait { retiredBrowser == nil && retiredWindow == nil }
    }
}

@MainActor
private final class ContextGate {
    let firstAccepted: Bool
    let flood: Bool
    var pending: CheckedContinuation<Void, Never>?
    var calls: [String] = []
    init(firstAccepted: Bool, flood: Bool) { self.firstAccepted = firstAccepted; self.flood = flood }
    func check(_ url: String) async throws -> Bool? {
        guard URL(string: url)?.path.hasPrefix("/context/media") == true || url.contains("/context/fallback.mp4") else { return false }
        calls.append(url)
        if calls.count == 1 && url.contains("/context/media?") {
            // Intentionally ignores cancellation, like an in-flight Spider callback.
            await withCheckedContinuation { pending = $0 }
            return firstAccepted
        }
        if flood { return false }
        return nil // Exercise the real shared Rule fallback on the queued context.
    }
    func release() { pending?.resume(); pending = nil }
}

@MainActor
private final class ContextDelegate: SeedBrowser {
    weak var target: (any WKNavigationDelegate)?
    var messages: [[String: Any]] = []
    override func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? [String: Any] { messages.append(value) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) { target?.webView?(webView, decidePolicyFor: action, decisionHandler: decisionHandler) ?? decisionHandler(.allow) }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { target?.webView?(webView, didStartProvisionalNavigation: navigation) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { target?.webView?(webView, didCommit: navigation) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { target?.webView?(webView, didFinish: navigation) }
    override func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { target?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { target?.webView?(webView, didFail: navigation, withError: error) }
}

@MainActor
private final class ContextHarness {
    let fixture: SeedScopeFixture
    var browser: WKWebView?
    var delegate: ContextDelegate?
    var attached = false, visible = false
    lazy var sniffer = WebViewSniffer(diagnosticDirectory: fixture.root, configureBrowser: { [weak self] web in
        guard let self else { return }; browser = web; attached = web.window != nil; visible = web.window?.isVisible ?? false
        let d = ContextDelegate(certificate: fixture.certificate); d.target = web.navigationDelegate
        delegate = d; web.navigationDelegate = d; web.configuration.userContentController.add(d, name: "context")
    }, configureStore: fixture.configure)
    init() throws { fixture = try SeedScopeFixture(scriptName: "wk_request_dedup_fixture.py", evidenceEnvironment: "NETVPLAYER_DEDUP_EVIDENCE_DIR") }
    func stop() { sniffer.cancel(); cleanup(); fixture.stop() }
    func cleanup() { browser?.configuration.userContentController.removeScriptMessageHandler(forName: "context"); browser = nil; delegate = nil }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<480 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }; throw URLError(.timedOut)
    }
    func rows() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/records")!)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
    func diagnostics() throws -> [[String: Any]] {
        let file = try #require(FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("web-sniff-") })
        return try #require((JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["events"] as? [[String: Any]])
    }
    func save(_ label: String, _ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: fixture.root.appendingPathComponent("observation-" + label + ".json"))
    }
}
