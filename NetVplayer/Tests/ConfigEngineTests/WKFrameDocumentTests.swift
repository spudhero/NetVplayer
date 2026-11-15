import Foundation
import Testing
import WebKit

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_WK_FRAME_DOCUMENT_EVIDENCE_DIR"] != nil))
@MainActor
struct WKFrameDocumentTests {
    private let expected = Data(repeating: 115, count: 32768) + Data(repeating: 116, count: 32768)
    private enum Mode: String { case control, urlKey, document }

    private func create(_ label: String, mode: Mode, frames: Int, guardNavigation: Bool = false,
        timeout: Int = 1500, maximum: Int = 8, delay: Int = 0, urlPrefilter: Bool = false) async throws -> (SeedScopeFixture, FrameDocumentBrowser) {
        let fixture = try SeedScopeFixture(scriptName: "wk_frame_document_fixture.py", evidenceEnvironment: "NETVPLAYER_WK_FRAME_DOCUMENT_EVIDENCE_DIR")
        do {
            let browser = try FrameDocumentBrowser(fixture: fixture, observer: mode != .control,
                documentBinding: mode == .document, guardNavigation: guardNavigation,
                timeout: timeout, maximum: maximum, delay: delay, urlPrefilter: urlPrefilter)
            var url = URLComponents(string: "https://video.example.test/frames/root")!
            url.queryItems = [URLQueryItem(name: "case", value: label), URLQueryItem(name: "frames", value: String(frames))]
            browser.web.load(URLRequest(url: try #require(url.url)))
            try await wait { browser.finishes == 1 }
            if frames > 0 {
                try await wait { try await browser.web.evaluateJavaScript("frameLoads.slice(0,\(frames)).every(n=>n===1)") as? Bool == true }
                try await wait { try await self.rows(fixture).filter { $0["kind"] as? String == "first-block" }.count == frames }
            }
            return (fixture, browser)
        } catch { fixture.stop(); throw error }
    }
    private func bridge(_ browser: FrameDocumentBrowser, frame: Int?, body: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        let payload = try #require(String(data: data, encoding: .utf8))
        let source = "(async()=>{try{return {accepted:true,value:await webkit.messageHandlers.responseClone.postMessage(\(payload))};}catch(error){return {accepted:false,error:String(error)}}})()"
        let value = try await browser.web.callAsyncJavaScript(frame == nil ? "return await eval(source)" : "return await frames[index].eval(source)",
            arguments: ["source": source, "index": frame ?? 0], in: nil, contentWorld: .page)
        return try #require(value as? [String: Any])
    }
    private func release(_ fixture: SeedScopeFixture, _ browser: FrameDocumentBrowser, label: String) async throws {
        browser.sink.release()
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/control/release?id=\(label)-0")!)
    }
    private func pageResults(_ browser: FrameDocumentBrowser) async throws -> [[String: Any]] {
        let value = try await browser.web.callAsyncJavaScript("return (await Promise.all(Array.from(frames, frame=>frame.pagePending))).flat()",
            arguments: [:], in: nil, contentWorld: .page)
        let pages = try #require(value as? [[String: Any]])
        for page in pages {
            try #require(page["sameNativePromise"] as? Bool == true && page["sameNativeResponse"] as? Bool == true)
            try #require(page["bodyUsedBefore"] as? Bool == false && page["bodyUsedAfter"] as? Bool == true)
            try #require(page["status"] as? Int == 200 && page["secondReadError"] as? String == "TypeError")
            try #require(page["bytes"] as? Int == expected.count && page["sha256"] as? String == FrameDocumentResponseSink.hash(expected))
            try #require(page["documentCookie"] as? String == "")
        }
        return pages
    }
    private func finish(_ fixture: SeedScopeFixture, _ browser: FrameDocumentBrowser, label: String,
        mediaCount: Int, pages: [[String: Any]], extra: [String: Any]) async throws {
        try await wait { try await self.rows(fixture).filter { $0["kind"] as? String == "gate-drained" }.count == mediaCount }
        try await wait { browser.sink.documentGate.outstanding.isEmpty }
        let records = try await rows(fixture), requests = records.filter { $0["kind"] as? String == "request" }
        let media = requests.filter { $0["path"] as? String == "/media/lifetime" }
        try #require(media.count == mediaCount && media.allSatisfy { $0["cookie"] as? String == "account=fresh" })
        try #require(requests.allSatisfy { $0["tls"] as? Bool == true && $0["host"] as? String == "video.example.test" })
        try #require(!records.contains { ["proxy-denied", "tls-rejected"].contains($0["kind"] as? String ?? "") })
        for transfer in browser.sink.completed { try #require(try browser.sink.bytes(transfer) == expected) }
        let gate = browser.sink.documentGate.snapshot
        try browser.sink.snapshot(to: fixture.root.appendingPathComponent(label + ".capture.json"), extra: extra.merging([
            "label": label, "pages": pages, "mediaRequests": mediaCount, "documentGate": gate,
            "nativeSubframeActions": browser.actions, "privateWorldDocumentBinding": browser.sink.useDocumentBinding,
            "nativeUniqueFrameIdentifierUsed": false, "responseBodyAttestationClaimed": false]) { _, value in value })
        browser.close()
        try await wait { browser.sink.documentGate.outstanding.isEmpty }
        try #require(browser.sink.transfers.isEmpty && browser.sink.pending.isEmpty && browser.sink.retainedBytes == 0)
        try #require(try FileManager.default.contentsOfDirectory(atPath: browser.sink.root.path).isEmpty)
        fixture.stop(); try #require(!fixture.process.isRunning)
        let closure: [String: Any] = ["passed": true, "label": label, "mediaRequests": mediaCount,
            "fixturePID": Int(fixture.process.processIdentifier), "fixtureRetired": true,
            "liveSpoolFiles": 0, "outstandingDocumentLookups": browser.sink.documentGate.outstanding.count,
            "captureCount": browser.sink.completed.count, "pages": pages.count]
        try JSONSerialization.data(withJSONObject: closure, options: [.prettyPrinted, .sortedKeys])
            .write(to: fixture.root.appendingPathComponent("closure.safe.json"))
    }
    private func twin(_ mode: Mode) async throws -> [[String: Any]] {
        let label = "same-url-twins-" + mode.rawValue
        let (fixture, browser) = try await create(label, mode: mode, frames: 2)
        defer { browser.close(); fixture.stop() }
        var attack: [String: Any] = [:]
        if mode != .control {
            try await wait { browser.sink.transfers.count == 2 && browser.sink.pending.count == 2 }
            let tokens = Set(browser.sink.transfers.values.compactMap { $0.metadata["privateDocumentTokenSHA256"] as? String })
            try #require(tokens.count == 2)
            let first = try #require(browser.sink.transfers.values.first { $0.metadata["fixtureFrameName"] as? String == "f0" })
            attack = try await bridge(browser, frame: 1, body: ["session": browser.sink.session, "op": "cancel", "cap": first.cap, "reason": "borrowed-by-same-url-sibling"])
            try #require(attack["accepted"] as? Bool == (mode == .urlKey))
            try #require(browser.sink.transfers[first.cap] != nil || mode == .urlKey)
            let visibility = try await browser.web.evaluateJavaScript("Array.from(frames,f=>typeof f.\(FrameDocumentGate.marker)).every(x=>x==='undefined')")
            try #require(visibility as? Bool == true)
            let wrapper = try await browser.web.evaluateJavaScript("frames[0].fetch.toString()") as? String ?? ""
            try #require(!wrapper.contains(browser.sink.session))
        }
        try await release(fixture, browser, label: label)
        let pages = try await pageResults(browser); try #require(pages.count == 2)
        if mode != .control { try await wait { browser.sink.completed.count == (mode == .urlKey ? 1 : 2) } }
        try await finish(fixture, browser, label: label, mediaCount: 2, pages: pages,
            extra: ["borrowedCapabilityAttack": attack, "nativePrivateDocumentMarkers": mode == .control ? 0 : 2,
                "pageScriptCanReadPrivateDocumentMarker": false, "URLKeyNegativeControl": mode == .urlKey])
        return pages
    }
    private func reload(_ mode: Mode, guardNavigation: Bool) async throws -> [[String: Any]] {
        let label = "same-url-reload-" + mode.rawValue + (guardNavigation ? "-guard" : "-binding")
        let (fixture, browser) = try await create(label, mode: mode, frames: 1, guardNavigation: guardNavigation)
        defer { browser.close(); fixture.stop() }
        if mode != .control { try await wait { browser.sink.transfers.count == 1 && browser.sink.pending.count == 1 } }
        let old = browser.sink.transfers.values.first
        let began = ProcessInfo.processInfo.systemUptime
        _ = try await browser.web.evaluateJavaScript("frames[0].location.reload()")
        try await wait { try await browser.web.evaluateJavaScript("frameLoads[0]===2") as? Bool == true }
        try await wait { try await self.rows(fixture).filter { $0["kind"] as? String == "first-block" }.count == 2 }
        var extra: [String: Any] = ["nativeNavigationGuard": guardNavigation,
            "pagehideHandlerIntentionallySuppressed": mode != .control, "oldDocumentFullBodyClaimed": false]
        if let old {
            try await wait { browser.sink.transfers.values.contains { $0.cap != old.cap } }
            let next = try #require(browser.sink.transfers.values.first { $0.cap != old.cap })
            try #require(old.metadata["privateDocumentTokenSHA256"] as? String != next.metadata["privateDocumentTokenSHA256"] as? String)
            if guardNavigation {
                try #require(browser.sink.transfers[old.cap] == nil && browser.sink.pending[old.cap] == nil)
                try #require(browser.sink.events.contains { $0["event"] as? String == "cancel" && $0["cap"] as? String == old.cap && $0["reason"] as? String == "native-subframe-navigation" })
                extra["oldCaptureRetiredBeforeServerReleaseAndTTL"] = true
            } else {
                try #require(browser.sink.transfers[old.cap] != nil)
                let attack = try await bridge(browser, frame: 0, body: ["session": browser.sink.session, "op": "cancel", "cap": old.cap, "reason": "old-capability-after-same-url-reload"])
                try #require(attack["accepted"] as? Bool == (mode == .urlKey))
                extra["staleCapabilityAttack"] = attack
                // This branch tests binding alone, so its stale capture is explicitly cleaned by the fixture.
                browser.sink.cancel(old.cap, reason: "fixture-cleanup-after-binding-check")
                extra["automaticOldCaptureCleanupClaimed"] = false
            }
            extra["secondsAfterReload"] = ProcessInfo.processInfo.systemUptime - began
            try #require(ProcessInfo.processInfo.systemUptime - began < 10)
        }
        try #require(!(try await rows(fixture)).contains { $0["kind"] as? String == "gate-release" })
        try await release(fixture, browser, label: label)
        let pages = try await pageResults(browser); try #require(pages.count == 1)
        if mode != .control { try await wait { browser.sink.completed.count == 1 } }
        try await finish(fixture, browser, label: label, mediaCount: 2, pages: pages, extra: extra)
        return pages
    }
    @Test func sameURLSiblingCapabilityIsRejectedByPrivateDocumentBinding() async throws {
        let control = try await twin(.control), raw = try await twin(.urlKey), candidate = try await twin(.document)
        #expect(try canonical(control) == canonical(raw)); #expect(try canonical(control) == canonical(candidate))
    }
    @Test func sameURLSubframeReplacementCannotReuseOldDocumentCapability() async throws {
        let control = try await reload(.control, guardNavigation: false)
        let raw = try await reload(.urlKey, guardNavigation: false), candidate = try await reload(.document, guardNavigation: false)
        #expect(try canonical(control) == canonical(raw)); #expect(try canonical(control) == canonical(candidate))
    }
    @Test func nativeSubframeReloadRetiresOldCaptureBeforeTTLAndWithoutPagehide() async throws {
        let control = try await reload(.control, guardNavigation: false), candidate = try await reload(.document, guardNavigation: true)
        #expect(try canonical(control) == canonical(candidate))
    }
    private func preciseSiblingReload(_ mode: Mode, historyPath: Bool = false, urlPrefilter: Bool = false) async throws -> [[String: Any]] {
        let label = (historyPath ? "history-path-sibling-reload-" : "precise-sibling-reload-") + mode.rawValue + (urlPrefilter ? "-url-prefilter" : "")
        let (fixture, browser) = try await create(label, mode: mode, frames: 2, guardNavigation: true, urlPrefilter: urlPrefilter)
        defer { browser.close(); fixture.stop() }
        if mode != .control { try await wait { browser.sink.transfers.count == 2 && browser.sink.pending.count == 2 } }
        let old = browser.sink.transfers.values.first { $0.metadata["fixtureFrameName"] as? String == "f0" }
        let sibling = browser.sink.transfers.values.first { $0.metadata["fixtureFrameName"] as? String == "f1" }
        if historyPath {
            _ = try await browser.web.evaluateJavaScript("frames[0].history.pushState({},'', '/lifetime/alias'+frames[0].location.search)")
            try await wait { try await browser.web.evaluateJavaScript("frames[0].location.pathname==='/lifetime/alias'") as? Bool == true }
            if let old { try #require(browser.sink.transfers[old.cap] != nil) }
        }
        let began = ProcessInfo.processInfo.systemUptime
        _ = try await browser.web.evaluateJavaScript("frames[0].location.reload()")
        try await wait { try await browser.web.evaluateJavaScript("frameLoads[0]===2 && frameLoads[1]===1") as? Bool == true }
        try await wait { try await self.rows(fixture).filter { $0["kind"] as? String == "first-block" }.count == 3 }
        var extra: [String: Any] = ["nativeNavigationGuard": true, "pagehideHandlerIntentionallySuppressed": mode != .control,
            "oldDocumentFullBodyClaimed": false, "preciseSameURLSiblingRetirementTest": true,
            "historyPathChangedBeforeReload": historyPath, "URLPrefilterNegativeControl": urlPrefilter]
        if let old, let sibling, historyPath && urlPrefilter {
            try await wait { browser.sink.events.contains { $0["event"] as? String == "capacity-rejected" } }
            try #require(browser.sink.transfers[old.cap] != nil && browser.sink.pending[old.cap] != nil)
            try #require(browser.sink.transfers[sibling.cap] != nil && browser.sink.pending[sibling.cap] != nil)
            try #require(!browser.sink.retiredDocumentTokens.contains(old.frame))
            extra["oldCaptureMissedByURLPrefilterBeforeFixtureCleanup"] = true
            extra["secondsAfterReload"] = ProcessInfo.processInfo.systemUptime - began
            // Preserve the negative observation, then release its abandoned spool for fixture closure.
            browser.sink.cancel(old.cap, reason: "fixture-cleanup-after-history-path-negative-control")
        } else if let old, let sibling {
            try await wait { browser.sink.transfers.count == 2 && browser.sink.pending.count == 2 }
            try #require(browser.sink.transfers[old.cap] == nil && browser.sink.pending[old.cap] == nil)
            try #require(browser.sink.transfers[sibling.cap] != nil && browser.sink.pending[sibling.cap] != nil)
            try #require(!browser.sink.events.contains { $0["event"] as? String == "cancel" && $0["cap"] as? String == sibling.cap })
            let next = try #require(browser.sink.transfers.values.first { $0.cap != sibling.cap })
            try #require(next.metadata["fixtureFrameName"] as? String == "f0" && next.frame != old.frame && next.frame != sibling.frame)
            extra["sameURLSiblingCapabilityPreserved"] = true
            extra["oldCaptureRetiredBeforeServerReleaseAndTTL"] = true
            extra["retiredDocumentSHA256"] = FrameDocumentResponseSink.hash(Data(old.frame.utf8))
            extra["preservedSiblingDocumentSHA256"] = FrameDocumentResponseSink.hash(Data(sibling.frame.utf8))
            extra["secondsAfterReload"] = ProcessInfo.processInfo.systemUptime - began
            try #require(ProcessInfo.processInfo.systemUptime - began < 10)
            try #require(browser.sink.retiredDocumentTokens.contains(old.frame) && !browser.sink.retiredDocumentTokens.contains(sibling.frame))
        }
        try #require(!(try await rows(fixture)).contains { $0["kind"] as? String == "gate-release" })
        try await release(fixture, browser, label: label)
        let pages = try await pageResults(browser); try #require(pages.count == 2)
        if mode != .control { try await wait { browser.sink.completed.count == (historyPath && urlPrefilter ? 1 : 2) } }
        try await finish(fixture, browser, label: label, mediaCount: 3, pages: pages, extra: extra)
        return pages
    }
    @Test func sameURLSiblingCaptureSurvivesPreciseNativeReloadRetirement() async throws {
        let control = try await preciseSiblingReload(.control), candidate = try await preciseSiblingReload(.document)
        #expect(try canonical(control) == canonical(candidate))
    }
    @Test func historyPathChangeCannotHideOldCaptureFromPreciseNativeReloadRetirement() async throws {
        let control = try await preciseSiblingReload(.control, historyPath: true)
        let raw = try await preciseSiblingReload(.document, historyPath: true, urlPrefilter: true)
        let candidate = try await preciseSiblingReload(.document, historyPath: true)
        #expect(try canonical(control) == canonical(raw)); #expect(try canonical(control) == canonical(candidate))
    }
    @Test func sameDocumentSubframeFragmentKeepsPrivateBinding() async throws {
        let label = "subframe-fragment-document"
        let (fixture, browser) = try await create(label, mode: .document, frames: 1, guardNavigation: true)
        defer { browser.close(); fixture.stop() }
        try await wait { browser.sink.transfers.count == 1 && browser.sink.pending.count == 1 }
        let cap = try #require(browser.sink.transfers.keys.first)
        _ = try await browser.web.evaluateJavaScript("frames[0].location.hash='same-document'")
        try await wait { try await browser.web.evaluateJavaScript("frames[0].location.hash==='#same-document'") as? Bool == true }
        try #require(browser.sink.transfers[cap] != nil)
        try await release(fixture, browser, label: label)
        let pages = try await pageResults(browser)
        try await wait { browser.sink.completed.count == 1 }
        try await finish(fixture, browser, label: label, mediaCount: 1, pages: pages,
            extra: ["sameDocumentFragmentCaptureCompleted": true, "originalCapabilityPreserved": true])
    }
    @Test func timedOutPrivateWorldLookupsKeepSlotsUntilWebKitActuallyReturns() async throws {
        let label = "document-probe-capacity"
        let (fixture, browser) = try await create(label, mode: .control, frames: 0, timeout: 100, maximum: 2, delay: 700)
        defer { browser.close(); fixture.stop() }
        let wrong = try await bridge(browser, frame: nil, body: ["session": "not-the-native-session", "op": "open"])
        try #require(wrong["accepted"] as? Bool == false && browser.sink.documentGate.started == 0)
        let values = try await browser.web.callAsyncJavaScript("""
        return await Promise.all([0,1,2].map(async()=>{
          try {await webkit.messageHandlers.responseClone.postMessage({session,op:'open',api:'fixture',url:'/media/forged',type:'basic',status:200});return 'accepted'}
          catch(error){return String(error)}
        }));
        """, arguments: ["session": browser.sink.session], in: nil, contentWorld: .page) as? [String] ?? []
        try #require(values.count == 3 && values.filter { $0.contains("deadline") }.count == 2 && values.filter { $0.contains("capacity") }.count == 1)
        try #require(browser.sink.documentGate.outstanding.count == 2 && browser.sink.documentGate.highWater == 2)
        let fourth = try await bridge(browser, frame: nil, body: ["session": browser.sink.session, "op": "open"])
        try #require(fourth["accepted"] as? Bool == false && (fourth["error"] as? String ?? "").contains("capacity"))
        try await wait { browser.sink.documentGate.outstanding.isEmpty }
        try #require(browser.sink.documentGate.started == 2 && browser.sink.documentGate.returned == 2)
        try #require(browser.sink.transfers.isEmpty && browser.sink.completed.isEmpty && browser.sink.retainedBytes == 0)
        try #require(!browser.sink.events.contains { $0["event"] as? String == "open" })
        try await finish(fixture, browser, label: label, mediaCount: 0, pages: [],
            extra: ["lateLookupCannotAdmitTimedOutMessage": true, "knownSessionFaultInjectionOnly": true,
                "unknownSessionRejectedBeforeLookup": true, "firstThreeReplies": values, "fourthReply": fourth])
    }
    private func canonical(_ pages: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: pages, options: .sortedKeys) }
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
private final class FrameDocumentBrowser: SeedBrowser {
    let web: WKWebView, sink: FrameDocumentResponseSink
    private let guardNavigation: Bool
    private let urlPrefilter: Bool
    private var closed = false
    private(set) var finishes = 0
    private(set) var actions: [[String: Any]] = []
    init(fixture: SeedScopeFixture, observer: Bool, documentBinding: Bool, guardNavigation: Bool,
        timeout: Int, maximum: Int, delay: Int, urlPrefilter: Bool) throws {
        self.guardNavigation = guardNavigation; self.urlPrefilter = urlPrefilter
        sink = try FrameDocumentResponseSink(root: fixture.root.appendingPathComponent("spool"), useDocumentBinding: documentBinding,
            probeTimeout: timeout, maximumLookups: maximum, probeDelay: delay)
        sink.lifetimeMilliseconds = 30000; sink.holdAcknowledgements = true
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); fixture.configure(config.websiteDataStore)
        config.userContentController.addScriptMessageHandler(sink, contentWorld: .page, name: "responseClone")
        let probe = """
        (()=>{const raw=fetch,apply=Reflect.apply,then=Promise.prototype.then;window.__lifetimeNative=[];
          window.fetch=function(...args){const p=apply(raw,this,args),row={promise:p,response:null};window.__lifetimeNative.push(row);
            void apply(then,p,[r=>{row.response=r},()=>{}]);return p};})();
        """
        var scripts = [probe]
        if observer {
            var source = try String(contentsOf: OriginalResponseFixture.tools.appendingPathComponent("wk_fetch_lifetime_observer.js"), encoding: .utf8)
            let hook = "apply(addEvent, window, ['pagehide', () => { for (const stop of active) stop('pagehide'); }]);"
            guard source.contains(hook) else { throw URLError(.cannotParseResponse) }
            source = source.replacingOccurrences(of: hook, with: "/* Fixture disables pagehide to test native frame retirement. */")
                .replacingOccurrences(of: "__SESSION__", with: sink.session).replacingOccurrences(of: "__CAPTURE_LIFETIME_MS__", with: "30000")
            scripts.append(source)
        }
        for source in scripts { config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)) }
        web = WKWebView(frame: .zero, configuration: config)
        super.init(certificate: fixture.certificate); web.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishes += 1 }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let frame = navigationAction.targetFrame, !frame.isMainFrame {
            let old = frame.request.url?.absoluteString ?? "", next = navigationAction.request.url?.absoluteString ?? ""
            let sameBase = FrameDocumentGate.normalized(old) == FrameDocumentGate.normalized(next)
            let fragment = sameBase && navigationAction.navigationType != .reload && URLComponents(string: next)?.fragment != nil
            actions.append(["old": old, "next": next, "type": navigationAction.navigationType.rawValue, "fragmentExemption": fragment])
            let group = FrameDocumentGate.group(frame)
            let hasCapture = sink.transfers.values.contains { $0.metadata["nativeFrameGroup"] as? String == group }
                || sink.completed.contains { $0.metadata["nativeFrameGroup"] as? String == group }
            // A History API path change does not create a document. URL grouping is diagnostic only.
            let hasAnyCapture = !sink.transfers.isEmpty || !sink.completed.isEmpty
            if guardNavigation && !fragment && (urlPrefilter ? hasCapture : hasAnyCapture) {
                // The navigation target can describe its destination request; the private realm is authoritative here.
                sink.documentGate.lookup(web: webView, frame: frame, requireSnapshotURL: false) { [weak self] result in
                    guard let self else { decisionHandler(.allow); return }
                    switch result {
                    case .success(let binding):
                        self.sink.retireDocument(binding.token)
                        self.actions.append(["privateDocumentRetiredSHA256": FrameDocumentResponseSink.hash(Data(binding.token.utf8)),
                            "boundHref": binding.href])
                    case .failure(let error):
                        self.sink.retire()
                        self.actions.append(["nativeLookupFailureRetiredCaptureSession": String(describing: error)])
                    }
                    decisionHandler(.allow)
                }
                return
            }
        }
        decisionHandler(.allow)
    }
    func close() {
        guard !closed else { return }; closed = true
        sink.retire(); web.stopLoading(); web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "responseClone", contentWorld: .page)
    }
}
