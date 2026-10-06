import Foundation
import XCTest
@testable import Networking

final class HTTPOriginIsolationTests: XCTestCase {
    func testConstrainedClientRejectsInitialCrossOriginBeforeSendingRequest() async throws {
        OriginIsolationProtocol.reset()
        let client = makeClient(origin: "https://origin.example")
        do {
            _ = try await client.get(
                url: "https://evil.example/private",
                headers: ["Authorization": "Bearer fixture"],
                allowsProxyFallback: false
            )
            XCTFail("Expected origin mismatch")
        } catch let error as HTTPError {
            guard case .originMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(OriginIsolationProtocol.requestCount(host: "evil.example"), 0)
    }

    func testRedirectDelegateRejectsCrossOriginBeforeFollowingRequest() throws {
        let origin = URL(string: "https://origin.example/start")!
        let delegate = OriginRedirectDelegate(origin: origin)
        let task = URLSession.shared.dataTask(with: origin)
        let redirectResponse = HTTPURLResponse(
            url: origin, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let crossOriginDecision = RequestBox()
        delegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: URLRequest(url: URL(string: "https://evil.example/private")!)
        ) { crossOriginDecision.set($0) }
        XCTAssertNil(crossOriginDecision.get())

        let sameOriginDecision = RequestBox()
        let sameOriginRequest = URLRequest(url: URL(string: "https://origin.example/next")!)
        delegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: sameOriginRequest
        ) { sameOriginDecision.set($0) }
        XCTAssertEqual(sameOriginDecision.get()?.url, sameOriginRequest.url)
    }

    func testConstrainedDownloadRejectsInitialCrossOriginBeforeWritingFile() async throws {
        OriginIsolationProtocol.reset()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("origin-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let client = makeClient(origin: "https://origin.example")
        do {
            _ = try await client.downloadFile(
                url: "https://evil.example/private",
                headers: ["X-Api-Key": "fixture"],
                to: destination,
                allowsProxyFallback: false
            )
            XCTFail("Expected origin mismatch")
        } catch let error as HTTPError {
            guard case .originMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(OriginIsolationProtocol.requestCount(host: "evil.example"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testConstrainedClientAcceptsSameOriginRequest() async throws {
        OriginIsolationProtocol.reset()
        let client = makeClient(origin: "https://origin.example")
        let response = try await client.get(
            url: "https://origin.example/success",
            allowsProxyFallback: false
        )
        XCTAssertEqual(OriginIsolationProtocol.requestCount(host: "origin.example"), 1)
        XCTAssertEqual(response.text, "ok")
    }

    private func makeClient(origin: String) -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OriginIsolationProtocol.self]
        return HTTPClient(session: URLSession(configuration: configuration))
            .constrained(to: URL(string: origin)!)
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?
    func set(_ value: URLRequest?) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func get() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class OriginIsolationProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String: Int] = [:]

    static func reset() { lock.lock(); defer { lock.unlock() }; requests = [:] }
    static func requestCount(host: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return requests[host, default: 0]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock(); Self.requests[host, default: 0] += 1; Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
