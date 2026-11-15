import Foundation
import Testing
import WebKit

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_WK_INTRINSICS_EVIDENCE_DIR"] != nil))
@MainActor
struct WKFetchIntrinsicSnapshotTests {
    private struct Receipt { let page: [String: Any]; let body: Data; let expected: Data; let byteViewLookups: Int }

    private func observe(_ label: String, hardened: Bool, scenario: String = "fetch", prelude: String = "", observerName: String? = nil) async throws -> Receipt {
        let fixture = try OriginalResponseFixture()
        defer { fixture.stop() }
        let name = observerName ?? (hardened ? "wk_response_intrinsics_observer.js" : "wk_response_clone_observer.js")
        let source = try String(contentsOf: OriginalResponseFixture.tools.appendingPathComponent(name), encoding: .utf8)
            .replacingOccurrences(of: "__CAPTURE_LIFETIME_MS__", with: "3000")
        let browser = try IntrinsicSnapshotBrowser(fixture: fixture.f, observer: source, prelude: prelude)
        defer { browser.retire() }
        browser.web.load(URLRequest(url: try #require(URL(string: fixture.url("/clone/page", label, ["scenario": scenario])))))
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
        try #require(page["sha256"] as? String == OriginalResponseSink.hash(fixture.media))
        try #require(page["sameNativePromise"] as? Bool == true && page["sameNativeResponse"] as? Bool == true)
        try #require(page["bodyUsedBefore"] as? Bool == false && page["bodyUsedAfter"] as? Bool == true)
        try #require(page["secondReadError"] as? String == "TypeError")
        try #require(browser.sink.completed.count == 1 && browser.sink.maxChunk <= OriginalResponseSink.chunkLimit)
        let lookups = try #require(try await browser.web.evaluateJavaScript("window.__byteViewLookups || 0") as? Int)
        let receipt = fixture.root.appendingPathComponent(label + ".capture.json")
        try browser.sink.snapshot(to: receipt, extra: ["page": page, "hardened": hardened,
            "attack": label, "observer": name, "byteViewLookups": lookups, "mediaRequests": rows.count, "arbitraryPageAttestation": false,
            "wholeResponseBackpressure": false])
        return Receipt(page: page, body: body, expected: fixture.media, byteViewLookups: lookups)
    }

    @Test(arguments: ["wk_response_intrinsics_observer.js", "wk_fetch_lifetime_observer.js",
                      "wk_xhr_intrinsics_observer.js", "wk_xhr_bounded_snapshot_observer.js"])
    func pageSpeciesCannotReplaceBridgeBytes(observer: String) async throws {
        // A local page customization must not supply the observer's byte views.
        let prelude = """
        (()=>{const Bytes=Uint8Array;window.__byteViewLookups=0;
          Object.defineProperty(Bytes,Symbol.species,{configurable:true,get(){
            window.__byteViewLookups++;
            return function(_buffer,_offset,length){const bytes=new Bytes(length);
              for(let index=0;index<length;index++)bytes[index]=37;return bytes;};
          }});
        })();
        """
        let result = try await observe(observer + "-species", hardened: true, prelude: prelude, observerName: observer)
        let exactBytes = result.body == result.expected
        #expect(exactBytes)
        #expect(result.byteViewLookups == 0)
    }

    @Test(arguments: ["wk_response_intrinsics_observer.js", "wk_fetch_lifetime_observer.js",
                      "wk_xhr_intrinsics_observer.js", "wk_xhr_bounded_snapshot_observer.js"])
    func pageConstructorGetterIsNotInvokedByBridge(observer: String) async throws {
        let prelude = """
        (()=>{const Bytes=Uint8Array;window.__byteViewLookups=0;
          Object.defineProperty(Bytes.prototype,'constructor',{configurable:true,get(){
            window.__byteViewLookups++;return Bytes;
          }});
        })();
        """
        let result = try await observe(observer + "-constructor", hardened: true, prelude: prelude, observerName: observer)
        let exactBytes = result.body == result.expected
        #expect(exactBytes)
        #expect(result.byteViewLookups == 0)
    }

    @Test func capturedCloneRejectsKnownReplacementWithoutChangingPageObjects() async throws {
        let baseline = try await observe("clone-original", hardened: false, scenario: "spoof")
        let candidate = try await observe("clone-snapshot", hardened: true, scenario: "spoof")
        let forged = Data("forged-page-body".utf8)
        #expect(baseline.body == forged && baseline.body != baseline.expected)
        #expect(candidate.body == candidate.expected && candidate.body != forged)
        #expect(baseline.page["cloneSHA256"] as? String == OriginalResponseSink.hash(forged))
        #expect(candidate.page["cloneSHA256"] as? String == baseline.page["cloneSHA256"] as? String)
    }

    @Test func capturedBodyGetterKeepsActualResponseBytes() async throws {
        let prelude = """
        Object.defineProperty(Response.prototype,'body',{configurable:true,get(){
          return new ReadableStream({start(controller){
            controller.enqueue(new TextEncoder().encode('forged-body-getter'));controller.close();
          }});
        }});
        """
        let baseline = try await observe("getter-original", hardened: false, prelude: prelude)
        let candidate = try await observe("getter-snapshot", hardened: true, prelude: prelude)
        #expect(baseline.body == Data("forged-body-getter".utf8) && baseline.body != baseline.expected)
        #expect(candidate.body == candidate.expected)
        #expect(candidate.page["cloneSHA256"] as? String == OriginalResponseSink.hash(candidate.expected))
    }

    @Test func capturedReaderMethodKeepsActualResponseBytes() async throws {
        let prelude = """
        (()=>{const seen=new WeakSet();
          ReadableStreamDefaultReader.prototype.read=function(){
            if(seen.has(this))return Promise.resolve({done:true,value:undefined});
            seen.add(this);return Promise.resolve({done:false,value:new TextEncoder().encode('forged-reader-method')});
          };
        })();
        """
        let baseline = try await observe("reader-original", hardened: false, prelude: prelude)
        let candidate = try await observe("reader-snapshot", hardened: true, prelude: prelude)
        #expect(baseline.body == Data("forged-reader-method".utf8) && baseline.body != baseline.expected)
        #expect(candidate.body == candidate.expected)
        #expect(candidate.page["cloneSHA256"] as? String == OriginalResponseSink.hash(candidate.expected))
    }
}

@MainActor
private final class IntrinsicSnapshotBrowser: SeedBrowser {
    let web: WKWebView
    let sink: OriginalResponseSink
    private var active = true

    init(fixture: SeedScopeFixture, observer: String, prelude: String) throws {
        sink = try OriginalResponseSink(root: fixture.root.appendingPathComponent("spool"))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        fixture.configure(config.websiteDataStore)
        let recorder = """
        (()=>{const raw=fetch;window.fetch=function(...args){const p=Reflect.apply(raw,this,args);
          window.__nativePromise=p;void p.then(r=>window.__nativeResponse=r,()=>{});return p;};})();
        """
        config.userContentController.addScriptMessageHandler(sink, contentWorld: .page, name: "responseClone")
        for source in [recorder, observer.replacingOccurrences(of: "__SESSION__", with: sink.session), prelude] where !source.isEmpty {
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
