import AppKit
import Foundation
import Testing
import WebKit

// Test target only: records existing shared discovery messages without accepting a candidate.
@MainActor
final class NativeMediaBrowser: SeedBrowser {
    let web: WKWebView, sink: OriginalResponseSink
    let window: NSWindow
    private(set) var candidates: [[String: Any]] = []
    private(set) var actions: [String] = [], responses: [String] = []
    private(set) var active = true
    init(fixture: SeedScopeFixture, observe: Bool) throws {
        sink = try OriginalResponseSink(root: fixture.root.appendingPathComponent(UUID().uuidString).appendingPathComponent("spool"))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        fixture.configure(config.websiteDataStore)
        config.mediaTypesRequiringUserActionForPlayback = []
        let calls = """
        window.__mediaAPICalls={fetch:0,xhr:0};
        (()=>{const f=fetch,s=XMLHttpRequest.prototype.send;
        window.fetch=function(...a){__mediaAPICalls.fetch++;return Reflect.apply(f,this,a);};
        XMLHttpRequest.prototype.send=function(...a){__mediaAPICalls.xhr++;return Reflect.apply(s,this,a);};})();
        """
        config.userContentController.addUserScript(WKUserScript(source: calls, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if observe {
            let clone = try String(contentsOf: OriginalResponseFixture.tools.appendingPathComponent("wk_response_clone_observer.js"), encoding: .utf8)
            config.userContentController.addScriptMessageHandler(sink, contentWorld: .page, name: "responseClone")
            config.userContentController.addUserScript(WKUserScript(source: clone.replacingOccurrences(of: "__SESSION__", with: sink.session), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Local WK media contract"
        window.contentView = web
        super.init(certificate: fixture.certificate)
        if observe {
            // Load the actual private shared script verbatim; no product visibility change or copy.
            let repo = OriginalResponseFixture.tools.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let source = try String(contentsOf: repo.appendingPathComponent("NetVplayer/Sources/ParseEngine/WebViewSniffer.swift"), encoding: .utf8)
            let parts = source.components(separatedBy: "private static let discoveryScript = #\"\"\"")
            try #require(parts.count == 2)
            let discovery = try #require(parts.last?.components(separatedBy: "\"\"\"#").first).replacingOccurrences(of: "__ORIGINAL_POLICY__", with: "true")
            config.userContentController.add(self, name: "sniffer")
            config.userContentController.addUserScript(WKUserScript(source: discovery, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        web.navigationDelegate = self
        window.orderFront(nil)
    }
    override func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard active, candidates.count < 128, let body = message.body as? [String: Any] else { return }
        candidates.append(body.merging(["nativeFrameMain": message.frameInfo.isMainFrame]) { _, r in r })
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { result = "ready" }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if actions.count < 32 { actions.append(navigationAction.request.url?.absoluteString ?? "") }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if responses.count < 32 { responses.append(navigationResponse.response.url?.absoluteString ?? "") }
        decisionHandler(.allow)
    }
    func script(_ code: String) async throws -> [String: Any] {
        let value = try await web.callAsyncJavaScript(code, arguments: [:], in: nil, contentWorld: .page)
        return try #require(value as? [String: Any])
    }
    func page() async throws -> [String: Any] { try await script("return await pagePending;") }
    func retire() {
        guard active else { return }
        active = false
        sink.retire()
        web.stopLoading()
        web.load(URLRequest(url: URL(string: "about:blank")!))
        web.navigationDelegate = nil
        window.orderOut(nil)
        window.close()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "sniffer")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "responseClone", contentWorld: .page)
    }
}

@MainActor
final class NativeMediaFixture {
    let f: SeedScopeFixture
    var root: URL { f.root }
    init() throws {
        f = try SeedScopeFixture(scriptName: "wk_native_media_fixture.py", evidenceEnvironment: "NETVPLAYER_WK_NATIVE_EVIDENCE_DIR")
    }
    func stop() { f.stop() }
    func url(_ path: String, _ label: String, _ extra: [String: String] = [:], host: String = "video.example.test") -> String {
        var c = URLComponents(string: "https://\(host)\(path)")!
        c.queryItems = extra.merging(["case": label]) { _, r in r }.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!.absoluteString
    }
    func wait(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }
    func browser(_ label: String, _ extra: [String: String] = [:], observe: Bool = true, waitForMediaNavigation: Bool = true) async throws -> NativeMediaBrowser {
        let b = try NativeMediaBrowser(fixture: f, observe: observe)
        b.web.load(URLRequest(url: URL(string: url("/native/page", label, extra))!))
        do {
            if waitForMediaNavigation {
                try await wait { _ = try? await b.web.evaluateJavaScript("void(0)"); return b.result != nil }
                try #require(b.result == "ready", "navigation: \(b.result ?? "none")")
            } else {
                // Native media can delay navigation completion. Cancel after the original DOM driver starts.
                try await wait { (try? await b.web.evaluateJavaScript("typeof nativeSnapshot === 'function'")) as? Bool == true }
            }
            return b
        } catch { b.retire(); throw error }
    }
    func rows() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(f.port)/control/records")!)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
    func mediaRows(_ label: String) async throws -> [[String: Any]] {
        try await rows().filter { $0["kind"] as? String == "request" && $0["case"] as? String == label && ($0["path"] as? String ?? "").hasPrefix("/media/") }
    }
    func release(_ label: String) async throws {
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(f.port)/control/release?id=\(label)")!)
        try await wait { try await self.rows().contains { $0["kind"] as? String == "gate-drained" && $0["case"] as? String == label } }
        // Bounded late-request observation after the held response has actually drained.
        try await Task.sleep(for: .milliseconds(400))
    }
    func save(_ name: String, _ b: NativeMediaBrowser, _ page: [String: Any], extra: [String: Any] = [:]) throws {
        let body: [String: Any] = ["page": page, "candidates": b.candidates, "navigationActions": b.actions,
                                  "navigationResponses": b.responses, "sinkEvents": b.sink.events,
                                  "rawBodies": b.sink.completed.count, "activeTransfers": b.sink.transfers.count,
                                  "sinkActive": b.sink.active, "browserActive": b.active, "extra": extra]
        try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent(name + ".native.json"))
    }
}
