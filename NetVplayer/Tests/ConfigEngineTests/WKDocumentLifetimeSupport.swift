import Foundation
import CryptoKit
import WebKit

@MainActor
final class DocumentResponseSink: NSObject, WKScriptMessageHandlerWithReply {
    typealias Reply = @MainActor @Sendable (Any?, String?) -> Void
    static let chunkLimit = 8192, bodyLimit = 1048576, spoolLimit = 4194304
    let session = UUID().uuidString
    let normalizeFragment: Bool
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
    init(root: URL, normalizeFragment: Bool = true) throws {
        self.normalizeFragment=normalizeFragment
        self.root=root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func event(_ name: String, _ detail: [String: Any] = [:]) {
        if events.count < 256 { events.append(detail.merging(["event":name]) { _, r in r }) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping Reply) {
        let f=message.frameInfo, o=f.securityOrigin
        let origin="\(o.protocol)://\(o.host):\(o.port)", url=f.request.url?.absoluteString ?? ""
        let frameURL: String
        if normalizeFragment, var components = URLComponents(string: url) {
            components.fragment = nil; frameURL = components.string ?? url
        } else { frameURL = url }
        receive(message.body, frame: "\(f.isMainFrame)|\(origin)|\(frameURL)",
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
