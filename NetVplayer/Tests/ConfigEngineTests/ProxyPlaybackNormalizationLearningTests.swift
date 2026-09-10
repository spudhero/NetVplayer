import Foundation
import Testing
import Networking
import ProxyServer

@Test func testQuarkHLSProxyReusesLearnedNormalizationDepth() async throws {
    let masterURL = "https://video-play-h-zb.drive.quark.cn/qv/hash/media.m3u8?auth_key=signed"
    let rawSegment0 = "https://video-play-h-zb.drive.quark.cn/qv/hash/media-0.ts?ct=segment0%253D"
    let normalizedSegment0 = "https://video-play-h-zb.drive.quark.cn/qv/hash/media-0.ts?ct=segment0%3D"
    let rawSegment1 = "https://video-play-h-zb.drive.quark.cn/qv/hash/media-1.ts?ct=segment1%253D"
    let normalizedSegment1 = "https://video-play-h-zb.drive.quark.cn/qv/hash/media-1.ts?ct=segment1%3D"
    let playlist = """
    #EXTM3U
    #EXTINF:4,
    media-0.ts?ct=segment0%253D
    #EXTINF:4,
    media-1.ts?ct=segment1%253D
    """

    QuarkNormalizationURLProtocol.register(responses: [
        masterURL: .init(body: playlist, statusCode: 200, contentType: "application/vnd.apple.mpegurl"),
        rawSegment0: .init(body: "bad query", statusCode: 400, contentType: "text/plain"),
        normalizedSegment0: .init(body: "segment-0", statusCode: 200, contentType: "video/mp2t"),
        rawSegment1: .init(body: "bad query", statusCode: 400, contentType: "text/plain"),
        normalizedSegment1: .init(body: "segment-1", statusCode: 200, contentType: "video/mp2t")
    ])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QuarkNormalizationURLProtocol.self]
    let handler = ProxyPlaybackHandler.make(
        httpClient: HTTPClient(session: URLSession(configuration: configuration))
    )

    let optionalMasterResponse = try await handler([
        "u64": ProxyURLCodec.encode(masterURL),
        "h64": ProxyURLCodec.encode("{}")
    ])
    let masterResponse = try #require(optionalMasterResponse)
    let rewrittenPlaylist = try #require(String(data: masterResponse.data, encoding: .utf8))
    let localSegmentURLs = rewrittenPlaylist
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { $0.hasPrefix("http://127.0.0.1:") }
    #expect(localSegmentURLs.count == 2)

    let firstParams = try proxyParameters(from: localSegmentURLs[0])
    let secondParams = try proxyParameters(from: localSegmentURLs[1])
    #expect(!(firstParams["qctx"] ?? "").isEmpty)
    #expect(firstParams["qctx"] == secondParams["qctx"])

    let optionalFirstResponse = try await handler(firstParams)
    let optionalSecondResponse = try await handler(secondParams)
    let firstResponse = try #require(optionalFirstResponse)
    let secondResponse = try #require(optionalSecondResponse)
    #expect(firstResponse.statusCode == 200)
    #expect(secondResponse.statusCode == 200)

    let requestedURLs = QuarkNormalizationURLProtocol.requestedURLs()
    #expect(requestedURLs.filter { $0 == rawSegment0 }.count == 1)
    #expect(requestedURLs.filter { $0 == normalizedSegment0 }.count == 1)
    #expect(requestedURLs.filter { $0 == rawSegment1 }.isEmpty)
    #expect(requestedURLs.filter { $0 == normalizedSegment1 }.count == 1)
}

@Test func testQuarkHLSProxyNormalizesAfterRawChildTimeout() async throws {
    let rawSegment = "https://video-play-h-zb.drive.quark.cn/qv/timeout/media-0.ts?ct=timeout%253D"
    let normalizedSegment = "https://video-play-h-zb.drive.quark.cn/qv/timeout/media-0.ts?ct=timeout%3D"
    QuarkNormalizationURLProtocol.register(responses: [
        rawSegment: .init(errorCode: .timedOut),
        normalizedSegment: .init(body: "segment-0", statusCode: 200, contentType: "video/mp2t")
    ])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QuarkNormalizationURLProtocol.self]
    let handler = ProxyPlaybackHandler.make(
        httpClient: HTTPClient(session: URLSession(configuration: configuration))
    )

    let optionalResponse = try await handler([
        "u64": ProxyURLCodec.encode(rawSegment),
        "h64": ProxyURLCodec.encode("{}"),
        "hls": "1",
        "qctx": "timeout-case"
    ])
    let response = try #require(optionalResponse)

    #expect(response.statusCode == 200)
    let requestedURLs = QuarkNormalizationURLProtocol.requestedURLs()
    #expect(requestedURLs.filter { $0 == rawSegment }.count == 1)
    #expect(requestedURLs.filter { $0 == normalizedSegment }.count == 1)
}

private func proxyParameters(from urlString: String) throws -> [String: String] {
    let components = try #require(URLComponents(string: urlString))
    return Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
}

private final class QuarkNormalizationURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let data: Data
        let statusCode: Int
        let contentType: String
        let errorCode: URLError.Code?

        init(body: String, statusCode: Int, contentType: String) {
            self.data = Data(body.utf8)
            self.statusCode = statusCode
            self.contentType = contentType
            self.errorCode = nil
        }

        init(errorCode: URLError.Code) {
            self.data = Data()
            self.statusCode = 0
            self.contentType = "application/octet-stream"
            self.errorCode = errorCode
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Stub] = [:]
    nonisolated(unsafe) private static var requests: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = Self.response(for: url.absoluteString)
            ?? Stub(body: "missing stub", statusCode: 500, contentType: "text/plain")
        if let errorCode = stub.errorCode {
            client?.urlProtocol(self, didFailWithError: URLError(errorCode))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": stub.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func register(responses: [String: Stub]) {
        lock.lock()
        defer { lock.unlock() }
        for (url, stub) in responses {
            self.responses[url] = stub
        }
        requests.removeAll { responses[$0] != nil }
    }

    static func requestedURLs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private static func response(for url: String) -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        requests.append(url)
        return responses[url]
    }
}
