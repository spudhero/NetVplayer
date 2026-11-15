import CryptoKit
import Foundation
import Testing
import WebKit

// Local experiment only. No production target imports these classes/scripts.
@MainActor
final class OriginalResponseSink: NSObject, WKScriptMessageHandlerWithReply {
    typealias Reply = @MainActor @Sendable (Any?, String?) -> Void
    static let chunkLimit = 8192, bodyLimit = 1048576, spoolLimit = 4194304
    let session = UUID().uuidString
    let root: URL
    var active = true, holdAcknowledgements = false
    var lifetimeMilliseconds = 3000
    private(set) var transfers: [String: Transfer] = [:]
    private(set) var completed: [Transfer] = []
    private(set) var events: [[String: Any]] = []
    private(set) var pending: [String: Reply] = [:]
    private(set) var maxChunk = 0, maxPending = 0, maxActive = 0, retainedBytes = 0

    final class Transfer {
        let cap: String, frame: String, file: URL, metadata: [String: Any]
        var handle: FileHandle?, bytes = 0, seq = 0
        init(cap: String, frame: String, file: URL, metadata: [String: Any]) throws {
            self.cap=cap; self.frame=frame; self.file=file; self.metadata=metadata
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            handle = try FileHandle(forWritingTo: file)
        }
    }
    init(root: URL) throws {
        self.root=root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func event(_ name: String, _ detail: [String: Any] = [:]) {
        if events.count < 256 { events.append(detail.merging(["event":name]) { _, r in r }) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping Reply) {
        let f=message.frameInfo, o=f.securityOrigin
        let origin="\(o.protocol)://\(o.host):\(o.port)", url=f.request.url?.absoluteString ?? ""
        receive(message.body, frame: "\(f.isMainFrame)|\(origin)|\(url)",
                provenance: ["nativeOrigin":origin,"nativeFrameURL":url,"isMainFrame":f.isMainFrame], reply:replyHandler)
    }
    private func receive(_ value: Any, frame: String, provenance: [String: Any], reply: @escaping Reply) {
        guard active, let b=value as? [String: Any], b["session"] as? String == session else { event("rejected-session"); reply(nil,"retired-session"); return }
        let op=b["op"] as? String ?? ""
        if op == "note" { event("note",b.filter { ["reason","detail","type"].contains($0.key) });reply([:],nil);return }
        if op == "open" {
            guard transfers.count < 2, completed.count + transfers.count < 8, retainedBytes < Self.spoolLimit else { event("capacity-rejected"); reply(nil,"capacity"); return }
            let cap=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
            do {
                let meta=b.filter{["api","url","type","status","redirected","byteSemantics"].contains($0.key)}.merging(provenance){_,r in r}
                let transfer=try Transfer(cap:cap,frame:frame,file:root.appendingPathComponent(cap+".partial"),metadata:meta)
                transfers[cap]=transfer;maxActive=max(maxActive,transfers.count);event("open",["cap":cap].merging(meta){_,r in r})
                reply(["cap":cap],nil)
                let delay=lifetimeMilliseconds
                Task { [weak self] in
                    try? await Task.sleep(for:.milliseconds(delay))
                    guard let self, self.transfers[cap] != nil else { return }
                    self.cancel(cap, reason:"expired")
                }
            } catch { event("open-failed");reply(nil,"file-error") }
            return
        }
        guard let cap=b["cap"] as? String, let t=transfers[cap], t.frame == frame else { event("rejected-capability");reply(nil,"invalid-capability-or-frame");return }
        if op == "cancel" { cancel(cap,reason:b["reason"] as? String ?? "cancel");reply([:],nil);return }
        if op == "chunk" {
            guard pending[cap] == nil, b["seq"] as? Int == t.seq, b["offset"] as? Int == t.bytes,
                  let encoded=b["data"] as? String, encoded.utf8.count <= 10924,
                  let data=Data(base64Encoded:encoded), !data.isEmpty, data.count <= Self.chunkLimit,
                  t.bytes+data.count <= Self.bodyLimit, retainedBytes+data.count <= Self.spoolLimit else {
                event("rejected-chunk");reply(nil,"invalid-chunk");return
            }
            do {
                try t.handle?.write(contentsOf:data);t.bytes+=data.count;t.seq+=1;retainedBytes+=data.count
                maxChunk=max(maxChunk,data.count);event("chunk",["cap":cap,"seq":t.seq-1,"bytes":data.count,"total":t.bytes])
                if holdAcknowledgements {pending[cap]=reply;maxPending=max(maxPending,pending.count)} else {reply(["ack":t.seq],nil)}
            } catch {cancel(cap,reason:"file-error");reply(nil,"file-error")}
            return
        }
        if op == "close" {
            guard pending[cap] == nil, b["seq"] as? Int == t.seq, b["total"] as? Int == t.bytes else {event("rejected-close");reply(nil,"invalid-close");return}
            do {
                try t.handle?.close();t.handle=nil
                let ready=root.appendingPathComponent(cap+".mp4")
                try FileManager.default.moveItem(at:t.file,to:ready)
                transfers.removeValue(forKey:cap);completed.append(t)
                event("close",["cap":cap,"bytes":t.bytes,"sha256":Self.hash(try Data(contentsOf:ready))]);reply([:],nil)
            } catch {cancel(cap,reason:"file-error");reply(nil,"file-error")}
            return
        }
        event("rejected-operation");reply(nil,"invalid-operation")
    }
    func release() {
        holdAcknowledgements=false
        let saved=pending;pending.removeAll()
        for (cap,reply) in saved {reply(["ack":transfers[cap]?.seq ?? 0],nil)}
    }
    func cancel(_ cap: String, reason: String) {
        guard let t=transfers.removeValue(forKey:cap) else {return}
        try? t.handle?.close();t.handle=nil;try? FileManager.default.removeItem(at:t.file);retainedBytes-=t.bytes
        pending.removeValue(forKey:cap)?(nil,reason);event("cancel",["cap":cap,"reason":reason,"bytes":t.bytes])
    }
    func retire() {
        active=false
        for cap in Array(transfers.keys) {cancel(cap,reason:"session-retired")}
        for t in completed {try? FileManager.default.removeItem(at:root.appendingPathComponent(t.cap+".mp4"))}
        event("session-retired");retainedBytes=0
    }
    func bytes(_ t: Transfer) throws -> Data {try Data(contentsOf:root.appendingPathComponent(t.cap+".mp4"))}
    static func hash(_ data: Data) -> String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func snapshot(to file: URL, extra: [String: Any] = [:]) throws {
        var values:[[String:Any]]=[]
        for t in completed {
            let body=try bytes(t)
            // Frozen evidence lives outside the live spool capability namespace.
            try body.write(to:file.deletingLastPathComponent().appendingPathComponent(t.cap+".captured"))
            values.append(t.metadata.merging(["cap":t.cap,"bytes":t.bytes,"sha256":Self.hash(body)]){_,r in r})
        }
        let data:[String:Any]=["completed":values,"events":events,"maxChunk":maxChunk,"maxPending":maxPending,"maxActive":maxActive,
                              "retainedBytes":retainedBytes,"headersObserved":false,"wholeResponseBackpressure":false,"extra":extra]
        try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:file)
    }
}

@MainActor
final class OriginalResponseBrowser: SeedBrowser {
    let web: WKWebView, sink: OriginalResponseSink
    var active=true
    init(fixture: SeedScopeFixture, observe: Bool=true, hold: Bool=false, lifetime: Int=3000) throws {
        sink=try OriginalResponseSink(root:fixture.root.appendingPathComponent(UUID().uuidString).appendingPathComponent("spool"))
        sink.holdAcknowledgements=hold;sink.lifetimeMilliseconds=lifetime
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent();fixture.configure(config.websiteDataStore)
        let recorder="""
        (()=>{const raw=fetch;window.fetch=function(...args){const p=Reflect.apply(raw,this,args);window.__nativePromise=p;void p.then(r=>window.__nativeResponse=r,()=>{});return p;};})();
        """
        config.userContentController.addUserScript(WKUserScript(source:recorder,injectionTime:.atDocumentStart,forMainFrameOnly:false))
        if observe {
            let source=try String(contentsOf:OriginalResponseFixture.tools.appendingPathComponent("wk_response_clone_observer.js"),encoding:.utf8)
            config.userContentController.addScriptMessageHandler(sink,contentWorld:.page,name:"responseClone")
            config.userContentController.addUserScript(WKUserScript(source:source.replacingOccurrences(of:"__SESSION__",with:sink.session),injectionTime:.atDocumentStart,forMainFrameOnly:false,in:.page))
        }
        web=WKWebView(frame:.zero,configuration:config)
        super.init(certificate:fixture.certificate);web.navigationDelegate=self
    }
    func webView(_ webView: WKWebView,didFinish navigation:WKNavigation!) {result="ready"}
    func script(_ code: String, _ args: [String:Any]=[:]) async throws -> [String:Any] {
        let value=try await web.callAsyncJavaScript(code,arguments:args,in:nil,contentWorld:.page)
        return try #require(value as? [String:Any])
    }
    func page() async throws -> [String:Any] {try await script("return await pagePending;")}
    func retire() {
        guard active else{return};active=false;sink.retire();web.stopLoading();web.load(URLRequest(url:URL(string:"about:blank")!))
        web.navigationDelegate=nil;web.configuration.userContentController.removeScriptMessageHandler(forName:"responseClone",contentWorld:.page)
    }
}

@MainActor
final class OriginalResponseFixture {
    static var tools: URL {
        var repo=URL(fileURLWithPath:#filePath);for _ in 0..<4 {repo.deleteLastPathComponent()}
        return repo.appendingPathComponent("script/fixtures/web-transport")
    }
    let f: SeedScopeFixture, media: Data
    var root:URL {f.root}
    init() throws {
        media=try Data(contentsOf:URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["NETVPLAYER_FEATURE_FIXTURE"])))
        f=try SeedScopeFixture(scriptName:"wk_response_clone_fixture.py",evidenceEnvironment:"NETVPLAYER_WK_CLONE_EVIDENCE_DIR")
    }
    func stop(){f.stop()}
    func url(_ path:String,_ label:String,_ extra:[String:String]=[:],host:String="video.example.test")->String {
        var c=URLComponents(string:"https://\(host)\(path)")!
        c.queryItems=extra.merging(["case":label]){_,r in r}.sorted{$0.key<$1.key}.map{URLQueryItem(name:$0.key,value:$0.value)}
        return c.url!.absoluteString
    }
    func browser(_ label:String,_ extra:[String:String]=[:],observe:Bool=true,hold:Bool=false,lifetime:Int=3000) async throws -> OriginalResponseBrowser {
        let b=try OriginalResponseBrowser(fixture:f,observe:observe,hold:hold,lifetime:lifetime)
        b.web.load(URLRequest(url:URL(string:url("/clone/page",label,extra))!))
        try await wait{_ = try? await b.web.evaluateJavaScript("void(0)");return b.result != nil}
        try #require(b.result == "ready","navigation: \(b.result ?? "none")");return b
    }
    func rows() async throws -> [[String:Any]] {
        let (data,_)=try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:\(f.port)/control/records")!)
        return try #require(JSONSerialization.jsonObject(with:data) as? [[String:Any]])
    }
    func mediaRows(_ label:String) async throws -> [[String:Any]] {try await rows().filter{$0["kind"] as? String == "request" && $0["case"] as? String == label && ($0["path"] as? String ?? "").hasPrefix("/media/")}}
    func wait(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<500 {if try await predicate(){return};try await Task.sleep(for:.milliseconds(20))}
        throw URLError(.timedOut)
    }
    func complete(_ b:OriginalResponseBrowser,count:Int=1) async throws {
        try await wait{b.sink.completed.count>=count}
        #expect(b.sink.maxChunk<=OriginalResponseSink.chunkLimit && b.sink.maxActive<=2 && b.sink.maxPending<=2)
    }
    func save(_ name:String,_ b:OriginalResponseBrowser,_ page:[String:Any],extra:[String:Any]=[:]) throws {
        try b.sink.snapshot(to:root.appendingPathComponent(name+".capture.json"),extra:["page":page].merging(extra){_,r in r})
    }
    func release(_ label:String) async throws {
        _ = try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:\(f.port)/control/release?id=\(label)")!)
        try await wait{try await self.rows().contains{$0["kind"] as? String == "gate-drained" && $0["case"] as? String == label}}
    }
    func play(_ b:OriginalResponseBrowser) async throws {
        let t=try #require(b.sink.completed.first), live=b.sink.root.appendingPathComponent(t.cap+".mp4")
        // Existing loopback server exposes only root/spool, with an unguessable token.
        let directory=root.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let published=directory.appendingPathComponent(t.cap+".mp4")
        try FileManager.default.createSymbolicLink(at:published,withDestinationURL:live)
        let spool="http://127.0.0.1:\(f.port)/spool/"+t.cap
        let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        task.arguments=["-B",Self.tools.appendingPathComponent("probe_browser_spool_player.py").path,"--library",try #require(ProcessInfo.processInfo.environment["NETVPLAYER_LIBMPV_PATH"]),"--url",spool]
        for name in ["player.stdout","player.stderr"] {FileManager.default.createFile(atPath:root.appendingPathComponent(name).path,contents:nil)}
        task.standardOutput=try FileHandle(forWritingTo:root.appendingPathComponent("player.stdout"));task.standardError=try FileHandle(forWritingTo:root.appendingPathComponent("player.stderr"))
        try task.run();task.waitUntilExit();try #require(task.terminationStatus==0)
        b.retire()
        #expect(!FileManager.default.fileExists(atPath:live.path))
        let (_,response)=try await URLSession.shared.data(from:URL(string:spool)!)
        #expect((response as? HTTPURLResponse)?.statusCode==410)
        try FileManager.default.removeItem(at:published)
    }
}
