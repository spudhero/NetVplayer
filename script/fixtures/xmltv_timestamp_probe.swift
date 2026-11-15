import CryptoKit
import Darwin
import Foundation
import Models

#if XMLTV_CACHE_DIAGNOSTICS
// Used only by a separately instrumented build, never by timed variants.
enum XMLTVCacheProbeCounters {
    nonisolated(unsafe) static var hits = 0
    nonisolated(unsafe) static var misses = 0
    nonisolated(unsafe) static var peakEntries = 0
}
#endif

/// Links the unmodified production parser (or the recorded baseline) into an
/// isolated CLI. No repository, preferences, account, network or UI is used.
@main
enum XMLTVTimestampProbe {
    static func cpu(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { fatalError("usage: probe feed.xml window|all") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var digest = SHA256(), count = 0, batches = 0, maxBatch = 0
        let window = args[2] == "window"
            ? DateInterval(start: Date(timeIntervalSince1970: 1_790_812_800), duration: 2 * 86_400) : nil
        var before = rusage(), after = rusage()
        guard getrusage(RUSAGE_SELF, &before) == 0 else { fatalError("getrusage failed") }
        let start = ProcessInfo.processInfo.systemUptime
        var status = "success"
        var channels: [String: String] = [:]
        do {
            channels = try XMLTVStreamingParser.parse(file: URL(fileURLWithPath: args[1]), window: window) { batch in
                // Digest every Codable field of every item, preserving batch/order,
                // followed by all channel IDs/names, rather than sampling rows.
                digest.update(data: try encoder.encode(batch))
                digest.update(data: Data([10]))
                count += batch.count; batches += 1; maxBatch = max(maxBatch, batch.count)
            }
        } catch let error as EPGImportError {
            status = String(describing: error)
        }
        digest.update(data: try encoder.encode(channels))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard getrusage(RUSAGE_SELF, &after) == 0 else { fatalError("getrusage failed") }
        var result: [String: Any] = [
            "status": status, "programmes": count, "channels": channels.count,
            "batches": batches, "maxBatch": maxBatch,
            "fullOutputSHA256": digest.finalize().map { String(format: "%02x", $0) }.joined(),
            "wallSeconds": elapsed, "cpuSeconds": cpu(after) - cpu(before),
            "peakRSSBytes": after.ru_maxrss
        ]
        #if XMLTV_CACHE_DIAGNOSTICS
        result["cacheHits"] = XMLTVCacheProbeCounters.hits
        result["cacheMisses"] = XMLTVCacheProbeCounters.misses
        result["cachePeakEntries"] = XMLTVCacheProbeCounters.peakEntries
        #endif
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
