import Foundation
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil))
@MainActor
struct WKNativeMediaTests {
    private func loaded(_ page: [String: Any], canvas: Bool = true) {
        #expect(page["outcome"] as? String == "loaded")
        #expect(page["width"] as? Int == 64 && page["height"] as? Int == 64)
        #expect((page["currentTime"] as? Double ?? 0) >= 0.25)
        #expect((page["duration"] as? Double ?? 0) >= 1.9)
        #expect((page["canvas"] as? [String: Any])?["readable"] as? Bool == canvas)
    }
    private func noRawResponse(_ b: NativeMediaBrowser, _ page: [String: Any]) {
        #expect(b.sink.completed.isEmpty && b.sink.transfers.isEmpty && b.sink.retainedBytes == 0)
        #expect((page["apiCalls"] as? [String: Int]) == ["fetch": 0, "xhr": 0])
        #expect(!b.sink.events.contains { $0["event"] as? String == "open" })
        #expect(b.candidates.contains { $0["kind"] as? String == "media" && $0["source"] as? String == "dom" })
        #expect(!b.actions.contains { $0.contains("/media/") && !$0.contains("/native/page") })
        #expect(!b.responses.contains { $0.contains("/media/") && !$0.contains("/native/page") })
    }
    @Test func originalHTMLSrcSourceAndDynamicSrcKeepNativePlaybackOutsideFetchClone() async throws {
        let h = try NativeMediaFixture(); defer { h.stop() }
        for mode in ["html-src", "html-source", "dynamic-src"] {
            let control = try await h.browser("control-" + mode, ["mode": mode], observe: false); defer { control.retire() }
            let plain = try await control.page(); loaded(plain)
            let b = try await h.browser(mode, ["mode": mode]); defer { b.retire() }
            let page = try await b.page(); loaded(page); noRawResponse(b, page)
            for key in ["outcome", "width", "height", "duration", "error", "playError"] {
                #expect(String(describing: page[key] ?? NSNull()) == String(describing: plain[key] ?? NSNull()))
            }
            #expect(page["documentCookie"] as? String == "")
            for label in ["control-" + mode, mode] {
                let rows = try await h.mediaRows(label)
                #expect(!rows.isEmpty)
                #expect(rows.allSatisfy { ($0["headers"] as? [String: String])?["cookie"] == "account=fresh" })
                #expect(rows.contains { ($0["headers"] as? [String: String])?["range"] != nil && $0["status"] as? Int == 206 })
            }
            try h.save(mode, b, page, extra: ["control": plain, "controlMediaRequests": try await h.mediaRows("control-" + mode).count, "observedMediaRequests": try await h.mediaRows(mode).count])
        }
    }
    @Test func nativeRedirectsUseBrowserRangeAndRotatedCookieWithoutFetchOrReplay() async throws {
        let h = try NativeMediaFixture(); defer { h.stop() }
        for cross in [false, true] {
            let label = cross ? "cross-redirect" : "rotation-redirect"
            let target = h.url("/media/native.mp4", label, ["expect": cross ? "" : "redirected"], host: cross ? "sibling.example.test" : "video.example.test")
            let redirect = h.url("/media/redirect", label, ["target": target, "rotate": "1"])
            let b = try await h.browser(label, ["target": redirect]); defer { b.retire() }
            let page = try await b.page(); loaded(page, canvas: !cross); noRawResponse(b, page)
            let rows = try await h.mediaRows(label)
            let final = rows.filter { $0["path"] as? String == "/media/native.mp4" }
            #expect(!final.isEmpty && rows.contains { $0["status"] as? Int == 302 })
            #expect(final.allSatisfy { ($0["headers"] as? [String: String])?["cookie"] == (cross ? nil : "account=redirected") })
            #expect(final.contains { $0["status"] as? Int == 206 })
            try h.save(label, b, page)
        }
    }
    @Test func crossOriginNativeDisplayAndCanvasCORSDoNotGrantRawResponseBytes() async throws {
        let h = try NativeMediaFixture(); defer { h.stop() }
        for mode in ["no-cors", "cors-allow", "cors-deny"] {
            let target = h.url("/media/native.mp4", mode, ["expect": "", "cors": mode == "cors-allow" ? "allow" : "none"], host: "sibling.example.test")
            let extra = ["target": target, "crossorigin": mode == "no-cors" ? "" : "anonymous"]
            var controlExtra = extra
            controlExtra["target"] = h.url("/media/native.mp4", "control-" + mode, ["expect": "", "cors": mode == "cors-allow" ? "allow" : "none"], host: "sibling.example.test")
            let control = try await h.browser("control-" + mode, controlExtra, observe: false); defer { control.retire() }
            let plain = try await control.page()
            let b = try await h.browser(mode, extra); defer { b.retire() }
            let page = try await b.page(); noRawResponse(b, page)
            #expect(page["outcome"] as? String == plain["outcome"] as? String)
            if mode == "cors-deny" {
                #expect(page["outcome"] as? String == "error" && page["error"] as? Int == 4)
            } else { loaded(page, canvas: mode == "cors-allow") }
            if mode == "no-cors" { #expect((page["canvas"] as? [String: Any])?["error"] as? String == "SecurityError") }
            let rows = try await h.mediaRows(mode)
            #expect(!rows.isEmpty && rows.allSatisfy { [200, 206].contains($0["status"] as? Int ?? 0) })
            #expect(rows.allSatisfy { ($0["headers"] as? [String: String])?["cookie"] == nil })
            try h.save(mode, b, page, extra: ["control": plain])
        }
    }
    @Test func declaredDOMCandidateCanPrecedeAnyOriginalMediaRequest() async throws {
        let h = try NativeMediaFixture(); defer { h.stop() }
        let b = try await h.browser("preload-none", ["preload": "none"]); defer { b.retire() }
        try await h.wait { b.candidates.contains { $0["kind"] as? String == "media" } }
        try await Task.sleep(for: .milliseconds(300))
        let page = try await b.script("return nativeSnapshot();"); noRawResponse(b, page)
        let rows = try await h.mediaRows("preload-none")
        #expect(rows.isEmpty && page["readyState"] as? Int == 0)
        try h.save("preload-none", b, page)
    }
    @Test func originalPageCancellationDrainsHoldWithoutFollowingLateMediaRedirect() async throws {
        let h = try NativeMediaFixture(); defer { h.stop() }
        let label = "page-cancel"
        let late = h.url("/media/native.mp4", label)
        let b = try await h.browser(label, ["target": h.url("/media/hold", label, ["target": late])], waitForMediaNavigation: false); defer { b.retire() }
        try await h.wait { try await h.mediaRows(label).contains { $0["path"] as? String == "/media/hold" } }
        let cancelled = try await b.script("return cancelOriginal();")
        try await h.release(label)
        let page = try await b.script("return nativeSnapshot();"); noRawResponse(b, page)
        #expect(try await h.mediaRows(label).allSatisfy { $0["path"] as? String == "/media/hold" })
        try h.save(label, b, page, extra: ["cancelSnapshot": cancelled, "postDrainObservationMS": 400])
    }
    @Test func nativeRetirementAndReplacementRejectOldSessionAndCookie() async throws {
        let h = try NativeMediaFixture(); defer { h.stop() }
        let label = "native-retire", late = h.url("/media/native.mp4", "native-retire")
        let b = try await h.browser(label, ["target": h.url("/media/hold", label, ["target": late])], waitForMediaNavigation: false)
        try await h.wait { try await h.mediaRows(label).contains { $0["path"] as? String == "/media/hold" } }
        let before = try await b.script("return nativeSnapshot();")
        b.retire()
        try await h.release(label)
        #expect(!b.sink.active && !b.active && b.sink.retainedBytes == 0)
        #expect(try await h.mediaRows(label).allSatisfy { $0["path"] as? String == "/media/hold" })
        try h.save(label, b, before, extra: ["postDrainObservationMS": 400])
        let target = h.url("/media/native.mp4", "replacement", ["expect": ""])
        let next = try await h.browser("replacement", ["seed": "0", "target": target]); defer { next.retire() }
        let page = try await next.page(); loaded(page); noRawResponse(next, page)
        #expect(next.sink.session != b.sink.session)
        #expect(try await h.mediaRows("replacement").allSatisfy { ($0["headers"] as? [String: String])?["cookie"] == nil })
        let stale = try await next.web.callAsyncJavaScript("try {await webkit.messageHandlers.responseClone.postMessage({session,op:'open'});return {accepted:true};} catch {return {rejected:true};}", arguments: ["session": b.sink.session], in: nil, contentWorld: .page)
        #expect((stale as? [String: Bool])?["rejected"] == true)
        try h.save("replacement", next, page, extra: ["oldSessionRejected": true])
    }
}
