import Foundation
import CryptoKit
import Testing
import Models
import Storage
import ProxyServer
@testable import MediaServerEngine

/// Explicit opt-in, bounded reads of a configured item. Uses a private copy of
/// the account and vault; never saves an account, reports progress, or logs URLs.
@Suite("Configured media server throughput", .serialized)
struct MediaServerThroughputTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NETVPLAYER_THROUGHPUT_INPUT"] != nil))
    func comparesTransportAndChunkCollection() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["NETVPLAYER_THROUGHPUT_INPUT"]))
        let domain = "MediaServerThroughput." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = MediaServerStore(storage: StorageManager(storageDirectory: root), preferences:
            .init(defaults: defaults, credentialStore: LocalCredentialStore(directory: root.appendingPathComponent("Credentials"))))
        let accountID = try #require(env["NETVPLAYER_THROUGHPUT_ACCOUNT"])
        let account = try #require(store.load().first { $0.id.uuidString.lowercased() == accountID.lowercased() })
        let client = try MediaServerClient(account: account, token: store.token(for: account))
        let itemID = try #require(env["NETVPLAYER_THROUGHPUT_ITEM"])
        let item = try await client.item(itemID)
        let info = try await client.playbackInfo(itemID)
        let source = try #require(info.MediaSources?.first)
        let sourceID = try #require(source.Id)
        let size = try #require(source.Size)
        let duration = Double(try #require(source.RunTimeTicks ?? item.RunTimeTicks)) / 10_000_000
        let fallback = client.originalRequest(item: itemID, source: sourceID, audio: false)
        let direct = source.Protocol?.lowercased() == "http" ? source.Path.flatMap(client.mediaRequest) : nil
        let request = direct ?? fallback
        var measurements: [[String: Any]] = []
        var previous: Data?
        let chunkSize = Int(env["NETVPLAYER_THROUGHPUT_BYTES"] ?? "4194304") ?? 4194304
        try #require((1...4 * 1024 * 1024).contains(chunkSize) && Int64(chunkSize) <= size)
        let pool = URLSession(configuration: .ephemeral)
        defer { pool.invalidateAndCancel() }
        let transport = MediaServerTransport()
        for mode in ["transport", "chunked", "reused", "reused", "transport"] {
            var range = request
            range.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
            let start = ContinuousClock.now
            let value: (Data, HTTPURLResponse)
            if mode == "transport" { value = try await transport.request(range, maximumBytes: chunkSize) }
            else { value = try await ThroughputChunkReader(request: range, maximumBytes: chunkSize, origin: nil, pool: mode == "reused" ? pool : nil).read() }
            try MediaServerTransport.validateRange(value.0, response: value.1, range: 0..<Int64(chunkSize), size: size)
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if let previous { #expect(value.0 == previous) }
            previous = value.0
            let row: [String: Any] = ["mode": mode, "bytes": value.0.count, "seconds": seconds,
                "bytesPerSecond": Double(value.0.count) / seconds, "status": value.1.statusCode]
            measurements.append(row)
            print("[MEDIA_THROUGHPUT] mode=\(mode) bytes=\(value.0.count) seconds=\(seconds) bytesPerSecond=\(Double(value.0.count) / seconds)")
        }
        try ProxyServer.shared.start()
        defer { ProxyServer.shared.stop() }
        let runtime = MediaServerRuntime(store: store)
        let resolved = try await runtime.resolve(.init(accountID: account.id, itemID: itemID))
        let owner = try #require(resolved.mediaServer)
        let proxy = resolved.url
        var range = URLRequest(url: try #require(URL(string: proxy)))
        range.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
        let start = ContinuousClock.now
        let value = try await URLSession.shared.data(for: range)
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(value.0 == previous)
        measurements.append(["mode": "productionProxy", "bytes": value.0.count, "seconds": seconds,
            "bytesPerSecond": Double(value.0.count) / seconds, "status": (value.1 as? HTTPURLResponse)?.statusCode ?? -1])
        if env["NETVPLAYER_THROUGHPUT_CONTINUOUS"] == "1" {
            let lower: Int64 = 64 * 1024 * 1024
            let count = 16 * 1024 * 1024
            try #require(lower + Int64(count) < size)
            range.setValue("bytes=\(lower)-\(lower + Int64(count) - 1)", forHTTPHeaderField: "Range")
            let begin = ContinuousClock.now
            let continuous = try await ThroughputChunkReader(request: range, maximumBytes: count, origin: nil).read()
            try MediaServerTransport.validateRange(continuous.0, response: continuous.1, range: lower..<lower + Int64(count), size: size)
            let elapsed = begin.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            measurements.append(["mode": "productionProxyContinuous", "bytes": count, "seconds": seconds,
                "bytesPerSecond": Double(count) / seconds, "status": continuous.1.statusCode, "offset": lower])
        }
        await runtime.release(owner.leaseID)
        let result: [String: Any] = ["testedAt": ISO8601DateFormatter().string(from: Date()),
            "kind": account.kind.rawValue, "fileBytes": size, "durationSeconds": duration,
            "averageRequiredBytesPerSecond": Double(size) / duration,
            "directPathAvailable": direct != nil, "measurements": measurements,
            "identicalBytes": true, "sha256": SHA256.hash(data: try #require(previous)).map { String(format: "%02x", $0) }.joined(),
            "credentialsSaved": false, "playbackProgressReported": false]
        if let output = env["NETVPLAYER_THROUGHPUT_REPORT"] {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
