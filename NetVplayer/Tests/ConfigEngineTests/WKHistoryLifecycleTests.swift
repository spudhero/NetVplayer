import AppKit
import Foundation
import Models
import Testing
import WebKit
@testable import ParseEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil))
@MainActor
struct WKHistoryLifecycleTests {
    @Test func restoredFetchRejectsOldAcceptance() async throws { try await run("fetch", "accept") }
    @Test func restoredDOMRejectsOldFallback() async throws { try await run("dom", "fallback") }
    @Test func restoredXHRRejectsOldError() async throws { try await run("xhr", "error") }

    @Test func sameOriginFrameRestoresWithoutRevivingItsOldCheck() async throws { try await run("iframe", "accept") }
    @Test func crossOriginFrameRestoresWithoutRevivingItsOldError() async throws { try await run("cross-frame", "error") }
    @Test func repeatedBackForwardClearsDiscoveryForEachRestore() async throws { try await run("fetch", "error", mode: "repeat") }
    @Test func explicitReloadCreatesNewDocumentInsteadOfBFCacheHit() async throws { try await run("fetch", "accept", mode: "reload") }
    @Test func currentRestoredCandidateErrorStillFails() async throws { try await run("xhr", "error", mode: "current-error") }
    @Test func cancellationDuringRestoredCheckRetiresWindow() async throws { try await run("fetch", "accept", mode: "cancel") }
    @Test func timeoutDuringRestoredCheckRetiresWindow() async throws { try await run("dom", "fallback", mode: "timeout") }
    @Test func replacementDuringRestoredCheckIsolatesNewSession() async throws { try await run("fetch", "error", mode: "replace") }

