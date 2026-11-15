import AppKit
import Foundation
import Models
import Testing
import WebKit
@testable import ParseEngine

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil))
@MainActor
struct WKWindowLifecycleTests {
    private func verifyOriginal(_ o: LifecycleObservation, success: Bool) throws {
        #expect(o.messages.contains { $0["stage"] as? String == "ready" })
        #expect(o.messages.allSatisfy { ($0["fetch"] as? Int ?? 0) == 0 && ($0["xhr"] as? Int ?? 0) == 0 && ($0["playCalls"] as? Int ?? 0) == 0 })
        #expect((o.spec != nil) == success)
        if success {
            let candidate = try #require(o.messages.first { $0["stage"] as? String == "candidate-created" })
            #expect(o.spec?.url == candidate["candidate"] as? String)
            #expect(o.messages.contains { $0["name"] as? String == "loadedmetadata" && $0["trusted"] as? Bool == true })
            #expect(o.mediaCount > 0)
        } else { #expect(o.mediaCount == 0) }
    }
    @Test func metadataCandidateRequiresWindowAttachmentAndOriginalNativeEvent() async throws {
        let h = try LifecycleHarness(); defer { h.stop() }
        for presentation in ["detached", "sized", "production", "visible"] {
            try verifyOriginal(try await h.run(mode: "metadata", presentation: presentation), success: ["production", "visible"].contains(presentation))
        }
    }
    @Test func originalAutoplayProducesCandidateAfterTimeAdvancesWithoutNativePlayCall() async throws {
        let h = try LifecycleHarness(); defer { h.stop() }
        for presentation in ["detached", "sized", "production", "visible"] {
            let o = try await h.run(mode: "autoplay", presentation: presentation)
            try verifyOriginal(o, success: ["production", "visible"].contains(presentation))
            if o.spec != nil { #expect(o.messages.contains { $0["stage"] as? String == "candidate-created" && ($0["time"] as? Double ?? 0) >= 0.25 }) }
        }
    }
    @Test func originalPreloadNoneStaysIdleInEveryPresentation() async throws {
        let h = try LifecycleHarness(); defer { h.stop() }
        for presentation in ["detached", "sized", "production", "visible"] {
            try verifyOriginal(try await h.run(mode: "none", presentation: presentation), success: false)
        }
    }
    @Test func originalEventDrivenNavigationKeepsOneCarrierAndAcceptsOnlyNewDocument() async throws {
        let h = try LifecycleHarness(); defer { h.stop() }
        let next = h.url("/lifecycle/page", ["case": "next", "mode": "metadata", "seed": "0"])
        let o = try await h.run(mode: "metadata", presentation: "production", extra: ["next": next])
        try verifyOriginal(o, success: true)
        #expect(o.spec?.url.contains("case=next") == true)
        #expect(o.messages.filter { $0["stage"] as? String == "replace" }.count == 1)
        #expect(o.messages.filter { $0["stage"] as? String == "candidate-created" }.count == 1)
    }
    @Test func completionReleasesBrowserAndWindowAndNewSessionHasNoOldCookie() async throws {
        let h = try LifecycleHarness(); defer { h.stop() }
        try verifyOriginal(try await h.run(mode: "metadata", presentation: "production"), success: true)
        let target = h.url("/media/native.mp4", ["case": "metadata", "expect": ""])
        let o = try await h.run(mode: "metadata", presentation: "production", extra: ["seed": "0", "target": target])
        try verifyOriginal(o, success: true)
    }
    @Test func cancellationTimeoutAndReplacementDrainNativeHoldAndRecycleCarrier() async throws {
        let h = try LifecycleHarness(); defer { h.stop() }
        for action in ["task", "cancel", "timeout", "replace"] { try await h.retireHeld(action) }
    }
    @Test func productionTLSDelegateRejectsFixtureCertificateAndReleasesCarrier() async throws {
        let h = try LifecycleHarness(); defer { h.stop() }
        _ = try await h.run(mode: "metadata", presentation: "production", trust: false)
    }

}

@MainActor
private final class LifecycleDelegate: SeedBrowser {
    weak var target: (any WKNavigationDelegate)?
    var messages: [[String: Any]] = []
    override func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? [String: Any], messages.count < 96 { messages.append(value) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        target?.webView?(webView, decidePolicyFor: action, decisionHandler: decisionHandler) ?? decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        target?.webView?(webView, decidePolicyFor: response, decisionHandler: decisionHandler) ?? decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { target?.webView?(webView, didStartProvisionalNavigation: navigation) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { target?.webView?(webView, didCommit: navigation) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { target?.webView?(webView, didFinish: navigation) }
    override func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { target?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { target?.webView?(webView, didFail: navigation, withError: error) }
}

private struct LifecycleObservation {
    let spec: PlaySpec?
    let messages: [[String: Any]]
    let mediaCount: Int
}

@MainActor
private final class LifecycleHarness {
    let fixture: SeedScopeFixture
    var browser: WKWebView?
    weak var productWindow: NSWindow?
    var referenceWindow: NSWindow?
    var delegate: LifecycleDelegate?
    var presentation = "production", trust = true
    var attachedAtStart = false, visibleAtStart = false
    lazy var sniffer = WebViewSniffer(diagnosticDirectory: fixture.root, configureBrowser: { [weak self] web in
        guard let self else { return }
        self.browser = web
        self.productWindow = web.window
        self.attachedAtStart = web.window != nil
        self.visibleAtStart = web.window?.isVisible ?? false
        let d = LifecycleDelegate(certificate: self.fixture.certificate)
        d.target = web.navigationDelegate; self.delegate = d
        if self.trust { web.navigationDelegate = d }
        web.configuration.userContentController.add(d, name: "lifecycle")
        if ["detached", "sized"].contains(self.presentation) {
            web.removeFromSuperview()
            web.frame = self.presentation == "detached" ? .zero : NSRect(x: 0, y: 0, width: 320, height: 240)
        }
        if self.presentation == "visible" {
            let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Local WK lifecycle contract"
            window.contentView = web; self.referenceWindow = window; window.orderFront(nil)
        }
    }, configureStore: fixture.configure)
    let policy = WebMediaPolicy(check: { URL(string: $0)?.path.hasPrefix("/candidate/") == true })
    init() throws { fixture = try SeedScopeFixture(scriptName: "wk_window_lifecycle_fixture.py", evidenceEnvironment: "NETVPLAYER_WK_WINDOW_EVIDENCE_DIR") }
    func stop() { sniffer.cancel(); cleanup(); fixture.stop() }
    func cleanup() {
        browser?.configuration.userContentController.removeScriptMessageHandler(forName: "lifecycle")
        browser = nil; delegate = nil
        referenceWindow?.contentView = nil; referenceWindow?.orderOut(nil); referenceWindow?.close(); referenceWindow = nil
    }
    func url(_ path: String, _ query: [String: String]) -> String {
        var c = URLComponents(string: "https://video.example.test" + path)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!.absoluteString
    }
    func rows() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/records")!)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
    func wait(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<240 { if try await predicate() { return }; try await Task.sleep(for: .milliseconds(25)) }
        throw URLError(.timedOut)
    }
    func save(_ name: String, _ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fixture.root.appendingPathComponent(name + "-" + UUID().uuidString + ".json"))
    }
    func run(mode: String, presentation: String, extra: [String: String] = [:], trust: Bool = true) async throws -> LifecycleObservation {
        self.presentation = presentation; self.trust = trust
        let start = try await rows().count
        defer { sniffer.cancel(); cleanup() }
        let page = url("/lifecycle/page", ["case": mode, "mode": mode].merging(extra) { _, new in new })
        var spec: PlaySpec?, failure: String?, errorCode: Int?
        do { spec = try await sniffer.sniff(url: page, timeout: mode == "none" ? 1.2 : 3, policy: policy) }
        catch { failure = String(describing: error); errorCode = (error as NSError).code
            if trust { #expect(error is WebViewSnifferError) }
            else { #expect((error as NSError).domain == NSURLErrorDomain && errorCode != NSURLErrorCancelled) }
        }
        let received = Array(try await rows().dropFirst(start))
        let media = received.filter { $0["path"] as? String == "/media/native.mp4" }
        let messages = delegate?.messages ?? []
        #expect(attachedAtStart && !visibleAtStart)
        #expect(browser?.configuration.mediaTypesRequiringUserActionForPlayback == [])
        #expect(productWindow == nil || productWindow?.contentView == nil)
        #expect(received.allSatisfy { !($0["path"] as? String ?? "").hasPrefix("/candidate/") })
        if !trust { #expect(spec == nil && media.isEmpty && !received.contains { $0["kind"] as? String == "request" }) }
        weak var oldWeb = browser
        cleanup()
        try await wait { oldWeb == nil && self.productWindow == nil }
        try save("observation-\(mode)-\(presentation)", ["mode": mode, "presentation": presentation, "url": page,
            "spec": spec?.url ?? NSNull(), "failure": failure ?? NSNull(), "errorCode": errorCode ?? NSNull(), "messages": messages,
            "attachedAtStart": attachedAtStart, "visibleAtStart": visibleAtStart, "productionTrust": !trust,
            "browserReleased": oldWeb == nil, "carrierReleased": productWindow == nil, "rows": received,
            "mediaCount": media.count, "configuredGestureRequired": 0])
        print("LIFECYCLE \(mode) \(presentation) candidate=\(spec != nil) media=\(media.count)")
        return LifecycleObservation(spec: spec, messages: messages, mediaCount: media.count)
    }
    func retireHeld(_ action: String) async throws {
        presentation = "production"; trust = true
        let target = url("/media/native.mp4", ["case": action])
        let hold = url("/media/hold", ["case": action, "target": target])
        let page = url("/lifecycle/page", ["case": action, "mode": "hold", "target": hold])
        let oldTask = Task { try await sniffer.sniff(url: page, timeout: action == "timeout" ? 1.5 : 10, policy: policy) }
        try await wait { try await self.rows().contains { $0["path"] as? String == "/media/hold" && $0["case"] as? String == action } }
        weak var oldWindow = productWindow
        var oldWeb = browser
        let oldDelegate = delegate
        var replacement: Task<PlaySpec, Error>?
        if action == "task" { oldTask.cancel() }
        if action == "cancel" { sniffer.cancel() }
        if action == "replace" {
            let page = url("/lifecycle/page", ["case": "replacement", "mode": "metadata", "seed": "0", "target": url("/media/native.mp4", ["case": "replacement", "expect": ""])])
            replacement = Task { try await sniffer.sniff(url: page, timeout: 5, policy: policy) }
        }
        do { _ = try await oldTask.value; Issue.record("retired media completed") }
        catch { if action == "timeout" { #expect(error is WebViewSnifferError) } else { #expect(error is CancellationError) } }
        #expect(oldWeb?.window == nil && (oldWindow == nil || oldWindow?.contentView == nil))
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/control/release?id=\(action)")!)
        try await wait { try await self.rows().contains { $0["kind"] as? String == "gate-drained" && $0["case"] as? String == action } }
        try await Task.sleep(for: .milliseconds(400))
        // Real retired WK context cannot use the removed handler to finish a new sniff.
        let rejected = try await oldWeb?.evaluateJavaScript("typeof window.webkit?.messageHandlers?.sniffer === 'undefined'") as? Bool
        #expect(rejected == true)
        if let replacement { let spec = try await replacement.value; #expect(spec.url.contains("case=replacement")) }
        let received = try await rows()
        #expect(!received.contains { $0["path"] as? String == "/media/native.mp4" && $0["case"] as? String == action })
        #expect(received.filter { $0["case"] as? String == "replacement" && $0["path"] as? String == "/media/native.mp4" }.allSatisfy { ($0["headers"] as? [String: String])?["cookie"] == nil })
        #expect(oldDelegate?.messages.contains { $0["stage"] as? String == "candidate-created" } == false)
        oldWeb?.configuration.userContentController.removeScriptMessageHandler(forName: "lifecycle")
        weak var releasedWeb = oldWeb
        oldWeb = nil; cleanup()
        try await wait { releasedWeb == nil && oldWindow == nil && self.productWindow == nil }
        try save("retirement-" + action, ["action": action, "oldHandlerAbsent": rejected ?? false,
            "gateDrained": true, "postDrainObservationMS": 400, "oldBrowserReleased": releasedWeb == nil,
            "oldWindowReleased": oldWindow == nil, "messages": oldDelegate?.messages ?? [], "rows": received])
    }
}
