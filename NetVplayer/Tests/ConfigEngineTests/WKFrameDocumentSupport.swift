import Foundation
import WebKit

@MainActor
final class FrameDocumentGate {
    struct Binding { let token: String, href: String, fixtureName: String }
    enum Failure: String, Error { case retired, capacity, deadline, missingWebView, invalidDocument, changedURL }
    typealias Completion = @MainActor (Result<Binding, any Error>) -> Void
    @MainActor
    final class Lookup {
        let group: String
        var completion: Completion?
        var deadline: Task<Void, Never>?
        init(group: String, completion: @escaping Completion) { self.group = group; self.completion = completion }
        func finish(_ result: Result<Binding, any Error>) {
            guard let callback = completion else { return }
            completion = nil; callback(result)
        }
    }
    static let marker = "__netvplayerNativeDocumentMarker"
    let world = WKContentWorld.world(name: "NetVplayer document " + UUID().uuidString)
    let timeoutMilliseconds: Int, maximumLookups: Int, injectedDelayMilliseconds: Int
    private(set) var active = true
    private(set) var outstanding: [UUID: Lookup] = [:]
    private(set) var started = 0, returned = 0, highWater = 0, capacityRejections = 0, deadlines = 0

    init(timeoutMilliseconds: Int = 1500, maximumLookups: Int = 8, injectedDelayMilliseconds: Int = 0) {
        precondition(timeoutMilliseconds > 0 && maximumLookups > 0 && maximumLookups <= 8)
        self.timeoutMilliseconds = timeoutMilliseconds; self.maximumLookups = maximumLookups
        self.injectedDelayMilliseconds = injectedDelayMilliseconds
    }
    static func normalized(_ url: String) -> String {
        guard var value = URLComponents(string: url) else { return url }
        value.fragment = nil; return value.string ?? url
    }
    static func group(_ frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        return "\(frame.isMainFrame)|\(origin.protocol)://\(origin.host):\(origin.port)|\(normalized(frame.request.url?.absoluteString ?? ""))"
    }
    func lookup(web: WKWebView?, frame: WKFrameInfo, requireSnapshotURL: Bool = true, completion: @escaping Completion) {
        guard active else { completion(.failure(Failure.retired)); return }
        // Timed-out WebKit evaluations retain their slot until they actually return.
        guard outstanding.count < maximumLookups else {
            capacityRejections += 1; completion(.failure(Failure.capacity)); return
        }
        guard let web else { completion(.failure(Failure.missingWebView)); return }
        let id = UUID(), request = Lookup(group: Self.group(frame), completion: completion)
        outstanding[id] = request; started += 1; highWater = max(highWater, outstanding.count)
        request.deadline = Task { [weak self, weak request] in
            guard let self, let request else { return }
            do { try await Task.sleep(for: .milliseconds(self.timeoutMilliseconds)) } catch { return }
            guard request.completion != nil else { return }
            self.deadlines += 1; request.finish(.failure(Failure.deadline))
        }
        Task {
            defer { request.deadline?.cancel(); outstanding.removeValue(forKey: id); returned += 1 }
            do {
                let result = try await web.callAsyncJavaScript("""
                if (delay > 0) await new Promise(resolve => setTimeout(resolve, delay));
                if (!Object.prototype.hasOwnProperty.call(globalThis, marker)) {
                    Object.defineProperty(globalThis, marker, {value: token, writable: false, configurable: false});
                }
                return {token: globalThis[marker], href: location.href, fixtureName: window.name};
                """, arguments: ["marker": Self.marker, "token": UUID().uuidString,
                    "delay": injectedDelayMilliseconds], in: frame, contentWorld: world)
                guard let value = result as? [String: Any], let token = value["token"] as? String,
                      UUID(uuidString: token) != nil, let href = value["href"] as? String else {
                    request.finish(.failure(Failure.invalidDocument)); return
                }
                guard !requireSnapshotURL || Self.normalized(href) == Self.normalized(frame.request.url?.absoluteString ?? "") else {
                    request.finish(.failure(Failure.changedURL)); return
                }
                request.finish(.success(Binding(token: token, href: href, fixtureName: value["fixtureName"] as? String ?? "")))
            } catch { request.finish(.failure(error)) }
        }
    }
    func invalidate(group: String) {
        for request in outstanding.values where request.group == group { request.finish(.failure(Failure.retired)) }
    }
    func retire() {
        active = false
        for request in outstanding.values { request.finish(.failure(Failure.retired)) }
    }
    var snapshot: [String: Any] {
        ["started": started, "returned": returned, "outstanding": outstanding.count, "highWater": highWater,
         "capacityRejections": capacityRejections, "deadlines": deadlines, "maximumLookups": maximumLookups,
         "timeoutMilliseconds": timeoutMilliseconds, "active": active]
    }
}