    private func run(_ api: String, _ outcome: String, mode: String = "back") async throws {
        let h = try HistoryHarness(), gate = HistoryGate(outcome: outcome, currentError: mode == "current-error")
        defer { gate.release(); h.stop() }
        let label = api + "-" + outcome + "-" + mode
        let page = "https://video.example.test/history/a?case=" + label + "&api=" + api + "&cache=1"
        let task = Task { try await h.sniffer.sniff(url: page, timeout: mode == "timeout" ? 3 : 10,
            policy: WebMediaPolicy(rules: [Rule(hosts: ["example.test"], regex: ["/history/media"])], check: { url in try await gate.check(url) })) }
        defer { task.cancel() }
        try await h.wait { gate.pending[1] != nil && h.shows("a").count == 1 }
        _ = try await h.browser?.evaluateJavaScript("window.advance(); void(0)")
        try await h.wait { h.shows("b").count == 1 && h.delegate?.events.contains("finished:b") == true }
        _ = try await h.browser?.evaluateJavaScript("window.returnToA(); void(0)")
        try await h.wait { h.shows("a").count == 2 && gate.pending[2] != nil }
        if mode == "repeat" {
            _ = try await h.browser?.evaluateJavaScript("window.forwardToB(); void(0)")
            try await h.wait { h.shows("b").count == 2 }
            _ = try await h.browser?.evaluateJavaScript("window.returnToA(); void(0)")
            try await h.wait { h.shows("a").count == 3 && gate.pending[3] != nil }
        } else if mode == "reload" {
            _ = try await h.browser?.evaluateJavaScript("window.reloadPage(); void(0)")
            try await h.wait { h.shows("a").count == 3 && gate.pending[3] != nil }
        }
        let checks = gate.calls.count, currentPending = gate.pending[checks] != nil
        gate.release(1)
        if checks == 3 { gate.release(2) }
        try await h.wait { gate.oldReturned }
        var replacement: PlaySpec?
        weak var oldBrowser = h.browser
        let oldDelegate = h.delegate
        if mode == "cancel" { h.sniffer.cancel() }
        else if mode == "replace" {
            replacement = try await h.sniffer.sniff(url: page.replacingOccurrences(of: "case=" + label, with: "case=replacement"), timeout: 5,
                policy: WebMediaPolicy(check: { $0.contains("/history/media?") }))
        } else if mode != "timeout" { gate.release(checks) }
        var spec: PlaySpec?, failure: String?
        do { spec = try await task.value } catch { failure = String(describing: error) }
        gate.release()
        // Let callbacks that deliberately ignore cancellation return after retirement.
        for _ in 0..<4 { await Task.yield() }
        let rows = try await h.rows(), messages = oldDelegate?.messages ?? [], events = oldDelegate?.events ?? []
        let show = messages.filter { $0["stage"] as? String == "pageshow" && $0["page"] as? String == "a" && $0["frame"] as? Bool != true }
        let diagnostics = try h.diagnostics()
        try h.save(label, ["api": api, "outcome": outcome, "mode": mode, "spec": spec?.url ?? NSNull(), "headers": spec?.headers ?? [:], "error": failure ?? NSNull(),
            "calls": gate.calls, "messages": messages, "navigation": events, "rows": rows, "diagnostics": diagnostics,
            "currentPending": currentPending, "attached": h.attached, "visible": h.visible, "replacement": replacement?.url ?? NSNull()])
        #expect(show.count == (checks == 3 ? 3 : 2) && show.allSatisfy { $0["trusted"] as? Bool == true })
        #expect(show[1]["persisted"] as? Bool == true, "Reload must not count as a BFCache hit")
        if mode == "reload" {
            #expect(show.last?["persisted"] as? Bool == false)
            #expect(Set(show.compactMap { $0["instance"] as? String }).count == 2)
        } else { #expect(Set(show.compactMap { $0["instance"] as? String }).count == 1) }
        if mode == "repeat" { #expect(show.last?["persisted"] as? Bool == true) }
        #expect(currentPending && gate.calls.count == checks)
        if ["cancel", "replace"].contains(mode) { #expect(failure == "CancellationError()" && spec == nil) }
        else if mode == "timeout" { #expect(failure == "noMediaFound" && spec == nil) }
        else if mode == "current-error" { #expect(failure != nil && spec == nil) }
        else {
            #expect(failure == nil && spec?.url.contains("/history/media?") == true)
            if ["fetch", "xhr"].contains(api) { #expect(spec?.headers.first { $0.key.lowercased() == "x-history-show" }?.value == (mode == "reload" ? "1" : String(checks))) }
        }
        if api.contains("frame") {
            let frames = messages.filter { $0["stage"] as? String == "pageshow" && $0["frame"] as? Bool == true }
            #expect(frames.count == 2 && frames.last?["persisted"] as? Bool == true)
            #expect(Set(frames.compactMap { $0["instance"] as? String }).count == 1)
        }
        if mode == "replace" { #expect(replacement?.url.contains("case=replacement") == true) }
        #expect(h.attached && !h.visible)
        #expect(rows.allSatisfy { $0["kind"] as? String != "proxy-denied" })
        #expect(messages.allSatisfy { $0["playCalls"] as? Int == 0 })
        // Keep only weak references while checking hidden-window retirement.
        weak var retiredWindow = oldBrowser?.window
        weak var replacementBrowser = h.browser
        weak var replacementWindow = h.browser?.window
        h.cleanup()
        try await h.wait { oldBrowser == nil && retiredWindow == nil && replacementBrowser == nil && replacementWindow == nil }
    }

}

@MainActor
private final class HistoryGate {
    let outcome: String, currentError: Bool
    var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    var calls: [String] = [], oldReturned = false
    init(outcome: String, currentError: Bool) { self.outcome = outcome; self.currentError = currentError }
    func check(_ url: String) async throws -> Bool? {
        guard URL(string: url)?.path == "/history/media" else { return false }
        calls.append(url); let index = calls.count
        await withCheckedContinuation { pending[index] = $0 }
        if index == 1 {
            oldReturned = true
            if outcome == "error" { throw URLError(.cannotParseResponse) }
            if outcome == "fallback" { return nil }
            return outcome == "accept"
        }
        if currentError { throw URLError(.cannotParseResponse) }
        return nil
    }
    func release(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
    func release() { let held = pending; pending = [:]; held.values.forEach { $0.resume() } }
}

@MainActor
private final class HistoryDelegate: SeedBrowser {
    weak var target: (any WKNavigationDelegate)?
    var messages: [[String: Any]] = [], events: [String] = []
    override func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { if let value = message.body as? [String: Any] { messages.append(value) } }
    func page(_ web: WKWebView) -> String { web.url?.lastPathComponent ?? "nil" }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) { target?.webView?(webView, decidePolicyFor: action, decisionHandler: decisionHandler) ?? decisionHandler(.allow) }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { events.append("started:" + page(webView)); target?.webView?(webView, didStartProvisionalNavigation: navigation) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { events.append("committed:" + page(webView)); target?.webView?(webView, didCommit: navigation) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { events.append("finished:" + page(webView)); target?.webView?(webView, didFinish: navigation) }
    override func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { events.append("failed-provisional"); target?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { events.append("failed"); target?.webView?(webView, didFail: navigation, withError: error) }
}

@MainActor
private final class HistoryHarness {
    let fixture: SeedScopeFixture
    var browser: WKWebView?, delegate: HistoryDelegate?
    var attached = false, visible = false
    lazy var sniffer = WebViewSniffer(diagnosticDirectory: fixture.root, configureBrowser: { [weak self] web in
        guard let self else { return }; browser = web; attached = web.window != nil; visible = web.window?.isVisible ?? false
        let d = HistoryDelegate(certificate: fixture.certificate); d.target = web.navigationDelegate; delegate = d; web.navigationDelegate = d
        web.configuration.userContentController.add(d, name: "history")
    }, configureStore: fixture.configure)
    init() throws { fixture = try SeedScopeFixture(scriptName: "wk_history_fixture.py", evidenceEnvironment: "NETVPLAYER_HISTORY_EVIDENCE_DIR") }
    func stop() { sniffer.cancel(); cleanup(); fixture.stop() }
    func cleanup() { browser?.configuration.userContentController.removeScriptMessageHandler(forName: "history"); browser = nil; delegate = nil }
    func shows(_ page: String) -> [[String: Any]] { delegate?.messages.filter { $0["stage"] as? String == "pageshow" && $0["page"] as? String == page && $0["frame"] as? Bool != true } ?? [] }
    func wait(_ condition: () -> Bool) async throws { for _ in 0..<240 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }; throw URLError(.timedOut) }
    func rows() async throws -> [[String: Any]] { let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/records")!); return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]]) }
    func diagnostics() throws -> [[String: Any]] {
        let files = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
        return try files.filter { $0.lastPathComponent.hasPrefix("web-sniff-") }.flatMap { p in
            try #require((JSONSerialization.jsonObject(with: Data(contentsOf: p)) as? [String: Any])?["events"] as? [[String: Any]])
        }
    }
    func save(_ label: String, _ value: [String: Any]) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: fixture.root.appendingPathComponent("observation-" + label + ".json")) }
}
