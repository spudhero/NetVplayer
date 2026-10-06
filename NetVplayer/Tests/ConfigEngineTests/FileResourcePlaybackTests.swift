import Foundation
import Testing
import Models
import PlayerEngine
import ProxyServer

@Test func registeredNASResourcesPlayDirectlyAndKeepLoopbackProtection() async throws {
    let server = ProxyServer(); try server.start(); defer { server.stop() }
    let url = try server.registerSeekableResource(.init(size: 1024) { range in
        Data(repeating: 42, count: range.count)
    })
    let spec = PlaySpec(url: url)
    #expect(PlaybackProxyPolicy.bypassReason(for: spec, proxyServer: server) == .localFileResource)
    #expect(!PlaybackProxyPolicy.shouldAttemptWebSniff(for: spec, sourceResolvedDirectMedia: false, proxyServer: server))
    #expect(PlaybackProxyPolicy.mpvOptionsForDirectPlayback(reason: .localFileResource, activeProxyPort: 7897).isEmpty)
    var request = URLRequest(url: URL(string: url)!)
    request.setValue("bytes=100-199", forHTTPHeaderField: "Range")
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 206)
    #expect(data == Data(repeating: 42, count: 100))
    #expect(throws: ProxyAccessError.self) { try ProxyAccessPolicy.validateTargetURL(url) }
    for untrusted in [
        url + "&other=1", url + "#fragment",
        url.replacingOccurrences(of: "127.0.0.1", with: "localhost"),
        url.replacingOccurrences(of: ":\(server.port)/", with: ":1234/"),
        "http://127.0.0.1:\(server.port)/resource?id=\(UUID().uuidString)",
        "http://127.0.0.1:\(server.port)/admin"
    ] {
        #expect(!server.isRegisteredSeekableResource(url: untrusted))
        #expect(PlaybackProxyPolicy.bypassReason(for: PlaySpec(url: untrusted), proxyServer: server) == nil)
    }
    server.unregisterSeekableResource(url: url)
    #expect(PlaybackProxyPolicy.bypassReason(for: spec, proxyServer: server) == nil)
    #expect((try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode == 404)
}

@Test func boundedNASStreamingAmortizesRoundTripsAndPreservesLargeOffsets() async throws {
    let server = ProxyServer(); try server.start(); defer { server.stop() }
    let reads = NASRangeReads()
    let resource = SeekableResource(size: 5_000_000_000, readChunkSize: 4 * 1024 * 1024) { range in
        await reads.record(range)
        return Data(repeating: UInt8(range.lowerBound % 256), count: range.count)
    }
    let url = try server.registerSeekableResource(resource)
    var request = URLRequest(url: URL(string: url)!)
    let start: Int64 = 4_000_000_000
    let count = 9 * 1024 * 1024 + 17
    request.setValue("bytes=\(start)-\(start + Int64(count) - 1)", forHTTPHeaderField: "Range")
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 206)
    #expect(data.count == count)
    let ranges = await reads.ranges
    #expect(ranges.count < 6)
    #expect(ranges.first?.lowerBound == start)
    #expect(ranges.last?.upperBound == start + Int64(count))
    #expect(ranges.allSatisfy { !$0.isEmpty && $0.count <= 4 * 1024 * 1024 })
    #expect(ranges.first?.count == 512 * 1024)
    for range in ranges {
        let offset = Int(range.lowerBound - start)
        #expect(data[offset] == UInt8(range.lowerBound % 256))
    }
    #expect(SeekableResource(size: 1, readChunkSize: Int64.max, read: { _ in Data() }).readChunkSize == 4 * 1024 * 1024)
}

private actor NASRangeReads {
    var ranges: [Range<Int64>] = []
    func record(_ range: Range<Int64>) { ranges.append(range) }
}