import CryptoKit

@MainActor
final class FrameDocumentResponseSink: NSObject, WKScriptMessageHandlerWithReply {
    typealias Reply = @MainActor @Sendable (Any?, String?) -> Void
    static let chunkLimit = 8192, bodyLimit = 1048576, spoolLimit = 4194304
    let documentGate: FrameDocumentGate
    let useDocumentBinding: Bool
    private(set) var retiredDocumentTokens = Set<String>()
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
    init(root: URL, useDocumentBinding: Bool = true, probeTimeout: Int = 1500, maximumLookups: Int = 8, probeDelay: Int = 0, normalizeFragment: Bool = true) throws {
        self.useDocumentBinding = useDocumentBinding
        self.documentGate = FrameDocumentGate(timeoutMilliseconds: probeTimeout, maximumLookups: maximumLookups, injectedDelayMilliseconds: probeDelay)
        self.normalizeFragment=normalizeFragment
        self.root=root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func event(_ name: String, _ detail: [String: Any] = [:]) {
        if events.count < 256 { events.append(detail.merging(["event":name]) { _, r in r }) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping Reply) {
        guard active, let body = message.body as? [String: Any], body["session"] as? String == session else {
            event("rejected-session"); replyHandler(nil, "retired-session"); return
        }
        let frame = message.frameInfo, origin = frame.securityOrigin
        let group = FrameDocumentGate.group(frame)
        documentGate.lookup(web: message.webView, frame: frame) { [weak self] result in
            guard let self, self.active else { replyHandler(nil, "retired-session"); return }
            switch result {
            case .failure(let error):
                self.event("document-binding-rejected", ["reason": String(describing: error)])
                replyHandler(nil, "document-binding-" + String(describing: error))
            case .success(let binding):
                guard !self.retiredDocumentTokens.contains(binding.token) else {
                    self.event("rejected-retired-document"); replyHandler(nil, "retired-document"); return
                }
                self.receive(body, frame: self.useDocumentBinding ? binding.token : group,
                    provenance: ["nativeOrigin": "\(origin.protocol)://\(origin.host):\(origin.port)",
                        "nativeFrameURL": frame.request.url?.absoluteString ?? "", "isMainFrame": frame.isMainFrame,
                        "nativeFrameGroup": group, "privateDocumentTokenSHA256": Self.hash(Data(binding.token.utf8)),
                        "fixtureFrameName": binding.fixtureName], reply: replyHandler)
            }
        }
    }
    func retireDocument(_ token: String) {
        guard useDocumentBinding else { retire(); return }
        if !retiredDocumentTokens.contains(token) && retiredDocumentTokens.count >= 8 {
            event("retired-document-limit"); retire(); return
        }
        retiredDocumentTokens.insert(token)
        for (cap, transfer) in transfers where transfer.frame == token {
            cancel(cap, reason: "native-subframe-navigation")
        }
        for transfer in completed where transfer.frame == token {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(transfer.cap + ".mp4"))
            retainedBytes -= transfer.bytes
        }
        completed.removeAll { $0.frame == token }
        event("native-document-retired", ["documentSHA256": Self.hash(Data(token.utf8))])
    }
    func retireFrameGroup(_ frame: WKFrameInfo) {
        let group = FrameDocumentGate.group(frame)
        documentGate.invalidate(group: group)
        for (cap, transfer) in transfers where transfer.metadata["nativeFrameGroup"] as? String == group {
            cancel(cap, reason: "native-subframe-navigation")
        }
        for transfer in completed where transfer.metadata["nativeFrameGroup"] as? String == group {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(transfer.cap + ".mp4"))
            retainedBytes -= transfer.bytes
        }
        completed.removeAll { $0.metadata["nativeFrameGroup"] as? String == group }
        event("native-frame-group-retired", ["group": group])
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
        active=false; documentGate.retire()
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
