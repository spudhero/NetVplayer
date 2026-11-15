import AppKit
import Foundation
import Models
import Testing
import WebKit
@testable import ParseEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil))
@MainActor
struct WKDocumentGenerationTests {
    @Test func oldAcceptedCheckCannotCompleteNavigatedDocument() async throws { try await run("navigate", outcome: "accept") }
    @Test func sameURLReloadRetiresDelayedRuleFallbackAndQueuedCandidates() async throws { try await run("reload", outcome: "fallback") }
    @Test func recreatedSameURLSameNameFrameRetiresOldCheckAndLateMessage() async throws { try await run("frame-replace", outcome: "accept") }
    @Test func crossOriginFrameNavigationRetiresDelayedRuleFallback() async throws { try await run("frame-cross", outcome: "fallback") }
    @Test func removedFrameErrorCannotFailCurrentDocument() async throws { try await run("frame-remove", outcome: "error") }
    @Test func removedFrameRejectionDropsQueuedCandidates() async throws { try await run("frame-remove", outcome: "reject") }
    @Test func sameDocumentHashKeepsItsPendingCandidate() async throws { try await run("hash", outcome: "accept", stays: true) }
    @Test func replacingSiblingDoesNotInvalidateLiveFrameCandidate() async throws { try await run("sibling", outcome: "accept", stays: true) }

    @Test func ordinaryHTTPDocumentRetainsDiscoveryWithoutSecureContextUUID() async throws { try await run("navigate", outcome: "accept", scheme: "http") }
    @Test func currentDocumentErrorStillFailsTheSniff() async throws { try await run("hash", outcome: "error", stays: true) }
    @Test func oldNavigationErrorCannotClearPendingReplacementWorker() async throws { try await run("navigate", outcome: "error", holdCurrent: true) }

    private func run(_ mode: String, outcome: String, stays: Bool = false, scheme: String = "https", holdCurrent: Bool = false) async throws {
        let h = try GenerationHarness(), gate = GenerationGate(outcome: outcome, holdCurrent: holdCurrent)
        defer { gate.release(); h.stop() }
        let label = mode + "-" + outcome + "-" + scheme
        let page = scheme + "://video.example.test/generation/page?case=" + label + "&mode=" + mode
        let policy = WebMediaPolicy(rules: [Rule(hosts: ["example.test"], regex: ["/candidate/"])], check: { url in try await gate.check(url) })
        let task = Task { try await h.sniffer.sniff(url: page, timeout: 8, policy: policy) }
        defer { task.cancel() }
        try await h.wait { gate.pending != nil }
        let oldInstance = try #require(h.delegate?.messages.first { $0["stage"] as? String == "candidate" }?["instance"] as? String)
        _ = try await h.browser?.evaluateJavaScript("window.advance(); void(0)")
        if stays {
            try await h.wait { h.delegate?.messages.contains { ["same-document", "sibling-replaced"].contains($0["stage"] as? String ?? "") } == true }
        } else {
            try await h.wait { h.delegate?.messages.contains { ($0["candidate"] as? String ?? "").contains("/candidate/current") } == true }
        }
        if holdCurrent { try await h.wait { gate.currentPending != nil } }
        gate.releaseOld()
        try await h.wait { gate.returned }
        if holdCurrent {
            // The old callback has now failed while the new worker is suspended.
            // Its cleanup cannot steal that worker or discard subsequent work.
            #expect(gate.currentPending != nil)
        }
        gate.release()
        var spec: PlaySpec?, error: String?
        do { spec = try await task.value } catch let failure { error = String(describing: failure) }
        let calls = gate.calls
        let messages = h.delegate?.messages ?? []
        let rows = try await h.rows()
        let value: [String: Any] = ["mode": mode, "outcome": outcome, "stays": stays, "calls": calls,
            "spec": spec?.url ?? NSNull(), "error": error ?? NSNull(), "messages": messages, "rows": rows,
            "oldInstance": oldInstance, "gateReturned": gate.returned, "attached": h.attached, "visible": h.visible, "scheme": scheme, "holdCurrent": holdCurrent]
        try h.save(label, value)
        #expect(gate.returned)
        if stays && outcome == "error" {
            #expect(error != nil && spec == nil)
        } else {
            #expect(error == nil)
            #expect(spec?.url.contains(stays ? "/candidate/old" : "/candidate/current") == true)
        }
        #expect(!calls.contains { $0.contains("/candidate/queued") || $0.contains("/candidate/late") })
        #expect(h.attached && !h.visible)
        #expect(messages.allSatisfy { ($0["fetchCalls"] as? Int ?? 0) == 0 && ($0["xhrCalls"] as? Int ?? 0) == 0 && ($0["playCalls"] as? Int ?? 0) == 0 })
        #expect(rows.allSatisfy { !($0["path"] as? String ?? "").hasPrefix("/candidate/") })
        if ["reload", "frame-replace", "frame-cross"].contains(mode) {
            let ready = messages.filter { $0["stage"] as? String == "ready" && ($0["frame"] as? Bool == (mode != "reload")) }
            #expect(Set(ready.compactMap { $0["instance"] as? String }).count == 2)
            #expect(Set(ready.compactMap { $0["url"] as? String }).count == 1)
        }
        weak var oldBrowser = h.browser
        weak var oldWindow = h.browser?.window
        h.cleanup()
        try await h.wait { oldBrowser == nil && oldWindow == nil }
    }
}

