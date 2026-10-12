import Foundation
import Networking
import ProxyServer
import Testing

@Suite(.serialized)
struct QuarkSegmentRecoveryTests {
    @Test func retriesTransientFailureBeforeResponse() async throws {
        let result = try await run(.timeoutOnce)
        #expect(result.handled)
        #expect(result.heads == 1)
        #expect(result.data == Data("parttail".utf8))
        #expect(SegmentRecoveryProtocol.requestCount == 2)
    }

    @Test func boundsTransientRetries() async throws {
        await #expect(throws: URLError.self) { try await run(.alwaysTimeout) }
        #expect(SegmentRecoveryProtocol.requestCount == 2)
    }

    @Test func neverReplaysAfterResponseStarted() async throws {
        let recorder = SegmentRecoveryRecorder()
        await #expect(throws: URLError.self) {
            try await run(.partialTimeout, recorder: recorder, encodedQuery: "segment%253D")
        }
        let snapshot = await recorder.snapshot()
        #expect(snapshot.heads == 1)
        #expect(snapshot.data == Data("part".utf8))
        #expect(SegmentRecoveryProtocol.requestCount == 1)
    }

    @Test func cancellationDoesNotRetry() async throws {
        await #expect(throws: URLError.self) { try await run(.cancelled) }
        #expect(SegmentRecoveryProtocol.requestCount == 1)
    }

    private func run(
        _ behavior: SegmentRecoveryProtocol.Behavior,
        recorder: SegmentRecoveryRecorder = SegmentRecoveryRecorder(),
        encodedQuery: String = "segment%3D"
    ) async throws -> (handled: Bool, heads: Int, data: Data) {
        SegmentRecoveryProtocol.configure(behavior)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SegmentRecoveryProtocol.self]
        let client = HTTPClient(session: URLSession(configuration: configuration)).withExplicitProxy(nil)
        let handler = ProxyPlaybackHandler.makeHandlers(httpClient: client, streamChunkSize: 4).streaming
        let handled = try await handler(
            [
                "u64": ProxyURLCodec.encode("https://video-h-jkdb-zb.drive.quark.cn/qv/segment.ts?ct=\(encodedQuery)"),
                "h64": ProxyURLCodec.encode("{}"),
                "hls": "1"
            ],
            { _ in await recorder.recordHead() },
            { data in await recorder.append(data) }
        )
        let snapshot = await recorder.snapshot()
        return (handled, snapshot.heads, snapshot.data)
    }
}

private actor SegmentRecoveryRecorder {
    private var heads = 0
    private var data = Data()
    func recordHead() { heads += 1 }
    func append(_ chunk: Data) { data.append(chunk) }
    func snapshot() -> (heads: Int, data: Data) { (heads, data) }
}

private final class SegmentRecoveryProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior { case timeoutOnce, alwaysTimeout, partialTimeout, cancelled }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var behavior = Behavior.timeoutOnce
    nonisolated(unsafe) private static var count = 0
    private var completion: DispatchWorkItem?

    static var requestCount: Int { lock.withLock { count } }
    static func configure(_ value: Behavior) {
        lock.withLock { behavior = value; count = 0 }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (behavior, attempt) = Self.lock.withLock {
            Self.count += 1
            return (Self.behavior, Self.count)
        }
        if behavior == .cancelled {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if behavior == .alwaysTimeout || (behavior == .timeoutOnce && attempt == 1) {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "video/mp2t", "Content-Length": "8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("part".utf8))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if behavior == .partialTimeout && attempt == 1 {
                self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            } else {
                self.client?.urlProtocol(self, didLoad: Data("tail".utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        completion = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    override func stopLoading() { completion?.cancel() }
}
