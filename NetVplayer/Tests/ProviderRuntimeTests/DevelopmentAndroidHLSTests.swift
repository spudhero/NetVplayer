#if DEBUG
import CryptoKit
import Foundation
import Models
import Network
import ProxyServer
import Testing
@testable import SpiderEngine

private func androidTSPrefix(_ offset: Int, count: Int = 5000) -> Data {
    var bytes = Data(repeating: 0, count: count)
    bytes.replaceSubrange(0..<12, with: Data([82,73,70,70,0,0,0,0,87,69,66,80]))
    for index in 0..<5 { bytes[offset + index * 188] = 0x47 }
    return bytes
}

@Test(arguments: [0, 736, 751])
func developmentAndroidHLSMatchesOriginalWindowAndSyncBoundaries(offset: Int) {
    var data = androidTSPrefix(offset)
    #expect(DevelopmentAndroidHLS.transportStreamOffset(data) == offset)
    data[offset + 2 * 188] = 0
    #expect(DevelopmentAndroidHLS.transportStreamOffset(data) == nil)
    #expect(DevelopmentAndroidHLS.transportStreamOffset(androidTSPrefix(752)) == nil)
    #expect(DevelopmentAndroidHLS.transportStreamOffset(Data(androidTSPrefix(0).prefix(1503))) == nil)
}

@Test(arguments: [1, 17, 736, 1504, 8192])
func developmentAndroidHLSAdvancesOnlyMatchedInputAcrossArbitraryChunks(chunkSize: Int) {
    let original = androidTSPrefix(736)
    var sniffer = DevelopmentAndroidHLS.Sniffer()
    var output = Data()
    for start in stride(from: 0, to: original.count, by: chunkSize) {
        output.append(sniffer.consume(Data(original[start..<min(start + chunkSize, original.count)])))
        #expect(sniffer.prefix.count <= 1504)
    }
    output.append(sniffer.finish())
    #expect(sniffer.offset == 736)
    #expect(output == Data(original.dropFirst(736)))
    for negative in [Data(original.prefix(1503)), Data("RIFF not a TS stream".utf8), Data(repeating: 0, count: 5000)] {
        var sniff = DevelopmentAndroidHLS.Sniffer()
        var result = sniff.consume(negative)
        result.append(sniff.finish())
        #expect(result == negative && sniff.offset == nil)
    }
}