@MainActor
private final class GenerationGate {
    let outcome: String
    var pending: CheckedContinuation<Void, Never>?
    var calls: [String] = []
    var returned = false
    let holdCurrent: Bool
    var currentPending: CheckedContinuation<Void, Never>?
    init(outcome: String, holdCurrent: Bool = false) { self.outcome = outcome; self.holdCurrent = holdCurrent }
    func check(_ url: String) async throws -> Bool? {
        guard URL(string: url)?.path.hasPrefix("/candidate/") == true else { return false }
        calls.append(url)
        if url.contains("/candidate/old") {
            // Deliberately ignores Task cancellation: late callback results/errors
            // must be isolated even when the underlying Spider keeps running.
            await withCheckedContinuation { pending = $0 }
            returned = true
            if outcome == "error" { throw URLError(.cannotParseResponse) }
            if outcome == "fallback" { return nil }
            return outcome != "reject"
        }
        if holdCurrent && url.contains("/candidate/current") { await withCheckedContinuation { currentPending = $0 } }
        return true
    }
    func releaseOld() { pending?.resume(); pending = nil }
    func release() { releaseOld(); currentPending?.resume(); currentPending = nil }
}

@MainActor
private final class GenerationDelegate: SeedBrowser {
    weak var target: (any WKNavigationDelegate)?
    var messages: [[String: Any]] = []
    override func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? [String: Any], messages.count < 96 { messages.append(value) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        target?.webView?(webView, decidePolicyFor: action, decisionHandler: decisionHandler) ?? decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { target?.webView?(webView, didStartProvisionalNavigation: navigation) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { target?.webView?(webView, didCommit: navigation) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { target?.webView?(webView, didFinish: navigation) }
    override func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { target?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { target?.webView?(webView, didFail: navigation, withError: error) }
}

@MainActor
private final class GenerationHarness {
    let fixture: SeedScopeFixture
    var browser: WKWebView?
    var delegate: GenerationDelegate?
    var attached = false, visible = false
    lazy var sniffer = WebViewSniffer(diagnosticDirectory: fixture.root, configureBrowser: { [weak self] web in
        guard let self else { return }
        browser = web; attached = web.window != nil; visible = web.window?.isVisible ?? false
        let d = GenerationDelegate(certificate: fixture.certificate); d.target = web.navigationDelegate
        delegate = d; web.navigationDelegate = d
        web.configuration.userContentController.add(d, name: "generation")
    }, configureStore: fixture.configure)
    init() throws { fixture = try SeedScopeFixture(scriptName: "wk_document_generation_fixture.py", evidenceEnvironment: "NETVPLAYER_GENERATION_EVIDENCE_DIR") }
    func stop() { sniffer.cancel(); cleanup(); fixture.stop() }
    func cleanup() { browser?.configuration.userContentController.removeScriptMessageHandler(forName: "generation"); browser = nil; delegate = nil }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<240 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        throw URLError(.timedOut)
    }
    func rows() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/records")!)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
    func save(_ label: String, _ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: fixture.root.appendingPathComponent("observation-" + label + ".json"))
    }
}
