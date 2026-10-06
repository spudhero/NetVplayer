import Foundation
import CryptoKit
import Testing
import Models
import DriveEngine
@testable import PlayerEngine
@testable import ProxyServer

private struct UCTransportProbeInput: Decodable, Sendable {
    let url: String
    let headers: [String: String]
    let expected_size: Int64
}

private struct UCTransportProbeMeasurement: Codable, Sendable {
    let bytes: Int
    let elapsed: Double
    let firstByte: Double
    let status: Int
    let sha256: String
    var MiBps: Double { Double(bytes) / max(0.001, elapsed) / 1_048_576 }
}

private final class UCLoopbackProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var bytes = 0
    private var status = 0
    private var firstByte: Double = 0
    private var started = Date()
    private var digest = SHA256()
    private var continuation: CheckedContinuation<UCTransportProbeMeasurement, Error>?
    private var session: URLSession?

    init(limit: Int) { self.limit = limit }

    func read(_ request: URLRequest) async throws -> UCTransportProbeMeasurement {
        try await withCheckedThrowingContinuation { continuation in
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = 40
            config.timeoutIntervalForResource = 60
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            lock.withLock {
                self.continuation = continuation
                self.session = session
                started = Date()
            }
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { status = (response as? HTTPURLResponse)?.statusCode ?? 0 }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let finished = lock.withLock { () -> Bool in
            guard continuation != nil else { return false }
            if bytes == 0 { firstByte = Date().timeIntervalSince(started) }
            let used = data.prefix(max(0, limit - bytes))
            digest.update(data: used)
            bytes += used.count
            return bytes >= limit
        }
        if finished { finish(nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        let state = lock.withLock { () -> (CheckedContinuation<UCTransportProbeMeasurement, Error>, UCTransportProbeMeasurement, URLSession?)? in
            guard let current = continuation else { return nil }
            continuation = nil
            let result = UCTransportProbeMeasurement(bytes: bytes, elapsed: Date().timeIntervalSince(started),
                firstByte: firstByte, status: status,
                sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
            let owned = session
            session = nil
            return (current, result, owned)
        }
        guard let (continuation, result, owned) = state else { return }
        owned?.invalidateAndCancel()
        if let error, result.bytes < limit { continuation.resume(throwing: error) }
        else { continuation.resume(returning: result) }
    }
}

@Test func ucHTTPThroughputProbeWhenEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["NETVPLAYER_UC_TRANSPORT_PROBE"] == "1" else { return }
    let inputPath = try #require(environment["NETVPLAYER_UC_TRANSPORT_REQUEST"])
    let outputPath = try #require(environment["NETVPLAYER_UC_TRANSPORT_OUTPUT"])
    let input = try JSONDecoder().decode(UCTransportProbeInput.self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
    try #require(URL(string: input.url)?.scheme == "https")
    try #require(URL(string: input.url)?.host?.hasSuffix(".drive.uc.cn") == true)
    let start: Int64 = 32 * 1024 * 1024
    let segmentKiB = min(4_096, max(64,
        environment["NETVPLAYER_UC_TRANSPORT_SEGMENT_KIB"].flatMap(Int.init) ?? 512))
    let segment = segmentKiB * 1024
    let count = min(32, max(1,
        environment["NETVPLAYER_UC_TRANSPORT_COUNT"].flatMap(Int.init) ?? 16))
    let targetBytes = segment * count
    let began = Date()
    let blocks = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
        for index in 0..<count {
            group.addTask {
                var headers = input.headers
                let offset = start + Int64(index * segment)
                headers["Range"] = "bytes=\(offset)-\(offset + Int64(segment) - 1)"
                let result = try await CurlRangeTransport.get(url: input.url, headers: headers, timeout: 30)
                guard result.response.statusCode == 206, result.response.data.count == segment else {
                    throw NSError(domain: "UCTransportProbe", code: result.response.statusCode)
                }
                return (index, result.response.data)
            }
        }
        var blocks: [(Int, Data)] = []
        for try await block in group { blocks.append(block) }
        return blocks.sorted { $0.0 < $1.0 }
    }
    let directElapsed = Date().timeIntervalSince(began)
    let directBytes = blocks.reduce(into: Data()) { $0.append($1.1) }
    let direct = UCTransportProbeMeasurement(bytes: directBytes.count, elapsed: directElapsed, firstByte: 0,
        status: 206, sha256: SHA256.hash(data: directBytes).map { String(format: "%02x", $0) }.joined())
    let directMode = "curl\(count)x\(segmentKiB)KiB"
    print("[UC_TRANSPORT_PROBE] mode=\(directMode) bytes=\(direct.bytes) seconds=\(direct.elapsed) MiBps=\(direct.MiBps)")

    let server = ProxyServer()
    try server.start()
    defer { server.stop() }
    let original = PlaySpec(url: input.url, contentLength: input.expected_size, headers: input.headers,
        metadata: [DrivePlaybackMetadataKey.provider: DriveProvider.uc.rawValue,
                   DrivePlaybackMetadataKey.route: DrivePlaybackRoute.ucOriginalProxy,
                   DrivePlaybackMetadataKey.size: String(input.expected_size)])
    let relay = try #require(LiveHLSRelayPolicy.localStreamRelaySpec(from: original, proxyServer: server))
    defer { server.unregisterRemoteStream(forLocalURL: relay.url) }
    var request = URLRequest(url: try #require(URL(string: relay.url)))
    request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
    let loopback = try await UCLoopbackProbeDelegate(limit: targetBytes).read(request)
    #expect(loopback.status == 206)
    #expect(loopback.bytes == targetBytes)
    #expect(loopback.sha256 == direct.sha256)
    print("[UC_TRANSPORT_PROBE] mode=currentRelay bytes=\(loopback.bytes) seconds=\(loopback.elapsed) MiBps=\(loopback.MiBps) hashMatches=\(loopback.sha256 == direct.sha256)")
    let report = [directMode: direct, "currentRelay": loopback]
    try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
}