@Test func developmentAndroidHLSHintsCannotAddWebPToFrozenCandidates() {
    #expect(DevelopmentAndroidHLS.candidates(format: 18, contentType: 18, uri: 18) == [8,13,11,2,0,1,7])
    #expect(DevelopmentAndroidHLS.candidates(format: 11, contentType: 8, uri: 11) == [11,8,13,2,0,1,7])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_ANDROID_HLS_TEST_SEGMENT"] != nil))
func developmentAndroidHLSFrozenUnmodifiedCapturedSegmentMatchesOriginalExtractor() throws {
    let path = try #require(ProcessInfo.processInfo.environment["NETVPLAYER_ANDROID_HLS_TEST_SEGMENT"])
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(DevelopmentAndroidLifecycleDiagnostics.sha256(data) == "ad776a46c6be80c37445ceec14ec63db2878d9b42dca6dbe3c34f3f6fac2abe0")
    #expect(DevelopmentAndroidHLS.transportStreamOffset(data) == 736)
    var sniffer = DevelopmentAndroidHLS.Sniffer()
    #expect(sniffer.consume(data) == Data(data.dropFirst(736)))
}

private actor AndroidHLSOutput {
    var heads: [ProxyStreamingResponseHead] = []
    var bytes = Data()
    func head(_ head: ProxyStreamingResponseHead) { heads.append(head) }
    func body(_ data: Data) { bytes.append(data) }
    func snapshot() -> ([ProxyStreamingResponseHead], Data) { (heads, bytes) }
}

@Test func developmentAndroidHLSStreamingWaitsForSniffAndAdjustsHeadWithExactSuffix() async throws {
    let raw = androidTSPrefix(736)
    let output = AndroidHLSOutput()
    let stream = DevelopmentAndroidHLSStream(role: .segment, headOnly: false, rangeRequested: false,
        sendHead: { await output.head($0) }, sendBody: { await output.body($0) })
    try await stream.head(.init(statusCode: 200, contentType: "image/webp", contentLength: raw.count,
        headers: ["ETag": "original", "Digest": "original", "X-Original": "keep"], closeConnection: true))
    try await stream.body(Data(raw.prefix(1503)))
    #expect(await output.snapshot().0.isEmpty)
    try await stream.body(Data(raw.dropFirst(1503)))
    try await stream.finish()
    let (heads, bytes) = await output.snapshot()
    #expect(heads.count == 1 && heads[0].contentType == "video/mp2t")
    #expect(heads[0].contentLength == raw.count - 736)
    #expect(heads[0].headers["ETag"] == nil && heads[0].headers["Digest"] == nil && heads[0].headers["X-Original"] == "keep")
    #expect(bytes == Data(raw.dropFirst(736)))
}

@Test func developmentAndroidHLSBypassesKeysEncryptedRangesHEADAndEncodedResponses() async throws {
    let raw = androidTSPrefix(736)
    let cases: [(DevelopmentAndroidHLS.Role?, Bool, Bool, Int, [String: String])] = [
        (.opaque,false,false,200,[:]), (.playlist,false,false,200,[:]), (nil,false,false,200,[:]),
        (.segment,false,true,200,[:]), (.segment,false,false,206,["Content-Range":"bytes 0-4998/5000"]),
        (.segment,false,false,200,["Content-Encoding":"gzip"]), (.segment,false,false,403,[:]),
        (.segment,true,false,200,[:])]
    for (role, headOnly, range, status, headers) in cases {
        let output = AndroidHLSOutput()
        let stream = DevelopmentAndroidHLSStream(role: role, headOnly: headOnly, rangeRequested: range,
            sendHead: { await output.head($0) }, sendBody: { await output.body($0) })
        try await stream.head(.init(statusCode: status, contentType: "image/webp", contentLength: raw.count, headers: headers))
        try await stream.body(raw)
        try await stream.finish()
        let (heads, bytes) = await output.snapshot()
        #expect(heads.count == 1 && heads[0].contentType == "image/webp" && heads[0].statusCode == status)
        #expect(bytes == (headOnly ? Data() : raw))
    }
}

@Test func developmentAndroidHLSReferenceRolesFollowTagsWithoutExtensionSelection() throws {
    let text = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,URI="audio?sign=a%2Bb%2F"
    #EXT-X-STREAM-INF:BANDWIDTH=1000
    child.webm
    #EXT-X-KEY:METHOD=AES-128,URI="key.webp"
    #EXTINF:2,
    encrypted.webp
    #EXT-X-KEY:METHOD=NONE
    #EXTINF:2,
    plain.webp
    #EXT-X-BYTERANGE:50@0
    ranged.webp
    #EXT-X-MAP:URI="init.webp"
    #EXTINF:2,
    fragment.webp
    """
    var roles: [String: DevelopmentAndroidHLS.Role] = [:]
    let response = try DevelopmentAndroidProxyManifest.map(.init(contentType: "text/plain", data: Data(text.utf8)),
        originalURL: "https://cdn.example.test/manifest/master?original=a%2Bb",
        hlsLocalize: { url, role in roles[url] = role; return "http://127.0.0.1:12345/bound/" + String(roles.count) },
        localize: { _ in nil })
    let base = "https://cdn.example.test/manifest/"
    #expect(roles[base + "child.webm"] == .playlist)
    #expect(roles[base + "audio?sign=a%2Bb%2F"] == .playlist)
    #expect(roles[base + "plain.webp"] == .segment)
    for name in ["key.webp","encrypted.webp","ranged.webp","init.webp","fragment.webp"] { #expect(roles[base + name] == .opaque) }
    #expect(!String(decoding: response.data, as: UTF8.self).contains("cdn.example.test"))
}

@Test func developmentAndroidHLSStreamFinishesShortInputAndCancellationDoesNotEmitIt() async throws {
    let raw = Data(androidTSPrefix(0).prefix(1503))
    let output = AndroidHLSOutput()
    let stream = DevelopmentAndroidHLSStream(role: .segment, headOnly: false, rangeRequested: false,
        sendHead: { await output.head($0) }, sendBody: { await output.body($0) })
    try await stream.head(.init(statusCode: 200, contentType: "image/webp", contentLength: raw.count))
    try await stream.body(raw)
    try await stream.finish()
    #expect(await output.snapshot().1 == raw)
    let cancelled = Task { () throws -> Void in
        try await Task.sleep(for: .seconds(30))
        try await stream.body(Data([1]))
    }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await output.snapshot().1 == raw)
}
final class AndroidHLSHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    let body: Data
    let status: Int
    let extraHeaders: [String: String]
    let contentType: String
    private let lock = NSLock()
    private var requests: [String] = []

    init(body: Data, status: Int = 200, extraHeaders: [String: String] = [:], contentType: String = "image/webp") throws {
        self.body = body; self.status = status; self.extraHeaders = extraHeaders
        self.contentType = contentType
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receive(connection, accumulated: Data())
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: self.listener.port!.rawValue)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, done, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let bytes { request.append(bytes) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.lock.lock(); self.requests.append(String(decoding: request, as: UTF8.self)); self.lock.unlock()
                var response = Data("HTTP/1.1 \(self.status) Fixture\r\nContent-Type: \(self.contentType)\r\nContent-Length: \(self.body.count)\r\nConnection: close\r\n\r\n".utf8)
                let additional = self.extraHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
                if !additional.isEmpty {
                    response = Data(String(decoding: response, as: UTF8.self).replacingOccurrences(of: "Connection: close\r\n", with: additional + "Connection: close\r\n").utf8)
                }
                if !request.starts(with: Data("HEAD ".utf8)) { response.append(self.body) }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if !done && error == nil && request.count < 8192 {
                self.receive(connection, accumulated: request)
            } else { connection.cancel() }
        }
    }

    func observedRequests() -> [String] { lock.lock(); defer { lock.unlock() }; return requests }
    func stop() { listener.cancel() }
}

@Test func developmentAndroidHLSRemoteTransportPreservesSignedReferenceAndOriginalHeaders() async throws {
    let raw = androidTSPrefix(736)
    let fixture = try AndroidHLSHTTPFixture(body: raw)
    defer { fixture.stop() }
    let port = try await fixture.start()
    let output = AndroidHLSOutput()
    let stream = DevelopmentAndroidHLSStream(role: .segment, headOnly: false, rangeRequested: false,
        sendHead: { await output.head($0) }, sendBody: { await output.body($0) })
    try await DevelopmentAndroidHLSRemoteTransport.send(url: "http://127.0.0.1:\(port)/first.webp?sign=a%2Bb%2F",
        headers: ["User-Agent":"Original-Fixture-UA", "Referer":"https://original.example.test/"], role: .segment, headOnly: false,
        mapPlaylist: { _,_ in throw URLError(.badServerResponse) },
        sendHead: { try await stream.head($0) }, sendBody: { try await stream.body($0) })
    try await stream.finish()
    let result = await output.snapshot()
    #expect(result.1 == Data(raw.dropFirst(736)))
    #expect(result.0.first?.contentLength == raw.count - 736)
    let requests = fixture.observedRequests()
    #expect(requests.count == 1)
    #expect(requests[0].contains("GET /first.webp?sign=a%2Bb%2F HTTP/1.1"))
    #expect(requests[0].contains("Original-Fixture-UA") && requests[0].contains("https://original.example.test/"))
}

@Test func developmentAndroidHLSRemoteErrorBodyIsPreservedWithoutTSOverrideOrRetry() async throws {
    let raw = androidTSPrefix(736)
    let fixture = try AndroidHLSHTTPFixture(body: raw, status: 403)
    defer { fixture.stop() }
    let port = try await fixture.start()
    let output = AndroidHLSOutput()
    let stream = DevelopmentAndroidHLSStream(role: .segment, headOnly: false, rangeRequested: false,
        sendHead: { await output.head($0) }, sendBody: { await output.body($0) })
    try await DevelopmentAndroidHLSRemoteTransport.send(url: "http://127.0.0.1:\(port)/original", headers: [:], role: .segment, headOnly: false,
        mapPlaylist: { response,_ in response }, sendHead: { try await stream.head($0) }, sendBody: { try await stream.body($0) })
    try await stream.finish()
    let result = await output.snapshot()
    #expect(result.1 == raw && result.0.first?.statusCode == 403 && result.0.first?.contentType == "image/webp")
    #expect(fixture.observedRequests().count == 1)
}

@Test func developmentAndroidHLSRemoteGzipIsDecodedOnceBeforeOriginalSniff() async throws {
    let raw = androidTSPrefix(736)
    let encoded = try #require(Data(base64Encoded: "H4sIAAAAAAAC/+3OsQkAIAwAsN4mWHGTLv7/iZ4hklyQmplx7d5WwGeGu7s7AAAAjzgJ5ltIiBMAAA=="))
    let fixture = try AndroidHLSHTTPFixture(body: encoded, extraHeaders: ["Content-Encoding":"gzip"])
    defer { fixture.stop() }
    let port = try await fixture.start()
    let output = AndroidHLSOutput()
    let stream = DevelopmentAndroidHLSStream(role: .segment, headOnly: false, rangeRequested: false,
        sendHead: { await output.head($0) }, sendBody: { await output.body($0) })
    try await DevelopmentAndroidHLSRemoteTransport.send(url: "http://127.0.0.1:\(port)/encoded", headers: [:], role: .segment, headOnly: false,
        mapPlaylist: { response,_ in response }, sendHead: { try await stream.head($0) }, sendBody: { try await stream.body($0) })
    try await stream.finish()
    let result = await output.snapshot()
    #expect(result.1 == Data(raw.dropFirst(736)))
    #expect(result.0.first?.contentType == "video/mp2t" && result.0.first?.contentLength == nil)
    #expect(result.0.first?.headers.keys.contains(where: { $0.lowercased() == "content-encoding" }) == false)
}

#endif


@Test func developmentAndroidHLSOnlyAdaptsProvablyWhole206Bodies() {
    #expect(DevelopmentAndroidHLS.isWholeBodyRequest(nil))
    #expect(DevelopmentAndroidHLS.isWholeBodyRequest("bytes=0-"))
    for range in ["bytes=1-", "bytes=-500", "bytes=0-4999", "bytes=0-,1-", "invalid"] {
        #expect(!DevelopmentAndroidHLS.isWholeBodyRequest(range))
    }
    let whole = ProxyStreamingResponseHead(statusCode: 206, contentType: "image/webp", contentLength: 5000,
        headers: ["Content-Range":"bytes 0-4999/5000"])
    #expect(DevelopmentAndroidHLS.isEntireResponse(whole))
    for range in ["bytes 0-4998/5000", "bytes 1-4999/5000", "bytes 0-4999/*", "bytes 0-4999/0", "bytes 0-4999/99999999999999999999999999999", "bytes 0-4999/5000,1-2/5000"] {
        #expect(!DevelopmentAndroidHLS.isEntireResponse(.init(statusCode: 206, contentType: "image/webp", contentLength: 5000, headers: ["Content-Range":range])))
    }
    #expect(!DevelopmentAndroidHLS.isEntireResponse(.init(statusCode: 206, contentType: "image/webp", contentLength: 4999, headers: whole.headers)))
}

@Test func developmentAndroidHLSRemoteWhole206RetainsRequestAndReturnsAdvancedRepresentation() async throws {
    let raw = androidTSPrefix(736)
    let fixture = try AndroidHLSHTTPFixture(body: raw, status: 206,
        extraHeaders: ["Content-Range":"bytes 0-\(raw.count-1)/\(raw.count)", "ETag":"original-validator"])
    defer { fixture.stop() }
    let port = try await fixture.start()
    let output = AndroidHLSOutput()
    let stream = DevelopmentAndroidHLSStream(role: .segment, headOnly: false,
        rangeRequested: !DevelopmentAndroidHLS.isWholeBodyRequest("bytes=0-"),
        sendHead: { await output.head($0) }, sendBody: { await output.body($0) })
    try await DevelopmentAndroidHLSRemoteTransport.send(url: "http://127.0.0.1:\(port)/original.webp?sign=a%2Bb%2F",
        headers: ["Range":"bytes=0-"], role: .segment, headOnly: false,
        mapPlaylist: { _,_ in throw URLError(.badServerResponse) },
        sendHead: { try await stream.head($0) }, sendBody: { try await stream.body($0) })
    try await stream.finish()
    let result = await output.snapshot()
    #expect(result.0.first?.statusCode == 200 && result.0.first?.contentType == "video/mp2t")
    #expect(result.0.first?.contentLength == raw.count-736)
    #expect(result.0.first?.headers.allSatisfy { !["content-range","etag"].contains($0.key.lowercased()) } == true)
    #expect(result.1 == Data(raw.dropFirst(736)))
    #expect(fixture.observedRequests().count == 1)
    #expect(fixture.observedRequests()[0].lowercased().contains("range: bytes=0-"))
}

@Test(arguments: [752, 842, 8647], [1, 17, 1504, 8192, 16384])
func developmentAndroidHLSReadsVerifiedTSBeyondTheInitialSniff(offset: Int, chunkSize: Int) {
    var original = androidTSPrefix(offset, count: 12000)
    original.replaceSubrange(12..<16, with: Data("VP8 ".utf8))
    // The original mu3.c sniff fails here; its HLS fallback read still parses TS.
    #expect(DevelopmentAndroidHLS.transportStreamOffset(original) == nil)
    var sniffer = DevelopmentAndroidHLS.Sniffer()
    var output = Data()
    for start in stride(from: 0, to: original.count, by: chunkSize) {
        output.append(sniffer.consume(Data(original[start..<min(start + chunkSize, original.count)])))
        #expect(sniffer.prefix.count <= DevelopmentAndroidHLS.readFallbackBytes)
    }
    output.append(sniffer.finish())
    #expect(sniffer.offset == offset)
    #expect(output == Data(original.dropFirst(offset)))
}

@Test func developmentAndroidHLSFallbackPreservesUnverifiedOrOutOfWindowBytes() {
    var valid = androidTSPrefix(842, count: 12000)
    valid.replaceSubrange(12..<16, with: Data("VP8 ".utf8))
    var nonWebP = valid; nonWebP.replaceSubrange(8..<12, with: Data("WAVE".utf8))
    var incompleteSync = valid; incompleteSync[842 + 4 * 188] = 0
    var nonVP8 = valid; nonVP8.replaceSubrange(12..<16, with: Data("JUNK".utf8))
    var outsideWindow = androidTSPrefix(8648, count: 12000)
    outsideWindow.replaceSubrange(12..<16, with: Data("VP8 ".utf8))
    for original in [nonWebP, nonVP8, incompleteSync, outsideWindow, Data(valid.prefix(1504)), Data(valid.prefix(1594))] {
        var sniffer = DevelopmentAndroidHLS.Sniffer()
        var output = sniffer.consume(original)
        output.append(sniffer.finish())
        #expect(sniffer.offset == nil)
        #expect(output == original)
        #expect(sniffer.prefix.count <= DevelopmentAndroidHLS.readFallbackBytes)
    }
}

private final class AndroidHLSObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [DevelopmentAndroidHLSStream.Observation] = []
    func append(_ observation: DevelopmentAndroidHLSStream.Observation) {
        lock.withLock { observations.append(observation) }
    }
    func snapshot() -> [DevelopmentAndroidHLSStream.Observation] {
        lock.withLock { observations }
    }
}

@Test func developmentAndroidHLSFallbackUpdatesWholeResponseAndKeepsEvidence() async throws {
    let output = AndroidHLSOutput()
    let evidence = AndroidHLSObservations()
    var original = androidTSPrefix(842, count: 12000)
    original.replaceSubrange(12..<16, with: Data("VP8 ".utf8))
    let stream = DevelopmentAndroidHLSStream(role: .segment, headOnly: false, rangeRequested: false,
        sendHead: { await output.head($0) }, sendBody: { await output.body($0) }, observe: { evidence.append($0) })
    try await stream.head(ProxyStreamingResponseHead(statusCode: 206, contentType: "image/webp", contentLength: original.count,
        headers: ["Content-Range": "bytes 0-11999/12000", "ETag": "raw"], closeConnection: true))
    try await stream.body(Data(original.prefix(1504)))
    #expect(await output.snapshot().0.isEmpty)
    try await stream.body(Data(original.dropFirst(1504)))
    try await stream.finish()
    let result = await output.snapshot()
    #expect(result.0.count == 1)
    #expect(result.0[0].statusCode == 200 && result.0[0].contentType == "video/mp2t")
    #expect(result.0[0].contentLength == original.count - 842)
    #expect(result.0[0].headers["Content-Range"] == nil && result.0[0].headers["ETag"] == nil)
    #expect(result.1 == Data(original.dropFirst(842)))
    let observation = try #require(evidence.snapshot().last)
    #expect(observation.complete && observation.entireResponse && observation.status == 206)
    #expect(observation.bytes == original.count && observation.declaredBodyBytes == original.count)
    #expect(observation.offset == 842 && observation.prefix == Data(original.prefix(9400)))
}
