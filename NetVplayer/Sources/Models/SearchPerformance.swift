import Foundation
import CryptoKit

/// A search-specific source identity. Persist only the digest, never source headers or queries.
public enum SearchPerformanceIdentity {
    public static func fingerprint(site: Site, configuration: String, runtime: String = "", quick: Bool = false) -> String {
        // Library identity already canonicalizes ext. Search also depends on the runtime,
        // crawler bundle, headers and timeout; presentation/selection changes do not reset it.
        let source = LibrarySourceIdentity.fingerprint(configurationURL: configuration.isEmpty ? "search:unconfigured" : configuration, site: site)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let headers = String(data: (try? encoder.encode(site.header)) ?? Data(), encoding: .utf8) ?? ""
        let material = [source, site.jar, headers, String(site.timeout), runtime, String(quick)]
        return SHA256.hash(data: (try? encoder.encode(material)) ?? Data())
            .map { String(format: "%02x", $0) }.joined()
    }
}

public enum SearchPerformancePhase: String, Codable, Sendable {
    case first, subsequent
}

public struct SearchPerformanceSample: Codable, Sendable {
    public let timestamp: Date
    public let phase: SearchPerformancePhase
    public let success: Bool
    public let durationMs: Double

    public init(timestamp: Date, phase: SearchPerformancePhase, success: Bool, durationMs: Double) {
        self.timestamp = timestamp
        self.phase = phase
        self.success = success
        self.durationMs = durationMs
    }
}

public struct SearchPerformanceSummary: Sendable {
    public let sampleCount: Int
    public let firstDurationMs: Double?
    public let subsequentDurationMs: Double?
    public let successProbability: Double
    public let schedulingCostMs: Double

    /// Evidence loses half its weight every three days, approaching a neutral prior.
    /// Empty successful pages carry no relevance penalty. Latency uses successes only.
    public init(samples: [SearchPerformanceSample], nextPhase: SearchPerformancePhase, now: Date = Date()) {
        var total = 0.0, successes = 0.0
        var firstWeight = 0.0, firstTotal = 0.0, laterWeight = 0.0, laterTotal = 0.0
        for sample in samples {
            let weight = pow(0.5, max(0, now.timeIntervalSince(sample.timestamp)) / (3 * 86_400))
            total += weight
            guard sample.success else { continue }
            successes += weight
            if sample.phase == .first {
                firstWeight += weight
                firstTotal += weight * sample.durationMs
            } else {
                laterWeight += weight
                laterTotal += weight * sample.durationMs
            }
        }
        sampleCount = samples.count
        firstDurationMs = firstWeight > 0 ? firstTotal / firstWeight : nil
        subsequentDurationMs = laterWeight > 0 ? laterTotal / laterWeight : nil
        successProbability = (1 + successes) / (2 + total)
        let weight = nextPhase == .first ? firstWeight : laterWeight
        let duration = nextPhase == .first ? firstTotal : laterTotal
        let predictedDuration = (2_000 + duration) / (1 + weight)
        schedulingCostMs = predictedDuration / successProbability
    }
}
