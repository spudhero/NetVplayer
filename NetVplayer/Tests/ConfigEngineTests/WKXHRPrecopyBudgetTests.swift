import Foundation
import Testing
import WebKit

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_WK_XHR_BUDGET_EVIDENCE_DIR"] != nil))
@MainActor
struct WKXHRPrecopyBudgetTests {
    private struct Receipt { let page: [String: Any]; let probe: [String: Int] }

    private func wait(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }

    private func observe(_ label: String, bounded: Bool, type: String, path: String, expected: Data, rejected: Bool, control: Bool = false) async throws -> Receipt {
        let fixture = try SeedScopeFixture(scriptName: "wk_xhr_budget_fixture.py", evidenceEnvironment: "NETVPLAYER_WK_XHR_BUDGET_EVIDENCE_DIR")
        defer { fixture.stop() }
        let filename = bounded ? "wk_xhr_bounded_snapshot_observer.js" : "wk_xhr_intrinsics_observer.js"
        let observer = control ? "" : try String(contentsOf: OriginalResponseFixture.tools.appendingPathComponent(filename), encoding: .utf8)
        let browser = try XHRBudgetBrowser(fixture: fixture, observer: observer)
        defer { browser.retire() }
        var url = URLComponents(string: "https://video.example.test/clone/page")!
        url.queryItems = ["case":label, "type":type, "target":path].map { URLQueryItem(name: $0.key, value: $0.value) }
        browser.web.load(URLRequest(url: try #require(url.url)))
        try await wait {
            _ = try? await browser.web.evaluateJavaScript("void(0)")
            return browser.result != nil
        }
        try #require(browser.result == "ready")
        let value = try await browser.web.callAsyncJavaScript("return await pagePending;", arguments: [:], in: nil, contentWorld: .page)
        var page = try #require(value as? [String: Any])
        let rawEvents = try #require(page["events"] as? [String])
        var transitions: [String] = []
        for event in rawEvents {
            if transitions.last == event {
                try #require(event == "readystatechange:3", "Only repeated native LOADING notifications may collapse")
            } else { transitions.append(event) }
        }
        try #require(transitions == ["readystatechange:2","readystatechange:3","readystatechange:4","load:4","loadend:4"])
        page["normalizedEvents"] = transitions
        try #require(page["bytes"] as? Int == expected.count && page["sha256"] as? String == OriginalResponseSink.hash(expected))
        try #require(page["status"] as? Int == 200 && page["responseIdentity"] as? Bool == true)
        try #require(page["sendReturnedUndefined"] as? Bool == true && page["documentCookie"] as? String == "")
        if control {
            try #require(browser.sink.events.isEmpty && browser.sink.completed.isEmpty && browser.sink.transfers.isEmpty)
        } else if rejected {
            let reason = bounded ? "xhr-body-limit" : "capture-stopped"
            try await wait { browser.sink.events.contains { $0["reason"] as? String == reason } }
            try #require(browser.sink.completed.isEmpty && browser.sink.transfers.isEmpty)
            try #require(browser.sink.retainedBytes == 0)
            if bounded { try #require(!browser.sink.events.contains { $0["event"] as? String == "open" }) }
        } else {
            try await wait { browser.sink.completed.count == 1 }
            let transfer = try #require(browser.sink.completed.first)
            try #require(browser.sink.bytes(transfer) == expected)
            try #require(browser.sink.maxChunk <= OriginalResponseSink.chunkLimit)
        }
        let probeValue = try await browser.web.evaluateJavaScript("window.__xhrBudgetProbe")
        let probe = try #require(probeValue as? [String: Int])
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(fixture.port)/control/records")!)
        let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let media = rows.filter { $0["kind"] as? String == "request" && ($0["path"] as? String ?? "").hasPrefix("/media/") }
        try #require(media.count == 1 && media.first?["status"] as? Int == 200)
        try browser.sink.snapshot(to: fixture.root.appendingPathComponent(label + ".capture.json"), extra: [
            "page":page, "probe":probe, "bounded":bounded, "rejected":rejected, "control":control,
            "expectedBodyBytes":expected.count, "expectedSHA256":OriginalResponseSink.hash(expected),
            "instrumentationRunsBeforeObserver":true, "pagePatchesSizeGettersAfterObserver":true,
            "testOnlyTransferLifetimeMilliseconds":8000, "mediaRequests":media.count,
            "arbitraryPageAttestation":false, "wholeResponseBackpressure":false])
        return Receipt(page: page, probe: probe)
    }

    private func check(_ label: String, type: String, path: String, expected: Data, rejected: Bool) async throws {
        let control1 = try await observe(label + "-control-1", bounded: false, type: type, path: path, expected: expected, rejected: rejected, control: true)
        let control2 = try await observe(label + "-control-2", bounded: false, type: type, path: path, expected: expected, rejected: rejected, control: true)
        let before = try await observe(label + "-before", bounded: false, type: type, path: path, expected: expected, rejected: rejected)
        let after = try await observe(label + "-bounded", bounded: true, type: type, path: path, expected: expected, rejected: rejected)
        let fields = ["type","status","responseIdentity","sendReturnedUndefined","normalizedEvents","bytes","sha256","textUnits","documentCookie"]
        let reference = try JSONSerialization.data(withJSONObject:control1.page.filter { fields.contains($0.key) },options:.sortedKeys)
        for receipt in [control2,before,after] {
            let actual = try JSONSerialization.data(withJSONObject:receipt.page.filter { fields.contains($0.key) },options:.sortedKeys)
            #expect(reference == actual)
        }
        #expect(control1.probe.values.allSatisfy { $0 == 0 } && control2.probe.values.allSatisfy { $0 == 0 })
        if rejected {
            #expect(before.probe["streamCalls"] == 1)
            #expect(after.probe.values.allSatisfy { $0 == 0 })
            if type == "arraybuffer" { #expect(before.probe["sliceInputBytes"] == expected.count) }
            if type != "blob" { #expect(before.probe["constructedBlobBytes"] == expected.count) }
        } else {
            #expect(before.probe == after.probe)
            #expect(after.probe["streamCalls"] == 1)
        }
    }

    @Test func arrayBufferIsRejectedBeforeFullCopy() async throws {
        try await check("arraybuffer-over", type:"arraybuffer", path:"/media/big", expected:Data(repeating:120,count:2097152), rejected:true)
    }
    @Test func blobIsRejectedBeforeOpeningStream() async throws {
        try await check("blob-over", type:"blob", path:"/media/big", expected:Data(repeating:120,count:2097152), rejected:true)
    }
    @Test func asciiTextIsRejectedBeforeBlobConstruction() async throws {
        try await check("text-over", type:"text", path:"/media/big", expected:Data(repeating:120,count:2097152), rejected:true)
    }
    @Test func utf8ByteCountRejectsShorterString() async throws {
        try await check("utf8-over", type:"text", path:"/media/budget-utf8-over", expected:Data((String(repeating:"😀",count:262144)+"é").utf8), rejected:true)
    }
    @Test func compressedBodyUsesDecodedLength() async throws {
        try await check("gzip-over", type:"arraybuffer", path:"/media/gzip", expected:Data(repeating:120,count:2097152), rejected:true)
    }
    @Test func exactArrayBufferBudgetStillCaptures() async throws {
        try await check("arraybuffer-exact", type:"arraybuffer", path:"/media/budget-binary-exact", expected:Data(repeating:120,count:1048576), rejected:false)
    }
    @Test func exactBlobBudgetStillCaptures() async throws {
        try await check("blob-exact", type:"blob", path:"/media/budget-binary-exact", expected:Data(repeating:120,count:1048576), rejected:false)
    }
    @Test func exactSupplementaryUTF8BudgetStillCaptures() async throws {
        try await check("utf8-exact", type:"text", path:"/media/budget-utf8-exact", expected:Data(String(repeating:"😀",count:262144).utf8), rejected:false)
    }
}

@MainActor
private final class XHRBudgetBrowser: SeedBrowser {
    let web: WKWebView
    let sink: OriginalResponseSink
    private var active = true

    init(fixture: SeedScopeFixture, observer: String) throws {
        sink = try OriginalResponseSink(root: fixture.root.appendingPathComponent("spool"))
        sink.lifetimeMilliseconds = 8000
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        fixture.configure(config.websiteDataStore)
        config.userContentController.addScriptMessageHandler(sink, contentWorld: .page, name: "responseClone")
        let instrumentation = """
        (()=>{
          const apply=Reflect.apply, getBuffer=Object.getOwnPropertyDescriptor(ArrayBuffer.prototype,'byteLength').get;
          const getSize=Object.getOwnPropertyDescriptor(Blob.prototype,'size').get;
          const slice=ArrayBuffer.prototype.slice, stream=Blob.prototype.stream, OriginalBlob=Blob;
          const counts=window.__xhrBudgetProbe={sliceCalls:0,sliceInputBytes:0,blobConstructions:0,constructedBlobBytes:0,streamCalls:0};
          ArrayBuffer.prototype.slice=function(...args){counts.sliceCalls++;counts.sliceInputBytes+=apply(getBuffer,this,[]);return apply(slice,this,args);};
          Blob.prototype.stream=function(...args){counts.streamCalls++;return apply(stream,this,args);};
          function InstrumentedBlob(...args){const blob=Reflect.construct(OriginalBlob,args);counts.blobConstructions++;counts.constructedBlobBytes+=apply(getSize,blob,[]);return blob;}
          InstrumentedBlob.prototype=OriginalBlob.prototype;Object.setPrototypeOf(InstrumentedBlob,OriginalBlob);window.Blob=InstrumentedBlob;
        })();
        """
        let pagePatches = """
        Object.defineProperty(ArrayBuffer.prototype,'byteLength',{configurable:true,get(){return 0;}});
        Object.defineProperty(Blob.prototype,'size',{configurable:true,get(){return 0;}});
        String.prototype.charCodeAt=function(){return 0;};
        """
        for source in [instrumentation, observer.replacingOccurrences(of:"__SESSION__",with:sink.session), pagePatches] {
            config.userContentController.addUserScript(WKUserScript(source:source,injectionTime:.atDocumentStart,forMainFrameOnly:false,in:.page))
        }
        web = WKWebView(frame:.zero,configuration:config)
        super.init(certificate:fixture.certificate)
        web.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { result = "ready" }
    func retire() {
        guard active else { return }; active = false
        sink.retire(); web.stopLoading(); web.load(URLRequest(url:URL(string:"about:blank")!))
        web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName:"responseClone",contentWorld:.page)
    }
}
