import Foundation
import Testing
import WebKit

@Suite(.serialized,.enabled(if:ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"] != nil && ProcessInfo.processInfo.environment["NETVPLAYER_LIBMPV_PATH"] != nil))
@MainActor
struct WKOriginalResponseCloneTests {
    private func checkPage(_ p:[String:Any],bytes:Data) {
        #expect(p["status"] as? Int == 200)
        #expect(p["bytes"] as? Int == bytes.count && p["sha256"] as? String == OriginalResponseSink.hash(bytes))
        #expect(p["cloneSHA256"] as? String == p["sha256"] as? String)
        #expect(p["sameNativePromise"] as? Bool == true && p["sameNativeResponse"] as? Bool == true)
        #expect(p["bodyUsedBefore"] as? Bool == false && p["bodyUsedAfter"] as? Bool == true)
        #expect(p["secondReadError"] as? String == "TypeError")
    }
    @Test func originalFetchResponseAndPageCloneStayReadableWithOneRequestAndDecode() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        let control=try await h.browser("plain",observe:false);defer{control.retire()}
        let plain=try await control.page();checkPage(plain,bytes:h.media)
        let b=try await h.browser("clone");defer{b.retire()}
        let page=try await b.page();checkPage(page,bytes:h.media);try await h.complete(b)
        #expect(page["documentCookie"] as? String == "")
        #expect(try b.sink.bytes(try #require(b.sink.completed.first)) == h.media)
        for label in ["plain","clone"] {
            let rows=try await h.mediaRows(label);#expect(rows.count==1)
            #expect((rows.first?["headers"] as? [String:String])?["cookie"] == "account=fresh")
        }
        try h.save("fetch",b,page,extra:["control":plain,"originalMediaRequests":1])
        try await h.play(b)
    }

    @Test func redirectRotationOmitAndRangeUseOriginalBrowserRequests() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        for mode in ["redirect","cross","omit","range"] {
            let label="request-"+mode
            var target=h.url("/media/body.mp4",label),options="{}"
            if mode=="redirect" {
                target=h.url("/media/redirect",label,["rotate":"1","target":h.url("/media/final.mp4",label,["expect":"redirected"])])
            } else if mode=="cross" {
                let cross=h.url("/media/final.mp4",label,["expect":"","cors":"allow"],host:"sibling.example.test")
                target=h.url("/media/redirect",label,["target":cross])
            } else if mode=="omit" {target=h.url("/media/omit.mp4",label,["expect":""]);options="{\"credentials\":\"omit\"}"}
            else {options="{\"headers\":{\"Range\":\"bytes=1-2\"}}"}
            let b=try await h.browser(label,["target":target,"options":options]);defer{b.retire()}
            let page=try await b.page();try await h.complete(b)
            let expected=mode=="range" ? h.media.subdata(in:1..<3):h.media
            #expect(page["sha256"] as? String == OriginalResponseSink.hash(expected))
            #expect(page["status"] as? Int == (mode=="range" ? 206:200))
            #expect(try b.sink.bytes(try #require(b.sink.completed.first))==expected)
            let rows=try await h.mediaRows(label)
            #expect(rows.count == (["redirect","cross"].contains(mode) ? 2:1))
            if mode=="redirect" {#expect(rows.map{($0["headers"] as? [String:String])?["cookie"] ?? ""} == ["account=fresh","account=redirected"])}
            if mode=="cross" || mode=="omit" {#expect((rows.last?["headers"] as? [String:String])?["cookie"] == nil)}
            if mode=="range" {#expect((rows.first?["headers"] as? [String:String])?["range"]=="bytes=1-2")}
            #expect(page["redirected"] as? Bool == ["redirect","cross"].contains(mode))
            try h.save(mode,b,page)
        }
    }

    @Test func corsPreflightResponseDenialAndOpaqueDoNotAcquireCapabilities() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        for mode in ["allow","preflight-deny","response-deny","opaque"] {
            let label="cors-"+mode
            let target=h.url("/media/"+mode+".mp4",label,["expect":"","cors":mode=="response-deny"||mode=="opaque" ? "none":mode],host:"sibling.example.test")
            let options=mode=="opaque" ? "{\"mode\":\"no-cors\"}":mode=="response-deny" ? "{}":"{\"headers\":{\"X-Local-Token\":\"synthetic\"}}"
            let b=try await h.browser(label,["target":target,"options":options]);defer{b.retire()}
            let page=try await b.page()
            if mode=="allow" {try await h.complete(b);checkPage(page,bytes:h.media)}
            else {
                #expect(b.sink.completed.isEmpty && b.sink.transfers.isEmpty)
                if mode=="opaque" {#expect(page["type"] as? String=="opaque" && page["status"] as? Int==0 && page["bytes"] as? Int==0)}
                else {#expect(page["error"] as? String == "TypeError")}
            }
            let rows=try await h.mediaRows(label)
            #expect(rows.map{$0["method"] as? String ?? ""} == (mode=="allow" ? ["OPTIONS","GET"]:mode=="preflight-deny" ? ["OPTIONS"]:["GET"]))
            if mode=="response-deny" {#expect(rows.first?["status"] as? Int==200)}
            try h.save(mode,b,page)
        }
    }

    @Test func cacheStorageReadIsNotInventedAsANewFetchAndHttpCacheHasReceipts() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        for scenario in ["cache","http-cache"] {
            let b=try await h.browser(scenario,["scenario":scenario]);defer{b.retire()}
            let page=try await b.page();try await h.complete(b,count:scenario=="cache" ? 1:2)
            let expected=Data("account=fresh".utf8)
            if scenario=="cache" {
                #expect(page["second"] as? String == "account=fresh")
                let cacheRows=try await h.mediaRows(scenario)
                #expect(b.sink.completed.count==1 && cacheRows.count==1)
            } else {
                let rows=try await h.mediaRows(scenario)
                #expect(rows.count==1 || rows.count==2)
                // WK may revalidate/reissue. The receipt, not the fetch intent, decides.
                let second=try #require(page["second"] as? [String:Any])
                #expect(second["sha256"] as? String==OriginalResponseSink.hash(Data((rows.count==1 ? "account=fresh":"account=second").utf8)))
            }
            #expect(try b.sink.bytes(try #require(b.sink.completed.first))==expected)
            try h.save(scenario,b,page,extra:["mediaReceiptCount":try await h.mediaRows(scenario).count])
        }
    }

    @Test func sameAndCrossOriginFramesAreAttributedByWKFrameInfo() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        let b=try await h.browser("frames",["scenario":"frames"]);defer{b.retire()}
        let page=try await b.page();try await h.complete(b,count:2)
        #expect((page["children"] as? [[String:Any]])?.count==2)
        #expect(Set(b.sink.completed.compactMap{$0.metadata["nativeOrigin"] as? String}) == ["https://video.example.test:0","https://sibling.example.test:0"])
        #expect(b.sink.completed.allSatisfy{$0.metadata["isMainFrame"] as? Bool == false})
        #expect(b.sink.completed.allSatisfy{($0.metadata["nativeFrameURL"] as? String ?? "").contains("/clone/page")})
        for t in b.sink.completed {#expect(try b.sink.bytes(t)==h.media)}
        try h.save("frames",b,page)
    }

    @Test func xhrReadableTypesPreservePageEventsAndBinaryIdentity() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        for type in ["arraybuffer","blob","","text","json","document"] {
            let name=type.isEmpty ? "default":type
            let control=try await h.browser("plain-xhr-"+name,["scenario":"xhr","type":type],observe:false);defer{control.retire()}
            let plain=try await control.page()
            let b=try await h.browser("xhr-"+name,["scenario":"xhr","type":type]);defer{b.retire()}
            let page=try await b.page()
            #expect(page["status"] as? Int==200 && page["responseIdentity"] as? Bool==true && page["sendReturnedUndefined"] as? Bool==true)
            for key in ["type","status","bytes","sha256","text","events"] {
                #expect(String(describing:page[key] ?? NSNull()) == String(describing:plain[key] ?? NSNull()),"XHR \(name) \(key)")
            }
            let binary=["arraybuffer","blob"].contains(type)
            if binary || type=="" || type=="text" {
                try await h.complete(b)
                let t=try #require(b.sink.completed.first),body=try b.sink.bytes(t)
                #expect(body == (binary ? h.media:Data("café\r\n".utf8)))
                #expect(t.metadata["byteSemantics"] as? String == (binary ? "response-body":"utf8-reencoded-text"))
                if !binary {#expect(body != Data([0x63,0x61,0x66,0xe9,0x0d,0x0a]))}
            } else {try await h.wait{b.sink.events.contains{$0["reason"] as? String == "xhr-unsupported-type"}};#expect(b.sink.completed.isEmpty)}
            #expect(try await h.mediaRows("xhr-"+name).count==1)
            try h.save("xhr-"+name,b,page,extra:["control":plain])
        }
    }

    @Test func xhrReuseCorsErrorAndAbortKeepOriginalLifecycle() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        let reused=try await h.browser("xhr-reuse",["scenario":"xhr","type":"arraybuffer","reuse":"1"]);defer{reused.retire()}
        let page=try await reused.page();try await h.complete(reused,count:2)
        #expect(try await h.mediaRows("xhr-reuse").count==2)
        for key in ["first","second"] {#expect((page[key] as? [String:Any])?["status"] as? Int==200)}
        try h.save("xhr-reuse",reused,page)
        let denied=try await h.browser("xhr-denied",["scenario":"xhr","type":"arraybuffer","target":h.url("/media/no-cors.mp4","xhr-denied",["expect":""],host:"sibling.example.test")]);defer{denied.retire()}
        let error=try await denied.page();#expect(error["status"] as? Int==0 && (error["events"] as? [String])?.contains("error")==true)
        let deniedRows=try await h.mediaRows("xhr-denied")
        #expect(denied.sink.completed.isEmpty && deniedRows.first?["status"] as? Int==200)
        try h.save("xhr-denied",denied,error)
        let label="xhr-abort",late=h.url("/media/late.mp4","xhr-abort")
        let aborted=try await h.browser(label,["scenario":"xhr","type":"arraybuffer","abort":"1","target":h.url("/media/hold",label,["target":late])]);defer{aborted.retire()}
        let result=try await aborted.page();#expect(result["status"] as? Int==0 && (result["events"] as? [String])?.contains("abort")==true)
        try await h.release(label);#expect(try await h.mediaRows(label).count==1 && aborted.sink.completed.isEmpty)
        try h.save("xhr-abort",aborted,result)
    }

    @Test func blockedBridgeAcknowledgementDoesNotBackpressureOriginalPageTee() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        let body=Data(repeating:0x7a,count:262144)
        let b=try await h.browser("backpressure",["target":h.url("/media/finite","backpressure")],hold:true);defer{b.retire()}
        try await h.wait{b.sink.pending.count==1}
        let page=try await b.page();checkPage(page,bytes:body)
        let copied=b.sink.transfers.values.reduce(0){$0+$1.bytes}
        #expect(copied<=8192 && copied<body.count && b.sink.completed.isEmpty)
        let receipt=try await h.mediaRows("backpressure")
        #expect(b.sink.maxPending==1 && receipt.count==1)
        b.sink.release();try await h.complete(b)
        #expect(try b.sink.bytes(try #require(b.sink.completed.first))==body)
        try h.save("backpressure",b,page,extra:["bytesBeforeAck":copied,"originalCompletedBeforeAck":true,"wholeResponseBackpressure":false])
    }

    @Test func declaredAndDecodedLimitsFailCaptureWithoutChangingPageBody() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        for mode in ["big","gzip"] {
            let b=try await h.browser("limit-"+mode,["target":h.url("/media/"+mode,"limit-"+mode)]);defer{b.retire()}
            let page=try await b.page()
            #expect(page["bytes"] as? Int==2097152 && page["status"] as? Int==200)
            #expect(page["sha256"] as? String == OriginalResponseSink.hash(Data(repeating:0x78,count:2097152)))
            if mode=="big" {try await h.wait{b.sink.events.contains{$0["reason"] as? String=="declared-body-limit"}}}
            else {try await h.wait{b.sink.events.contains{$0["event"] as? String=="cancel" && $0["reason"] as? String=="decoded-body-limit"}}}
            #expect(b.sink.completed.isEmpty && b.sink.transfers.isEmpty && b.sink.retainedBytes==0)
            #expect(try await h.mediaRows("limit-"+mode).count==1)
            try h.save("limit-"+mode,b,page)
        }
    }

    @Test func capabilityRejectsBadSequenceWrongFrameExpiredAndRetiredSession() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        let b=try await h.browser("capability",hold:true,lifetime:6000);defer{b.retire()}
        try await h.wait{b.sink.pending.count==1}
        let cap=try #require(b.sink.transfers.keys.first)
        let wrong=try await b.script("try {await webkit.messageHandlers.responseClone.postMessage({session,op:'chunk',cap,seq:9,offset:0,data:'YQ=='});return {accepted:true};}catch(e){return {rejected:true};}",["session":b.sink.session,"cap":cap])
        #expect(wrong["rejected"] as? Bool==true && b.sink.events.contains{$0["event"] as? String=="rejected-chunk"})
        // Real cross-origin iframe attempts to use a capability opened by the main frame.
        let crossed=try await b.script("""
        const frame=document.createElement('iframe');
        frame.src='https://sibling.example.test/clone/page?scenario=fetch&seed=0&case=cap-frame&target='+encodeURIComponent('https://sibling.example.test/media/frame.mp4?case=cap-frame&expect=');
        document.body.append(frame);return {};
        """)
        #expect(crossed.isEmpty)
        try await h.wait{b.sink.transfers.count==2}
        let child=try #require(b.sink.transfers.values.first{$0.metadata["isMainFrame"] as? Bool==false})
        let forged=try await b.script("try{await webkit.messageHandlers.responseClone.postMessage({session,op:'cancel',cap,reason:'forged'});return {accepted:true};}catch(e){return {rejected:true};}",["session":b.sink.session,"cap":child.cap])
        #expect(forged["rejected"] as? Bool==true && b.sink.transfers[child.cap] != nil)
        let page=try await b.page()
        try h.save("capability",b,page,extra:["badSequenceRejected":true,"crossFrameRejected":true])
        let oldSession=b.sink.session;b.retire();#expect(b.sink.pending.isEmpty && b.sink.transfers.isEmpty && b.sink.retainedBytes==0)
        let next=try await h.browser("next-capability",["seed":"0","target":h.url("/media/next.mp4","next-capability",["expect":""])]);defer{next.retire()}
        let nextPage=try await next.page();try await h.complete(next)
        for session in [oldSession,next.sink.session] {
            let stale=try await next.script("try{await webkit.messageHandlers.responseClone.postMessage({session,op:'close',cap,seq:0,total:0});return {accepted:true};}catch(e){return {rejected:true};}",["session":session,"cap":cap])
            #expect(stale["rejected"] as? Bool==true)
        }
        try h.save("replacement",next,nextPage,extra:["oldSessionRejected":true,"oldCapabilityRejected":true])
    }

    @Test func expiryCancelsCaptureWhilePageCanFinish() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        let b=try await h.browser("expiry",hold:true,lifetime:1000);defer{b.retire()}
        let page=try await b.page();checkPage(page,bytes:h.media)
        try await h.wait{b.sink.events.contains{$0["event"] as? String=="cancel" && $0["reason"] as? String=="expired"}}
        #expect(b.sink.transfers.isEmpty && b.sink.pending.isEmpty && b.sink.completed.isEmpty && b.sink.retainedBytes==0)
        try h.save("expiry",b,page)
    }


    @Test func bridgeSequenceCapacityAndOneShotCloseAreEnforced() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        let b=try await h.browser("bridge-guards");defer{b.retire()}
        let page=try await b.page();try await h.complete(b)
        let result=try await b.script("""
        const send=m=>webkit.messageHandlers.responseClone.postMessage({session,...m});
        const failures=[];
        const bad=async(name,m)=>{try{await send(m);failures.push(name+'-accepted');}catch{failures.push(name+'-rejected');}};
        const {cap}=await send({op:'open',api:'contract-input',url:location.href});
        await bad('sequence',{op:'chunk',cap,seq:1,offset:0,data:'YQ=='});
        await send({op:'chunk',cap,seq:0,offset:0,data:'YQ=='});
        await bad('duplicate',{op:'chunk',cap,seq:0,offset:0,data:'YQ=='});
        await bad('offset',{op:'chunk',cap,seq:1,offset:0,data:'YQ=='});
        await bad('oversize',{op:'chunk',cap,seq:1,offset:1,data:btoa('x'.repeat(8193))});
        await bad('early-close',{op:'close',cap,seq:9,total:1});
        const other=await send({op:'open',api:'contract-input',url:location.href});
        await bad('capacity',{op:'open',api:'contract-input',url:location.href});
        await send({op:'cancel',cap:other.cap});
        await send({op:'close',cap,seq:1,total:1});
        await bad('reused-close',{op:'close',cap,seq:1,total:1});
        for(let i=0;i<5;i++) {const t=await send({op:'open',api:'contract-input',url:location.href});await send({op:'close',cap:t.cap,seq:0,total:0});}
        const final=await send({op:'open',api:'contract-input',url:location.href});
        await bad('reserved-slot',{op:'open',api:'contract-input',url:location.href});
        await send({op:'close',cap:final.cap,seq:0,total:0});
        await bad('completed-limit',{op:'open',api:'contract-input',url:location.href});
        return {failures};
        """,["session":b.sink.session])
        #expect(result["failures"] as? [String] == ["sequence-rejected","duplicate-rejected","offset-rejected","oversize-rejected","early-close-rejected","capacity-rejected","reused-close-rejected","reserved-slot-rejected","completed-limit-rejected"])
        #expect(b.sink.transfers.isEmpty && b.sink.maxActive==2 && b.sink.completed.count==8)
        try h.save("bridge-guards",b,page,extra:result)
    }

    @Test func pageWorldCloneCanBeReplacedAndIsNotBrowserAttestation() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        let b=try await h.browser("page-world",["scenario":"spoof"]);defer{b.retire()}
        let page=try await b.page();try await h.complete(b)
        #expect(page["sha256"] as? String==OriginalResponseSink.hash(h.media))
        let body=try b.sink.bytes(try #require(b.sink.completed.first))
        #expect(body==Data("forged-page-body".utf8) && body != h.media)
        #expect(try await h.mediaRows("page-world").count==1)
        try h.save("page-world",b,page,extra:["pageWorldResponseAttestation":false,"cloneOverriddenByPage":true])
    }

    @Test func abortAndReplacementDrainOriginalPendingRequestWithoutLateGET() async throws {
        let h=try OriginalResponseFixture();defer{h.stop()}
        for retired in [false,true] {
            let label=retired ? "retired-fetch":"aborted-fetch",target=h.url("/media/late.mp4",retired ? "retired-fetch":"aborted-fetch")
            let b=try await h.browser(label,["scenario":"abort","target":h.url("/media/hold",label,["target":target])]);defer{b.retire()}
            try await h.wait{try await h.mediaRows(label).count==1}
            var page:[String:Any]=[:]
            if retired {b.retire();page=["retired":true]}
            else {_ = try await b.script("abortController.abort();return {};");page=try await b.page();#expect(page["error"] as? String=="AbortError")}
            try await h.release(label);#expect(try await h.mediaRows(label).count==1 && b.sink.completed.isEmpty)
            try h.save(label,b,page)
        }
    }
}
