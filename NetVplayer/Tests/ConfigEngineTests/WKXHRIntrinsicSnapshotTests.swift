import Foundation
import Testing
import WebKit

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_WK_XHR_INTRINSICS_EVIDENCE_DIR"] != nil))
@MainActor
struct WKXHRIntrinsicSnapshotTests {
    private struct Receipt { let page: [String: Any]; let body: Data; let expected: Data }

    private func observe(_ label: String, hardened: Bool, type: String, prelude: String) async throws -> Receipt {
        let fixture = try OriginalResponseFixture()
        defer { fixture.stop() }
        let name = hardened ? "wk_xhr_intrinsics_observer.js" : "wk_response_intrinsics_observer.js"
        let source = try String(contentsOf: OriginalResponseFixture.tools.appendingPathComponent(name), encoding: .utf8)
        let browser = try XHRIntrinsicSnapshotBrowser(fixture: fixture.f, observer: source, prelude: prelude)
        defer { browser.retire() }
        browser.web.load(URLRequest(url: try #require(URL(string: fixture.url("/clone/page", label, ["scenario": "xhr", "type": type])))))
        try await fixture.wait {
            _ = try? await browser.web.evaluateJavaScript("void(0)")
            return browser.result != nil
        }
        try #require(browser.result == "ready")
        let value = try await browser.web.callAsyncJavaScript("return await pagePending;", arguments: [:], in: nil, contentWorld: .page)
        let page = try #require(value as? [String: Any])
        try await fixture.wait { !browser.sink.completed.isEmpty }
        let transfer = try #require(browser.sink.completed.first)
        let body = try browser.sink.bytes(transfer)
        let rows = try await fixture.mediaRows(label)
        try #require(rows.count == 1, "Observer must not add another media request")
        try #require(page["status"] as? Int == 200 && page["responseIdentity"] as? Bool == true)
        try #require(page["sendReturnedUndefined"] as? Bool == true)
        try #require(browser.sink.completed.count == 1 && browser.sink.maxChunk <= OriginalResponseSink.chunkLimit)
        let cookie = try #require(try await browser.web.evaluateJavaScript("document.cookie") as? String)
        try #require(cookie == "")
        try browser.sink.snapshot(to: fixture.root.appendingPathComponent(label + ".capture.json"), extra: [
            "page": page, "hardened": hardened, "attack": label, "mediaRequests": rows.count,
            "pageDocumentCookie": cookie, "arbitraryPageAttestation": false, "wholeResponseBackpressure": false])
        return Receipt(page: page, body: body, expected: fixture.media)
    }

    private func check(_ label: String, type: String, prelude: String, pageForged: Bool = false) async throws {
        let before = try await observe(label + "-original", hardened: false, type: type, prelude: prelude)
        let after = try await observe(label + "-snapshot", hardened: true, type: type, prelude: prelude)
        let forged = Data("forged-xhr-body".utf8)
        #expect(before.body == forged && before.body != before.expected)
        #expect(after.body == after.expected && after.body != forged)
        let expectedPage = OriginalResponseSink.hash(pageForged ? forged : after.expected)
        #expect(before.page["sha256"] as? String == expectedPage)
        #expect(after.page["sha256"] as? String == expectedPage)
        // Progress can repeat readystatechange while LOADING. Keep event order
        // and terminal events exact without requiring identical network chunking.
        func eventOrder(_ page: [String: Any]) throws -> [String] {
            let events = try #require(page["events"] as? [String])
            return events.reduce(into: [String]()) { order, event in
                if event != "readystatechange" || order.last != event { order.append(event) }
            }
        }
        #expect(try eventOrder(before.page) == ["readystatechange", "load", "loadend"])
        #expect(try eventOrder(after.page) == ["readystatechange", "load", "loadend"])
        #expect(before.page["bytes"] as? Int == after.page["bytes"] as? Int)
    }

    @Test func capturedXHRResponseGetterPreservesActualResponse() async throws {
        try await check("xhr-getter", type: "arraybuffer", prelude: """
        (()=>{const values=new WeakMap();
          Object.defineProperty(XMLHttpRequest.prototype,'response',{configurable:true,get(){
            if(!values.has(this))values.set(this,new TextEncoder().encode('forged-xhr-body').buffer);
            return values.get(this);
          }});
        })();
        """, pageForged: true)
    }

    @Test func capturedArrayBufferSlicePreservesActualResponse() async throws {
        try await check("xhr-slice", type: "arraybuffer", prelude: """
        ArrayBuffer.prototype.slice=function(){return new TextEncoder().encode('forged-xhr-body').buffer;};
        """)
    }

    @Test func capturedBlobStreamPreservesActualResponse() async throws {
        try await check("xhr-stream", type: "blob", prelude: """
        Blob.prototype.stream=function(){return new ReadableStream({start(controller){
          controller.enqueue(new TextEncoder().encode('forged-xhr-body'));controller.close();
        }});};
        """)
    }

    @Test func capturedBlobConstructorPreservesActualResponse() async throws {
        try await check("xhr-constructor", type: "arraybuffer", prelude: """
        (()=>{const OriginalBlob=Blob;window.Blob=function(){return new OriginalBlob(['forged-xhr-body']);};})();
        """)
    }
}

@MainActor
private final class XHRIntrinsicSnapshotBrowser: SeedBrowser {
    let web: WKWebView
    let sink: OriginalResponseSink
    private var active = true

    init(fixture: SeedScopeFixture, observer: String, prelude: String) throws {
        sink = try OriginalResponseSink(root: fixture.root.appendingPathComponent("spool"))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        fixture.configure(config.websiteDataStore)
        config.userContentController.addScriptMessageHandler(sink, contentWorld: .page, name: "responseClone")
        for source in [observer.replacingOccurrences(of: "__SESSION__", with: sink.session), prelude] {
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        web = WKWebView(frame: .zero, configuration: config)
        super.init(certificate: fixture.certificate)
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { result = "ready" }

    func retire() {
        guard active else { return }
        active = false
        sink.retire()
        web.stopLoading()
        web.load(URLRequest(url: URL(string: "about:blank")!))
        web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "responseClone", contentWorld: .page)
    }
}
